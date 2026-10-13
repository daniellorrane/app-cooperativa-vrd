-- E-commerce E4: recomendações por histórico, indicações entre cooperados e cupons de desconto.
-- Rodar inteiro no SQL Editor do Supabase, uma vez. Não apaga dados existentes.

-- =====================================================================
-- 1. CUPONS
-- =====================================================================
create table if not exists public.cupons_loja (
  id uuid primary key default gen_random_uuid(),
  codigo text not null unique check (codigo ~ '^[A-Z0-9_-]{3,20}$'),
  tipo text not null check (tipo in ('percentual', 'valor')),
  valor integer not null check (valor > 0),
  minimo_centavos integer not null default 0 check (minimo_centavos >= 0),
  limite_usos integer check (limite_usos is null or limite_usos > 0),
  limite_por_usuario smallint not null default 1 check (limite_por_usuario between 1 and 20),
  validade_ate timestamptz,
  ativo boolean not null default true,
  criado_por uuid,
  criado_em timestamptz not null default now(),
  constraint cupom_percentual_valido check (tipo <> 'percentual' or valor <= 100)
);

alter table public.cupons_loja enable row level security;

drop policy if exists cupons_loja_admin on public.cupons_loja;
create policy cupons_loja_admin on public.cupons_loja
  for all using (privado.eh_admin()) with check (privado.eh_admin());

alter table public.pedidos
  add column if not exists cupom_id uuid references public.cupons_loja(id) on delete set null,
  add column if not exists cupom_codigo text,
  add column if not exists desconto_centavos integer not null default 0 check (desconto_centavos >= 0);

-- Subtotal do carrinho, com o preço promocional quando existir.
create or replace function privado.subtotal_carrinho(p_usuario uuid)
returns integer
language sql
stable
security definer
set search_path = public, privado
as $$
  select coalesce(sum(c.quantidade * coalesce(p.preco_promo_centavos, p.preco_centavos)), 0)::integer
    from public.carrinho_itens c
    join public.loja_produtos p on p.id = c.produto_id
   where c.usuario_id = p_usuario;
$$;

-- Valor do desconto para um subtotal. Nunca passa do subtotal.
create or replace function privado.desconto_cupom(c public.cupons_loja, p_subtotal integer)
returns integer
language sql
immutable
as $$
  select least(
    p_subtotal,
    case when c.tipo = 'percentual'
         then floor(p_subtotal::numeric * c.valor / 100)::integer
         else c.valor
    end
  );
$$;

-- Confere se o cupom pode ser usado agora pelo cooperado. Lança erro com a mensagem para a tela.
-- Com p_bloquear, trava a linha do cupom para duas compras simultâneas não passarem do limite.
create or replace function privado.checar_cupom(
  p_codigo text, p_usuario uuid, p_subtotal integer, p_bloquear boolean default false
)
returns public.cupons_loja
language plpgsql
security definer
set search_path = public, privado
as $$
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
$$;

-- O app chama antes de finalizar, para mostrar o desconto. O pedido confere de novo ao criar.
create or replace function public.validar_cupom_loja(p_codigo text)
returns jsonb
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  v_usuario uuid := auth.uid();
  v_subtotal integer;
  c public.cupons_loja%rowtype;
begin
  if not privado.usuario_aprovado() then
    raise exception 'Sua conta precisa estar aprovada para comprar.';
  end if;

  v_subtotal := privado.subtotal_carrinho(v_usuario);
  if v_subtotal = 0 then
    raise exception 'Seu carrinho está vazio.';
  end if;

  c := privado.checar_cupom(p_codigo, v_usuario, v_subtotal, false);

  return jsonb_build_object(
    'codigo', c.codigo,
    'subtotal_centavos', v_subtotal,
    'desconto_centavos', privado.desconto_cupom(c, v_subtotal)
  );
end;
$$;

-- Administrador cria ou altera um cupom.
create or replace function public.salvar_cupom_loja(
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
  v_id uuid;
  v_codigo text := upper(trim(coalesce(p_codigo, '')));
begin
  if not privado.eh_admin() then
    raise exception 'Apenas administradores podem alterar cupons.';
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
                                      limite_por_usuario, validade_ate, ativo, criado_por)
      values (v_codigo, p_tipo, p_valor, coalesce(p_minimo_centavos, 0), p_limite_usos,
              coalesce(p_limite_por_usuario, 1), p_validade, coalesce(p_ativo, true), auth.uid())
      returning id into v_id;
    else
      update public.cupons_loja
         set codigo = v_codigo, tipo = p_tipo, valor = p_valor,
             minimo_centavos = coalesce(p_minimo_centavos, 0), limite_usos = p_limite_usos,
             limite_por_usuario = coalesce(p_limite_por_usuario, 1), validade_ate = p_validade,
             ativo = coalesce(p_ativo, true)
       where id = p_id
      returning id into v_id;
      if v_id is null then
        raise exception 'Cupom não encontrado.';
      end if;
    end if;
  exception when unique_violation then
    raise exception 'Já existe um cupom com o código %.', v_codigo;
  end;

  perform privado.auditar(
    case when p_id is null then 'cupom_criado' else 'cupom_alterado' end,
    'cupom', v_id::text,
    jsonb_build_object('codigo', v_codigo, 'tipo', p_tipo, 'valor', p_valor, 'ativo', coalesce(p_ativo, true))
  );
  return v_id;
end;
$$;

-- =====================================================================
-- 2. CRIAR PEDIDO COM CUPOM
-- Mesma regra da E3, mais o cupom. Total = subtotal - desconto + frete.
-- =====================================================================
drop function if exists public.criar_pedido_loja(uuid, text, jsonb);

create or replace function public.criar_pedido_loja(
  p_cotacao uuid, p_opcao text, p_endereco jsonb default null, p_cupom text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  v_usuario uuid := auth.uid();
  v_cot public.cotacoes_frete%rowtype;
  v_opcao jsonb;
  v_metodo text;
  v_frete integer;
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

  select o.value into v_opcao
    from jsonb_array_elements(v_cot.opcoes) o
   where o.value->>'id' = p_opcao
   limit 1;
  if v_opcao is null then
    raise exception 'Escolha uma opção de entrega válida.';
  end if;

  v_metodo := v_opcao->>'metodo';
  v_frete := (v_opcao->>'preco_centavos')::integer;

  select string_agg(c2.produto_id::text || ':' || c2.quantidade::text, ',' order by c2.produto_id::text)
    into v_assinatura
    from public.carrinho_itens c2 where c2.usuario_id = v_usuario;
  if v_assinatura is distinct from v_cot.carrinho_assinatura then
    raise exception 'Seu carrinho mudou depois do cálculo do frete. Calcule de novo.';
  end if;

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
    v_opcao->>'nome',
    (v_opcao->>'prazo_dias')::smallint
  )
  returning id into v_pedido;

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
                                             'metodo', v_metodo, 'cupom', v_cupom_codigo));
  return v_pedido;
end;
$$;

-- =====================================================================
-- 3. INDICAÇÕES ENTRE COOPERADOS
-- Quem indica gera um link (do produto ou da lista). Quem abre o link e está logado aceita.
-- O sistema não guarda o contato de ninguém: só o link. Quem indicou vê só a contagem de aceites.
-- =====================================================================
create table if not exists public.indicacoes_loja (
  id uuid primary key default gen_random_uuid(),
  remetente_id uuid not null references auth.users(id) on delete cascade,
  produto_id uuid references public.loja_produtos(id) on delete cascade,
  lista_id uuid references public.listas_loja(id) on delete cascade,
  token text not null unique default replace(gen_random_uuid()::text, '-', ''),
  criado_em timestamptz not null default now(),
  check (num_nonnulls(produto_id, lista_id) = 1)
);

create table if not exists public.indicacoes_loja_aceites (
  indicacao_id uuid not null references public.indicacoes_loja(id) on delete cascade,
  usuario_id uuid not null references auth.users(id) on delete cascade,
  aceita_em timestamptz not null default now(),
  primary key (indicacao_id, usuario_id)
);

alter table public.indicacoes_loja enable row level security;
alter table public.indicacoes_loja_aceites enable row level security;

drop policy if exists indicacoes_proprias on public.indicacoes_loja;
create policy indicacoes_proprias on public.indicacoes_loja
  for all using (remetente_id = auth.uid() and privado.usuario_aprovado())
  with check (remetente_id = auth.uid() and privado.usuario_aprovado());

drop policy if exists indicacoes_aceites_proprias on public.indicacoes_loja_aceites;
create policy indicacoes_aceites_proprias on public.indicacoes_loja_aceites
  for select using (usuario_id = auth.uid());

-- Gera (ou reaproveita) o link de indicação de um produto ou de uma lista.
create or replace function public.criar_indicacao_loja(p_produto uuid default null, p_lista uuid default null)
returns text
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  v_token text;
  v_hoje integer;
begin
  if not privado.usuario_aprovado() then
    raise exception 'Sua conta precisa estar aprovada para indicar.';
  end if;
  if num_nonnulls(p_produto, p_lista) <> 1 then
    raise exception 'Escolha um produto ou uma lista para indicar.';
  end if;

  if p_produto is not null and not exists (select 1 from public.loja_produtos where id = p_produto and ativo) then
    raise exception 'Este produto não está disponível para indicação.';
  end if;
  if p_lista is not null and not exists (select 1 from public.listas_loja where id = p_lista and usuario_id = auth.uid()) then
    raise exception 'Lista não encontrada.';
  end if;

  -- Reaproveita o link que já existe para o mesmo item.
  select i.token into v_token
    from public.indicacoes_loja i
   where i.remetente_id = auth.uid()
     and i.produto_id is not distinct from p_produto
     and i.lista_id is not distinct from p_lista
   limit 1;
  if v_token is not null then
    return v_token;
  end if;

  select count(*) into v_hoje from public.indicacoes_loja
   where remetente_id = auth.uid() and criado_em > now() - interval '1 day';
  if v_hoje >= 50 then
    raise exception 'Você atingiu o limite de indicações de hoje. Tente amanhã.';
  end if;

  insert into public.indicacoes_loja (remetente_id, produto_id, lista_id)
  values (auth.uid(), p_produto, p_lista)
  returning token into v_token;

  return v_token;
end;
$$;

-- Quem abre o link aceita a indicação. Retorna o destino para o app abrir.
create or replace function public.aceitar_indicacao_loja(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  i public.indicacoes_loja%rowtype;
  v_lista_token text;
begin
  if not privado.usuario_aprovado() then
    raise exception 'Sua conta precisa estar aprovada para continuar.';
  end if;

  select * into i from public.indicacoes_loja where token = p_token;
  if not found then
    raise exception 'Link de indicação inválido ou removido.';
  end if;

  if i.remetente_id <> auth.uid() then
    insert into public.indicacoes_loja_aceites (indicacao_id, usuario_id)
    values (i.id, auth.uid())
    on conflict do nothing;
  end if;

  if i.produto_id is not null then
    return jsonb_build_object('tipo', 'produto', 'id', i.produto_id);
  end if;

  select l.token into v_lista_token from public.listas_loja l where l.id = i.lista_id;
  return jsonb_build_object('tipo', 'lista', 'token', v_lista_token);
end;
$$;

-- Lista das indicações de quem está logado, com a contagem de aceites.
create or replace function public.minhas_indicacoes_loja()
returns table(id uuid, tipo text, nome text, token text, aceites bigint, criado_em timestamptz)
language sql
stable
security definer
set search_path = public, privado
as $$
  select i.id,
         case when i.produto_id is not null then 'produto' else 'lista' end,
         coalesce(p.nome, l.titulo),
         i.token,
         (select count(*) from public.indicacoes_loja_aceites a where a.indicacao_id = i.id),
         i.criado_em
    from public.indicacoes_loja i
    left join public.loja_produtos p on p.id = i.produto_id
    left join public.listas_loja l on l.id = i.lista_id
   where i.remetente_id = auth.uid() and privado.usuario_aprovado()
   order by i.criado_em desc;
$$;

-- =====================================================================
-- 4. RECOMENDAÇÕES
-- Ordem: indicado por amigo, parecido com favoritos, parecido com compras, bem avaliado.
-- Cada produto recebe um motivo curto para a tela.
-- =====================================================================
drop function if exists public.recomendados_para_mim();

create or replace function public.recomendados_para_mim()
returns table(
  id uuid, nome text, preco_centavos integer, preco_promo_centavos integer, imagem_caminho text,
  estoque integer, categoria_id uuid, categoria_nome text, media numeric, avaliacoes bigint,
  favorito boolean, motivo text
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
  select p.id, p.nome, p.preco_centavos, p.preco_promo_centavos, p.imagem_caminho,
         p.estoque, p.categoria_id, c.nome,
         r.media, coalesce(r.total, 0), false,
         case
           when exists (select 1 from indicados x where x.produto_id = p.id) then 'Indicado por um amigo'
           when p.categoria_id in (select cf.categoria_id from categorias_favoritas cf) then 'Parecido com o que você favoritou'
           when p.categoria_id in (select cc.categoria_id from categorias_compradas cc) then 'Parecido com o que você já comprou'
           when coalesce(r.media, 0) >= 4 then 'Muito bem avaliado pelos cooperados'
           else 'Novidade na loja'
         end
    from public.loja_produtos p
    left join public.loja_categorias c on c.id = p.categoria_id
    left join lateral (
      select round(avg(a.nota)::numeric, 1) as media, count(*) as total
        from public.avaliacoes_produto a
       where a.produto_id = p.id and a.status = 'publicada'
    ) r on true
   where p.ativo and p.estoque > 0
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
-- 5. PERMISSÕES
-- Funções do app: só cooperado logado (e o administrador, onde couber).
-- =====================================================================
revoke all on function public.validar_cupom_loja(text) from public, anon;
grant execute on function public.validar_cupom_loja(text) to authenticated;

revoke all on function public.salvar_cupom_loja(uuid, text, text, integer, integer, integer, smallint, timestamptz, boolean) from public, anon;
grant execute on function public.salvar_cupom_loja(uuid, text, text, integer, integer, integer, smallint, timestamptz, boolean) to authenticated;

revoke all on function public.criar_pedido_loja(uuid, text, jsonb, text) from public, anon;
grant execute on function public.criar_pedido_loja(uuid, text, jsonb, text) to authenticated;

revoke all on function public.recomendados_para_mim() from public, anon;
grant execute on function public.recomendados_para_mim() to authenticated;

revoke all on function public.criar_indicacao_loja(uuid, uuid) from public, anon;
grant execute on function public.criar_indicacao_loja(uuid, uuid) to authenticated;

revoke all on function public.aceitar_indicacao_loja(text) from public, anon;
grant execute on function public.aceitar_indicacao_loja(text) to authenticated;

revoke all on function public.minhas_indicacoes_loja() from public, anon;
grant execute on function public.minhas_indicacoes_loja() to authenticated;

revoke all on function privado.checar_cupom(text, uuid, integer, boolean) from public, anon, authenticated;
revoke all on function privado.subtotal_carrinho(uuid) from public, anon, authenticated;
revoke all on function privado.desconto_cupom(public.cupons_loja, integer) from public, anon, authenticated;
