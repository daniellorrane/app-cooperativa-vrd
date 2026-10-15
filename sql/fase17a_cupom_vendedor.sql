-- Fase 17 (parte 1): cupom por vendedor.
-- Cupom cadastrado por um vendedor vale só para os produtos dele. O desconto é calculado sobre esses itens
-- (e o valor mínimo também). Quem cadastrou arca com o desconto (extrato). Cupom da cooperativa continua valendo para o carrinho inteiro.
-- Vendedor suspenso ou não aprovado tem os cupons parados.
-- Rode no SQL Editor do Supabase e responda "feito".

-- 0. Verificação
do $$
begin
  if to_regprocedure('public.criar_pedido_loja(uuid,jsonb,jsonb,text)') is null
     or to_regprocedure('privado.vendedor_aprovado(uuid)') is null
     or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'cupons_loja' and column_name = 'vendedor_id') then
    raise exception 'Fase 16 (parte 2) não encontrada. Aplique a fase 16 antes desta.';
  end if;
end $$;

-- 1. Subtotal do carrinho para o cupom: o carrinho inteiro (cupom da cooperativa) ou só os itens do vendedor
create or replace function privado.subtotal_carrinho_cupom(p_usuario uuid, p_vendedor uuid)
returns integer
language sql
stable
security definer
set search_path = public, privado
as $$
  select coalesce(sum(ci.quantidade * coalesce(p.preco_promo_centavos, p.preco_centavos)), 0)::integer
    from public.carrinho_itens ci
    join public.loja_produtos p on p.id = ci.produto_id
   where ci.usuario_id = p_usuario
     and (p_vendedor is null or p.vendedor_id = p_vendedor);
$$;

-- 2. Conferência do cupom: cupom de vendedor só vale se o vendedor estiver aprovado
create or replace function privado.checar_cupom(p_codigo text, p_usuario uuid, p_subtotal integer, p_bloquear boolean default false)
returns public.cupons_loja
language plpgsql
security definer
set search_path = public, privado
as $function$
declare
  c public.cupons_loja%rowtype;
  v_codigo text := upper(trim(coalesce(p_codigo, '')));
  v_usos_total integer;
  v_usos_usuario integer;
begin
  if v_codigo = '' then
    raise exception 'Informe o código do cupom.';
  end if;

  if p_bloquear then
    select * into c from public.cupons_loja where codigo = v_codigo for update;
  else
    select * into c from public.cupons_loja where codigo = v_codigo;
  end if;

  if not found or not c.ativo or (c.validade_ate is not null and c.validade_ate <= now()) then
    raise exception 'Cupom inválido ou expirado.';
  end if;
  -- Cupom de vendedor suspenso ou não aprovado não vale
  if c.vendedor_id is not null and not privado.vendedor_aprovado(c.vendedor_id) then
    raise exception 'Cupom inválido ou expirado.';
  end if;

  if p_subtotal < c.minimo_centavos then
    raise exception 'Este cupom vale para compras a partir de R$ %.',
      replace(trim(to_char(c.minimo_centavos / 100.0, '999999990.00')), '.', ',');
  end if;

  -- Pedidos cancelados, expirados ou com prazo vencido não contam como uso.
  select count(*) into v_usos_total from public.pedidos p
   where p.cupom_id = c.id
     and not (p.status in ('cancelado', 'expirado') or (p.status = 'aguardando_pagamento' and p.expira_em <= now()));

  if c.limite_usos is not null and v_usos_total >= c.limite_usos then
    raise exception 'Este cupom já atingiu o limite de uso.';
  end if;

  select count(*) into v_usos_usuario from public.pedidos p
   where p.cupom_id = c.id and p.usuario_id = p_usuario
     and not (p.status in ('cancelado', 'expirado') or (p.status = 'aguardando_pagamento' and p.expira_em <= now()));

  if v_usos_usuario >= c.limite_por_usuario then
    raise exception 'Você já usou este cupom.';
  end if;

  return c;
end;
$function$;

-- 3. Validação do cupom no carrinho (tela de finalização): mostra o desconto sobre a base certa
create or replace function public.validar_cupom_loja(p_codigo text)
returns jsonb
language plpgsql
security definer
set search_path = public, privado
as $function$
declare
  v_usuario uuid := auth.uid();
  v_subtotal integer;
  v_base integer;
  v_vendedor_cupom uuid;
  v_nome_loja text;
  c public.cupons_loja%rowtype;
begin
  if not privado.usuario_aprovado() then
    raise exception 'Sua conta precisa estar aprovada para comprar.';
  end if;

  v_subtotal := privado.subtotal_carrinho(v_usuario);
  if v_subtotal = 0 then
    raise exception 'Seu carrinho está vazio.';
  end if;

  -- Cupom de vendedor: base é só o que é desse vendedor. Código inexistente cai na checagem abaixo.
  select vendedor_id into v_vendedor_cupom from public.cupons_loja
   where codigo = upper(trim(coalesce(p_codigo, '')));

  v_base := privado.subtotal_carrinho_cupom(v_usuario, v_vendedor_cupom);
  if v_base = 0 then
    raise exception 'Este cupom não vale para os produtos do seu carrinho.';
  end if;

  c := privado.checar_cupom(p_codigo, v_usuario, v_base, false);

  if c.vendedor_id is not null then
    select nome_loja into v_nome_loja from public.loja_vendedores where id = c.vendedor_id;
  end if;

  return jsonb_build_object(
    'codigo', c.codigo,
    'subtotal_centavos', v_subtotal,
    'base_centavos', v_base,
    'desconto_centavos', privado.desconto_cupom(c, v_base),
    'escopo', case when c.vendedor_id is null then 'carrinho' else 'vendedor' end,
    'nome_loja', v_nome_loja
  );
end;
$function$;

-- 4. Checkout: o desconto do cupom de vendedor é calculado sobre os itens do vendedor no pedido.
-- Restante igual à fase 16 (parte 2).
create or replace function public.criar_pedido_loja(
  p_cotacao uuid,
  p_escolhas jsonb,
  p_endereco jsonb default null,
  p_cupom text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  v_usuario uuid := auth.uid();
  v_cot public.cotacoes_frete%rowtype;
  g jsonb;
  v_opcao jsonb;
  v_chave text;
  v_grupos integer;
  v_metodos text[] := '{}';
  v_metodo text;
  v_frete integer := 0;
  v_prazo integer := 0;
  v_rotulos text[] := '{}';
  v_assinatura text;
  v_pedido uuid;
  v_minutos integer;
  v_subtotal integer := 0;
  v_desconto integer := 0;
  v_base integer := 0;
  v_cupom_vendedor uuid;
  v_cupom_id uuid;
  v_cupom_codigo text;
  v_abertos integer;
  v_campo text;
  c public.cupons_loja%rowtype;
  r record;
begin
  if not privado.usuario_aprovado() then
    raise exception 'Sua conta precisa estar aprovada para comprar.';
  end if;

  select * into v_cot from public.cotacoes_frete
   where id = p_cotacao and usuario_id = v_usuario
   for update;
  if not found then
    raise exception 'Cotação de frete não encontrada. Calcule o frete de novo.';
  end if;
  if v_cot.expira_em <= now() then
    raise exception 'A cotação de frete expirou. Calcule de novo.';
  end if;

  select string_agg(c2.produto_id::text || ':' || c2.quantidade::text, ',' order by c2.produto_id::text)
    into v_assinatura
    from public.carrinho_itens c2 where c2.usuario_id = v_usuario;
  if v_assinatura is distinct from v_cot.carrinho_assinatura then
    raise exception 'Seu carrinho mudou depois do cálculo do frete. Calcule de novo.';
  end if;

  -- Cada grupo (cooperativa ou vendedor) precisa de uma escolha válida, vinda da cotação do servidor
  v_grupos := jsonb_array_length(v_cot.grupos);
  if v_grupos is null or v_grupos = 0 then
    raise exception 'Cotação de frete sem entregas. Calcule de novo.';
  end if;
  if p_escolhas is null or jsonb_typeof(p_escolhas) <> 'object'
     or (select count(*) from jsonb_object_keys(p_escolhas)) <> v_grupos then
    raise exception 'Escolha a forma de entrega de cada parte do pedido.';
  end if;

  for g in select value from jsonb_array_elements(v_cot.grupos) loop
    v_chave := g->>'chave';
    if not (p_escolhas ? v_chave) then
      raise exception 'Escolha a forma de entrega de cada parte do pedido.';
    end if;
    select o.value into v_opcao from jsonb_array_elements(g->'opcoes') o
     where o.value->>'id' = p_escolhas->>v_chave
     limit 1;
    if v_opcao is null then
      raise exception 'Escolha uma opção de entrega válida para "%".', g->>'nome';
    end if;
    v_metodos := v_metodos || (v_opcao->>'metodo');
    v_frete := v_frete + (v_opcao->>'preco_centavos')::integer;
    v_prazo := greatest(v_prazo, coalesce((v_opcao->>'prazo_dias')::integer, 0));
  end loop;

  -- Retirada só existe quando o carrinho é todo da cooperativa (um grupo só)
  if v_grupos > 1 and 'retirada' = any(v_metodos) then
    raise exception 'Retirada na cooperativa só vale para pedidos só com produtos da cooperativa.';
  end if;
  v_metodo := case when v_grupos = 1 then v_metodos[1] else 'transportadora' end;

  if v_metodo <> 'retirada' then
    if p_endereco is null then
      raise exception 'Informe o endereço de entrega.';
    end if;
    foreach v_campo in array array['cep', 'logradouro', 'numero', 'bairro', 'cidade', 'uf'] loop
      if coalesce(trim(p_endereco->>v_campo), '') = '' then
        raise exception 'Preencha o endereço de entrega (campo: %).', v_campo;
      end if;
    end loop;
    if p_endereco->>'cep' <> v_cot.cep then
      raise exception 'O CEP do endereço não é o mesmo da cotação. Calcule o frete de novo.';
    end if;
  end if;

  select count(*) into v_abertos from public.pedidos
   where usuario_id = v_usuario and status = 'aguardando_pagamento' and expira_em > now();
  if v_abertos >= 3 then
    raise exception 'Você já tem 3 pedidos aguardando pagamento. Pague ou cancele um deles antes de continuar.';
  end if;

  select coalesce((select nullif(valor, '')::integer from public.loja_configuracoes
                    where chave = 'minutos_expiracao_pedido'), 30)
    into v_minutos;

  -- Rótulo do frete no pedido: o nome da opção (um grupo) ou "grupo: opção" (vários grupos)
  for g in select value from jsonb_array_elements(v_cot.grupos) loop
    v_opcao := null;
    select o.value into v_opcao from jsonb_array_elements(g->'opcoes') o
     where o.value->>'id' = p_escolhas->>(g->>'chave') limit 1;
    v_rotulos := array_append(v_rotulos,
      case when v_grupos = 1 then v_opcao->>'nome' else (g->>'nome') || ': ' || (v_opcao->>'nome') end);
  end loop;

  insert into public.pedidos (
    usuario_id, metodo_entrega, subtotal_centavos, frete_centavos, total_centavos,
    expira_em, endereco, frete_servico, prazo_dias
  ) values (
    v_usuario, v_metodo, 0, v_frete, v_frete,
    now() + make_interval(mins => v_minutos),
    case when v_metodo = 'retirada' then null else
      jsonb_build_object(
        'cep', p_endereco->>'cep', 'logradouro', p_endereco->>'logradouro',
        'numero', p_endereco->>'numero', 'complemento', nullif(p_endereco->>'complemento', ''),
        'bairro', p_endereco->>'bairro', 'cidade', p_endereco->>'cidade', 'uf', p_endereco->>'uf')
    end,
    left(array_to_string(v_rotulos, '; '), 150),
    least(v_prazo, 90)::smallint
  )
  returning id into v_pedido;

  -- Itens: estoque travado e decrementado, preço do momento da compra
  for r in
    select c2.quantidade, p.id as produto_id, p.nome, p.preco_centavos, p.preco_promo_centavos,
           p.estoque, p.ativo
      from public.carrinho_itens c2
      join public.loja_produtos p on p.id = c2.produto_id
     where c2.usuario_id = v_usuario
     for update of p
  loop
    if not r.ativo then
      raise exception 'O produto "%" não está mais disponível. Remova do carrinho e tente de novo.', r.nome;
    end if;
    if r.estoque < r.quantidade then
      raise exception 'Estoque insuficiente para "%". Restam % unidade(s).', r.nome, r.estoque;
    end if;

    update public.loja_produtos set estoque = estoque - r.quantidade where id = r.produto_id;

    insert into public.pedido_itens (pedido_id, produto_id, nome_snapshot, preco_unitario_centavos, quantidade)
    values (v_pedido, r.produto_id, r.nome, coalesce(r.preco_promo_centavos, r.preco_centavos), r.quantidade);

    v_subtotal := v_subtotal + r.quantidade * coalesce(r.preco_promo_centavos, r.preco_centavos);
  end loop;

  -- Um envio por grupo: quem envia recebe o frete (extrato)
  for g in select value from jsonb_array_elements(v_cot.grupos) loop
    v_chave := g->>'chave';
    select o.value into v_opcao from jsonb_array_elements(g->'opcoes') o
     where o.value->>'id' = p_escolhas->>v_chave limit 1;
    insert into public.pedido_envios (pedido_id, vendedor_id, origem_nome, servico, prazo_dias, frete_centavos, status)
    values (
      v_pedido,
      nullif(g->>'vendedor_id', '')::uuid,
      g->>'nome',
      left(v_opcao->>'nome', 150),
      least(coalesce((v_opcao->>'prazo_dias')::integer, 0), 90)::smallint,
      (v_opcao->>'preco_centavos')::integer,
      'aguardando'
    );
  end loop;

  -- Cupom: a base é o subtotal do carrinho (cupom da cooperativa) ou só os itens do vendedor do cupom.
  -- Se falhar, o pedido inteiro é desfeito.
  if nullif(trim(coalesce(p_cupom, '')), '') is not null then
    select vendedor_id into v_cupom_vendedor from public.cupons_loja
     where codigo = upper(trim(p_cupom));

    if v_cupom_vendedor is null then
      v_base := v_subtotal;
    else
      select coalesce(sum(i.quantidade * i.preco_unitario_centavos), 0)::integer into v_base
        from public.pedido_itens i
       where i.pedido_id = v_pedido and i.vendedor_id = v_cupom_vendedor;
    end if;

    if v_base = 0 then
      raise exception 'Este cupom não vale para os produtos do seu carrinho.';
    end if;

    c := privado.checar_cupom(p_cupom, v_usuario, v_base, true);
    v_desconto := privado.desconto_cupom(c, v_base);
    v_cupom_id := c.id;
    v_cupom_codigo := c.codigo;
  end if;

  update public.pedidos
     set subtotal_centavos = v_subtotal,
         desconto_centavos = v_desconto,
         cupom_id = v_cupom_id,
         cupom_codigo = v_cupom_codigo,
         total_centavos = v_subtotal - v_desconto + v_frete,
         atualizado_em = now()
   where id = v_pedido;

  delete from public.cotacoes_frete where id = p_cotacao;

  perform privado.auditar('pedido_criado', 'pedido', v_pedido::text,
                          jsonb_build_object('total_centavos', v_subtotal - v_desconto + v_frete,
                                             'metodo', v_metodo, 'envios', v_grupos, 'cupom', v_cupom_codigo));
  return v_pedido;
end;
$$;

-- 5. Cupons do próprio vendedor (listar e salvar). Admin continua usando salvar_cupom_loja.
create or replace function public.cupons_vendedor_loja()
returns table (
  id uuid, codigo text, tipo text, valor integer, minimo_centavos integer,
  limite_usos integer, limite_por_usuario smallint, validade_ate timestamptz, ativo boolean, usos integer
)
language sql
stable
security definer
set search_path = public, privado
as $$
  select c.id, c.codigo, c.tipo, c.valor, c.minimo_centavos, c.limite_usos, c.limite_por_usuario, c.validade_ate, c.ativo,
         (select count(*)::integer from public.pedidos p
           where p.cupom_id = c.id
             and not (p.status in ('cancelado', 'expirado') or (p.status = 'aguardando_pagamento' and p.expira_em <= now())))
    from public.cupons_loja c
   where c.vendedor_id in (select v.id from public.loja_vendedores v where v.usuario_id = auth.uid())
   order by c.criado_em desc
   limit 200
$$;

create or replace function public.salvar_cupom_vendedor_loja(
  p_id uuid,
  p_codigo text,
  p_tipo text,
  p_valor integer,
  p_minimo_centavos integer,
  p_limite_usos integer,
  p_limite_por_usuario smallint,
  p_validade timestamptz,
  p_ativo boolean
)
returns uuid
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  v_vendedor uuid;
  v_id uuid;
  v_codigo text := upper(trim(coalesce(p_codigo, '')));
begin
  select v.id into v_vendedor from public.loja_vendedores v
   where v.usuario_id = auth.uid() and v.status = 'aprovado';
  if v_vendedor is null then
    raise exception 'Só vendedores aprovados criam cupons.';
  end if;
  if v_codigo !~ '^[A-Z0-9_-]{3,20}$' then
    raise exception 'Código do cupom: use de 3 a 20 letras, números, - ou _.';
  end if;
  if p_tipo not in ('percentual', 'valor') then
    raise exception 'Tipo de cupom inválido.';
  end if;
  if p_valor is null or p_valor < 1 or (p_tipo = 'percentual' and p_valor > 100) then
    raise exception 'Valor do cupom inválido. Para percentual, use de 1 a 100.';
  end if;

  begin
    if p_id is null then
      insert into public.cupons_loja (codigo, tipo, valor, minimo_centavos, limite_usos,
                                      limite_por_usuario, validade_ate, ativo, criado_por, vendedor_id)
      values (v_codigo, p_tipo, p_valor, coalesce(p_minimo_centavos, 0), p_limite_usos,
              coalesce(p_limite_por_usuario, 1), p_validade, coalesce(p_ativo, true), auth.uid(), v_vendedor)
      returning id into v_id;
    else
      -- Vendedor só altera cupom dele
      update public.cupons_loja
         set codigo = v_codigo, tipo = p_tipo, valor = p_valor,
             minimo_centavos = coalesce(p_minimo_centavos, 0), limite_usos = p_limite_usos,
             limite_por_usuario = coalesce(p_limite_por_usuario, 1), validade_ate = p_validade,
             ativo = coalesce(p_ativo, true)
       where id = p_id and vendedor_id = v_vendedor
      returning id into v_id;
      if v_id is null then
        raise exception 'Cupom não encontrado.';
      end if;
    end if;
  exception when unique_violation then
    raise exception 'Já existe um cupom com o código %.', v_codigo;
  end;

  perform privado.auditar(
    case when p_id is null then 'cupom_vendedor_criado' else 'cupom_vendedor_alterado' end,
    'cupom', v_id::text,
    jsonb_build_object('codigo', v_codigo, 'tipo', p_tipo, 'valor', p_valor, 'ativo', coalesce(p_ativo, true))
  );
  return v_id;
end;
$$;

-- 6. Permissões
revoke execute on function public.cupons_vendedor_loja() from anon, public;
revoke execute on function public.salvar_cupom_vendedor_loja(uuid, text, text, integer, integer, integer, smallint, timestamptz, boolean) from anon, public;
grant execute on function public.cupons_vendedor_loja() to authenticated;
grant execute on function public.salvar_cupom_vendedor_loja(uuid, text, text, integer, integer, integer, smallint, timestamptz, boolean) to authenticated;
revoke execute on function privado.subtotal_carrinho_cupom(uuid, uuid) from anon, public;

-- 7. Verificação final
do $$
begin
  if to_regprocedure('public.salvar_cupom_vendedor_loja(uuid,text,text,integer,integer,integer,smallint,timestamptz,boolean)') is null
     or to_regprocedure('public.cupons_vendedor_loja()') is null
     or to_regprocedure('privado.subtotal_carrinho_cupom(uuid,uuid)') is null then
    raise exception 'Funções do cupom de vendedor não criadas.';
  end if;
end $$;
