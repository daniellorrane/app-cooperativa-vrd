-- Fase 8 (e-commerce, etapa E2): pedidos, reserva de estoque e pagamento pelo Mercado Pago.
-- Executar no SQL Editor do Supabase (projeto yutsnhuhimijtzqhpopu). Pode rodar mais de uma vez.
-- Requer: sql/fase7_ecommerce_e1.sql (já rodado).
--
-- Como fica a configuração:
--   - Dados comuns (nome da loja, endereço de retirada, prazo do pedido) ficam em loja_configuracoes.
--     O administrador preenche tudo na tela Loja > Gerenciar > Pagamento e configurações.
--   - Segredos (token do Mercado Pago e chave do webhook) ficam no Supabase Vault.
--     O app nunca mostra o valor: só informa se está configurado.
--     Só a Edge Function (chave de serviço) consegue ler.
--
-- Como funciona o estoque:
--   - Ao criar o pedido, o estoque é reservado (descontado na hora).
--   - Se o pedido expirar ou for cancelado, o estoque volta.
--   - Verificação de expirados a cada 5 minutos (pg_cron).
--   - Se o pagamento chegar depois de expirar e ainda houver estoque, o pedido é confirmado.
--     Se não houver estoque, o pedido vai para "pago" com aviso ao administrador.
--
-- Valores sempre em centavos. O preço é lido do banco no momento do pedido, nunca do navegador.

-- =====================================================================
-- 1. CONFIGURAÇÕES NÃO SECRETAS
-- =====================================================================
create table if not exists public.loja_configuracoes (
  chave text primary key check (chave in (
    'nome_loja', 'endereco_retirada', 'horario_retirada',
    'minutos_expiracao_pedido', 'url_publica_app', 'mp_public_key'
  )),
  valor text not null default '' check (length(valor) <= 500),
  atualizado_em timestamptz not null default now()
);

insert into public.loja_configuracoes (chave, valor)
values ('nome_loja', 'Cooperativa Agropecuária Vale do Rio Doce'),
       ('minutos_expiracao_pedido', '30')
on conflict (chave) do nothing;

alter table public.loja_configuracoes enable row level security;

drop policy if exists loja_config_ler on public.loja_configuracoes;
create policy loja_config_ler on public.loja_configuracoes
  for select to authenticated
  using (
    chave in ('nome_loja', 'endereco_retirada', 'horario_retirada')
    and privado.usuario_aprovado()
    or privado.eh_admin()
  );

drop policy if exists loja_config_admin on public.loja_configuracoes;
create policy loja_config_admin on public.loja_configuracoes
  for all to authenticated
  using (privado.eh_admin()) with check (privado.eh_admin());

-- =====================================================================
-- 2. SEGREDOS NO VAULT
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
  if p_nome not in ('mp_access_token', 'mp_webhook_secret') then
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

create or replace function public.salvar_segredo_loja(p_nome text, p_valor text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not privado.eh_admin() then
    raise exception 'Apenas administradores podem alterar estas chaves.';
  end if;
  perform privado.gravar_segredo(p_nome, p_valor);
end;
$$;

-- Diz apenas se está configurado. Nunca devolve o valor.
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
    'mp_webhook_secret', exists (select 1 from vault.secrets s where s.name = 'mp_webhook_secret')
  );
end;
$$;

-- Só a Edge Function usa (chave de serviço). O app não tem acesso.
create or replace function public.ler_segredo_loja(p_nome text)
returns text
language sql
stable
security definer
set search_path = public, vault
as $$
  select d.decrypted_secret::text from vault.decrypted_secrets d where d.name = p_nome limit 1;
$$;

-- =====================================================================
-- 3. PEDIDOS
-- =====================================================================
create table if not exists public.pedidos (
  id uuid primary key default gen_random_uuid(),
  codigo text not null unique default (
    'PED-' || to_char(now(), 'YYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6))
  ),
  usuario_id uuid references public.usuarios(id) on delete set null,
  status text not null default 'aguardando_pagamento' check (status in (
    'aguardando_pagamento', 'pago', 'em_separacao', 'pronto_retirada',
    'retirado', 'cancelado', 'expirado'
  )),
  metodo_entrega text not null default 'retirada' check (metodo_entrega in ('retirada')),
  subtotal_centavos integer not null check (subtotal_centavos >= 0),
  frete_centavos integer not null default 0 check (frete_centavos >= 0),
  total_centavos integer not null check (total_centavos >= 0),
  mp_preferencia_id text,
  mp_pagamento_id text,
  mp_status text,
  observacao_admin text check (observacao_admin is null or length(observacao_admin) <= 500),
  expira_em timestamptz not null,
  pago_em timestamptz,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  check (total_centavos = subtotal_centavos + frete_centavos)
);
create index if not exists pedidos_usuario_idx on public.pedidos (usuario_id, criado_em desc);
create index if not exists pedidos_status_expira_idx on public.pedidos (status, expira_em);

create table if not exists public.pedido_itens (
  id uuid primary key default gen_random_uuid(),
  pedido_id uuid not null references public.pedidos(id) on delete cascade,
  produto_id uuid references public.loja_produtos(id) on delete set null,
  nome_snapshot text not null check (length(nome_snapshot) <= 250),
  preco_unitario_centavos integer not null check (preco_unitario_centavos >= 1),
  quantidade smallint not null check (quantidade between 1 and 20)
);
create index if not exists pedido_itens_pedido_idx on public.pedido_itens (pedido_id);
create index if not exists pedido_itens_produto_idx on public.pedido_itens (produto_id);

alter table public.pedidos enable row level security;
alter table public.pedido_itens enable row level security;

drop policy if exists pedidos_ler on public.pedidos;
create policy pedidos_ler on public.pedidos
  for select to authenticated
  using (usuario_id = auth.uid() or privado.eh_admin());

drop policy if exists pedido_itens_ler on public.pedido_itens;
create policy pedido_itens_ler on public.pedido_itens
  for select to authenticated
  using (
    exists (select 1 from public.pedidos p
             where p.id = pedido_id and (p.usuario_id = auth.uid() or privado.eh_admin()))
  );

-- Pedidos não têm escrita direta. Tudo passa pelas funções abaixo.

-- Devolve ao estoque as unidades de um pedido (ignora produtos já apagados).
create or replace function privado.devolver_estoque_pedido(p_pedido uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update public.loja_produtos p
     set estoque = p.estoque + i.quantidade
    from public.pedido_itens i
   where i.pedido_id = p_pedido and i.produto_id = p.id;
$$;

-- Expira pedidos sem pagamento depois do prazo e devolve o estoque.
create or replace function privado.expirar_pedidos()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  total integer := 0;
begin
  for r in
    select p.id from public.pedidos p
     where p.status = 'aguardando_pagamento' and p.expira_em < now()
     for update skip locked
  loop
    perform privado.devolver_estoque_pedido(r.id);
    update public.pedidos set status = 'expirado', atualizado_em = now() where id = r.id;
    total := total + 1;
  end loop;
  return total;
end;
$$;

-- Cria o pedido a partir do carrinho e reserva o estoque. Tudo ou nada.
create or replace function public.criar_pedido_loja(p_metodo text default 'retirada')
returns uuid
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  v_usuario uuid := auth.uid();
  v_pedido uuid;
  v_minutos integer;
  v_subtotal integer := 0;
  v_abertos integer;
  r record;
begin
  if not privado.usuario_aprovado() then
    raise exception 'Sua conta precisa estar aprovada para comprar.';
  end if;
  if p_metodo <> 'retirada' then
    raise exception 'Esta forma de entrega ainda não está disponível.';
  end if;

  select count(*) into v_abertos from public.pedidos
   where usuario_id = v_usuario and status = 'aguardando_pagamento' and expira_em > now();
  if v_abertos >= 3 then
    raise exception 'Você já tem 3 pedidos aguardando pagamento. Pague ou cancele um deles antes de continuar.';
  end if;

  if not exists (select 1 from public.carrinho_itens where usuario_id = v_usuario) then
    raise exception 'Seu carrinho está vazio.';
  end if;

  select coalesce((select nullif(valor, '')::integer from public.loja_configuracoes
                    where chave = 'minutos_expiracao_pedido'), 30)
    into v_minutos;

  insert into public.pedidos (usuario_id, metodo_entrega, subtotal_centavos, total_centavos, expira_em)
  values (v_usuario, p_metodo, 0, 0, now() + make_interval(mins => v_minutos))
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
     set subtotal_centavos = v_subtotal, total_centavos = v_subtotal, atualizado_em = now()
   where id = v_pedido;

  perform privado.auditar('pedido_criado', 'pedido', v_pedido::text,
                          jsonb_build_object('total_centavos', v_subtotal));
  return v_pedido;
end;
$$;

-- Cancelamento pelo próprio cooperado, enquanto aguarda pagamento.
create or replace function public.cancelar_pedido_loja(p_pedido uuid)
returns void
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  v_status text;
begin
  select p.status into v_status from public.pedidos p
   where p.id = p_pedido and p.usuario_id = auth.uid()
   for update;
  if not found then
    raise exception 'Pedido não encontrado.';
  end if;
  if v_status <> 'aguardando_pagamento' then
    raise exception 'Só é possível cancelar pedidos que ainda aguardam pagamento.';
  end if;

  perform privado.devolver_estoque_pedido(p_pedido);
  update public.pedidos set status = 'cancelado', atualizado_em = now() where id = p_pedido;
  perform privado.auditar('pedido_cancelado', 'pedido', p_pedido::text, '{}'::jsonb);
end;
$$;

-- Administrador avança a separação. Cancelar um pedido já pago devolve o estoque.
-- O reembolso é feito no Mercado Pago, manualmente.
create or replace function public.avancar_pedido_loja(p_pedido uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  v_atual text;
begin
  if not privado.eh_admin() then
    raise exception 'Apenas administradores.';
  end if;

  select p.status into v_atual from public.pedidos p where p.id = p_pedido for update;
  if not found then
    raise exception 'Pedido não encontrado.';
  end if;

  if not (
       (v_atual = 'pago' and p_status in ('em_separacao', 'cancelado'))
    or (v_atual = 'em_separacao' and p_status in ('pronto_retirada', 'cancelado'))
    or (v_atual = 'pronto_retirada' and p_status = 'retirado')
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
  perform privado.auditar('pedido_status_alterado', 'pedido', p_pedido::text,
                          jsonb_build_object('de', v_atual, 'para', p_status));
end;
$$;

-- =====================================================================
-- 4. FUNÇÕES DO WEBHOOK E DA EDGE FUNCTION (só chave de serviço)
-- =====================================================================
create or replace function public.registrar_preferencia_loja(p_pedido uuid, p_preferencia text)
returns void
language sql
security definer
set search_path = public
as $$
  update public.pedidos
     set mp_preferencia_id = p_preferencia, atualizado_em = now()
   where id = p_pedido and status = 'aguardando_pagamento';
$$;

-- Chamada pelo webhook depois de consultar o pagamento na API do Mercado Pago.
-- É idempotente: o mesmo pagamento aprovado duas vezes não faz nada na segunda.
create or replace function public.confirmar_pagamento_loja(
  p_pedido uuid,
  p_pagamento text,
  p_status text,
  p_valor_centavos integer
)
returns text
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  v_p public.pedidos%rowtype;
  v_novo text;
  v_obs text := null;
  v_sem_estoque boolean;
begin
  select * into v_p from public.pedidos where id = p_pedido for update;
  if not found then
    return 'pedido_inexistente';
  end if;

  if p_status <> 'approved' then
    update public.pedidos
       set mp_pagamento_id = p_pagamento, mp_status = p_status, atualizado_em = now()
     where id = p_pedido;
    return 'registrado';
  end if;

  if v_p.status in ('pago', 'em_separacao', 'pronto_retirada', 'retirado') then
    return 'ja_processado';
  end if;

  if p_valor_centavos <> v_p.total_centavos then
    update public.pedidos
       set mp_pagamento_id = p_pagamento, mp_status = 'valor_divergente',
           observacao_admin = 'Pagamento aprovado com valor diferente do pedido. Verificar antes de separar.',
           atualizado_em = now()
     where id = p_pedido;
    perform privado.auditar('pagamento_divergente', 'pedido', p_pedido::text,
                            jsonb_build_object('esperado', v_p.total_centavos, 'recebido', p_valor_centavos));
    return 'valor_divergente';
  end if;

  if v_p.status = 'aguardando_pagamento' then
    v_novo := 'pago';
  else
    -- Expirado ou cancelado: o estoque já voltou. Tenta reservar de novo.
    select exists (
      select 1 from public.pedido_itens i
        left join public.loja_produtos p on p.id = i.produto_id
       where i.pedido_id = p_pedido and (p.id is null or not p.ativo or p.estoque < i.quantidade)
    ) into v_sem_estoque;

    if v_sem_estoque then
      v_novo := 'pago';
      v_obs := 'Pagamento recebido depois de expirar ou cancelar, e sem estoque suficiente. Decidir entre repor o estoque ou reembolsar.';
    else
      update public.loja_produtos p
         set estoque = p.estoque - i.quantidade
        from public.pedido_itens i
       where i.pedido_id = p_pedido and i.produto_id = p.id;
      v_novo := 'pago';
    end if;
  end if;

  update public.pedidos
     set status = v_novo,
         pago_em = coalesce(pago_em, now()),
         mp_pagamento_id = p_pagamento,
         mp_status = 'approved',
         observacao_admin = coalesce(v_obs, observacao_admin),
         atualizado_em = now()
   where id = p_pedido;

  -- Tira do carrinho os produtos que foram pagos.
  delete from public.carrinho_itens c
   using public.pedido_itens i, public.pedidos p
   where p.id = p_pedido and i.pedido_id = p_pedido
     and c.usuario_id = p.usuario_id and c.produto_id = i.produto_id;

  perform privado.auditar('pagamento_aprovado', 'pedido', p_pedido::text,
                          jsonb_build_object('pagamento', p_pagamento, 'total_centavos', v_p.total_centavos));
  return v_novo;
end;
$$;

-- =====================================================================
-- 5. PERMISSÕES DAS FUNÇÕES
-- =====================================================================
revoke execute on function privado.devolver_estoque_pedido(uuid) from public, anon, authenticated;
revoke execute on function privado.expirar_pedidos() from public, anon, authenticated;
revoke execute on function privado.gravar_segredo(text, text) from public, anon, authenticated;

revoke execute on function public.salvar_segredo_loja(text, text) from public, anon;
revoke execute on function public.status_loja_pagamento() from public, anon;
revoke execute on function public.criar_pedido_loja(text) from public, anon;
revoke execute on function public.cancelar_pedido_loja(uuid) from public, anon;
revoke execute on function public.avancar_pedido_loja(uuid, text) from public, anon;
grant execute on function public.salvar_segredo_loja(text, text) to authenticated;
grant execute on function public.status_loja_pagamento() to authenticated;
grant execute on function public.criar_pedido_loja(text) to authenticated;
grant execute on function public.cancelar_pedido_loja(uuid) to authenticated;
grant execute on function public.avancar_pedido_loja(uuid, text) to authenticated;

revoke execute on function public.ler_segredo_loja(text) from public, anon, authenticated;
revoke execute on function public.registrar_preferencia_loja(uuid, text) from public, anon, authenticated;
revoke execute on function public.confirmar_pagamento_loja(uuid, text, text, integer) from public, anon, authenticated;
grant execute on function public.ler_segredo_loja(text) to service_role;
grant execute on function public.registrar_preferencia_loja(uuid, text) to service_role;
grant execute on function public.confirmar_pagamento_loja(uuid, text, text, integer) to service_role;

-- =====================================================================
-- 6. EXPIRAÇÃO AUTOMÁTICA (a cada 5 minutos)
-- =====================================================================
select cron.schedule('loja-expirar-pedidos', '*/5 * * * *', 'select privado.expirar_pedidos();');

-- =====================================================================
-- 7. VERIFICAÇÃO
-- =====================================================================
select 'tabelas_pedidos' as item,
       string_agg(table_name, ', ' order by table_name) as resultado
  from information_schema.tables
 where table_schema = 'public' and table_name in ('pedidos', 'pedido_itens', 'loja_configuracoes')
union all
select 'funcoes_pagamento',
       string_agg(p.proname, ', ' order by p.proname)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname in ('public', 'privado')
   and p.proname in ('criar_pedido_loja', 'cancelar_pedido_loja', 'avancar_pedido_loja',
                     'confirmar_pagamento_loja', 'registrar_preferencia_loja', 'ler_segredo_loja',
                     'salvar_segredo_loja', 'status_loja_pagamento', 'expirar_pedidos')
union all
select 'tarefa_expirar', coalesce((select jobname || ' ' || schedule from cron.job
                                    where jobname = 'loja-expirar-pedidos'), 'faltando')
union all
select 'segredos_no_vault', string_agg(name, ', ' order by name)
  from vault.secrets where name in ('mp_access_token', 'mp_webhook_secret');
