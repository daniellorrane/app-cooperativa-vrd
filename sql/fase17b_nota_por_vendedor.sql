-- Fase 17 (parte 2): nota fiscal por vendedor.
-- Cada pedido gera uma nota para a cooperativa (produtos dela) e uma para cada vendedor (produtos dele).
-- A nota de cada vendedor sai pela conta de emissão dele (token do Focus NFe guardado no Vault), com os dados fiscais dele.
-- Frete entra na nota de quem envia. Cupom de vendedor reduz a nota do vendedor. Cupom da cooperativa é rateado pelo subtotal de cada grupo.
-- Vender exige CNPJ (MEI também tem CNPJ). Emissão de vendedor só liga com CNPJ, dados fiscais e token conectados.
-- Rode no SQL Editor do Supabase e responda "feito".

-- 0. Verificação
do $$
begin
  if to_regclass('public.pedido_envios') is null
     or to_regprocedure('privado.eh_admin()') is null
     or to_regclass('vault.secrets') is null then
    raise exception 'Fase 17 (parte 1) não encontrada. Aplique a parte 1 antes desta.';
  end if;
end $$;

-- 1. Dados fiscais de cada vendedor
alter table public.loja_vendedores
  add column if not exists fiscal_razao_social text,
  add column if not exists fiscal_ie text,
  add column if not exists fiscal_regime text check (fiscal_regime is null or fiscal_regime in ('simples', 'normal')),
  add column if not exists fiscal_logradouro text,
  add column if not exists fiscal_numero text,
  add column if not exists fiscal_bairro text,
  add column if not exists fiscal_municipio text,
  add column if not exists fiscal_uf text check (fiscal_uf is null or fiscal_uf ~ '^[A-Z]{2}$'),
  add column if not exists fiscal_cep text check (fiscal_cep is null or fiscal_cep ~ '^[0-9]{8}$'),
  add column if not exists fiscal_natureza_operacao text not null default 'Venda de mercadoria',
  add column if not exists fiscal_cfop text,
  add column if not exists fiscal_csosn text,
  add column if not exists fiscal_cst_icms text,
  add column if not exists fiscal_icms_aliquota text,
  add column if not exists fiscal_origem text,
  add column if not exists fiscal_cst_pis text,
  add column if not exists fiscal_cst_cofins text,
  add column if not exists fiscal_ambiente text not null default 'homologacao' check (fiscal_ambiente in ('homologacao', 'producao')),
  add column if not exists fiscal_ativo boolean not null default false,
  add column if not exists fiscal_token_configurado boolean not null default false;

-- 2. Notas por pedido e por grupo (vendedor_id nulo = cooperativa)
create table if not exists public.pedido_notas (
  id uuid primary key default gen_random_uuid(),
  pedido_id uuid not null references public.pedidos(id) on delete cascade,
  vendedor_id uuid references public.loja_vendedores(id) on delete restrict,
  status text not null default 'processando' check (status in ('processando', 'autorizada', 'erro', 'cancelada')),
  ref text,
  tentativas integer not null default 0,
  numero text,
  chave text,
  danfe text,
  erro text check (erro is null or length(erro) <= 1000),
  valor_centavos integer not null default 0 check (valor_centavos >= 0),
  criado_em timestamptz not null default now(),
  atualizada_em timestamptz not null default now()
);

create unique index if not exists pedido_notas_grupo_uidx
  on public.pedido_notas (pedido_id, (coalesce(vendedor_id, '00000000-0000-0000-0000-000000000000'::uuid)));
create index if not exists pedido_notas_vendedor_idx on public.pedido_notas (vendedor_id);

alter table public.pedido_notas enable row level security;

drop policy if exists notas_admin on public.pedido_notas;
create policy notas_admin on public.pedido_notas for all to authenticated
  using (privado.eh_admin()) with check (privado.eh_admin());

drop policy if exists notas_comprador_ler on public.pedido_notas;
create policy notas_comprador_ler on public.pedido_notas for select to authenticated
  using (exists (select 1 from public.pedidos p where p.id = pedido_notas.pedido_id and p.usuario_id = auth.uid()));

drop policy if exists notas_vendedor_ler on public.pedido_notas;
create policy notas_vendedor_ler on public.pedido_notas for select to authenticated
  using (vendedor_id in (select v.id from public.loja_vendedores v where v.usuario_id = auth.uid()));

-- 3. Notas já emitidas (cooperativa) passam para a tabela nova. Idempotente.
insert into public.pedido_notas (pedido_id, vendedor_id, status, ref, tentativas, numero, chave, danfe, erro, valor_centavos, atualizada_em)
select p.id, null,
       coalesce(p.nf_status, 'processando'), p.nf_ref, coalesce(p.nf_tentativas, 0), p.nf_numero, p.nf_chave, p.nf_danfe, p.nf_erro,
       p.total_centavos, coalesce(p.nf_atualizada_em, now())
  from public.pedidos p
 where p.nf_ref is not null
on conflict (pedido_id, (coalesce(vendedor_id, '00000000-0000-0000-0000-000000000000'::uuid))) do nothing;

-- 4. Cadastro de vendedor exige CNPJ (CPF não pode vender com nota)
create or replace function public.cadastrar_vendedor_loja(p_nome text, p_documento text, p_descricao text default null::text, p_cep text default null::text)
returns public.loja_vendedores
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  v public.loja_vendedores;
  v_doc text := regexp_replace(coalesce(p_documento, ''), '\D', '', 'g');
  v_cep text := regexp_replace(coalesce(p_cep, ''), '\D', '', 'g');
begin
  if auth.uid() is null or not privado.usuario_aprovado() then
    raise exception 'Entre com uma conta aprovada para se cadastrar como vendedor.';
  end if;
  if char_length(trim(coalesce(p_nome, ''))) < 3 then
    raise exception 'Informe o nome da loja com pelo menos 3 letras.';
  end if;
  if v_doc !~ '^[0-9]{14}$' then
    raise exception 'Para vender, informe o CNPJ (14 números). MEI também tem CNPJ.';
  end if;
  if v_cep <> '' and v_cep !~ '^[0-9]{8}$' then
    raise exception 'O CEP de origem precisa ter 8 números.';
  end if;
  if exists (select 1 from public.loja_vendedores where usuario_id = auth.uid()) then
    raise exception 'Você já tem um cadastro de vendedor.';
  end if;

  insert into public.loja_vendedores (usuario_id, nome_loja, documento, descricao, cep_origem)
  values (auth.uid(), trim(p_nome), v_doc, nullif(trim(coalesce(p_descricao, '')), ''), nullif(v_cep, ''))
  returning * into v;

  perform privado.auditar('vendedor_cadastrado', 'loja_vendedor', v.id::text, '{}'::jsonb);
  return v;
end $$;

-- 5. Vendedor salva os dados fiscais dele. Ligar a emissão exige CNPJ, token conectado e campos obrigatórios.
create or replace function public.salvar_fiscal_vendedor_loja(p_dados jsonb)
returns public.loja_vendedores
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  v public.loja_vendedores;
  v_regime text := nullif(trim(coalesce(p_dados->>'regime', '')), '');
  v_uf text := upper(nullif(trim(coalesce(p_dados->>'uf', '')), ''));
  v_cep text := regexp_replace(coalesce(p_dados->>'cep', ''), '\D', '', 'g');
  v_ambiente text := coalesce(nullif(trim(coalesce(p_dados->>'ambiente', '')), ''), 'homologacao');
  v_ativo boolean := coalesce((p_dados->>'ativo')::boolean, false);
  v_campo text;
  v_faltando text[] := '{}';
begin
  select * into v from public.loja_vendedores
   where usuario_id = auth.uid() and status = 'aprovado';
  if v.id is null then
    raise exception 'Só vendedores aprovados configuram a emissão de nota.';
  end if;
  if v_regime is not null and v_regime not in ('simples', 'normal') then
    raise exception 'Regime tributário inválido.';
  end if;
  if v_uf is not null and v_uf !~ '^[A-Z]{2}$' then
    raise exception 'UF com 2 letras.';
  end if;
  if v_cep <> '' and v_cep !~ '^[0-9]{8}$' then
    raise exception 'CEP fiscal com 8 números.';
  end if;
  if v_ambiente not in ('homologacao', 'producao') then
    raise exception 'Ambiente inválido.';
  end if;

  if v_ativo then
    if regexp_replace(v.documento, '\D', '', 'g') !~ '^[0-9]{14}$' then
      raise exception 'Para emitir nota, o cadastro precisa ter CNPJ.';
    end if;
    if not v.fiscal_token_configurado then
      raise exception 'Conecte a sua conta de emissão antes de ligar a emissão de nota.';
    end if;
  end if;

  update public.loja_vendedores set
    fiscal_razao_social = nullif(trim(coalesce(p_dados->>'razao_social', '')), ''),
    fiscal_ie = nullif(trim(coalesce(p_dados->>'ie', '')), ''),
    fiscal_regime = v_regime,
    fiscal_logradouro = nullif(trim(coalesce(p_dados->>'logradouro', '')), ''),
    fiscal_numero = nullif(trim(coalesce(p_dados->>'numero', '')), ''),
    fiscal_bairro = nullif(trim(coalesce(p_dados->>'bairro', '')), ''),
    fiscal_municipio = nullif(trim(coalesce(p_dados->>'municipio', '')), ''),
    fiscal_uf = v_uf,
    fiscal_cep = nullif(v_cep, ''),
    fiscal_natureza_operacao = coalesce(nullif(trim(coalesce(p_dados->>'natureza_operacao', '')), ''), 'Venda de mercadoria'),
    fiscal_cfop = nullif(trim(coalesce(p_dados->>'cfop', '')), ''),
    fiscal_csosn = nullif(trim(coalesce(p_dados->>'csosn', '')), ''),
    fiscal_cst_icms = nullif(trim(coalesce(p_dados->>'cst_icms', '')), ''),
    fiscal_icms_aliquota = nullif(trim(coalesce(p_dados->>'icms_aliquota', '')), ''),
    fiscal_origem = nullif(trim(coalesce(p_dados->>'origem', '')), ''),
    fiscal_cst_pis = nullif(trim(coalesce(p_dados->>'cst_pis', '')), ''),
    fiscal_cst_cofins = nullif(trim(coalesce(p_dados->>'cst_cofins', '')), ''),
    fiscal_ambiente = v_ambiente,
    fiscal_ativo = v_ativo
  where id = v.id
  returning * into v;

  -- Campos obrigatórios só quando a emissão está ligada
  if v.fiscal_ativo then
    foreach v_campo in array array['fiscal_razao_social', 'fiscal_ie', 'fiscal_regime', 'fiscal_logradouro', 'fiscal_numero',
                                   'fiscal_bairro', 'fiscal_municipio', 'fiscal_uf', 'fiscal_cep', 'fiscal_cfop'] loop
      if (to_jsonb(v) ->> v_campo) is null then
        v_faltando := v_faltando || v_campo;
      end if;
    end loop;
    if v.fiscal_regime = 'simples' and v.fiscal_csosn is null then
      v_faltando := v_faltando || 'fiscal_csosn';
    end if;
    if v.fiscal_regime = 'normal' and (v.fiscal_cst_icms is null or v.fiscal_icms_aliquota is null) then
      v_faltando := v_faltando || 'fiscal_cst_icms ou fiscal_icms_aliquota';
    end if;
    if coalesce(array_length(v_faltando, 1), 0) > 0 then
      raise exception 'Preencha os dados fiscais antes de ligar a emissão: %.', array_to_string(v_faltando, ', ');
    end if;
  end if;

  perform privado.auditar('nf_fiscal_vendedor_alterado', 'loja_vendedor', v.id::text,
                          jsonb_build_object('ativo', v.fiscal_ativo, 'ambiente', v.fiscal_ambiente));
  return v;
end $$;

-- 6. Vendedor conecta a conta de emissão dele (token do Focus NFe). O valor não volta para o app.
create or replace function public.salvar_token_nf_vendedor_loja(p_token text)
returns void
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  v public.loja_vendedores;
  v_id uuid;
  v_nome text;
  v_valor text := trim(coalesce(p_token, ''));
begin
  select * into v from public.loja_vendedores
   where usuario_id = auth.uid() and status = 'aprovado';
  if v.id is null then
    raise exception 'Só vendedores aprovados conectam conta de emissão.';
  end if;
  if length(v_valor) < 8 then
    raise exception 'O token parece curto demais. Copie o token completo.';
  end if;

  v_nome := 'nf_vendedor_' || v.id::text || '_token';
  select s.id into v_id from vault.secrets s where s.name = v_nome;
  if v_id is null then
    perform vault.create_secret(v_valor, v_nome, 'Nota fiscal do vendedor');
  else
    perform vault.update_secret(v_id, v_valor, v_nome, 'Nota fiscal do vendedor');
  end if;

  update public.loja_vendedores set fiscal_token_configurado = true where id = v.id;
  perform privado.auditar('nf_token_vendedor_alterado', 'loja_vendedor', v.id::text, '{}'::jsonb);
end $$;

-- 7. Dados fiscais do próprio vendedor para a tela (sem segredos)
create or replace function public.meus_dados_fiscais_vendedor_loja()
returns jsonb
language sql
stable
security definer
set search_path = public, privado
as $$
  select to_jsonb(v) - 'usuario_id' - 'decidido_por' - 'mp_user_id'
    from public.loja_vendedores v
   where v.usuario_id = auth.uid()
   limit 1
$$;

-- 8. Emissão por grupo: admin prepara a nota da cooperativa (vendedor nulo) ou de um vendedor.
drop function if exists public.preparar_nota_loja(uuid);
drop function if exists public.referencia_nota_loja(uuid);
drop function if exists public.confirmar_nota_loja(uuid, text, text, text, text, text);

create or replace function public.preparar_nota_loja(p_pedido uuid, p_vendedor uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  p public.pedidos%rowtype;
  n public.pedido_notas%rowtype;
  u public.usuarios%rowtype;
  v_vend public.loja_vendedores%rowtype;
  cfg jsonb := '{}'::jsonb;
  v_faltando text[] := '{}';
  v_campo text;
  v_sem_ncm text;
  v_itens jsonb;
  v_subtotal integer;
  v_frete integer;
  v_desconto integer := 0;
  v_outros integer;
  v_dono_cupom uuid;
  v_tentativas integer;
  v_ref text;
  v_total integer;
  v_token_nome text;
  v_existe boolean;
begin
  if not privado.eh_admin() then
    raise exception 'Apenas administradores.';
  end if;

  select * into p from public.pedidos where id = p_pedido for update;
  if not found then
    raise exception 'Pedido não encontrado.';
  end if;
  if p.status not in ('pago', 'em_separacao', 'pronto_retirada', 'enviado', 'entregue', 'retirado') then
    raise exception 'A nota só pode ser emitida depois do pagamento aprovado.';
  end if;

  -- Grupo: cooperativa (nulo) ou vendedor
  if p_vendedor is null then
    select exists (select 1 from public.pedido_itens i where i.pedido_id = p_pedido and i.vendedor_id is null) into v_existe;
    if not v_existe then
      raise exception 'Este pedido não tem produtos da cooperativa.';
    end if;

    select coalesce(jsonb_object_agg(l.chave, l.valor), '{}'::jsonb) into cfg
      from public.loja_configuracoes l where l.chave like 'fiscal\_%';
    if cfg->>'fiscal_ativo' is distinct from 'sim' then
      raise exception 'A emissão de nota fiscal está desligada. Ligue em Pagamento e configurações.';
    end if;
    v_token_nome := 'focus_nfe_token';
  else
    select * into v_vend from public.loja_vendedores where id = p_vendedor;
    if not found then
      raise exception 'Vendedor não encontrado.';
    end if;
    select exists (select 1 from public.pedido_itens i where i.pedido_id = p_pedido and i.vendedor_id = p_vendedor) into v_existe;
    if not v_existe then
      raise exception 'Este pedido não tem produtos deste vendedor.';
    end if;
    if not v_vend.fiscal_ativo then
      raise exception 'A emissão de nota está desligada para "%". O vendedor precisa preencher os dados fiscais.', v_vend.nome_loja;
    end if;
    if regexp_replace(v_vend.documento, '\D', '', 'g') !~ '^[0-9]{14}$' then
      raise exception 'O vendedor "%" precisa ter CNPJ para emitir nota.', v_vend.nome_loja;
    end if;
    if not v_vend.fiscal_token_configurado then
      raise exception 'O vendedor "%" ainda não conectou a conta de emissão.', v_vend.nome_loja;
    end if;

    cfg := jsonb_build_object(
      'fiscal_ativo', 'sim',
      'fiscal_ambiente', v_vend.fiscal_ambiente,
      'fiscal_cnpj', regexp_replace(v_vend.documento, '\D', '', 'g'),
      'fiscal_razao_social', v_vend.fiscal_razao_social,
      'fiscal_ie', v_vend.fiscal_ie,
      'fiscal_regime', v_vend.fiscal_regime,
      'fiscal_logradouro', v_vend.fiscal_logradouro,
      'fiscal_numero', v_vend.fiscal_numero,
      'fiscal_bairro', v_vend.fiscal_bairro,
      'fiscal_municipio', v_vend.fiscal_municipio,
      'fiscal_uf', v_vend.fiscal_uf,
      'fiscal_cep', v_vend.fiscal_cep,
      'fiscal_natureza_operacao', v_vend.fiscal_natureza_operacao,
      'fiscal_cfop', v_vend.fiscal_cfop,
      'fiscal_csosn', v_vend.fiscal_csosn,
      'fiscal_cst_icms', v_vend.fiscal_cst_icms,
      'fiscal_icms_aliquota', v_vend.fiscal_icms_aliquota,
      'fiscal_origem', v_vend.fiscal_origem,
      'fiscal_cst_pis', v_vend.fiscal_cst_pis,
      'fiscal_cst_cofins', v_vend.fiscal_cst_cofins
    );
    v_token_nome := 'nf_vendedor_' || p_vendedor::text || '_token';
  end if;

  foreach v_campo in array array['fiscal_cnpj', 'fiscal_razao_social', 'fiscal_ie', 'fiscal_regime',
                                 'fiscal_logradouro', 'fiscal_numero', 'fiscal_bairro', 'fiscal_municipio',
                                 'fiscal_uf', 'fiscal_cep', 'fiscal_natureza_operacao', 'fiscal_cfop'] loop
    if coalesce(trim(cfg->>v_campo), '') = '' then
      v_faltando := v_faltando || v_campo;
    end if;
  end loop;
  if cfg->>'fiscal_regime' = 'simples' then
    if coalesce(trim(cfg->>'fiscal_csosn'), '') = '' then v_faltando := v_faltando || 'fiscal_csosn'; end if;
  else
    if coalesce(trim(cfg->>'fiscal_cst_icms'), '') = '' then v_faltando := v_faltando || 'fiscal_cst_icms'; end if;
    if coalesce(trim(cfg->>'fiscal_icms_aliquota'), '') = '' then v_faltando := v_faltando || 'fiscal_icms_aliquota'; end if;
  end if;
  if coalesce(array_length(v_faltando, 1), 0) > 0 then
    raise exception 'Preencha os dados fiscais: %.', array_to_string(v_faltando, ', ');
  end if;

  -- NCM dos produtos deste grupo
  select string_agg(coalesce(pr.nome, i.nome_snapshot), ', ') into v_sem_ncm
    from public.pedido_itens i
    left join public.loja_produtos pr on pr.id = i.produto_id
   where i.pedido_id = p_pedido
     and i.vendedor_id is not distinct from p_vendedor
     and (pr.id is null or pr.ncm is null);
  if v_sem_ncm is not null then
    raise exception 'Falta o NCM destes produtos: %. Preencha no cadastro do produto.', v_sem_ncm;
  end if;

  select jsonb_agg(jsonb_build_object(
           'produto_id', i.produto_id,
           'descricao', i.nome_snapshot,
           'quantidade', i.quantidade,
           'valor_unitario_centavos', i.preco_unitario_centavos,
           'ncm', pr.ncm,
           'unidade', pr.unidade)
         order by i.nome_snapshot)
    into v_itens
    from public.pedido_itens i
    join public.loja_produtos pr on pr.id = i.produto_id
   where i.pedido_id = p_pedido
     and i.vendedor_id is not distinct from p_vendedor;

  select coalesce(sum(i.quantidade * i.preco_unitario_centavos), 0)::integer into v_subtotal
    from public.pedido_itens i
   where i.pedido_id = p_pedido and i.vendedor_id is not distinct from p_vendedor;

  select coalesce(sum(e.frete_centavos), 0)::integer into v_frete
    from public.pedido_envios e
   where e.pedido_id = p_pedido and e.vendedor_id is not distinct from p_vendedor;

  -- Desconto: cupom de vendedor fica na nota dele; cupom da cooperativa é rateado pelo subtotal de cada grupo
  if coalesce(p.desconto_centavos, 0) > 0 and p.cupom_id is not null then
    select c.vendedor_id into v_dono_cupom from public.cupons_loja c where c.id = p.cupom_id;
    if v_dono_cupom is not null then
      v_desconto := case when v_dono_cupom = p_vendedor then p.desconto_centavos else 0 end;
    elsif p.subtotal_centavos > 0 then
      select coalesce(sum(round(p.desconto_centavos::numeric * s.sub / p.subtotal_centavos))::integer, 0) into v_outros
        from (select i.vendedor_id, sum(i.quantidade * i.preco_unitario_centavos) as sub
                from public.pedido_itens i
               where i.pedido_id = p_pedido and i.vendedor_id is not null
               group by i.vendedor_id) s;
      if p_vendedor is null then
        v_desconto := p.desconto_centavos - v_outros;
      else
        v_desconto := round(p.desconto_centavos::numeric * v_subtotal / p.subtotal_centavos)::integer;
      end if;
    end if;
  end if;

  v_total := v_subtotal - v_desconto + v_frete;
  if v_total < 0 then
    raise exception 'Valor da nota negativo. Confira os descontos do pedido.';
  end if;

  -- Referência nova a cada tentativa: a Focus NFe não aceita reaproveitar a referência de uma nota já enviada.
  select * into n from public.pedido_notas
   where pedido_id = p_pedido and vendedor_id is not distinct from p_vendedor
   for update;
  if found and n.status in ('processando', 'autorizada') then
    raise exception 'Esta nota já está em situação "%". Atualize a situação antes de emitir outra.',
      case n.status when 'processando' then 'em processamento' else 'autorizada' end;
  end if;

  v_tentativas := coalesce(n.tentativas, 0) + 1;
  v_ref := 'ped' || replace(p_pedido::text, '-', '') || 'v'
        || coalesce(replace(p_vendedor::text, '-', ''), 'coop') || 't' || v_tentativas;

  insert into public.pedido_notas (pedido_id, vendedor_id, status, ref, tentativas, erro, valor_centavos, atualizada_em)
  values (p_pedido, p_vendedor, 'processando', v_ref, v_tentativas, null, v_total, now())
  on conflict (pedido_id, (coalesce(vendedor_id, '00000000-0000-0000-0000-000000000000'::uuid)))
  do update set status = 'processando', ref = excluded.ref, tentativas = excluded.tentativas,
                erro = null, valor_centavos = excluded.valor_centavos, atualizada_em = now();

  select * into u from public.usuarios where id = p.usuario_id;

  perform privado.auditar('nota_emissao_solicitada', 'pedido', p_pedido::text,
                          jsonb_build_object('ref', v_ref, 'vendedor', p_vendedor));

  return jsonb_build_object(
    'ref', v_ref,
    'ambiente', coalesce(cfg->>'fiscal_ambiente', 'homologacao'),
    'regime', cfg->>'fiscal_regime',
    'config', cfg,
    'token_nome', v_token_nome,
    'metodo_entrega', p.metodo_entrega,
    'subtotal_centavos', v_subtotal,
    'frete_centavos', v_frete,
    'desconto_centavos', v_desconto,
    'total_centavos', v_total,
    'destinatario', jsonb_build_object(
      'nome', coalesce(u.nome_completo, 'Consumidor'),
      'cpf', u.cpf,
      'email', u.email,
      'telefone', u.telefone,
      'endereco', p.endereco),
    'itens', coalesce(v_itens, '[]'::jsonb)
  );
end;
$$;

create or replace function public.referencia_nota_loja(p_pedido uuid, p_vendedor uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, privado
as $$
declare
  n public.pedido_notas%rowtype;
  v_ambiente text;
begin
  if not privado.eh_admin() then
    raise exception 'Apenas administradores.';
  end if;

  select * into n from public.pedido_notas
   where pedido_id = p_pedido and vendedor_id is not distinct from p_vendedor;
  if not found or n.ref is null then
    raise exception 'Esta nota ainda não foi emitida.';
  end if;

  if p_vendedor is null then
    select coalesce((select l.valor from public.loja_configuracoes l where l.chave = 'fiscal_ambiente'), 'homologacao') into v_ambiente;
  else
    select v.fiscal_ambiente into v_ambiente from public.loja_vendedores v where v.id = p_vendedor;
  end if;

  return jsonb_build_object(
    'ref', n.ref,
    'nf_status', n.status,
    'numero', n.numero,
    'ambiente', coalesce(v_ambiente, 'homologacao'),
    'token_nome', case when p_vendedor is null then 'focus_nfe_token' else 'nf_vendedor_' || p_vendedor::text || '_token' end
  );
end;
$$;

create or replace function public.confirmar_nota_loja(
  p_pedido uuid, p_vendedor uuid, p_status text, p_numero text, p_chave text, p_danfe text, p_erro text
)
returns void
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  v_usuario uuid;
  v_linhas integer;
begin
  update public.pedido_notas
     set status = p_status,
         numero = coalesce(p_numero, numero),
         chave = coalesce(p_chave, chave),
         danfe = coalesce(p_danfe, danfe),
         erro = case when p_status = 'erro' then left(p_erro, 1000) else null end,
         atualizada_em = now()
   where pedido_id = p_pedido and vendedor_id is not distinct from p_vendedor;
  get diagnostics v_linhas = row_count;
  if v_linhas = 0 then
    return;
  end if;

  select usuario_id into v_usuario from public.pedidos where id = p_pedido;
  if p_status = 'autorizada' and v_usuario is not null then
    perform privado.notificar(array[v_usuario], 'Nota fiscal emitida',
                              'Uma nota fiscal do seu pedido está disponível em Meus pedidos.', null);
  end if;
  perform privado.auditar('nota_' || p_status, 'pedido', p_pedido::text,
                          jsonb_build_object('numero', p_numero, 'vendedor', p_vendedor,
                                             'erro', left(coalesce(p_erro, ''), 300)));
end;
$$;

-- 9. Permissões
revoke execute on function public.salvar_fiscal_vendedor_loja(jsonb) from anon, public;
revoke execute on function public.salvar_token_nf_vendedor_loja(text) from anon, public;
revoke execute on function public.meus_dados_fiscais_vendedor_loja() from anon, public;
revoke execute on function public.preparar_nota_loja(uuid, uuid) from anon, public;
revoke execute on function public.referencia_nota_loja(uuid, uuid) from anon, public;
revoke execute on function public.confirmar_nota_loja(uuid, uuid, text, text, text, text, text) from anon, public;
grant execute on function public.salvar_fiscal_vendedor_loja(jsonb) to authenticated;
grant execute on function public.salvar_token_nf_vendedor_loja(text) to authenticated;
grant execute on function public.meus_dados_fiscais_vendedor_loja() to authenticated;
grant execute on function public.preparar_nota_loja(uuid, uuid) to authenticated;
grant execute on function public.referencia_nota_loja(uuid, uuid) to authenticated;
grant execute on function public.confirmar_nota_loja(uuid, uuid, text, text, text, text, text) to authenticated;

-- 10. Verificação final
do $$
begin
  if to_regclass('public.pedido_notas') is null
     or to_regprocedure('public.preparar_nota_loja(uuid,uuid)') is null
     or to_regprocedure('public.confirmar_nota_loja(uuid,uuid,text,text,text,text,text)') is null
     or to_regprocedure('public.salvar_token_nf_vendedor_loja(text)') is null
     or to_regprocedure('public.salvar_fiscal_vendedor_loja(jsonb)') is null then
    raise exception 'Funções ou tabela da nota por vendedor não criadas.';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'preparar_nota_loja' and p.pronargs = 1) then
    raise exception 'Versão antiga de preparar_nota_loja ainda existe.';
  end if;
end $$;
