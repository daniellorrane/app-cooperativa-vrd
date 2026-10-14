-- Fase 13: marketplace, fundação.
-- Vendedores externos (cadastro, aprovação e comissão pelo administrador), produto por vendedor,
-- pedido com vendedor, e catálogo de provedores de entrega (credenciais no Vault).
-- Não muda ainda o carrinho, o checkout nem a vitrine (fases 14 e 15).
-- Rode no SQL Editor do Supabase e responda "feito".

-- 0. Verificação das funções base
do $$
begin
  if to_regprocedure('privado.eh_admin()') is null
     or to_regprocedure('privado.usuario_aprovado()') is null
     or to_regprocedure('privado.auditar(text,text,text,jsonb)') is null then
    raise exception 'Funções base não encontradas. Confirme que as fases anteriores foram aplicadas.';
  end if;
end $$;

-- 1. Vendedores
create table if not exists public.loja_vendedores (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null unique references auth.users(id) on delete cascade,
  nome_loja text not null check (char_length(nome_loja) between 3 and 80),
  documento text not null check (documento ~ '^([0-9]{11}|[0-9]{14})$'),
  descricao text check (descricao is null or char_length(descricao) <= 500),
  cep_origem text check (cep_origem is null or cep_origem ~ '^[0-9]{8}$'),
  status text not null default 'pendente'
    check (status in ('pendente', 'aprovado', 'suspenso', 'recusado')),
  comissao_percentual numeric(5,2)
    check (comissao_percentual is null or comissao_percentual between 0 and 100),
  mp_user_id text,
  criado_em timestamptz not null default now(),
  decidido_em timestamptz,
  decidido_por uuid references auth.users(id) on delete set null
);

alter table public.loja_vendedores enable row level security;

drop policy if exists vendedores_ler on public.loja_vendedores;
create policy vendedores_ler on public.loja_vendedores for select to authenticated
  using (usuario_id = auth.uid() or privado.eh_admin());

drop policy if exists vendedores_admin on public.loja_vendedores;
create policy vendedores_admin on public.loja_vendedores for all to authenticated
  using (privado.eh_admin()) with check (privado.eh_admin());

-- Sem política de escrita para o vendedor: cadastro, aprovação e comissão passam pelas funções abaixo.

-- Funções auxiliares (lidas pelas políticas sem depender do RLS do chamador)
create or replace function privado.vendedor_do_usuario()
returns uuid language sql stable security definer set search_path = public, privado as $$
  select v.id from public.loja_vendedores v
  where v.usuario_id = auth.uid() and v.status = 'aprovado'
$$;

create or replace function privado.vendedor_aprovado(p_vendedor uuid)
returns boolean language sql stable security definer set search_path = public, privado as $$
  select exists (
    select 1 from public.loja_vendedores v
    where v.id = p_vendedor and v.status = 'aprovado'
  )
$$;

-- Comissão efetiva: a do vendedor, se houver; senão a padrão da loja; produto da cooperativa não paga comissão.
create or replace function privado.comissao_vendedor(p_vendedor uuid)
returns numeric language sql stable security definer set search_path = public, privado as $$
  select case when p_vendedor is null then 0 else coalesce(
    (select v.comissao_percentual from public.loja_vendedores v where v.id = p_vendedor),
    (select case when c.valor ~ '^[0-9]+([.,][0-9]+)?$' then replace(c.valor, ',', '.')::numeric end
       from public.loja_configuracoes c where c.chave = 'comissao_padrao_percentual'),
    0
  ) end
$$;

-- 2. Produtos por vendedor
alter table public.loja_produtos
  add column if not exists vendedor_id uuid references public.loja_vendedores(id) on delete restrict;
create index if not exists loja_produtos_vendedor_idx on public.loja_produtos (vendedor_id);

-- Produto de vendedor: só o próprio vendedor (aprovado) cria e edita. Produto da cooperativa continua só do administrador.
drop policy if exists loja_produtos_vendedor on public.loja_produtos;
create policy loja_produtos_vendedor on public.loja_produtos for all to authenticated
  using (vendedor_id is not null and vendedor_id = privado.vendedor_do_usuario())
  with check (vendedor_id is not null and vendedor_id = privado.vendedor_do_usuario());

-- Vitrine e leitura: produto de vendedor só aparece se o vendedor estiver aprovado.
drop policy if exists loja_produtos_ler on public.loja_produtos;
create policy loja_produtos_ler on public.loja_produtos for select to authenticated
  using (
    (ativo and privado.usuario_aprovado() and (vendedor_id is null or privado.vendedor_aprovado(vendedor_id)))
    or privado.eh_admin()
    or (vendedor_id is not null and vendedor_id = privado.vendedor_do_usuario())
  );

-- Vendedor não troca de dono, e variação fica com o mesmo vendedor do produto principal.
create or replace function privado.protege_vendedor_produto()
returns trigger language plpgsql security definer set search_path = public, privado as $$
declare v_pai uuid;
begin
  if tg_op = 'UPDATE' and new.vendedor_id is distinct from old.vendedor_id then
    raise exception 'O vendedor de um produto não pode ser trocado.';
  end if;
  if new.variacao_de is not null then
    select p.vendedor_id into v_pai from public.loja_produtos p where p.id = new.variacao_de;
    if v_pai is distinct from new.vendedor_id then
      raise exception 'A variação precisa ser do mesmo vendedor do produto principal.';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists loja_produtos_vendedor_protege on public.loja_produtos;
create trigger loja_produtos_vendedor_protege
  before insert or update on public.loja_produtos
  for each row execute function privado.protege_vendedor_produto();

-- 3. Pedidos por vendedor. Uma compra com itens de vendedores diferentes vira um pedido por vendedor,
--    todos ligados pelo mesmo compra_id. Pedido com vendedor_id nulo é da cooperativa.
alter table public.pedidos
  add column if not exists vendedor_id uuid references public.loja_vendedores(id) on delete restrict;
alter table public.pedidos add column if not exists compra_id uuid;
create index if not exists pedidos_vendedor_idx on public.pedidos (vendedor_id);
create index if not exists pedidos_compra_idx on public.pedidos (compra_id);

-- 4. Comissão padrão da loja (0 até o administrador definir outro valor na tela de configurações).
-- A tabela aceita só chaves conhecidas, então a lista de chaves é ampliada antes do insert.
alter table public.loja_configuracoes drop constraint if exists loja_configuracoes_chave_check;
alter table public.loja_configuracoes add constraint loja_configuracoes_chave_check check (chave = any (array[
  'nome_loja', 'endereco_retirada', 'horario_retirada', 'minutos_expiracao_pedido', 'url_publica_app',
  'mp_public_key', 'cep_origem', 'entrega_local_ativa', 'entrega_local_ceps', 'taxa_entrega_local_centavos',
  'melhor_envio_sandbox',
  'fiscal_ativo', 'fiscal_ambiente', 'fiscal_cnpj', 'fiscal_razao_social', 'fiscal_ie', 'fiscal_regime',
  'fiscal_logradouro', 'fiscal_numero', 'fiscal_bairro', 'fiscal_municipio', 'fiscal_uf', 'fiscal_cep',
  'fiscal_natureza_operacao', 'fiscal_cfop', 'fiscal_csosn', 'fiscal_cst_icms', 'fiscal_icms_aliquota',
  'fiscal_origem', 'fiscal_cst_pis', 'fiscal_cst_cofins',
  'comissao_padrao_percentual'
]::text[]));

insert into public.loja_configuracoes (chave, valor, atualizado_em)
values ('comissao_padrao_percentual', '0', now())
on conflict (chave) do nothing;

-- 5. Funções do vendedor e do administrador

-- Cadastro do vendedor: entra como pendente até o administrador aprovar.
create or replace function public.cadastrar_vendedor_loja(
  p_nome text, p_documento text, p_descricao text default null, p_cep text default null
)
returns public.loja_vendedores
language plpgsql security definer set search_path = public, privado as $$
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
  if v_doc !~ '^([0-9]{11}|[0-9]{14})$' then
    raise exception 'Informe um CPF (11 números) ou CNPJ (14 números).';
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

-- Aprovação, recusa, suspensão e reativação de vendedor (só administrador).
create or replace function public.decidir_vendedor_loja(p_vendedor uuid, p_acao text)
returns public.loja_vendedores
language plpgsql security definer set search_path = public, privado as $$
declare v public.loja_vendedores;
begin
  if not privado.eh_admin() then
    raise exception 'Apenas administradores decidem sobre vendedores.';
  end if;

  select * into v from public.loja_vendedores where id = p_vendedor;
  if v.id is null then raise exception 'Vendedor não encontrado.'; end if;

  if not (
    (p_acao in ('aprovar', 'recusar') and v.status = 'pendente')
    or (p_acao = 'suspender' and v.status = 'aprovado')
    or (p_acao = 'reativar' and v.status = 'suspenso')
  ) then
    raise exception 'Essa ação não se aplica à situação atual do vendedor.';
  end if;

  update public.loja_vendedores
     set status = case p_acao
           when 'aprovar' then 'aprovado'
           when 'reativar' then 'aprovado'
           when 'suspender' then 'suspenso'
           when 'recusar' then 'recusado' end,
         decidido_em = now(),
         decidido_por = auth.uid()
   where id = p_vendedor
  returning * into v;

  perform privado.auditar('vendedor_' || p_acao, 'loja_vendedor', v.id::text, jsonb_build_object('status', v.status));
  return v;
end $$;

-- Comissão de um vendedor. Valor vazio (null) volta a usar a comissão padrão da loja.
create or replace function public.definir_comissao_vendedor_loja(p_vendedor uuid, p_percentual numeric)
returns public.loja_vendedores
language plpgsql security definer set search_path = public, privado as $$
declare v public.loja_vendedores;
begin
  if not privado.eh_admin() then
    raise exception 'Apenas administradores definem comissões.';
  end if;
  if p_percentual is not null and (p_percentual < 0 or p_percentual > 100) then
    raise exception 'A comissão precisa estar entre 0 e 100.';
  end if;

  update public.loja_vendedores set comissao_percentual = p_percentual
   where id = p_vendedor
  returning * into v;
  if v.id is null then raise exception 'Vendedor não encontrado.'; end if;

  perform privado.auditar('comissao_vendedor_alterada', 'loja_vendedor', v.id::text,
    jsonb_build_object('percentual', p_percentual));
  return v;
end $$;

-- 6. Provedores de entrega (multi-provedor). Configuração pública fica aqui; segredos ficam no Vault.
create table if not exists public.loja_provedores_entrega (
  codigo text primary key check (codigo ~ '^[a-z][a-z0-9_]{2,30}$'),
  nome text not null,
  tipo text not null check (tipo in ('sob_demanda', 'transportadora', 'proprio')),
  ativo boolean not null default false,
  ambiente text not null default 'homologacao' check (ambiente in ('homologacao', 'producao')),
  configuracao jsonb not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now()
);

insert into public.loja_provedores_entrega (codigo, nome, tipo) values
  ('lalamove', 'Lalamove', 'sob_demanda'),
  ('uber_direct', 'Uber Direct', 'sob_demanda'),
  ('loggi', 'Loggi', 'transportadora')
on conflict (codigo) do nothing;

alter table public.loja_provedores_entrega enable row level security;

drop policy if exists provedores_admin on public.loja_provedores_entrega;
create policy provedores_admin on public.loja_provedores_entrega for all to authenticated
  using (privado.eh_admin()) with check (privado.eh_admin());

-- Grava chave secreta de um provedor no Vault. Nome fixo: entrega_<codigo>_<campo>.
create or replace function privado.gravar_segredo_entrega(p_codigo text, p_campo text, p_valor text)
returns void language plpgsql security definer set search_path = public, vault as $$
declare
  v_id uuid;
  v_nome text := 'entrega_' || p_codigo || '_' || p_campo;
begin
  if p_campo not in ('token', 'segredo') then raise exception 'Campo de segredo desconhecido.'; end if;
  if p_valor is null or length(trim(p_valor)) < 8 then
    raise exception 'O valor parece curto demais. Copie a chave completa.';
  end if;

  select s.id into v_id from vault.secrets s where s.name = v_nome;
  if v_id is null then
    perform vault.create_secret(trim(p_valor), v_nome, 'Entrega: ' || v_nome);
  else
    perform vault.update_secret(v_id, trim(p_valor), v_nome, 'Entrega: ' || v_nome);
  end if;

  perform privado.auditar('segredo_entrega_alterado', 'loja_provedor_entrega', p_codigo,
    jsonb_build_object('campo', p_campo));
end $$;

create or replace function public.salvar_segredo_entrega_loja(p_codigo text, p_campo text, p_valor text)
returns void language plpgsql security definer set search_path = public, privado as $$
begin
  if not privado.eh_admin() then
    raise exception 'Apenas administradores podem alterar estas chaves.';
  end if;
  if not exists (select 1 from public.loja_provedores_entrega where codigo = p_codigo) then
    raise exception 'Provedor de entrega desconhecido.';
  end if;
  perform privado.gravar_segredo_entrega(p_codigo, p_campo, p_valor);
end $$;

-- Ativa ou desativa um provedor e define o ambiente. A configuração pública não pode guardar segredos.
create or replace function public.salvar_provedor_entrega_loja(
  p_codigo text, p_ativo boolean, p_ambiente text, p_configuracao jsonb
)
returns public.loja_provedores_entrega
language plpgsql security definer set search_path = public, privado as $$
declare v public.loja_provedores_entrega;
begin
  if not privado.eh_admin() then
    raise exception 'Apenas administradores configuram a entrega.';
  end if;
  if p_ambiente not in ('homologacao', 'producao') then
    raise exception 'Ambiente inválido.';
  end if;
  if jsonb_typeof(coalesce(p_configuracao, '{}'::jsonb)) <> 'object' then
    raise exception 'A configuração precisa ser um conjunto de campos.';
  end if;
  if coalesce(p_configuracao, '{}'::jsonb)::text ~* '(token|secret|senha|password)' then
    raise exception 'Não guarde chaves secretas aqui. Use o campo de token ou de segredo.';
  end if;

  update public.loja_provedores_entrega
     set ativo = coalesce(p_ativo, false),
         ambiente = p_ambiente,
         configuracao = coalesce(p_configuracao, '{}'::jsonb),
         atualizado_em = now()
   where codigo = p_codigo
  returning * into v;
  if v.codigo is null then raise exception 'Provedor de entrega desconhecido.'; end if;

  perform privado.auditar('provedor_entrega_alterado', 'loja_provedor_entrega', p_codigo,
    jsonb_build_object('ativo', v.ativo, 'ambiente', v.ambiente));
  return v;
end $$;

-- 7. Permissões: as funções checam login e administrador por dentro (mesmo padrão das fases anteriores).
grant execute on function public.cadastrar_vendedor_loja(text, text, text, text) to authenticated;
grant execute on function public.decidir_vendedor_loja(uuid, text) to authenticated;
grant execute on function public.definir_comissao_vendedor_loja(uuid, numeric) to authenticated;
grant execute on function public.salvar_segredo_entrega_loja(text, text, text) to authenticated;
grant execute on function public.salvar_provedor_entrega_loja(text, boolean, text, jsonb) to authenticated;
