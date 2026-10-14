-- Fase 16 (parte 1): envios por vendedor, frete grátis por vendedor e frete no extrato de quem envia.
-- Cada vendedor envia os próprios itens. O frete pago por um envio vai para quem envia.
-- Produtos da cooperativa seguem a regra de frete grátis da configuração da loja.
-- Os adaptadores dos provedores de entrega e o checkout com vários envios vêm na parte 2.
-- Rode no SQL Editor do Supabase e responda "feito".

-- 0. Verificação
do $$
begin
  if to_regclass('public.loja_repasses') is null or to_regprocedure('privado.gera_repasses_pedido()') is null then
    raise exception 'Fase 15 não encontrada. Aplique a fase 15 antes desta.';
  end if;
end $$;

-- 1. Regra de frete grátis por vendedor (null = sem frete grátis)
alter table public.loja_vendedores
  add column if not exists frete_gratis_minimo_centavos integer
    check (frete_gratis_minimo_centavos is null or frete_gratis_minimo_centavos >= 0);

-- Regra da cooperativa, na configuração da loja. A tabela só aceita chaves listadas, então a lista é ampliada.
alter table public.loja_configuracoes drop constraint if exists loja_configuracoes_chave_check;
alter table public.loja_configuracoes add constraint loja_configuracoes_chave_check check (chave = any (array[
  'nome_loja', 'endereco_retirada', 'horario_retirada', 'minutos_expiracao_pedido', 'url_publica_app',
  'mp_public_key', 'cep_origem', 'entrega_local_ativa', 'entrega_local_ceps', 'taxa_entrega_local_centavos',
  'melhor_envio_sandbox',
  'fiscal_ativo', 'fiscal_ambiente', 'fiscal_cnpj', 'fiscal_razao_social', 'fiscal_ie', 'fiscal_regime',
  'fiscal_logradouro', 'fiscal_numero', 'fiscal_bairro', 'fiscal_municipio', 'fiscal_uf', 'fiscal_cep',
  'fiscal_natureza_operacao', 'fiscal_cfop', 'fiscal_csosn', 'fiscal_cst_icms', 'fiscal_icms_aliquota',
  'fiscal_origem', 'fiscal_cst_pis', 'fiscal_cst_cofins',
  'comissao_padrao_percentual',
  'frete_gratis_minimo_centavos'
]::text[]));

-- 2. Envios: um por vendedor em cada pedido (vendedor_id nulo = cooperativa)
create table if not exists public.pedido_envios (
  id uuid primary key default gen_random_uuid(),
  pedido_id uuid not null references public.pedidos(id) on delete cascade,
  vendedor_id uuid references public.loja_vendedores(id) on delete restrict, -- null = cooperativa
  servico text,
  prazo_dias smallint,
  frete_centavos integer not null default 0 check (frete_centavos >= 0),
  codigo_rastreio text,
  status text not null default 'aguardando'
    check (status in ('aguardando', 'enviado', 'entregue', 'cancelado')),
  criado_em timestamptz not null default now(),
  enviado_em timestamptz,
  entregue_em timestamptz
);

create index if not exists pedido_envios_pedido_idx on public.pedido_envios (pedido_id);
create index if not exists pedido_envios_vendedor_idx on public.pedido_envios (vendedor_id);

alter table public.pedido_envios enable row level security;

drop policy if exists envios_admin on public.pedido_envios;
create policy envios_admin on public.pedido_envios for all to authenticated
  using (privado.eh_admin()) with check (privado.eh_admin());

drop policy if exists envios_comprador_ler on public.pedido_envios;
create policy envios_comprador_ler on public.pedido_envios for select to authenticated
  using (exists (select 1 from public.pedidos p where p.id = pedido_envios.pedido_id and p.usuario_id = auth.uid()));

drop policy if exists envios_vendedor_ler on public.pedido_envios;
create policy envios_vendedor_ler on public.pedido_envios for select to authenticated
  using (vendedor_id in (select v.id from public.loja_vendedores v where v.usuario_id = auth.uid()));

-- 3. Pedidos antigos: um envio da cooperativa com o frete e a situação que o pedido já tinha
insert into public.pedido_envios (pedido_id, vendedor_id, servico, prazo_dias, frete_centavos, codigo_rastreio, status, enviado_em, entregue_em)
select p.id, null, p.frete_servico, p.prazo_dias, coalesce(p.frete_centavos, 0), p.codigo_rastreio,
       case when p.status in ('entregue', 'retirado') then 'entregue'
            when p.status = 'enviado' then 'enviado'
            when p.status in ('cancelado', 'expirado') then 'cancelado'
            else 'aguardando' end,
       case when p.status in ('enviado', 'entregue') then p.atualizado_em end,
       p.entregue_em
  from public.pedidos p
 where p.status not in ('aguardando_pagamento')
   and not exists (select 1 from public.pedido_envios e where e.pedido_id = p.id);

-- 4. Extrato: o frete vai para quem envia (cada envio gera uma linha de frete)
create or replace function privado.gera_repasses_pedido()
returns trigger language plpgsql security definer set search_path = public, privado
as $$
declare
  v_dono uuid;
begin
  if new.status <> 'pago' or old.status = 'pago' then return new; end if;
  if exists (select 1 from public.loja_repasses r where r.pedido_id = new.id) then return new; end if;

  -- Venda: uma linha por vendedor (líquido) e uma para a cooperativa (produtos próprios)
  insert into public.loja_repasses (vendedor_id, pedido_id, tipo, valor_centavos, status)
  select i.vendedor_id, new.id, 'venda', sum(i.liquido_vendedor_centavos)::integer,
         case when i.vendedor_id is null then 'pago' else 'pendente' end
    from public.pedido_itens i
   where i.pedido_id = new.id
   group by i.vendedor_id;

  -- Comissão da cooperativa sobre os itens de vendedor
  insert into public.loja_repasses (vendedor_id, pedido_id, tipo, valor_centavos, status)
  select null, new.id, 'comissao', x.total, 'pago'
    from (select coalesce(sum(i.comissao_centavos), 0)::integer as total
            from public.pedido_itens i where i.pedido_id = new.id) x
   where x.total > 0;

  -- Frete: uma linha por envio, para quem envia. Pedido sem envios (antigo) segue para a cooperativa.
  if exists (select 1 from public.pedido_envios e where e.pedido_id = new.id) then
    insert into public.loja_repasses (vendedor_id, pedido_id, tipo, valor_centavos, status)
    select e.vendedor_id, new.id, 'frete', e.frete_centavos,
           case when e.vendedor_id is null then 'pago' else 'pendente' end
      from public.pedido_envios e
     where e.pedido_id = new.id and e.frete_centavos > 0;
  elsif coalesce(new.frete_centavos, 0) > 0 then
    insert into public.loja_repasses (vendedor_id, pedido_id, tipo, valor_centavos, status)
    values (null, new.id, 'frete', new.frete_centavos, 'pago');
  end if;

  -- Desconto: debitado de quem cadastrou o cupom
  if coalesce(new.desconto_centavos, 0) > 0 then
    select c.vendedor_id into v_dono from public.cupons_loja c where c.id = new.cupom_id;
    insert into public.loja_repasses (vendedor_id, pedido_id, tipo, valor_centavos, status)
    values (v_dono, new.id, 'desconto', -new.desconto_centavos,
            case when v_dono is null then 'pago' else 'pendente' end);
  end if;

  return new;
end $$;

-- 5. Funções do vendedor
-- Regra de frete grátis dos itens do próprio vendedor (valor vazio = sem frete grátis)
create or replace function public.definir_frete_gratis_vendedor_loja(p_minimo_centavos integer)
returns public.loja_vendedores
language plpgsql security definer set search_path = public, privado
as $$
declare v public.loja_vendedores;
begin
  if p_minimo_centavos is not null and p_minimo_centavos < 0 then
    raise exception 'O valor mínimo para frete grátis não pode ser negativo.';
  end if;
  update public.loja_vendedores set frete_gratis_minimo_centavos = p_minimo_centavos
   where usuario_id = auth.uid() and status = 'aprovado'
  returning * into v;
  if v.id is null then
    raise exception 'Só vendedores aprovados definem regras de frete.';
  end if;
  perform privado.auditar('frete_gratis_vendedor_alterado', 'loja_vendedor', v.id::text,
    jsonb_build_object('minimo_centavos', p_minimo_centavos));
  return v;
end $$;

-- Vendedor registra o envio do próprio pacote com o código de rastreio
create or replace function public.marcar_envio_vendedor_loja(p_envio uuid, p_codigo text)
returns public.pedido_envios
language plpgsql security definer set search_path = public, privado
as $$
declare
  v public.pedido_envios;
  v_codigo text := nullif(trim(coalesce(p_codigo, '')), '');
begin
  if v_codigo is null or char_length(v_codigo) > 60 then
    raise exception 'Informe o código de rastreio (até 60 caracteres).';
  end if;

  update public.pedido_envios e
     set status = 'enviado', codigo_rastreio = v_codigo, enviado_em = now()
   where e.id = p_envio
     and e.status = 'aguardando'
     and e.vendedor_id in (select x.id from public.loja_vendedores x where x.usuario_id = auth.uid() and x.status = 'aprovado')
  returning * into v;
  if v.id is null then
    raise exception 'Envio não encontrado, já enviado ou não é da sua loja.';
  end if;

  perform privado.auditar('envio_vendedor_marcado', 'pedido_envio', v.id::text, jsonb_build_object('pedido', v.pedido_id));
  return v;
end $$;

-- Envios do próprio vendedor
create or replace function public.meus_envios_loja()
returns table (id uuid, pedido_codigo text, criado_em timestamptz, frete_centavos integer, status text, codigo_rastreio text, servico text, prazo_dias smallint)
language sql stable security definer set search_path = public, privado
as $$
  select e.id, p.codigo, e.criado_em, e.frete_centavos, e.status, e.codigo_rastreio, e.servico, e.prazo_dias
    from public.pedido_envios e
    join public.pedidos p on p.id = e.pedido_id
   where e.vendedor_id in (select v.id from public.loja_vendedores v where v.usuario_id = auth.uid())
   order by e.criado_em desc
   limit 300
$$;

-- 6. Permissões
revoke execute on function public.definir_frete_gratis_vendedor_loja(integer) from anon, public;
revoke execute on function public.marcar_envio_vendedor_loja(uuid, text) from anon, public;
revoke execute on function public.meus_envios_loja() from anon, public;
grant execute on function public.definir_frete_gratis_vendedor_loja(integer) to authenticated;
grant execute on function public.marcar_envio_vendedor_loja(uuid, text) to authenticated;
grant execute on function public.meus_envios_loja() to authenticated;
