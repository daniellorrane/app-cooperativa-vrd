-- Fase 4: carteirinha digital (QR code), biblioteca de documentos com versões, enquetes e pesquisas.
-- Executar no SQL Editor do Supabase (projeto yutsnhuhimijtzqhpopu). Pode rodar mais de uma vez.
-- Requer: sql/fase3_agenda.sql (já rodado).
--
-- Regras:
--   Biblioteca e enquetes gerais (sem área): todos os aprovados veem.
--   Área: somente os funcionários da área e administradores veem.
--   Publicam: administradores (geral ou qualquer área) e funcionários (somente das suas áreas).
--   Documentos não são apagados: são arquivados, e cada nova versão fica guardada.
--   Enquetes anônimas: o sistema não mostra quem respondeu. O banco guarda o vínculo só para impedir resposta dupla.

-- =====================================================================
-- 1. CARTEIRINHA DIGITAL
-- =====================================================================
alter table public.usuarios add column if not exists codigo_carteirinha text;
update public.usuarios
   set codigo_carteirinha = replace(gen_random_uuid()::text, '-', '')
 where codigo_carteirinha is null;
alter table public.usuarios alter column codigo_carteirinha set not null;
alter table public.usuarios alter column codigo_carteirinha set default replace(gen_random_uuid()::text, '-', '');
create unique index if not exists usuarios_codigo_carteirinha_key on public.usuarios (codigo_carteirinha);

-- O código é gerado pelo servidor e só muda pela função renovar_carteirinha().
create or replace function privado.protege_codigo_carteirinha()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.codigo_carteirinha := replace(gen_random_uuid()::text, '-', '');
  elsif coalesce(current_setting('app.sistema', true), '') <> 'on' then
    new.codigo_carteirinha := old.codigo_carteirinha;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_protege_codigo_carteirinha on public.usuarios;
create trigger trg_protege_codigo_carteirinha
  before insert or update on public.usuarios
  for each row execute function privado.protege_codigo_carteirinha();

-- Validação pública (quem lê o QR code). Mostra só o mínimo: nome abreviado, tipo, situação.
create or replace function public.validar_carteirinha(p_codigo text)
returns table (nome_exibicao text, tipo_acesso text, situacao text, cadastro_desde date)
language sql
stable
security definer
set search_path = public
as $$
  select regexp_replace(trim(u.nome_completo), '^(\S+).*\s(\S+)$', '\1 \2'),
         u.tipo_acesso,
         case when u.status = 'aprovado' then 'Ativo' else 'Inativo' end,
         u.criado_em::date
    from public.usuarios u
   where u.codigo_carteirinha = p_codigo
     and length(p_codigo) = 32;
$$;

revoke execute on function public.validar_carteirinha(text) from public;
grant execute on function public.validar_carteirinha(text) to anon, authenticated;

create or replace function public.renovar_carteirinha()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_novo text := replace(gen_random_uuid()::text, '-', '');
begin
  if auth.uid() is null then
    raise exception 'Sessão inválida.';
  end if;
  perform set_config('app.sistema', 'on', true);
  update public.usuarios set codigo_carteirinha = v_novo where id = auth.uid();
  perform privado.auditar('carteirinha_renovada', 'usuarios', auth.uid()::text, '{}'::jsonb);
  return v_novo;
end;
$$;

revoke execute on function public.renovar_carteirinha() from public, anon;
grant execute on function public.renovar_carteirinha() to authenticated;

-- =====================================================================
-- 2. REGRAS DE PUBLICAÇÃO E VISIBILIDADE
-- =====================================================================
create or replace function privado.pode_publicar_em(p_area uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select privado.funcao_admin() or (p_area is not null and privado.e_funcionario_da_area(p_area));
$$;

-- =====================================================================
-- 3. BIBLIOTECA DE DOCUMENTOS
-- =====================================================================
create table if not exists public.documentos (
  id uuid primary key default gen_random_uuid(),
  titulo text not null check (length(trim(titulo)) between 3 and 120),
  descricao text check (descricao is null or length(descricao) <= 1000),
  area_id uuid references public.areas(id) on delete cascade,
  arquivado boolean not null default false,
  criado_por uuid references public.usuarios(id) on delete set null,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create table if not exists public.documento_versoes (
  id uuid primary key default gen_random_uuid(),
  documento_id uuid not null references public.documentos(id) on delete cascade,
  versao integer not null check (versao >= 1),
  caminho text not null unique,
  nome_arquivo text not null check (length(trim(nome_arquivo)) between 1 and 200),
  tipo_mime text not null check (tipo_mime in (
    'application/pdf',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'image/png', 'image/jpeg', 'image/webp')),
  tamanho integer not null check (tamanho > 0 and tamanho <= 10485760),
  observacao text check (observacao is null or length(observacao) <= 300),
  publicado_por uuid references public.usuarios(id) on delete set null,
  publicado_em timestamptz not null default now(),
  unique (documento_id, versao)
);

create or replace function privado.pode_ver_documento(p_documento uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.documentos d
     where d.id = p_documento
       and (
         privado.funcao_admin()
         or (not d.arquivado and d.area_id is null and exists (
               select 1 from public.usuarios u where u.id = auth.uid() and u.status = 'aprovado'))
         or (not d.arquivado and d.area_id is not null and privado.e_funcionario_da_area(d.area_id))
       )
  );
$$;

create or replace function privado.pode_publicar_documento(p_documento uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.documentos d
     where d.id = p_documento and privado.pode_publicar_em(d.area_id)
  );
$$;

alter table public.documentos enable row level security;
alter table public.documento_versoes enable row level security;
revoke all on public.documentos from anon, authenticated;
revoke all on public.documento_versoes from anon, authenticated;
grant select on public.documentos to authenticated;
grant select on public.documento_versoes to authenticated;

drop policy if exists documentos_ler on public.documentos;
create policy documentos_ler on public.documentos
  for select to authenticated
  using (privado.pode_ver_documento(id));

drop policy if exists documento_versoes_ler on public.documento_versoes;
create policy documento_versoes_ler on public.documento_versoes
  for select to authenticated
  using (privado.pode_ver_documento(documento_id));

create or replace function public.criar_documento(p_titulo text, p_descricao text, p_area uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_titulo text := trim(coalesce(p_titulo, ''));
  v_descricao text := nullif(trim(coalesce(p_descricao, '')), '');
begin
  if not privado.pode_publicar_em(p_area) then
    raise exception 'Você não pode publicar documentos para esta área.';
  end if;
  if length(v_titulo) < 3 or length(v_titulo) > 120 then
    raise exception 'O título precisa ter de 3 a 120 caracteres.';
  end if;
  if v_descricao is not null and length(v_descricao) > 1000 then
    raise exception 'A descrição pode ter até 1000 caracteres.';
  end if;

  insert into public.documentos (titulo, descricao, area_id, criado_por)
  values (v_titulo, v_descricao, p_area, auth.uid())
  returning id into v_id;

  perform privado.auditar('documento_criado', 'documentos', v_id::text, jsonb_build_object('area_id', p_area));
  return v_id;
end;
$$;

revoke execute on function public.criar_documento(text, text, uuid) from public, anon;
grant execute on function public.criar_documento(text, text, uuid) to authenticated;

-- Registra um arquivo já enviado ao bucket "biblioteca" como nova versão.
create or replace function public.publicar_versao(
  p_documento uuid,
  p_caminho text,
  p_nome text,
  p_mime text,
  p_tamanho integer,
  p_observacao text
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  d record;
  v_versao integer;
  v_observacao text := nullif(trim(coalesce(p_observacao, '')), '');
begin
  select * into d from public.documentos where id = p_documento;
  if not found or not privado.pode_publicar_em(d.area_id) then
    raise exception 'Você não pode publicar uma nova versão deste documento.';
  end if;
  if p_caminho is null or left(p_caminho, length(p_documento::text) + 1) <> p_documento::text || '/' then
    raise exception 'Arquivo inválido para este documento.';
  end if;
  if p_tamanho is null or p_tamanho <= 0 or p_tamanho > 10485760 then
    raise exception 'O arquivo deve ter até 10 MB.';
  end if;
  if v_observacao is not null and length(v_observacao) > 300 then
    raise exception 'A observação pode ter até 300 caracteres.';
  end if;

  select coalesce(max(v.versao), 0) + 1 into v_versao
    from public.documento_versoes v where v.documento_id = p_documento;

  insert into public.documento_versoes
    (documento_id, versao, caminho, nome_arquivo, tipo_mime, tamanho, observacao, publicado_por)
  values
    (p_documento, v_versao, p_caminho, p_nome, p_mime, p_tamanho, v_observacao, auth.uid());

  update public.documentos set atualizado_em = now() where id = p_documento;

  -- Aviso genérico, sem o nome do documento. Quem publicou não recebe.
  perform privado.notificar(
    (select coalesce(array_agg(x), '{}'::uuid[]) from unnest(privado.publico_do_evento(d.area_id)) as x where x <> auth.uid()),
    case when v_versao = 1 then 'Novo documento na biblioteca' else 'Documento atualizado na biblioteca' end,
    'Há um documento novo ou atualizado na biblioteca. Abra o sistema para ver.',
    null);

  perform privado.auditar('documento_versao_publicada', 'documentos', p_documento::text,
    jsonb_build_object('versao', v_versao));
  return v_versao;
end;
$$;

revoke execute on function public.publicar_versao(uuid, text, text, text, integer, text) from public, anon;
grant execute on function public.publicar_versao(uuid, text, text, text, integer, text) to authenticated;

create or replace function public.arquivar_documento(p_documento uuid, p_arquivar boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  d record;
begin
  select * into d from public.documentos where id = p_documento;
  if not found or not privado.pode_publicar_em(d.area_id) then
    raise exception 'Você não pode alterar este documento.';
  end if;

  update public.documentos set arquivado = coalesce(p_arquivar, true), atualizado_em = now() where id = p_documento;
  perform privado.auditar(
    case when coalesce(p_arquivar, true) then 'documento_arquivado' else 'documento_reativado' end,
    'documentos', p_documento::text, '{}'::jsonb);
end;
$$;

revoke execute on function public.arquivar_documento(uuid, boolean) from public, anon;
grant execute on function public.arquivar_documento(uuid, boolean) to authenticated;

-- Bucket privado. Pasta = id do documento. Só quem vê o documento lê; só quem publica envia.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'biblioteca', 'biblioteca', false, 10485760,
  array[
    'application/pdf',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'image/png', 'image/jpeg', 'image/webp'
  ]
)
on conflict (id) do update
  set public = false,
      file_size_limit = 10485760,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists biblioteca_storage_enviar on storage.objects;
create policy biblioteca_storage_enviar on storage.objects
  for insert to authenticated
  with check (
    case when bucket_id = 'biblioteca'
      then privado.pode_publicar_documento(((storage.foldername(name))[1])::uuid)
      else false
    end
  );

drop policy if exists biblioteca_storage_ler on storage.objects;
create policy biblioteca_storage_ler on storage.objects
  for select to authenticated
  using (
    case when bucket_id = 'biblioteca'
      then privado.pode_ver_documento(((storage.foldername(name))[1])::uuid)
      else false
    end
  );

-- =====================================================================
-- 4. ENQUETES E PESQUISAS
-- =====================================================================
create table if not exists public.enquetes (
  id uuid primary key default gen_random_uuid(),
  titulo text not null check (length(trim(titulo)) between 3 and 160),
  descricao text check (descricao is null or length(descricao) <= 1000),
  area_id uuid references public.areas(id) on delete cascade,
  multipla_escolha boolean not null default false,
  anonima boolean not null default true,
  aceita_comentario boolean not null default false,
  encerra_em timestamptz not null,
  criado_por uuid references public.usuarios(id) on delete set null,
  criado_em timestamptz not null default now()
);

create table if not exists public.enquete_opcoes (
  id uuid primary key default gen_random_uuid(),
  enquete_id uuid not null references public.enquetes(id) on delete cascade,
  texto text not null check (length(trim(texto)) between 1 and 200),
  ordem smallint not null default 0
);

create table if not exists public.enquete_respostas (
  enquete_id uuid not null references public.enquetes(id) on delete cascade,
  usuario_id uuid not null references public.usuarios(id) on delete cascade,
  comentario text check (comentario is null or length(comentario) <= 500),
  respondido_em timestamptz not null default now(),
  primary key (enquete_id, usuario_id)
);

create table if not exists public.enquete_escolhas (
  enquete_id uuid not null,
  usuario_id uuid not null,
  opcao_id uuid not null references public.enquete_opcoes(id) on delete cascade,
  primary key (enquete_id, usuario_id, opcao_id),
  foreign key (enquete_id, usuario_id) references public.enquete_respostas(enquete_id, usuario_id) on delete cascade
);

create or replace function privado.pode_ver_enquete(p_enquete uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.enquetes e
     where e.id = p_enquete
       and (
         privado.funcao_admin()
         or (e.area_id is null and exists (
               select 1 from public.usuarios u where u.id = auth.uid() and u.status = 'aprovado'))
         or (e.area_id is not null and privado.e_funcionario_da_area(e.area_id))
       )
  );
$$;

alter table public.enquetes enable row level security;
alter table public.enquete_opcoes enable row level security;
alter table public.enquete_respostas enable row level security;
alter table public.enquete_escolhas enable row level security;
revoke all on public.enquetes from anon, authenticated;
revoke all on public.enquete_opcoes from anon, authenticated;
revoke all on public.enquete_respostas from anon, authenticated;
revoke all on public.enquete_escolhas from anon, authenticated;
grant select on public.enquetes to authenticated;
grant select on public.enquete_opcoes to authenticated;
-- Respostas e escolhas não são lidas diretamente: só pelas funções abaixo.

drop policy if exists enquetes_ler on public.enquetes;
create policy enquetes_ler on public.enquetes
  for select to authenticated
  using (privado.pode_ver_enquete(id));

drop policy if exists enquete_opcoes_ler on public.enquete_opcoes;
create policy enquete_opcoes_ler on public.enquete_opcoes
  for select to authenticated
  using (privado.pode_ver_enquete(enquete_id));

create or replace function public.criar_enquete(
  p_titulo text,
  p_descricao text,
  p_area uuid,
  p_multipla boolean,
  p_anonima boolean,
  p_aceita_comentario boolean,
  p_encerra_em timestamptz,
  p_opcoes text[]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_titulo text := trim(coalesce(p_titulo, ''));
  v_descricao text := nullif(trim(coalesce(p_descricao, '')), '');
  v_n integer;
begin
  if not privado.pode_publicar_em(p_area) then
    raise exception 'Você não pode criar enquetes para esta área.';
  end if;
  if length(v_titulo) < 3 or length(v_titulo) > 160 then
    raise exception 'O título precisa ter de 3 a 160 caracteres.';
  end if;
  if v_descricao is not null and length(v_descricao) > 1000 then
    raise exception 'A descrição pode ter até 1000 caracteres.';
  end if;
  if p_encerra_em is null or p_encerra_em <= now() then
    raise exception 'Informe um encerramento depois de agora.';
  end if;
  v_n := coalesce(array_length(p_opcoes, 1), 0);
  if v_n < 2 or v_n > 10 then
    raise exception 'Informe de 2 a 10 opções.';
  end if;
  if exists (select 1 from unnest(p_opcoes) o where length(trim(o)) < 1 or length(trim(o)) > 200) then
    raise exception 'Cada opção precisa ter de 1 a 200 caracteres.';
  end if;

  insert into public.enquetes
    (titulo, descricao, area_id, multipla_escolha, anonima, aceita_comentario, encerra_em, criado_por)
  values
    (v_titulo, v_descricao, p_area, coalesce(p_multipla, false), coalesce(p_anonima, true),
     coalesce(p_aceita_comentario, false), p_encerra_em, auth.uid())
  returning id into v_id;

  insert into public.enquete_opcoes (enquete_id, texto, ordem)
  select v_id, trim(o.texto), o.posicao::smallint
    from unnest(p_opcoes) with ordinality as o(texto, posicao);

  perform privado.notificar(
    (select coalesce(array_agg(x), '{}'::uuid[]) from unnest(privado.publico_do_evento(p_area)) as x where x <> auth.uid()),
    'Nova enquete ou pesquisa',
    'Há uma nova enquete ou pesquisa para você responder.',
    null);

  perform privado.auditar('enquete_criada', 'enquetes', v_id::text, jsonb_build_object('area_id', p_area));
  return v_id;
end;
$$;

revoke execute on function public.criar_enquete(text, text, uuid, boolean, boolean, boolean, timestamptz, text[]) from public, anon;
grant execute on function public.criar_enquete(text, text, uuid, boolean, boolean, boolean, timestamptz, text[]) to authenticated;

create or replace function public.responder_enquete(p_enquete uuid, p_opcoes uuid[], p_comentario text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  e record;
  v_n integer;
  v_comentario text := nullif(trim(coalesce(p_comentario, '')), '');
begin
  select * into e from public.enquetes where id = p_enquete;
  if not found or not privado.pode_ver_enquete(p_enquete) then
    raise exception 'Enquete não encontrada.';
  end if;
  if now() >= e.encerra_em then
    raise exception 'Esta enquete já foi encerrada.';
  end if;
  if exists (select 1 from public.enquete_respostas r where r.enquete_id = p_enquete and r.usuario_id = auth.uid()) then
    raise exception 'Você já respondeu esta enquete.';
  end if;

  v_n := coalesce(array_length(p_opcoes, 1), 0);
  if v_n < 1 then
    raise exception 'Escolha pelo menos uma opção.';
  end if;
  if v_n > 1 and not e.multipla_escolha then
    raise exception 'Escolha apenas uma opção.';
  end if;
  if (select count(distinct x) from unnest(p_opcoes) as x) <> v_n then
    raise exception 'Há opções repetidas.';
  end if;
  if (select count(*) from public.enquete_opcoes o where o.enquete_id = p_enquete and o.id = any(p_opcoes)) <> v_n then
    raise exception 'Opção inválida.';
  end if;
  if v_comentario is not null and not e.aceita_comentario then
    raise exception 'Esta enquete não aceita comentários.';
  end if;
  if v_comentario is not null and length(v_comentario) > 500 then
    raise exception 'O comentário pode ter até 500 caracteres.';
  end if;

  insert into public.enquete_respostas (enquete_id, usuario_id, comentario)
  values (p_enquete, auth.uid(), v_comentario);

  insert into public.enquete_escolhas (enquete_id, usuario_id, opcao_id)
  select p_enquete, auth.uid(), x from unnest(p_opcoes) as x;

  -- Auditoria registra só que houve participação, nunca a opção escolhida.
  perform privado.auditar('enquete_respondida', 'enquetes', p_enquete::text, '{}'::jsonb);
end;
$$;

revoke execute on function public.responder_enquete(uuid, uuid[], text) from public, anon;
grant execute on function public.responder_enquete(uuid, uuid[], text) to authenticated;

create or replace function public.encerrar_enquete(p_enquete uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  e record;
begin
  select * into e from public.enquetes where id = p_enquete;
  if not found or not (privado.funcao_admin() or e.criado_por = auth.uid()) then
    raise exception 'Você não pode encerrar esta enquete.';
  end if;
  update public.enquetes set encerra_em = least(encerra_em, now()) where id = p_enquete;
  perform privado.auditar('enquete_encerrada', 'enquetes', p_enquete::text, '{}'::jsonb);
end;
$$;

revoke execute on function public.encerrar_enquete(uuid) from public, anon;
grant execute on function public.encerrar_enquete(uuid) to authenticated;

-- Lista para o painel: sem votos, só dados gerais e se a pessoa já respondeu.
create or replace function public.listar_enquetes()
returns table (id uuid, titulo text, area text, encerra_em timestamptz, ja_respondeu boolean, anonima boolean, multipla_escolha boolean)
language sql
stable
security definer
set search_path = public
as $$
  select e.id,
         e.titulo,
         a.nome,
         e.encerra_em,
         exists (select 1 from public.enquete_respostas r where r.enquete_id = e.id and r.usuario_id = auth.uid()),
         e.anonima,
         e.multipla_escolha
    from public.enquetes e
    left join public.areas a on a.id = e.area_id
   where privado.pode_ver_enquete(e.id)
   order by e.encerra_em desc
   limit 100;
$$;

revoke execute on function public.listar_enquetes() from public, anon;
grant execute on function public.listar_enquetes() to authenticated;

-- Detalhe: os resultados só aparecem depois de responder, após o encerramento, ou para o criador e administradores.
create or replace function public.detalhe_enquete(p_enquete uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  e record;
  v_uid uuid := auth.uid();
  v_gestor boolean;
  v_respondeu boolean;
  v_encerrada boolean;
  v_ver boolean;
begin
  select * into e from public.enquetes where id = p_enquete;
  if not found or not privado.pode_ver_enquete(p_enquete) then
    raise exception 'Enquete não encontrada.';
  end if;

  v_gestor := privado.funcao_admin() or e.criado_por = v_uid;
  v_respondeu := exists (select 1 from public.enquete_respostas r where r.enquete_id = p_enquete and r.usuario_id = v_uid);
  v_encerrada := now() >= e.encerra_em;
  v_ver := v_gestor or v_respondeu or v_encerrada;

  return jsonb_build_object(
    'id', e.id,
    'titulo', e.titulo,
    'descricao', e.descricao,
    'area', (select a.nome from public.areas a where a.id = e.area_id),
    'multipla_escolha', e.multipla_escolha,
    'anonima', e.anonima,
    'aceita_comentario', e.aceita_comentario,
    'encerra_em', e.encerra_em,
    'encerrada', v_encerrada,
    'gestor', v_gestor,
    'ja_respondeu', v_respondeu,
    'pode_ver_resultado', v_ver,
    'total_respondentes', (select count(*) from public.enquete_respostas r where r.enquete_id = p_enquete),
    'opcoes', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', o.id,
        'texto', o.texto,
        'votos', case when v_ver then (select count(*) from public.enquete_escolhas c where c.opcao_id = o.id) else null end,
        'minha', exists (select 1 from public.enquete_escolhas c where c.opcao_id = o.id and c.usuario_id = v_uid)
      ) order by o.ordem), '[]'::jsonb)
        from public.enquete_opcoes o where o.enquete_id = p_enquete
    ),
    'comentarios', case when v_ver and e.aceita_comentario then (
      select coalesce(jsonb_agg(r.comentario order by r.respondido_em) filter (where r.comentario is not null), '[]'::jsonb)
        from public.enquete_respostas r where r.enquete_id = p_enquete
    ) else null end,
    'quem_votou', case when v_gestor and not e.anonima then (
      select coalesce(jsonb_agg(jsonb_build_object('nome', u.nome_completo, 'respondido_em', r.respondido_em) order by u.nome_completo), '[]'::jsonb)
        from public.enquete_respostas r join public.usuarios u on u.id = r.usuario_id
       where r.enquete_id = p_enquete
    ) else null end
  );
end;
$$;

revoke execute on function public.detalhe_enquete(uuid) from public, anon;
grant execute on function public.detalhe_enquete(uuid) to authenticated;

-- =====================================================================
-- 5. EXPORTAÇÃO (LGPD): inclui enquetes respondidas e a carteirinha ativa
-- =====================================================================
create or replace function public.exportar_meus_dados()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_dados jsonb;
begin
  if v_uid is null then
    raise exception 'Sessão inválida.';
  end if;

  select jsonb_build_object(
    'gerado_em', now(),
    'cadastro', (
      select jsonb_build_object(
        'nome_completo', u.nome_completo, 'cpf', u.cpf, 'email', u.email, 'telefone', u.telefone,
        'tipo_acesso', u.tipo_acesso, 'status', u.status, 'criado_em', u.criado_em
      ) from public.usuarios u where u.id = v_uid
    ),
    'aceites', coalesce((
      select jsonb_agg(jsonb_build_object('documento', a.documento, 'versao', a.versao, 'aceito_em', a.aceito_em) order by a.aceito_em)
        from public.aceites a where a.usuario_id = v_uid
    ), '[]'::jsonb),
    'atendimentos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'assunto', c.assunto,
        'tipo', c.tipo,
        'status', c.status,
        'criado_em', c.criado_em,
        'area', (select a.nome from public.areas a where a.id = c.area_id),
        'avaliacao', c.avaliacao,
        'avaliacao_comentario', c.avaliacao_comentario,
        'mensagens', coalesce((
          select jsonb_agg(jsonb_build_object(
            'quando', m.criado_em,
            'autor', case when m.autor_id = v_uid then 'Você' else 'Equipe' end,
            'texto', m.texto,
            'anexos', coalesce((
              select jsonb_agg(jsonb_build_object('nome_arquivo', x.nome_arquivo, 'enviado_em', x.criado_em) order by x.criado_em)
                from public.anexos x where x.mensagem_id = m.id
            ), '[]'::jsonb)
          ) order by m.criado_em)
          from public.mensagens m where m.conversa_id = c.id
        ), '[]'::jsonb)
      ) order by c.criado_em)
        from public.conversas c where c.solicitante_id = v_uid
    ), '[]'::jsonb),
    'agenda_eventos_criados', coalesce((
      select jsonb_agg(jsonb_build_object('titulo', e.titulo, 'inicio', e.inicio, 'criado_em', e.criado_em) order by e.criado_em)
        from public.eventos e where e.criado_por = v_uid
    ), '[]'::jsonb),
    'agenda_confirmacoes', coalesce((
      select jsonb_agg(jsonb_build_object('evento', e.titulo, 'inicio', e.inicio, 'tipo', r.tipo, 'resposta', r.resposta, 'respondido_em', r.respondido_em) order by r.respondido_em)
        from public.eventos_respostas r join public.eventos e on e.id = r.evento_id
       where r.usuario_id = v_uid
    ), '[]'::jsonb),
    'enquetes_respondidas', coalesce((
      select jsonb_agg(jsonb_build_object('enquete', e.titulo, 'respondido_em', r.respondido_em, 'comentario', r.comentario) order by r.respondido_em)
        from public.enquete_respostas r join public.enquetes e on e.id = r.enquete_id
       where r.usuario_id = v_uid
    ), '[]'::jsonb),
    'documentos_publicados', coalesce((
      select jsonb_agg(jsonb_build_object('documento', d.titulo, 'versao', v.versao, 'publicado_em', v.publicado_em) order by v.publicado_em)
        from public.documento_versoes v join public.documentos d on d.id = v.documento_id
       where v.publicado_por = v_uid
    ), '[]'::jsonb),
    'notificacoes', coalesce((
      select jsonb_agg(jsonb_build_object('quando', n.criado_em, 'titulo', n.titulo, 'corpo', n.corpo) order by n.criado_em)
        from public.notificacoes n where n.usuario_id = v_uid
    ), '[]'::jsonb),
    'pedidos_sobre_dados', coalesce((
      select jsonb_agg(jsonb_build_object('tipo', t.tipo, 'status', t.status, 'criado_em', t.criado_em, 'resposta', t.resposta) order by t.criado_em)
        from public.solicitacoes_titular t where t.usuario_id = v_uid
    ), '[]'::jsonb),
    'ouvidoria', coalesce((
      select jsonb_agg(jsonb_build_object('protocolo', o.protocolo, 'tipo', o.tipo, 'assunto', o.assunto, 'status', o.status, 'resposta', o.resposta, 'criado_em', o.criado_em) order by o.criado_em)
        from public.ouvidoria o where o.usuario_id = v_uid and o.anonima = false
    ), '[]'::jsonb)
  ) into v_dados;

  perform privado.auditar('exportacao_dados', 'usuarios', v_uid::text, '{}'::jsonb);
  return v_dados;
end;
$$;

-- =====================================================================
-- 6. Verificação
-- =====================================================================
select 'coluna_codigo_carteirinha' as item,
       count(*)::text as resultado
  from information_schema.columns
 where table_schema = 'public' and table_name = 'usuarios' and column_name = 'codigo_carteirinha'
union all
select 'usuarios_sem_codigo', count(*)::text from public.usuarios where codigo_carteirinha is null
union all
select 'tabelas_fase4', count(*)::text
  from information_schema.tables
 where table_schema = 'public'
   and table_name in ('documentos', 'documento_versoes', 'enquetes', 'enquete_opcoes', 'enquete_respostas', 'enquete_escolhas')
union all
select 'funcoes_fase4', count(*)::text
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where (n.nspname = 'public' and p.proname in ('validar_carteirinha', 'renovar_carteirinha', 'criar_documento', 'publicar_versao', 'arquivar_documento', 'criar_enquete', 'responder_enquete', 'encerrar_enquete', 'listar_enquetes', 'detalhe_enquete'))
    or (n.nspname = 'privado' and p.proname in ('pode_publicar_em', 'pode_publicar_documento', 'pode_ver_documento', 'pode_ver_enquete', 'protege_codigo_carteirinha'))
union all
select 'bucket_biblioteca', count(*)::text from storage.buckets where id = 'biblioteca';
