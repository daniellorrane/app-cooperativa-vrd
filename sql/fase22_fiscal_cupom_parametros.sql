-- Fase 22: regras fiscais e de cupom configuráveis.
-- nf_emissor: cada vendedor emite pela própria conta (padrão), ou a cooperativa emite as notas dos produtos de vendedor.
-- cupom_rateio_metodo e cupom_rateio_arredondamento: como o desconto do cupom da cooperativa é dividido entre as notas.
-- A conta usada em cada nota fica gravada, para a consulta e o cancelamento usarem a mesma conta da emissão,
-- mesmo que o parâmetro seja trocado depois.
-- Rode no SQL Editor do Supabase e responda "feito".

-- 0. Verificação
do $$
begin
  if to_regprocedure('public.preparar_nota_loja(uuid,uuid)') is null
     or to_regprocedure('public.referencia_nota_loja(uuid,uuid)') is null
     or to_regprocedure('privado.parametro_loja(text)') is null then
    raise exception 'Fases 17b e 21 não encontradas. Aplique-as antes desta.';
  end if;
end $$;

-- 1. Catálogo: três parâmetros novos
insert into public.loja_parametros (chave, grupo, rotulo, ajuda, tipo, opcoes, minimo, maximo, padrao, ordem) values
  ('nf_emissor', 'fiscal', 'Quem emite a nota dos produtos de vendedor',
   'Cada vendedor emite pela própria conta, ou a cooperativa emite essas notas pela conta dela. A segunda opção muda a responsabilidade fiscal: confirme com o contador antes de usar.',
   'escolha', '[{"valor":"vendedor","rotulo":"Cada vendedor, pela própria conta (padrão)"},{"valor":"cooperativa","rotulo":"A cooperativa, pela conta da cooperativa"}]',
   null, null, 'vendedor', 25),
  ('cupom_rateio_metodo', 'fiscal', 'Divisão do desconto do cupom da cooperativa entre as notas',
   'Define a parte do desconto que cada nota recebe. O desconto de cupom de vendedor fica sempre na nota dele.',
   'escolha', '[{"valor":"subtotal","rotulo":"Proporcional ao valor de cada grupo (padrão)"},{"valor":"quantidade","rotulo":"Proporcional à quantidade de itens"},{"valor":"igual","rotulo":"Igual para cada grupo"}]',
   null, null, 'subtotal', 230),
  ('cupom_rateio_arredondamento', 'fiscal', 'Centavos que sobram do rateio',
   'Quem fica com a diferença de centavos do arredondamento.',
   'escolha', '[{"valor":"cooperativa","rotulo":"A cooperativa (padrão)"},{"valor":"maior_grupo","rotulo":"O grupo com maior valor"}]',
   null, null, 'cooperativa', 240)
on conflict (chave) do update set
  grupo = excluded.grupo, rotulo = excluded.rotulo, ajuda = excluded.ajuda, tipo = excluded.tipo,
  opcoes = excluded.opcoes, minimo = excluded.minimo, maximo = excluded.maximo,
  padrao = excluded.padrao, ordem = excluded.ordem;

-- 2. Colunas de conta usada na emissão (a consulta e o cancelamento usam a mesma conta)
alter table public.pedido_notas
  add column if not exists conta_token_nome text,
  add column if not exists conta_ambiente text;

-- 3. Rateio do desconto entre os grupos do pedido (cupom de vendedor fica no grupo dele)
create or replace function privado.rateio_desconto_pedido(p_pedido uuid)
returns table (grupo_vendedor_id uuid, parte_desconto integer)
language plpgsql
stable
security definer
set search_path = public, privado
as $$
declare
  p public.pedidos%rowtype;
  v_metodo text := coalesce(nullif(privado.parametro_loja('cupom_rateio_metodo'), ''), 'subtotal');
  v_arredondamento text := coalesce(nullif(privado.parametro_loja('cupom_rateio_arredondamento'), ''), 'cooperativa');
  v_dono uuid;
  v_desconto integer;
begin
  select * into p from public.pedidos where id = p_pedido;
  if not found then
    return;
  end if;

  v_desconto := coalesce(p.desconto_centavos, 0);

  -- Sem desconto: todos os grupos ficam com zero
  if v_desconto <= 0 then
    return query
      select g.vendedor_id, 0
        from (select distinct i.vendedor_id from public.pedido_itens i where i.pedido_id = p_pedido) g;
    return;
  end if;

  -- Cupom de vendedor: o desconto inteiro fica no grupo dele
  if p.cupom_id is not null then
    select c.vendedor_id into v_dono from public.cupons_loja c where c.id = p.cupom_id;
  end if;
  if v_dono is not null then
    return query
      select g.vendedor_id, (case when g.vendedor_id is not distinct from v_dono then v_desconto else 0 end)::integer
        from (select distinct i.vendedor_id from public.pedido_itens i where i.pedido_id = p_pedido) g;
    return;
  end if;

  -- Cupom da cooperativa: divide pelo método escolhido e ajusta a diferença de centavos
  return query
  with grupos as (
    select i.vendedor_id,
           sum(i.quantidade * i.preco_unitario_centavos)::numeric as valor,
           sum(i.quantidade)::numeric as qtd
      from public.pedido_itens i
     where i.pedido_id = p_pedido
     group by i.vendedor_id
  ),
  pesos as (
    select g.vendedor_id,
           (case v_metodo when 'quantidade' then g.qtd when 'igual' then 1::numeric else g.valor end) as peso
      from grupos g
  ),
  partes as (
    select s.vendedor_id, s.peso,
           coalesce(round(v_desconto::numeric * s.peso / nullif(sum(s.peso) over (), 0))::integer, 0) as parte
      from pesos s
  ),
  escolhido as (
    select pa.vendedor_id
      from partes pa
     order by (case when v_arredondamento = 'cooperativa' and pa.vendedor_id is null then 0 else 1 end),
              pa.peso desc, pa.vendedor_id nulls first
     limit 1
  )
  select pa.vendedor_id,
         (pa.parte + case when pa.vendedor_id is not distinct from (select e.vendedor_id from escolhido e)
                          then v_desconto - (select sum(x.parte) from partes x)
                          else 0 end)::integer
    from partes pa;
end;
$$;

revoke execute on function privado.rateio_desconto_pedido(uuid) from public, anon, authenticated;

-- 4. Preparação da nota: quem emite depende do parâmetro nf_emissor
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
  v_tentativas integer;
  v_ref text;
  v_total integer;
  v_token_nome text;
  v_existe boolean;
  v_emissor text := coalesce(nullif(privado.parametro_loja('nf_emissor'), ''), 'vendedor');
  v_pela_cooperativa boolean;
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

  -- Grupo: cooperativa (nulo) ou vendedor. Produtos de vendedor saem pela cooperativa quando o parâmetro manda.
  v_pela_cooperativa := p_vendedor is null or v_emissor = 'cooperativa';

  if p_vendedor is null then
    select exists (select 1 from public.pedido_itens i where i.pedido_id = p_pedido and i.vendedor_id is null) into v_existe;
    if not v_existe then
      raise exception 'Este pedido não tem produtos da cooperativa.';
    end if;
  else
    select * into v_vend from public.loja_vendedores where id = p_vendedor;
    if not found then
      raise exception 'Vendedor não encontrado.';
    end if;
    select exists (select 1 from public.pedido_itens i where i.pedido_id = p_pedido and i.vendedor_id = p_vendedor) into v_existe;
    if not v_existe then
      raise exception 'Este pedido não tem produtos deste vendedor.';
    end if;
  end if;

  if v_pela_cooperativa then
    select coalesce(jsonb_object_agg(l.chave, l.valor), '{}'::jsonb) into cfg
      from public.loja_configuracoes l where l.chave like 'fiscal\_%';
    if cfg->>'fiscal_ativo' is distinct from 'sim' then
      raise exception 'A emissão de nota fiscal está desligada. Ligue em Pagamento e configurações.';
    end if;
    v_token_nome := 'focus_nfe_token';
  else
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

  -- Desconto deste grupo, conforme o rateio dos parâmetros
  select r.parte_desconto into v_desconto
    from privado.rateio_desconto_pedido(p_pedido) r
   where r.grupo_vendedor_id is not distinct from p_vendedor;
  v_desconto := coalesce(v_desconto, 0);

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

  insert into public.pedido_notas (pedido_id, vendedor_id, status, ref, tentativas, erro, valor_centavos, atualizada_em,
                                   conta_token_nome, conta_ambiente)
  values (p_pedido, p_vendedor, 'processando', v_ref, v_tentativas, null, v_total, now(),
          v_token_nome, coalesce(cfg->>'fiscal_ambiente', 'homologacao'))
  on conflict (pedido_id, (coalesce(vendedor_id, '00000000-0000-0000-0000-000000000000'::uuid)))
  do update set status = 'processando', ref = excluded.ref, tentativas = excluded.tentativas,
                erro = null, valor_centavos = excluded.valor_centavos, atualizada_em = now(),
                conta_token_nome = excluded.conta_token_nome, conta_ambiente = excluded.conta_ambiente;

  select * into u from public.usuarios where id = p.usuario_id;

  perform privado.auditar('nota_emissao_solicitada', 'pedido', p_pedido::text,
                          jsonb_build_object('ref', v_ref, 'vendedor', p_vendedor, 'emitida_pela_cooperativa', v_pela_cooperativa));

  return jsonb_build_object(
    'ref', v_ref,
    'ambiente', coalesce(cfg->>'fiscal_ambiente', 'homologacao'),
    'regime', cfg->>'fiscal_regime',
    'config', cfg,
    'token_nome', v_token_nome,
    'emitida_pela_cooperativa', v_pela_cooperativa,
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

-- 5. Referência da nota (consulta e cancelamento): usa a conta gravada na emissão
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
  v_token text;
  v_emissor text := coalesce(nullif(privado.parametro_loja('nf_emissor'), ''), 'vendedor');
begin
  if not privado.eh_admin() then
    raise exception 'Apenas administradores.';
  end if;

  select * into n from public.pedido_notas
   where pedido_id = p_pedido and vendedor_id is not distinct from p_vendedor;
  if not found or n.ref is null then
    raise exception 'Esta nota ainda não foi emitida.';
  end if;

  -- Notas emitidas depois da fase 22 guardam a conta usada; as anteriores seguem a regra atual
  if n.conta_token_nome is not null then
    v_token := n.conta_token_nome;
    v_ambiente := n.conta_ambiente;
  elsif p_vendedor is null or v_emissor = 'cooperativa' then
    v_token := 'focus_nfe_token';
    select coalesce((select l.valor from public.loja_configuracoes l where l.chave = 'fiscal_ambiente'), 'homologacao') into v_ambiente;
  else
    v_token := 'nf_vendedor_' || p_vendedor::text || '_token';
    select v.fiscal_ambiente into v_ambiente from public.loja_vendedores v where v.id = p_vendedor;
  end if;

  return jsonb_build_object(
    'ref', n.ref,
    'nf_status', n.status,
    'numero', n.numero,
    'ambiente', coalesce(v_ambiente, 'homologacao'),
    'token_nome', v_token
  );
end;
$$;

-- 6. Verificação final
do $$
declare
  v_qtd integer;
  r record;
  v_soma integer;
begin
  select count(*) into v_qtd from public.loja_parametros
   where chave in ('nf_emissor', 'cupom_rateio_metodo', 'cupom_rateio_arredondamento');
  if v_qtd <> 3 then
    raise exception 'Parâmetros da fase 22 não cadastrados.';
  end if;
  if privado.parametro_loja('nf_emissor') <> 'vendedor' then
    raise exception 'Padrão de nf_emissor incorreto.';
  end if;

  -- Em todos os pedidos com desconto, a soma das partes tem de ser igual ao desconto
  for r in select p.id, p.desconto_centavos from public.pedidos p where coalesce(p.desconto_centavos, 0) > 0 loop
    select coalesce(sum(x.parte_desconto), 0)::integer into v_soma from privado.rateio_desconto_pedido(r.id) x;
    if v_soma <> r.desconto_centavos then
      raise exception 'Rateio do pedido % não fecha: % de %.', r.id, v_soma, r.desconto_centavos;
    end if;
  end loop;
end $$;
