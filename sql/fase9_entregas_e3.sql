-- Fase 9 (e-commerce, etapa E3): frete, entrega local, transportadora e rastreio.
-- Executar no SQL Editor do Supabase (projeto yutsnhuhimijtzqhpopu). Pode rodar mais de uma vez.
-- Requer: sql/fase8_pagamentos_e2.sql (já rodado).
--
-- O que muda:
--   - Produtos ganham peso e medidas (necessários para cotar frete).
--   - Cotação de frete fica guardada no servidor. O valor do frete escolhido é o que foi cotado,
--     nunca o que vier do navegador. A cotação expira em 15 minutos e vale só para o carrinho cotado.
--   - Pedido guarda endereço de entrega (só para entrega), forma de envio, prazo e código de rastreio.
--   - Novos status: enviado e entregue.
--   - Token do Melhor Envio fica no Vault, como o do Mercado Pago.

-- =====================================================================
-- 1. PRODUTOS: peso e medidas
-- =====================================================================
alter table public.loja_produtos
  add column if not exists peso_g integer check (peso_g is null or peso_g between 1 and 100000),
  add column if not exists altura_cm smallint check (altura_cm is null or altura_cm between 1 and 200),
  add column if not exists largura_cm smallint check (largura_cm is null or largura_cm between 1 and 200),
  add column if not exists comprimento_cm smallint check (comprimento_cm is null or comprimento_cm between 1 and 200);

-- =====================================================================
-- 2. CONFIGURAÇÕES NOVAS
-- =====================================================================
alter table public.loja_configuracoes drop constraint if exists loja_configuracoes_chave_check;
alter table public.loja_configuracoes add constraint loja_configuracoes_chave_check check (chave in (
  'nome_loja', 'endereco_retirada', 'horario_retirada',
  'minutos_expiracao_pedido', 'url_publica_app', 'mp_public_key',
  'cep_origem', 'entrega_local_ativa', 'entrega_local_ceps',
  'taxa_entrega_local_centavos', 'melhor_envio_sandbox'
));

-- =====================================================================
-- 3. SEGREDOS: inclui o token do Melhor Envio
-- =====================================================================
create or replace function privado.gravar_segredo(p_nome text, p_valor text)
returns void
language plpgsql
security definer
set search_path = public, vault
as $$
declare
  v_id uuid;
begin
  if p_nome not in ('mp_access_token', 'mp_webhook_secret', 'melhor_envio_token') then
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
    'melhor_envio_token', exists (select 1 from vault.secrets s where s.name = 'melhor_envio_token')
  );
end;
$$;

-- =====================================================================
-- 4. COTAÇÕES DE FRETE (guardadas no servidor)
-- =====================================================================
create table if not exists public.cotacoes_frete (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references public.usuarios(id) on delete cascade,
  cep text not null check (cep ~ '^[0-9]{8}$'),
  carrinho_assinatura text not null,
  opcoes jsonb not null,
  expira_em timestamptz not null,
  criado_em timestamptz not null default now()
);
create index if not exists cotacoes_frete_usuario_idx on public.cotacoes_frete (usuario_id);

alter table public.cotacoes_frete enable row level security;

drop policy if exists cotacoes_ler_proprias on public.cotacoes_frete;
create policy cotacoes_ler_proprias on public.cotacoes_frete
  for select to authenticated
  using (usuario_id = auth.uid());

-- Gravada só pela Edge Function (chave de serviço). O cliente não escreve direto.

-- =====================================================================
-- 5. PEDIDOS: entrega, endereço, rastreio e novos status
-- =====================================================================
alter table public.pedidos drop constraint if exists pedidos_status_check;
alter table public.pedidos add constraint pedidos_status_check check (status in (
  'aguardando_pagamento', 'pago', 'em_separacao', 'pronto_retirada',
  'enviado', 'entregue', 'retirado', 'cancelado', 'expirado'
));

alter table public.pedidos drop constraint if exists pedidos_metodo_entrega_check;
alter table public.pedidos add constraint pedidos_metodo_entrega_check
  check (metodo_entrega in ('retirada', 'entrega_local', 'transportadora'));

alter table public.pedidos
  add column if not exists frete_servico text check (frete_servico is null or length(frete_servico) <= 150),
  add column if not exists prazo_dias smallint check (prazo_dias is null or prazo_dias between 0 and 90),
  add column if not exists endereco jsonb,
  add column if not exists codigo_rastreio text check (codigo_rastreio is null or length(codigo_rastreio) <= 60);

-- Função antiga (só retirada) sai; a nova exige cotação.
drop function if exists public.criar_pedido_loja(text);

-- Cria o pedido a partir do carrinho e de uma opção de frete cotada no servidor.
create or replace function public.criar_pedido_loja(
  p_cotacao uuid,
  p_opcao text,
  p_endereco jsonb default null
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
  v_abertos integer;
  v_campo text;
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

  -- O carrinho precisa ser o mesmo que foi cotado.
  select string_agg(c.produto_id::text || ':' || c.quantidade::text, ',' order by c.produto_id::text)
    into v_assinatura
    from public.carrinho_itens c where c.usuario_id = v_usuario;
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
    select c.quantidade, p.id as produto_id, p.nome, p.preco_centavos, p.preco_promo_centavos,
           p.estoque, p.ativo
      from public.carrinho_itens c
      join public.loja_produtos p on p.id = c.produto_id
     where c.usuario_id = v_usuario
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

  update public.pedidos
     set subtotal_centavos = v_subtotal, total_centavos = v_subtotal + v_frete, atualizado_em = now()
   where id = v_pedido;

  delete from public.cotacoes_frete where id = p_cotacao;

  perform privado.auditar('pedido_criado', 'pedido', v_pedido::text,
                          jsonb_build_object('total_centavos', v_subtotal + v_frete, 'metodo', v_metodo));
  return v_pedido;
end;
$$;

-- Administrador avança a separação e a entrega.
create or replace function public.avancar_pedido_loja(p_pedido uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  v_atual text;
  v_metodo text;
  v_usuario uuid;
begin
  if not privado.eh_admin() then
    raise exception 'Apenas administradores.';
  end if;

  select p.status, p.metodo_entrega, p.usuario_id into v_atual, v_metodo, v_usuario
    from public.pedidos p where p.id = p_pedido for update;
  if not found then
    raise exception 'Pedido não encontrado.';
  end if;

  if not (
       (v_atual = 'pago' and p_status in ('em_separacao', 'cancelado'))
    or (v_atual = 'em_separacao' and v_metodo = 'retirada' and p_status in ('pronto_retirada', 'cancelado'))
    or (v_atual = 'em_separacao' and v_metodo <> 'retirada' and p_status = 'cancelado')
    or (v_atual = 'pronto_retirada' and p_status = 'retirado')
    or (v_atual = 'enviado' and p_status = 'entregue')
  ) then
    raise exception 'Não é possível mudar o pedido de "%" para "%".', v_atual, p_status;
  end if;

  if p_status = 'cancelado' then
    perform privado.devolver_estoque_pedido(p_pedido);
  end if;

  update public.pedidos
     set status = p_status,
         observacao_admin = case when p_status = 'cancelado'
           then 'Cancelado pela loja. Se houve pagamento, fazer o reembolso no Mercado Pago.'
           else observacao_admin end,
         atualizado_em = now()
   where id = p_pedido;

  if p_status in ('pronto_retirada', 'entregue') and v_usuario is not null then
    perform privado.notificar(array[v_usuario], 'Atualização do seu pedido',
                              'Seu pedido da loja mudou de situação. Veja em Meus pedidos.', null);
  end if;

  perform privado.auditar('pedido_status_alterado', 'pedido', p_pedido::text,
                          jsonb_build_object('de', v_atual, 'para', p_status));
end;
$$;

-- Marca o envio (transportadora ou entrega local) com código de rastreio opcional.
create or replace function public.marcar_envio_loja(p_pedido uuid, p_codigo text default null)
returns void
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  v_atual text;
  v_metodo text;
  v_usuario uuid;
  v_codigo text := nullif(trim(coalesce(p_codigo, '')), '');
begin
  if not privado.eh_admin() then
    raise exception 'Apenas administradores.';
  end if;

  select p.status, p.metodo_entrega, p.usuario_id into v_atual, v_metodo, v_usuario
    from public.pedidos p where p.id = p_pedido for update;
  if not found then
    raise exception 'Pedido não encontrado.';
  end if;
  if v_atual <> 'em_separacao' or v_metodo = 'retirada' then
    raise exception 'Só pedidos em separação para entrega podem ser marcados como enviados.';
  end if;
  if v_metodo = 'transportadora' and (v_codigo is null or length(v_codigo) < 3) then
    raise exception 'Informe o código de rastreio da transportadora.';
  end if;

  update public.pedidos
     set status = 'enviado', codigo_rastreio = v_codigo, atualizado_em = now()
   where id = p_pedido;

  if v_usuario is not null then
    perform privado.notificar(array[v_usuario], 'Seu pedido foi enviado',
                              'Acompanhe a entrega em Meus pedidos.', null);
  end if;
  perform privado.auditar('pedido_enviado', 'pedido', p_pedido::text,
                          jsonb_build_object('metodo', v_metodo, 'rastreio', v_codigo is not null));
end;
$$;

-- =====================================================================
-- 6. PERMISSÕES
-- =====================================================================
revoke execute on function public.criar_pedido_loja(uuid, text, jsonb) from public, anon;
grant execute on function public.criar_pedido_loja(uuid, text, jsonb) to authenticated;

revoke execute on function public.avancar_pedido_loja(uuid, text) from public, anon;
grant execute on function public.avancar_pedido_loja(uuid, text) to authenticated;

revoke execute on function public.marcar_envio_loja(uuid, text) from public, anon;
grant execute on function public.marcar_envio_loja(uuid, text) to authenticated;

revoke execute on function public.status_loja_pagamento() from public, anon;
grant execute on function public.status_loja_pagamento() to authenticated;

revoke execute on function privado.gravar_segredo(text, text) from public, anon, authenticated;

-- =====================================================================
-- 7. VERIFICAÇÃO
-- =====================================================================
select 'colunas_produto' as item,
       string_agg(column_name, ', ' order by column_name) as resultado
  from information_schema.columns
 where table_schema = 'public' and table_name = 'loja_produtos'
   and column_name in ('peso_g', 'altura_cm', 'largura_cm', 'comprimento_cm')
union all
select 'colunas_pedido', string_agg(column_name, ', ' order by column_name)
  from information_schema.columns
 where table_schema = 'public' and table_name = 'pedidos'
   and column_name in ('frete_servico', 'prazo_dias', 'endereco', 'codigo_rastreio')
union all
select 'tabela_cotacoes', case when exists (select 1 from information_schema.tables
                                             where table_schema = 'public' and table_name = 'cotacoes_frete')
                              then 'ok' else 'faltando' end
union all
select 'funcoes_entrega', string_agg(p.proname, ', ' order by p.proname)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('criar_pedido_loja', 'marcar_envio_loja', 'avancar_pedido_loja');
