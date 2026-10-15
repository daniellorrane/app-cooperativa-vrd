-- Fase 16 (parte 2): checkout com vários envios.
-- Um pedido pode ter vários envios: a cooperativa e cada vendedor enviam os próprios produtos.
-- Cada envio tem sua forma de entrega, seu frete e vai para quem envia (extrato).
-- Frete grátis por grupo: se o subtotal do grupo atingir o mínimo, as opções pagas saem por zero.
-- Rode no SQL Editor do Supabase e responda "feito".

-- 0. Verificação
do $$
begin
  if to_regprocedure('public.criar_pedido_loja(uuid,text,jsonb,text)') is null or to_regclass('public.pedido_envios') is null then
    raise exception 'Fase 16 (parte 1) não encontrada. Aplique a parte 1 antes desta.';
  end if;
end $$;

-- 1. Envios guardam o nome de quem envia (o comprador não lê a tabela de vendedores)
alter table public.pedido_envios add column if not exists origem_nome text;

update public.pedido_envios e
   set origem_nome = coalesce((select v.nome_loja from public.loja_vendedores v where v.id = e.vendedor_id), 'Cooperativa')
 where e.origem_nome is null;

-- 2. Cotação passa a guardar os grupos (cooperativa e cada vendedor), no lugar da lista única de opções.
-- Cotações antigas expiram em 15 minutos; apagar é seguro.
delete from public.cotacoes_frete;
alter table public.cotacoes_frete rename column opcoes to grupos;

-- 3. Nova assinatura do checkout: uma escolha de entrega por grupo.
drop function if exists public.criar_pedido_loja(uuid, text, jsonb, text);

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

  -- Cupom: confere e calcula aqui, com o carrinho já travado. Se falhar, o pedido inteiro é desfeito.
  if nullif(trim(coalesce(p_cupom, '')), '') is not null then
    c := privado.checar_cupom(p_cupom, v_usuario, v_subtotal, true);
    v_desconto := privado.desconto_cupom(c, v_subtotal);
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

revoke execute on function public.criar_pedido_loja(uuid, jsonb, jsonb, text) from anon, public;
grant execute on function public.criar_pedido_loja(uuid, jsonb, jsonb, text) to authenticated;

-- 4. Situação dos envios acompanha o pedido (o administrador muda o pedido; o envio da cooperativa acompanha)
-- Envios de vendedores só saem de "aguardando" quando o vendedor registra o rastreio, mas entregue e cancelado valem para todos.
create or replace function privado.sincroniza_envios_pedido()
returns trigger
language plpgsql
security definer
set search_path = public, privado
as $$
begin
  if new.status is not distinct from old.status then return new; end if;

  if new.status = 'enviado' then
    update public.pedido_envios
       set status = 'enviado', enviado_em = coalesce(enviado_em, now())
     where pedido_id = new.id and vendedor_id is null and status = 'aguardando';
  elsif new.status in ('entregue', 'retirado') then
    update public.pedido_envios
       set status = 'entregue', enviado_em = coalesce(enviado_em, now()), entregue_em = coalesce(entregue_em, now())
     where pedido_id = new.id and status in ('aguardando', 'enviado');
  elsif new.status in ('cancelado', 'expirado') then
    update public.pedido_envios set status = 'cancelado'
     where pedido_id = new.id and status = 'aguardando';
  end if;

  return new;
end;
$$;

drop trigger if exists pedidos_sincroniza_envios on public.pedidos;
create trigger pedidos_sincroniza_envios
  after update of status on public.pedidos
  for each row execute function privado.sincroniza_envios_pedido();

-- 5. Verificação final
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'cotacoes_frete' and column_name = 'grupos') then
    raise exception 'Coluna grupos não criada.';
  end if;
  if to_regprocedure('public.criar_pedido_loja(uuid,jsonb,jsonb,text)') is null then
    raise exception 'Nova criar_pedido_loja não criada.';
  end if;
end $$;
