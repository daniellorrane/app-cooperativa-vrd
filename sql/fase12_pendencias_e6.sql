-- E-commerce fase 12: pendências do plano.
--   1. Exclusão de conta: o endereço de entrega é apagado dos pedidos (o pedido e os valores ficam, sem dados pessoais).
--   2. Avaliação só de quem comprou e recebeu/pagou o pedido.
--   3. Variações de produto (tamanho, cor etc.), cada uma com estoque e preço próprios.
--   4. Nota fiscal eletrônica pelo Focus NFe, com dados e parâmetros preenchidos pelo administrador no app.
-- Rodar inteiro no SQL Editor do Supabase, uma vez. Não apaga dados existentes.

-- =====================================================================
-- 0. CONFIGURAÇÕES FISCAIS E CHAVE DO FOCUS NFE
-- =====================================================================
alter table public.loja_configuracoes drop constraint if exists loja_configuracoes_chave_check;
alter table public.loja_configuracoes add constraint loja_configuracoes_chave_check check (chave = any (array[
  'nome_loja', 'endereco_retirada', 'horario_retirada', 'minutos_expiracao_pedido', 'url_publica_app', 'mp_public_key',
  'cep_origem', 'entrega_local_ativa', 'entrega_local_ceps', 'taxa_entrega_local_centavos', 'melhor_envio_sandbox',
  'fiscal_ativo', 'fiscal_ambiente', 'fiscal_cnpj', 'fiscal_razao_social', 'fiscal_ie', 'fiscal_regime',
  'fiscal_logradouro', 'fiscal_numero', 'fiscal_bairro', 'fiscal_municipio', 'fiscal_uf', 'fiscal_cep',
  'fiscal_natureza_operacao', 'fiscal_cfop', 'fiscal_csosn', 'fiscal_cst_icms', 'fiscal_icms_aliquota',
  'fiscal_origem', 'fiscal_cst_pis', 'fiscal_cst_cofins'
]::text[]));

-- Segredos: inclui o token do Focus NFe (guardado no Vault, nunca na tabela de configurações).
create or replace function privado.gravar_segredo(p_nome text, p_valor text)
returns void
language plpgsql
security definer
set search_path = public, vault
as $$
declare
  v_id uuid;
begin
  if p_nome not in ('mp_access_token', 'mp_webhook_secret', 'melhor_envio_token', 'focus_nfe_token') then
    raise exception 'Segredo desconhecido.';
  end if;
  if p_valor is null or length(trim(p_valor)) < 8 then
    raise exception 'O valor parece curto demais. Copie a chave completa.';
  end if;

  select s.id into v_id from vault.secrets s where s.name = p_nome;
  if v_id is null then
    perform vault.create_secret(trim(p_valor), p_nome, 'Loja: ' || p_nome);
  else
    perform vault.update_secret(v_id, trim(p_valor), p_nome, 'Loja: ' || p_nome);
  end if;

  perform privado.auditar('segredo_loja_alterado', 'loja_configuracao', p_nome, '{}'::jsonb);
end;
$$;

create or replace function public.status_loja_pagamento()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, vault
as $$
begin
  if not privado.eh_admin() then
    raise exception 'Apenas administradores.';
  end if;
  return jsonb_build_object(
    'mp_access_token', exists (select 1 from vault.secrets s where s.name = 'mp_access_token'),
    'mp_webhook_secret', exists (select 1 from vault.secrets s where s.name = 'mp_webhook_secret'),
    'melhor_envio_token', exists (select 1 from vault.secrets s where s.name = 'melhor_envio_token'),
    'focus_nfe_token', exists (select 1 from vault.secrets s where s.name = 'focus_nfe_token')
  );
end;
$$;

-- =====================================================================
-- 1. EXCLUSÃO DE CONTA
-- Pedidos ficam (exigência fiscal e financeira), sem o usuário e sem o endereço.
-- =====================================================================
create or replace function public.excluir_minha_conta(p_modo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Sessão inválida.';
  end if;
  if p_modo not in ('apagar', 'anonimizar') then
    raise exception 'Modo de exclusão inválido.';
  end if;

  perform set_config('app.excluindo_conta', 'on', true);

  if p_modo = 'anonimizar' then
    update public.conversas c
       set perfil_solicitante = coalesce(c.perfil_solicitante, u.tipo_acesso),
           solicitante_id = null
      from public.usuarios u
     where c.solicitante_id = v_uid and u.id = v_uid;
    update public.mensagens set autor_id = null where autor_id = v_uid;
    delete from public.notificacoes where usuario_id = v_uid;
  end if;

  -- Loja: pedidos ficam com o usuário nulo (ON DELETE SET NULL), mas o endereço é apagado.
  update public.pedidos set endereco = null where usuario_id = v_uid;
  delete from public.cotacoes_frete where usuario_id = v_uid;

  update public.usuarios set aprovado_por = null where aprovado_por = v_uid;
  -- Cascata: funcionarios_areas; no modo apagar também conversas, mensagens e notificações
  delete from public.usuarios where id = v_uid;
  delete from auth.users where id = v_uid;
end;
$$;

-- =====================================================================
-- 2. AVALIAÇÃO SÓ DE QUEM COMPROU
-- =====================================================================
drop policy if exists avaliacoes_inserir on public.avaliacoes_produto;
create policy avaliacoes_inserir on public.avaliacoes_produto
  for insert with check (
    usuario_id = auth.uid()
    and status = 'publicada'
    and privado.usuario_aprovado()
    and exists (
      select 1
        from public.pedidos p
        join public.pedido_itens i on i.pedido_id = p.id
       where p.usuario_id = auth.uid()
         and i.produto_id = avaliacoes_produto.produto_id
         and p.status in ('pago', 'em_separacao', 'pronto_retirada', 'enviado', 'entregue', 'retirado')
    )
  );

-- =====================================================================
-- 3. VARIAÇÕES DE PRODUTO
-- Uma variação é um produto da loja ligado a um produto principal (variacao_de).
-- Cada variação tem nome, preço, estoque e situação próprios. O carrinho e o pedido não mudam.
-- =====================================================================
alter table public.loja_produtos
  add column if not exists ncm text check (ncm is null or ncm ~ '^[0-9]{8}$'),
  add column if not exists unidade text not null default 'UN' check (length(unidade) between 1 and 6),
  add column if not exists variacao_de uuid references public.loja_produtos(id) on delete cascade,
  add column if not exists variacao_rotulo text check (variacao_rotulo is null or length(variacao_rotulo) between 1 and 60);

alter table public.loja_produtos drop constraint if exists loja_produtos_variacao_check;
alter table public.loja_produtos add constraint loja_produtos_variacao_check
  check (variacao_de is null or (variacao_de <> id and variacao_rotulo is not null));

create index if not exists loja_produtos_variacao_de_idx on public.loja_produtos (variacao_de);

-- Cria ou altera uma variação do produto principal.
create or replace function public.salvar_variacao_loja(
  p_pai uuid,
  p_id uuid,
  p_rotulo text,
  p_preco integer,
  p_promo integer,
  p_estoque integer,
  p_ativo boolean
)
returns uuid
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  pai public.loja_produtos%rowtype;
  v_rotulo text := trim(coalesce(p_rotulo, ''));
  v_id uuid;
begin
  if not privado.eh_admin() then
    raise exception 'Apenas administradores.';
  end if;

  select * into pai from public.loja_produtos where id = p_pai;
  if not found then
    raise exception 'Produto principal não encontrado.';
  end if;
  if pai.variacao_de is not null then
    raise exception 'Uma variação não pode ter outras variações. Escolha o produto principal.';
  end if;
  if v_rotulo = '' or length(v_rotulo) > 60 then
    raise exception 'Informe o nome da variação (ex.: P / Azul), com até 60 caracteres.';
  end if;
  if p_preco is null or p_preco < 0 or (p_promo is not null and (p_promo < 0 or p_promo > p_preco)) then
    raise exception 'Preço inválido. A promoção não pode ser maior que o preço normal.';
  end if;
  if p_estoque is null or p_estoque < 0 then
    raise exception 'Informe o estoque (0 ou mais).';
  end if;

  if p_id is null then
    insert into public.loja_produtos (
      categoria_id, nome, descricao, preco_centavos, preco_promo_centavos, estoque, imagem_caminho,
      ativo, peso_g, altura_cm, largura_cm, comprimento_cm, ncm, unidade, criado_por,
      variacao_de, variacao_rotulo
    ) values (
      pai.categoria_id, pai.nome || ' (' || v_rotulo || ')', pai.descricao, p_preco, p_promo, p_estoque,
      pai.imagem_caminho, coalesce(p_ativo, true), pai.peso_g, pai.altura_cm, pai.largura_cm,
      pai.comprimento_cm, pai.ncm, pai.unidade, auth.uid(), pai.id, v_rotulo
    )
    returning id into v_id;
  else
    update public.loja_produtos
       set nome = pai.nome || ' (' || v_rotulo || ')',
           variacao_rotulo = v_rotulo,
           preco_centavos = p_preco,
           preco_promo_centavos = p_promo,
           estoque = p_estoque,
           ativo = coalesce(p_ativo, true),
           atualizado_em = now()
     where id = p_id and variacao_de = pai.id
    returning id into v_id;
    if v_id is null then
      raise exception 'Variação não encontrada para este produto.';
    end if;
  end if;

  perform privado.auditar(case when p_id is null then 'variacao_criada' else 'variacao_alterada' end,
                          'produto', v_id::text, jsonb_build_object('pai', pai.id, 'rotulo', v_rotulo));
  return v_id;
end;
$$;

-- Vitrine: só produtos principais. Com variações, mostra o menor preço e o estoque somado.
drop function if exists public.vitrine_loja(uuid, text);
create function public.vitrine_loja(p_categoria uuid default null, p_busca text default null)
returns table(
  id uuid, nome text, preco_centavos integer, preco_promo_centavos integer, imagem_caminho text,
  estoque integer, categoria_id uuid, categoria_nome text, media numeric, avaliacoes bigint,
  favorito boolean, tem_variacoes boolean
)
language sql
stable
security definer
set search_path = public, privado
as $$
  select p.id, p.nome,
         coalesce(v.minimo, p.preco_centavos),
         case when coalesce(v.total, 0) = 0 then p.preco_promo_centavos end,
         p.imagem_caminho,
         case when coalesce(v.total, 0) = 0 then p.estoque else coalesce(v.estoque_total, 0)::integer end,
         p.categoria_id, c.nome,
         r.media, coalesce(r.total, 0),
         exists (select 1 from public.favoritos f where f.produto_id = p.id and f.usuario_id = auth.uid()),
         coalesce(v.total, 0) > 0
    from public.loja_produtos p
    left join public.loja_categorias c on c.id = p.categoria_id
    left join lateral (
      select round(avg(a.nota)::numeric, 1) as media, count(*) as total
        from public.avaliacoes_produto a
       where a.produto_id = p.id and a.status = 'publicada'
    ) r on true
    left join lateral (
      select count(*) as total,
             min(coalesce(c2.preco_promo_centavos, c2.preco_centavos)) filter (where c2.ativo) as minimo,
             sum(c2.estoque) filter (where c2.ativo) as estoque_total
        from public.loja_produtos c2
       where c2.variacao_de = p.id
    ) v on true
   where p.variacao_de is null
     and p.ativo
     and privado.usuario_aprovado()
     and (p_categoria is null or p.categoria_id = p_categoria)
     and (p_busca is null or length(trim(p_busca)) = 0
          or p.nome ilike '%' || replace(replace(trim(p_busca), '%', ''), '_', '') || '%')
   order by p.nome
   limit 200;
$$;

-- Recomendações: mesma regra da E4, sem variações (a vitrine mostra o produto principal).
drop function if exists public.recomendados_para_mim();
create function public.recomendados_para_mim()
returns table(
  id uuid, nome text, preco_centavos integer, preco_promo_centavos integer, imagem_caminho text,
  estoque integer, categoria_id uuid, categoria_nome text, media numeric, avaliacoes bigint,
  favorito boolean, motivo text, tem_variacoes boolean
)
language sql
stable
security definer
set search_path = public, privado
as $$
  with categorias_favoritas as (
    select distinct p.categoria_id
      from public.favoritos f
      join public.loja_produtos p on p.id = f.produto_id
     where f.usuario_id = auth.uid() and p.categoria_id is not null
  ),
  categorias_compradas as (
    select distinct p.categoria_id
      from public.pedidos o
      join public.pedido_itens i on i.pedido_id = o.id
      join public.loja_produtos p on p.id = i.produto_id
     where o.usuario_id = auth.uid()
       and o.status not in ('cancelado', 'expirado')
       and p.categoria_id is not null
  ),
  indicados as (
    select i.produto_id
      from public.indicacoes_loja i
      join public.indicacoes_loja_aceites a on a.indicacao_id = i.id
     where a.usuario_id = auth.uid() and i.produto_id is not null
    union
    select li.produto_id
      from public.indicacoes_loja i
      join public.indicacoes_loja_aceites a on a.indicacao_id = i.id
      join public.lista_loja_itens li on li.lista_id = i.lista_id
     where a.usuario_id = auth.uid() and i.lista_id is not null
  )
  select p.id, p.nome,
         coalesce(v.minimo, p.preco_centavos),
         case when coalesce(v.total, 0) = 0 then p.preco_promo_centavos end,
         p.imagem_caminho,
         case when coalesce(v.total, 0) = 0 then p.estoque else coalesce(v.estoque_total, 0)::integer end,
         p.categoria_id, c.nome,
         r.media, coalesce(r.total, 0), false,
         case
           when exists (select 1 from indicados x where x.produto_id = p.id) then 'Indicado por um amigo'
           when p.categoria_id in (select cf.categoria_id from categorias_favoritas cf) then 'Parecido com o que você favoritou'
           when p.categoria_id in (select cc.categoria_id from categorias_compradas cc) then 'Parecido com o que você já comprou'
           when coalesce(r.media, 0) >= 4 then 'Muito bem avaliado pelos cooperados'
           else 'Novidade na loja'
         end,
         coalesce(v.total, 0) > 0
    from public.loja_produtos p
    left join public.loja_categorias c on c.id = p.categoria_id
    left join lateral (
      select round(avg(a.nota)::numeric, 1) as media, count(*) as total
        from public.avaliacoes_produto a
       where a.produto_id = p.id and a.status = 'publicada'
    ) r on true
    left join lateral (
      select count(*) as total,
             min(coalesce(c2.preco_promo_centavos, c2.preco_centavos)) filter (where c2.ativo) as minimo,
             sum(c2.estoque) filter (where c2.ativo) as estoque_total
        from public.loja_produtos c2
       where c2.variacao_de = p.id
    ) v on true
   where p.variacao_de is null
     and p.ativo
     and (p.estoque > 0 or coalesce(v.estoque_total, 0) > 0)
     and privado.usuario_aprovado()
     and not exists (select 1 from public.favoritos f where f.produto_id = p.id and f.usuario_id = auth.uid())
   order by
     exists (select 1 from indicados x where x.produto_id = p.id) desc,
     (p.categoria_id in (select cf.categoria_id from categorias_favoritas cf)) desc,
     (p.categoria_id in (select cc.categoria_id from categorias_compradas cc)) desc,
     r.media desc nulls last,
     coalesce(r.total, 0) desc,
     p.nome
   limit 12;
$$;

-- =====================================================================
-- 4. NOTA FISCAL (Focus NFe)
-- Emissão, consulta e cancelamento. O token fica no Vault. O navegador nunca fala com o Focus NFe.
-- =====================================================================
alter table public.pedidos
  add column if not exists nf_status text check (nf_status in ('processando', 'autorizada', 'erro', 'cancelada')),
  add column if not exists nf_ref text,
  add column if not exists nf_tentativas smallint not null default 0,
  add column if not exists nf_numero text,
  add column if not exists nf_chave text,
  add column if not exists nf_danfe text,
  add column if not exists nf_erro text check (nf_erro is null or length(nf_erro) <= 1000),
  add column if not exists nf_atualizada_em timestamptz;

-- Passo 1 da emissão: confere os dados fiscais e devolve tudo que a Edge Function precisa montar a nota.
create or replace function public.preparar_nota_loja(p_pedido uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  p public.pedidos%rowtype;
  u public.usuarios%rowtype;
  cfg jsonb := '{}'::jsonb;
  v_faltando text[] := '{}';
  v_campo text;
  v_sem_ncm text;
  v_itens jsonb;
  v_ref text;
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
  if p.nf_status in ('processando', 'autorizada') then
    raise exception 'Este pedido já tem uma nota em situação "%". Atualize a situação antes de emitir outra.',
      case p.nf_status when 'processando' then 'em processamento' else 'autorizada' end;
  end if;

  select coalesce(jsonb_object_agg(l.chave, l.valor), '{}'::jsonb) into cfg
    from public.loja_configuracoes l where l.chave like 'fiscal\_%';

  if cfg->>'fiscal_ativo' is distinct from 'sim' then
    raise exception 'A emissão de nota fiscal está desligada. Ligue em Pagamento e configurações.';
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
    raise exception 'Preencha os dados fiscais em Pagamento e configurações: %.', array_to_string(v_faltando, ', ');
  end if;

  select string_agg(coalesce(pr.nome, i.nome_snapshot), ', ') into v_sem_ncm
    from public.pedido_itens i
    left join public.loja_produtos pr on pr.id = i.produto_id
   where i.pedido_id = p_pedido and (pr.id is null or pr.ncm is null);
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
   where i.pedido_id = p_pedido;

  select * into u from public.usuarios where id = p.usuario_id;

  -- Referência nova a cada tentativa: a Focus NFe não aceita reaproveitar a referência de uma nota já enviada.
  v_ref := 'ped' || replace(p.id::text, '-', '') || '-' || (p.nf_tentativas + 1);
  update public.pedidos
     set nf_status = 'processando', nf_ref = v_ref, nf_tentativas = nf_tentativas + 1,
         nf_erro = null, nf_atualizada_em = now()
   where id = p_pedido;

  perform privado.auditar('nota_emissao_solicitada', 'pedido', p_pedido::text, jsonb_build_object('ref', v_ref));

  return jsonb_build_object(
    'ref', v_ref,
    'ambiente', coalesce(cfg->>'fiscal_ambiente', 'homologacao'),
    'regime', cfg->>'fiscal_regime',
    'config', cfg,
    'metodo_entrega', p.metodo_entrega,
    'subtotal_centavos', p.subtotal_centavos,
    'frete_centavos', p.frete_centavos,
    'desconto_centavos', p.desconto_centavos,
    'total_centavos', p.total_centavos,
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

-- Dados para consultar ou cancelar uma nota já emitida.
create or replace function public.referencia_nota_loja(p_pedido uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, privado
as $$
declare
  p public.pedidos%rowtype;
begin
  if not privado.eh_admin() then
    raise exception 'Apenas administradores.';
  end if;
  select * into p from public.pedidos where id = p_pedido;
  if not found or p.nf_ref is null then
    raise exception 'Este pedido ainda não tem nota fiscal emitida.';
  end if;
  return jsonb_build_object(
    'ref', p.nf_ref,
    'nf_status', p.nf_status,
    'numero', p.nf_numero,
    'ambiente', coalesce((select l.valor from public.loja_configuracoes l where l.chave = 'fiscal_ambiente'), 'homologacao')
  );
end;
$$;

-- Passo 2: a Edge Function registra o resultado (só o servidor).
create or replace function public.confirmar_nota_loja(
  p_pedido uuid, p_status text, p_numero text, p_chave text, p_danfe text, p_erro text
)
returns void
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  v_usuario uuid;
begin
  update public.pedidos
     set nf_status = p_status,
         nf_numero = coalesce(p_numero, nf_numero),
         nf_chave = coalesce(p_chave, nf_chave),
         nf_danfe = coalesce(p_danfe, nf_danfe),
         nf_erro = case when p_status = 'erro' then left(p_erro, 1000) else null end,
         nf_atualizada_em = now()
   where id = p_pedido
  returning usuario_id into v_usuario;

  if not found then
    return;
  end if;

  if p_status = 'autorizada' and v_usuario is not null then
    perform privado.notificar(array[v_usuario], 'Nota fiscal emitida',
                              'Sua nota fiscal está disponível em Meus pedidos.', null);
  end if;
  perform privado.auditar('nota_' || p_status, 'pedido', p_pedido::text,
                          jsonb_build_object('numero', p_numero, 'erro', left(coalesce(p_erro, ''), 300)));
end;
$$;

-- =====================================================================
-- 5. PERMISSÕES
-- =====================================================================
revoke all on function public.vitrine_loja(uuid, text) from public, anon;
grant execute on function public.vitrine_loja(uuid, text) to authenticated;

revoke all on function public.recomendados_para_mim() from public, anon;
grant execute on function public.recomendados_para_mim() to authenticated;

revoke all on function public.salvar_variacao_loja(uuid, uuid, text, integer, integer, integer, boolean) from public, anon;
grant execute on function public.salvar_variacao_loja(uuid, uuid, text, integer, integer, integer, boolean) to authenticated;

revoke all on function public.preparar_nota_loja(uuid) from public, anon;
grant execute on function public.preparar_nota_loja(uuid) to authenticated;

revoke all on function public.referencia_nota_loja(uuid) from public, anon;
grant execute on function public.referencia_nota_loja(uuid) to authenticated;

revoke all on function public.confirmar_nota_loja(uuid, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.confirmar_nota_loja(uuid, text, text, text, text, text) to service_role;

revoke all on function public.excluir_minha_conta(text) from public, anon;
grant execute on function public.excluir_minha_conta(text) to authenticated;
