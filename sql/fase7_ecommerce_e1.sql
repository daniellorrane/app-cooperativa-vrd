-- Fase 7 (e-commerce, etapa E1): catálogo, carrinho, favoritos, listas de presentes e avaliações.
-- Executar no SQL Editor do Supabase (projeto yutsnhuhimijtzqhpopu). Pode rodar mais de uma vez.
-- Requer: sql/fase6_endurecimento.sql (já rodado).
-- Nesta etapa NÃO há pagamento nem pedidos. Isso entra na E2 (Mercado Pago).
--
-- Regras:
--   Produto ativo: todo cooperado aprovado vê. Produto inativo: só administradores.
--   Catálogo, carrinho, favoritos e listas: cada pessoa vê e altera só o que é dela.
--   Lista de presentes: quem recebe o link precisa estar logado e aprovado.
--     A função ver_lista_compartilhada não mostra quem comprou (isso não é guardado aqui).
--   Avaliação: uma por produto e por pessoa. Administradores podem ocultar.
--     A regra "só quem comprou pode avaliar" entra na E2, quando existirem pedidos.
--   Preços sempre em centavos (inteiro). Administrador que muda preço gera registro de auditoria.

-- =====================================================================
-- 1. FUNÇÕES AUXILIARES
-- =====================================================================
create or replace function privado.usuario_aprovado()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.usuarios u
     where u.id = auth.uid() and u.status = 'aprovado'
  );
$$;

create or replace function privado.eh_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(auth.uid() = any(privado.administradores()), false);
$$;

revoke execute on function privado.usuario_aprovado() from public, anon;
revoke execute on function privado.eh_admin() from public, anon;
grant execute on function privado.usuario_aprovado() to authenticated;
grant execute on function privado.eh_admin() to authenticated;

-- =====================================================================
-- 2. TABELAS
-- =====================================================================
create table if not exists public.loja_categorias (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (length(trim(nome)) between 2 and 60),
  ordem smallint not null default 0 check (ordem between 0 and 999),
  ativa boolean not null default true,
  criado_em timestamptz not null default now()
);

create table if not exists public.loja_produtos (
  id uuid primary key default gen_random_uuid(),
  categoria_id uuid references public.loja_categorias(id) on delete set null,
  nome text not null check (length(trim(nome)) between 3 and 150),
  descricao text check (descricao is null or length(descricao) <= 4000),
  preco_centavos integer not null check (preco_centavos between 1 and 100000000),
  preco_promo_centavos integer check (
    preco_promo_centavos is null
    or (preco_promo_centavos >= 1 and preco_promo_centavos < preco_centavos)
  ),
  estoque integer not null default 0 check (estoque between 0 and 1000000),
  imagem_caminho text check (imagem_caminho is null or length(imagem_caminho) <= 300),
  ativo boolean not null default false,
  criado_por uuid references public.usuarios(id) on delete set null,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index if not exists loja_produtos_categoria_idx on public.loja_produtos (categoria_id);
create index if not exists loja_produtos_ativo_nome_idx on public.loja_produtos (ativo, nome);

create table if not exists public.carrinho_itens (
  usuario_id uuid not null references public.usuarios(id) on delete cascade,
  produto_id uuid not null references public.loja_produtos(id) on delete cascade,
  quantidade smallint not null default 1 check (quantidade between 1 and 20),
  atualizado_em timestamptz not null default now(),
  primary key (usuario_id, produto_id)
);

create table if not exists public.favoritos (
  usuario_id uuid not null references public.usuarios(id) on delete cascade,
  produto_id uuid not null references public.loja_produtos(id) on delete cascade,
  criado_em timestamptz not null default now(),
  primary key (usuario_id, produto_id)
);
create index if not exists favoritos_produto_idx on public.favoritos (produto_id);

create table if not exists public.listas_loja (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references public.usuarios(id) on delete cascade,
  titulo text not null check (length(trim(titulo)) between 2 and 100),
  tipo text not null default 'presentes' check (tipo in ('presentes', 'desejos')),
  -- Token aleatório (122 bits) usado no link de compartilhamento. Não é o id da lista.
  token text not null unique default replace(gen_random_uuid()::text, '-', ''),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index if not exists listas_loja_usuario_idx on public.listas_loja (usuario_id);

create table if not exists public.lista_loja_itens (
  lista_id uuid not null references public.listas_loja(id) on delete cascade,
  produto_id uuid not null references public.loja_produtos(id) on delete cascade,
  quantidade_desejada smallint not null default 1 check (quantidade_desejada between 1 and 50),
  -- Preenchido pela E2 quando um pedido pago inclui o item. Não pode passar do desejado.
  quantidade_comprada smallint not null default 0 check (quantidade_comprada >= 0),
  adicionado_em timestamptz not null default now(),
  primary key (lista_id, produto_id),
  check (quantidade_comprada <= quantidade_desejada)
);
create index if not exists lista_loja_itens_produto_idx on public.lista_loja_itens (produto_id);

create table if not exists public.avaliacoes_produto (
  id uuid primary key default gen_random_uuid(),
  produto_id uuid not null references public.loja_produtos(id) on delete cascade,
  usuario_id uuid not null references public.usuarios(id) on delete cascade,
  nota smallint not null check (nota between 1 and 5),
  comentario text check (comentario is null or length(trim(comentario)) <= 600),
  status text not null default 'publicada' check (status in ('publicada', 'oculta')),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  unique (produto_id, usuario_id)
);
create index if not exists avaliacoes_produto_usuario_idx on public.avaliacoes_produto (usuario_id);

-- =====================================================================
-- 3. GATILHOS
-- =====================================================================
-- Carrinho: produto precisa estar ativo e a quantidade não pode passar do estoque.
create or replace function privado.checar_estoque_carrinho()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_estoque integer;
  v_ativo boolean;
begin
  select p.estoque, p.ativo into v_estoque, v_ativo
    from public.loja_produtos p where p.id = new.produto_id;

  if not coalesce(v_ativo, false) then
    raise exception 'Este produto não está mais disponível.';
  end if;
  if v_estoque = 0 then
    raise exception 'Este produto está sem estoque no momento.';
  end if;
  if new.quantidade > v_estoque then
    raise exception 'Restam apenas % unidades deste produto.', v_estoque;
  end if;
  return new;
end;
$$;

drop trigger if exists carrinho_checar_estoque on public.carrinho_itens;
create trigger carrinho_checar_estoque
  before insert or update on public.carrinho_itens
  for each row execute function privado.checar_estoque_carrinho();

-- Auditoria: mudança de preço ou de promoção.
create or replace function privado.audita_preco_produto()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.preco_centavos is distinct from old.preco_centavos
     or new.preco_promo_centavos is distinct from old.preco_promo_centavos then
    perform privado.auditar(
      'preco_alterado', 'loja_produto', new.id::text,
      jsonb_build_object(
        'preco_de', old.preco_centavos, 'preco_para', new.preco_centavos,
        'promo_de', old.preco_promo_centavos, 'promo_para', new.preco_promo_centavos
      )
    );
  end if;
  new.atualizado_em := now();
  return new;
end;
$$;

drop trigger if exists loja_produtos_audita_preco on public.loja_produtos;
create trigger loja_produtos_audita_preco
  before update on public.loja_produtos
  for each row execute function privado.audita_preco_produto();

-- Avaliação: só administradores mudam o status (ocultar ou mostrar).
create or replace function privado.protege_status_avaliacao()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status is distinct from old.status and not privado.eh_admin() then
    raise exception 'Apenas administradores podem ocultar ou mostrar avaliações.';
  end if;
  if new.status is distinct from old.status then
    perform privado.auditar(
      case when new.status = 'oculta' then 'avaliacao_ocultada' else 'avaliacao_publicada' end,
      'avaliacao_produto', new.id::text,
      jsonb_build_object('produto_id', new.produto_id)
    );
  end if;
  new.atualizado_em := now();
  return new;
end;
$$;

drop trigger if exists avaliacoes_protege_status on public.avaliacoes_produto;
create trigger avaliacoes_protege_status
  before update on public.avaliacoes_produto
  for each row execute function privado.protege_status_avaliacao();

-- =====================================================================
-- 4. PERMISSÕES DE TABELA (RLS)
-- =====================================================================
alter table public.loja_categorias enable row level security;
alter table public.loja_produtos enable row level security;
alter table public.carrinho_itens enable row level security;
alter table public.favoritos enable row level security;
alter table public.listas_loja enable row level security;
alter table public.lista_loja_itens enable row level security;
alter table public.avaliacoes_produto enable row level security;

drop policy if exists loja_categorias_ler on public.loja_categorias;
create policy loja_categorias_ler on public.loja_categorias
  for select to authenticated
  using (privado.usuario_aprovado() or privado.eh_admin());

drop policy if exists loja_categorias_admin on public.loja_categorias;
create policy loja_categorias_admin on public.loja_categorias
  for all to authenticated
  using (privado.eh_admin()) with check (privado.eh_admin());

drop policy if exists loja_produtos_ler on public.loja_produtos;
create policy loja_produtos_ler on public.loja_produtos
  for select to authenticated
  using ((ativo and privado.usuario_aprovado()) or privado.eh_admin());

drop policy if exists loja_produtos_admin on public.loja_produtos;
create policy loja_produtos_admin on public.loja_produtos
  for all to authenticated
  using (privado.eh_admin()) with check (privado.eh_admin());

drop policy if exists carrinho_proprio on public.carrinho_itens;
create policy carrinho_proprio on public.carrinho_itens
  for all to authenticated
  using (usuario_id = auth.uid() and privado.usuario_aprovado())
  with check (usuario_id = auth.uid() and privado.usuario_aprovado());

drop policy if exists favoritos_proprios on public.favoritos;
create policy favoritos_proprios on public.favoritos
  for all to authenticated
  using (usuario_id = auth.uid() and privado.usuario_aprovado())
  with check (usuario_id = auth.uid() and privado.usuario_aprovado());

drop policy if exists listas_proprias on public.listas_loja;
create policy listas_proprias on public.listas_loja
  for all to authenticated
  using (usuario_id = auth.uid() and privado.usuario_aprovado())
  with check (usuario_id = auth.uid() and privado.usuario_aprovado());

drop policy if exists lista_itens_proprios on public.lista_loja_itens;
create policy lista_itens_proprios on public.lista_loja_itens
  for all to authenticated
  using (exists (select 1 from public.listas_loja l where l.id = lista_id and l.usuario_id = auth.uid()))
  with check (exists (select 1 from public.listas_loja l where l.id = lista_id and l.usuario_id = auth.uid()));

drop policy if exists avaliacoes_ler on public.avaliacoes_produto;
create policy avaliacoes_ler on public.avaliacoes_produto
  for select to authenticated
  using (
    (status = 'publicada' and privado.usuario_aprovado())
    or usuario_id = auth.uid()
    or privado.eh_admin()
  );

drop policy if exists avaliacoes_inserir on public.avaliacoes_produto;
create policy avaliacoes_inserir on public.avaliacoes_produto
  for insert to authenticated
  with check (usuario_id = auth.uid() and status = 'publicada' and privado.usuario_aprovado());

drop policy if exists avaliacoes_editar on public.avaliacoes_produto;
create policy avaliacoes_editar on public.avaliacoes_produto
  for update to authenticated
  using (usuario_id = auth.uid() or privado.eh_admin())
  with check (usuario_id = auth.uid() or privado.eh_admin());

drop policy if exists avaliacoes_apagar on public.avaliacoes_produto;
create policy avaliacoes_apagar on public.avaliacoes_produto
  for delete to authenticated
  using (usuario_id = auth.uid() or privado.eh_admin());

-- =====================================================================
-- 5. FOTOS DOS PRODUTOS (bucket público só para leitura; envio só administradores)
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('loja-fotos', 'loja-fotos', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = true,
      file_size_limit = 2097152,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists loja_fotos_enviar on storage.objects;
create policy loja_fotos_enviar on storage.objects
  for insert to authenticated
  with check (bucket_id = 'loja-fotos' and privado.eh_admin());

drop policy if exists loja_fotos_trocar on storage.objects;
create policy loja_fotos_trocar on storage.objects
  for update to authenticated
  using (bucket_id = 'loja-fotos' and privado.eh_admin())
  with check (bucket_id = 'loja-fotos' and privado.eh_admin());

drop policy if exists loja_fotos_apagar on storage.objects;
create policy loja_fotos_apagar on storage.objects
  for delete to authenticated
  using (bucket_id = 'loja-fotos' and privado.eh_admin());

-- =====================================================================
-- 6. CONSULTAS PARA A TELA (vitrine, recomendações e lista compartilhada)
-- =====================================================================
create or replace function public.vitrine_loja(p_categoria uuid default null, p_busca text default null)
returns table (
  id uuid, nome text, preco_centavos integer, preco_promo_centavos integer,
  imagem_caminho text, estoque integer, categoria_id uuid, categoria_nome text,
  media numeric, avaliacoes bigint, favorito boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, p.nome, p.preco_centavos, p.preco_promo_centavos, p.imagem_caminho,
         p.estoque, p.categoria_id, c.nome,
         r.media, coalesce(r.total, 0),
         exists (select 1 from public.favoritos f where f.produto_id = p.id and f.usuario_id = auth.uid())
    from public.loja_produtos p
    left join public.loja_categorias c on c.id = p.categoria_id
    left join lateral (
      select round(avg(a.nota)::numeric, 1) as media, count(*) as total
        from public.avaliacoes_produto a
       where a.produto_id = p.id and a.status = 'publicada'
    ) r on true
   where p.ativo
     and privado.usuario_aprovado()
     and (p_categoria is null or p.categoria_id = p_categoria)
     and (p_busca is null or length(trim(p_busca)) = 0
          or p.nome ilike '%' || replace(replace(trim(p_busca), '%', ''), '_', '') || '%')
   order by p.nome
   limit 200;
$$;

create or replace function public.recomendados_para_mim()
returns table (
  id uuid, nome text, preco_centavos integer, preco_promo_centavos integer,
  imagem_caminho text, estoque integer, categoria_id uuid, categoria_nome text,
  media numeric, avaliacoes bigint, favorito boolean, motivo text
)
language sql
stable
security definer
set search_path = public
as $$
  with categorias_favoritas as (
    select distinct p.categoria_id
      from public.favoritos f
      join public.loja_produtos p on p.id = f.produto_id
     where f.usuario_id = auth.uid() and p.categoria_id is not null
  )
  select p.id, p.nome, p.preco_centavos, p.preco_promo_centavos, p.imagem_caminho,
         p.estoque, p.categoria_id, c.nome,
         r.media, coalesce(r.total, 0), false,
         case when cf.categoria_id is not null
              then 'Parecido com o que você favoritou'
              else 'Muito bem avaliado pelos cooperados' end
    from public.loja_produtos p
    left join public.loja_categorias c on c.id = p.categoria_id
    left join categorias_favoritas cf on cf.categoria_id = p.categoria_id
    left join lateral (
      select round(avg(a.nota)::numeric, 1) as media, count(*) as total
        from public.avaliacoes_produto a
       where a.produto_id = p.id and a.status = 'publicada'
    ) r on true
   where p.ativo and p.estoque > 0
     and privado.usuario_aprovado()
     and not exists (select 1 from public.favoritos f where f.produto_id = p.id and f.usuario_id = auth.uid())
   order by (cf.categoria_id is not null) desc, r.media desc nulls last, coalesce(r.total, 0) desc, p.nome
   limit 12;
$$;

create or replace function public.ver_lista_compartilhada(p_token text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', l.id,
    'titulo', l.titulo,
    'tipo', l.tipo,
    'dono', split_part(u.nome_completo, ' ', 1),
    'itens', coalesce((
      select jsonb_agg(jsonb_build_object(
               'produto_id', p.id,
               'nome', p.nome,
               'preco_centavos', coalesce(p.preco_promo_centavos, p.preco_centavos),
               'imagem', p.imagem_caminho,
               'disponivel', (p.estoque > 0),
               'desejada', i.quantidade_desejada,
               'comprada', i.quantidade_comprada)
             order by p.nome)
        from public.lista_loja_itens i
        join public.loja_produtos p on p.id = i.produto_id
       where i.lista_id = l.id and p.ativo
    ), '[]'::jsonb)
  )
  from public.listas_loja l
  join public.usuarios u on u.id = l.usuario_id
  where l.token = p_token
    and privado.usuario_aprovado();
$$;

revoke execute on function public.vitrine_loja(uuid, text) from public, anon;
revoke execute on function public.recomendados_para_mim() from public, anon;
revoke execute on function public.ver_lista_compartilhada(text) from public, anon;
grant execute on function public.vitrine_loja(uuid, text) to authenticated;
grant execute on function public.recomendados_para_mim() to authenticated;
grant execute on function public.ver_lista_compartilhada(text) to authenticated;

-- =====================================================================
-- 7. VERIFICAÇÃO
-- =====================================================================
select 'tabelas_loja' as item,
       count(*)::text as resultado
  from information_schema.tables
 where table_schema = 'public'
   and table_name in ('loja_categorias', 'loja_produtos', 'carrinho_itens', 'favoritos',
                      'listas_loja', 'lista_loja_itens', 'avaliacoes_produto')
union all
select 'bucket_loja_fotos', case when exists (select 1 from storage.buckets where id = 'loja-fotos' and public) then 'ok' else 'faltando' end
union all
select 'funcoes_loja', string_agg(p.proname, ', ' order by p.proname)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname in ('public', 'privado')
   and p.proname in ('vitrine_loja', 'recomendados_para_mim', 'ver_lista_compartilhada',
                     'usuario_aprovado', 'eh_admin', 'checar_estoque_carrinho', 'audita_preco_produto',
                     'protege_status_avaliacao');
