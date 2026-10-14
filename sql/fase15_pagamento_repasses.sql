-- Fase 15: pagamento único, comissão por item e extrato de repasses.
-- Modelo: o cliente paga uma vez, na conta da cooperativa. O sistema grava, em cada item,
-- quanto é do vendedor e quanto é comissão. Ao pagar, gera o extrato (repasses) de cada vendedor
-- e da cooperativa. Devolução reembolsada estorna todo o extrato da compra: ninguém fica com comissão.
-- Cupom: o desconto é debitado de quem cadastrou o cupom (cooperativa ou vendedor).
-- Rode no SQL Editor do Supabase e responda "feito".

-- 0. Verificação
do $$
begin
  if to_regclass('public.devolucoes_loja') is null
     or to_regprocedure('privado.comissao_vendedor(uuid)') is null
     or to_regprocedure('privado.confere_vendedor_item()') is null then
    raise exception 'Fases anteriores não encontradas. Aplique as fases 7 a 14 antes desta.';
  end if;
end $$;

-- 1. Item do pedido: vendedor, comissão e valor líquido do vendedor, gravados na compra
alter table public.pedido_itens
  add column if not exists vendedor_id uuid references public.loja_vendedores(id) on delete restrict,
  add column if not exists comissao_percentual numeric(5,2),
  add column if not exists comissao_centavos integer not null default 0 check (comissao_centavos >= 0),
  add column if not exists liquido_vendedor_centavos integer not null default 0;

create index if not exists pedido_itens_vendedor_idx on public.pedido_itens (vendedor_id);

-- Mesmo gatilho da fase 14, agora também calcula a comissão do item no momento da compra.
create or replace function privado.confere_vendedor_item()
returns trigger language plpgsql security definer set search_path = public, privado
as $$
declare
  v_vendedor uuid;
  v_pct numeric;
  v_bruto integer;
begin
  select p.vendedor_id into v_vendedor from public.loja_produtos p where p.id = new.produto_id;
  if v_vendedor is not null and not privado.vendedor_aprovado(v_vendedor) then
    raise exception 'Um produto deste pedido não está mais disponível. Retire-o do carrinho e tente de novo.';
  end if;

  v_bruto := new.preco_unitario_centavos * new.quantidade;
  if v_vendedor is null then
    new.vendedor_id := null;
    new.comissao_percentual := 0;
    new.comissao_centavos := 0;
    new.liquido_vendedor_centavos := v_bruto;
  else
    v_pct := privado.comissao_vendedor(v_vendedor);
    new.vendedor_id := v_vendedor;
    new.comissao_percentual := v_pct;
    new.comissao_centavos := round(v_bruto * v_pct / 100)::integer;
    new.liquido_vendedor_centavos := v_bruto - new.comissao_centavos;
  end if;
  return new;
end $$;

-- 2. Cupom: quem cadastrou (null = cooperativa)
alter table public.cupons_loja
  add column if not exists vendedor_id uuid references public.loja_vendedores(id) on delete restrict;

-- 3. Extrato de repasses
create table if not exists public.loja_repasses (
  id uuid primary key default gen_random_uuid(),
  vendedor_id uuid references public.loja_vendedores(id) on delete restrict, -- null = cooperativa
  pedido_id uuid not null references public.pedidos(id) on delete restrict,
  devolucao_id uuid references public.devolucoes_loja(id) on delete restrict,
  tipo text not null check (tipo in ('venda', 'comissao', 'frete', 'desconto', 'estorno')),
  valor_centavos integer not null,
  status text not null default 'pendente' check (status in ('pendente', 'pago')),
  criado_em timestamptz not null default now(),
  pago_em timestamptz
);

create index if not exists loja_repasses_vendedor_idx on public.loja_repasses (vendedor_id, status);
create index if not exists loja_repasses_pedido_idx on public.loja_repasses (pedido_id);

alter table public.loja_repasses enable row level security;

drop policy if exists repasses_admin on public.loja_repasses;
create policy repasses_admin on public.loja_repasses for all to authenticated
  using (privado.eh_admin()) with check (privado.eh_admin());

drop policy if exists repasses_vendedor_ler on public.loja_repasses;
create policy repasses_vendedor_ler on public.loja_repasses for select to authenticated
  using (vendedor_id in (select v.id from public.loja_vendedores v where v.usuario_id = auth.uid()));

-- Só os gatilhos gravam o extrato. Ninguém grava direto.

-- 4. Pedido pago: gera o extrato da compra (uma vez)
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

  -- Frete pago pelo cliente fica com a cooperativa (frete por vendedor vem na fase 16)
  if coalesce(new.frete_centavos, 0) > 0 then
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

drop trigger if exists pedidos_gera_repasses on public.pedidos;
create trigger pedidos_gera_repasses
  after update of status on public.pedidos
  for each row execute function privado.gera_repasses_pedido();

-- 5. Devolução reembolsada: estorna todo o extrato da compra (ninguém fica com comissão)
create or replace function privado.estorna_repasses_devolucao()
returns trigger language plpgsql security definer set search_path = public, privado
as $$
begin
  if new.status <> 'reembolsada' or old.status = 'reembolsada' then return new; end if;
  if exists (select 1 from public.loja_repasses r where r.devolucao_id = new.id) then return new; end if;

  insert into public.loja_repasses (vendedor_id, pedido_id, devolucao_id, tipo, valor_centavos, status)
  select r.vendedor_id, r.pedido_id, new.id, 'estorno', -r.valor_centavos,
         case when r.vendedor_id is null then 'pago' else 'pendente' end
    from public.loja_repasses r
   where r.pedido_id = new.pedido_id and r.devolucao_id is null;

  return new;
end $$;

drop trigger if exists devolucoes_estorna_repasses on public.devolucoes_loja;
create trigger devolucoes_estorna_repasses
  after update of status on public.devolucoes_loja
  for each row execute function privado.estorna_repasses_devolucao();

-- 6. Funções de tela
-- Extrato do próprio vendedor
create or replace function public.meu_extrato_loja()
returns table (criado_em timestamptz, codigo text, tipo text, valor_centavos integer, status text)
language sql stable security definer set search_path = public, privado
as $$
  select r.criado_em, p.codigo, r.tipo, r.valor_centavos, r.status
    from public.loja_repasses r
    join public.pedidos p on p.id = r.pedido_id
   where r.vendedor_id in (select v.id from public.loja_vendedores v where v.usuario_id = auth.uid())
   order by r.criado_em desc
   limit 300
$$;

-- Saldo de cada vendedor (administrador)
create or replace function public.repasses_resumo_loja()
returns table (vendedor_id uuid, nome_loja text, situacao text, saldo_pendente_centavos integer, saldo_pago_centavos integer)
language plpgsql stable security definer set search_path = public, privado
as $$
begin
  if not privado.eh_admin() then
    raise exception 'Apenas administradores veem os repasses.';
  end if;
  return query
    select v.id, v.nome_loja, v.status,
           coalesce(sum(r.valor_centavos) filter (where r.status = 'pendente'), 0)::integer,
           coalesce(sum(r.valor_centavos) filter (where r.status = 'pago'), 0)::integer
      from public.loja_vendedores v
      left join public.loja_repasses r on r.vendedor_id = v.id
     group by v.id, v.nome_loja, v.status
     order by v.nome_loja;
end $$;

-- Marca como pago o saldo pendente de um vendedor. O dinheiro é transferido fora do app (Pix ou outro meio).
create or replace function public.pagar_repasses_loja(p_vendedor uuid)
returns integer
language plpgsql security definer set search_path = public, privado
as $$
declare
  v_saldo integer;
begin
  if not privado.eh_admin() then
    raise exception 'Apenas administradores registram repasses.';
  end if;

  select coalesce(sum(r.valor_centavos), 0)::integer into v_saldo
    from public.loja_repasses r
   where r.vendedor_id = p_vendedor and r.status = 'pendente';

  if v_saldo <= 0 then
    raise exception 'Não há valor a repassar. Se o saldo for negativo, o vendedor deve à cooperativa.';
  end if;

  update public.loja_repasses set status = 'pago', pago_em = now()
   where vendedor_id = p_vendedor and status = 'pendente';

  perform privado.auditar('repasse_pago', 'loja_vendedor', p_vendedor::text,
    jsonb_build_object('valor_centavos', v_saldo));
  return v_saldo;
end $$;

-- 7. Permissões
revoke execute on function public.meu_extrato_loja() from anon, public;
revoke execute on function public.repasses_resumo_loja() from anon, public;
revoke execute on function public.pagar_repasses_loja(uuid) from anon, public;
grant execute on function public.meu_extrato_loja() to authenticated;
grant execute on function public.repasses_resumo_loja() to authenticated;
grant execute on function public.pagar_repasses_loja(uuid) to authenticated;
