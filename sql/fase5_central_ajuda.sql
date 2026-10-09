-- Fase 5: central de ajuda (FAQ). Artigos gerais e por área, com resposta "isso resolveu?".
-- Executar no SQL Editor do Supabase (projeto yutsnhuhimijtzqhpopu). Pode rodar mais de uma vez.
-- Requer: sql/fase4_carteirinha_biblioteca_enquetes.sql (já rodado).
--
-- Regras:
--   Artigo geral publicado: todos os cooperados e funcionários aprovados veem.
--   Artigo de área publicado: funcionários da área e administradores veem.
--   Rascunho (não publicado): só quem publica (administradores e funcionários da área) vê.
--   Quem publica: administradores (geral ou qualquer área) e funcionários (somente das suas áreas).

-- =====================================================================
-- 1. TABELAS
-- =====================================================================
create table if not exists public.faq_artigos (
  id uuid primary key default gen_random_uuid(),
  pergunta text not null check (length(trim(pergunta)) between 5 and 200),
  resposta text not null check (length(trim(resposta)) between 10 and 4000),
  categoria text check (categoria is null or length(trim(categoria)) between 1 and 60),
  area_id uuid references public.areas(id) on delete cascade,
  publicado boolean not null default false,
  ordem smallint not null default 0 check (ordem between 0 and 999),
  criado_por uuid references public.usuarios(id) on delete set null,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index if not exists faq_artigos_publicado_idx on public.faq_artigos (publicado, ordem);

create table if not exists public.faq_avaliacoes (
  artigo_id uuid not null references public.faq_artigos(id) on delete cascade,
  usuario_id uuid not null references public.usuarios(id) on delete cascade,
  util boolean not null,
  criado_em timestamptz not null default now(),
  primary key (artigo_id, usuario_id)
);

-- =====================================================================
-- 2. REGRAS DE ACESSO
-- =====================================================================
create or replace function privado.pode_ver_artigo(p_artigo uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.faq_artigos a
     where a.id = p_artigo
       and (
         privado.pode_publicar_em(a.area_id)
         or (a.publicado and (
              (a.area_id is null and exists (
                 select 1 from public.usuarios u where u.id = auth.uid() and u.status = 'aprovado'))
              or (a.area_id is not null and privado.e_funcionario_da_area(a.area_id))
            ))
       )
  );
$$;

alter table public.faq_artigos enable row level security;
alter table public.faq_avaliacoes enable row level security;
revoke all on public.faq_artigos from anon, authenticated;
revoke all on public.faq_avaliacoes from anon, authenticated;
grant select on public.faq_artigos to authenticated;
grant select on public.faq_avaliacoes to authenticated;

drop policy if exists faq_artigos_ler on public.faq_artigos;
create policy faq_artigos_ler on public.faq_artigos
  for select to authenticated
  using (privado.pode_ver_artigo(id));

-- Cada pessoa vê só a própria avaliação. Os totais saem da função estatisticas_faq().
drop policy if exists faq_avaliacoes_proprias on public.faq_avaliacoes;
create policy faq_avaliacoes_proprias on public.faq_avaliacoes
  for select to authenticated
  using (usuario_id = auth.uid());

-- =====================================================================
-- 3. FUNÇÕES
-- =====================================================================
create or replace function public.salvar_artigo_faq(
  p_id uuid,
  p_pergunta text,
  p_resposta text,
  p_categoria text,
  p_area uuid,
  p_publicado boolean,
  p_ordem integer
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  a record;
  v_pergunta text := trim(coalesce(p_pergunta, ''));
  v_resposta text := trim(coalesce(p_resposta, ''));
  v_categoria text := nullif(trim(coalesce(p_categoria, '')), '');
begin
  if not privado.pode_publicar_em(p_area) then
    raise exception 'Você não pode publicar artigos para esta área.';
  end if;
  if length(v_pergunta) < 5 or length(v_pergunta) > 200 then
    raise exception 'A pergunta precisa ter de 5 a 200 caracteres.';
  end if;
  if length(v_resposta) < 10 or length(v_resposta) > 4000 then
    raise exception 'A resposta precisa ter de 10 a 4000 caracteres.';
  end if;
  if v_categoria is not null and length(v_categoria) > 60 then
    raise exception 'A categoria pode ter até 60 caracteres.';
  end if;
  if p_ordem is null or p_ordem < 0 or p_ordem > 999 then
    raise exception 'A ordem deve estar entre 0 e 999.';
  end if;

  if p_id is null then
    insert into public.faq_artigos
      (pergunta, resposta, categoria, area_id, publicado, ordem, criado_por)
    values
      (v_pergunta, v_resposta, v_categoria, p_area, coalesce(p_publicado, false), p_ordem, auth.uid())
    returning id into v_id;
    perform privado.auditar('faq_criado', 'faq_artigos', v_id::text, jsonb_build_object('area_id', p_area));
  else
    select * into a from public.faq_artigos where id = p_id;
    if not found or not privado.pode_publicar_em(a.area_id) then
      raise exception 'Artigo não encontrado.';
    end if;
    update public.faq_artigos
       set pergunta = v_pergunta,
           resposta = v_resposta,
           categoria = v_categoria,
           area_id = p_area,
           publicado = coalesce(p_publicado, false),
           ordem = p_ordem,
           atualizado_em = now()
     where id = p_id;
    v_id := p_id;
    perform privado.auditar('faq_atualizado', 'faq_artigos', v_id::text,
      jsonb_build_object('publicado', coalesce(p_publicado, false)));
  end if;

  return v_id;
end;
$$;

revoke execute on function public.salvar_artigo_faq(uuid, text, text, text, uuid, boolean, integer) from public, anon;
grant execute on function public.salvar_artigo_faq(uuid, text, text, text, uuid, boolean, integer) to authenticated;

create or replace function public.excluir_artigo_faq(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  a record;
begin
  select * into a from public.faq_artigos where id = p_id;
  if not found or not privado.pode_publicar_em(a.area_id) then
    raise exception 'Artigo não encontrado.';
  end if;
  delete from public.faq_artigos where id = p_id;
  perform privado.auditar('faq_excluido', 'faq_artigos', p_id::text, '{}'::jsonb);
end;
$$;

revoke execute on function public.excluir_artigo_faq(uuid) from public, anon;
grant execute on function public.excluir_artigo_faq(uuid) to authenticated;

create or replace function public.avaliar_artigo_faq(p_artigo uuid, p_util boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not privado.pode_ver_artigo(p_artigo) then
    raise exception 'Artigo não encontrado.';
  end if;
  insert into public.faq_avaliacoes (artigo_id, usuario_id, util, criado_em)
  values (p_artigo, auth.uid(), coalesce(p_util, false), now())
  on conflict (artigo_id, usuario_id)
  do update set util = excluded.util, criado_em = excluded.criado_em;
end;
$$;

revoke execute on function public.avaliar_artigo_faq(uuid, boolean) from public, anon;
grant execute on function public.avaliar_artigo_faq(uuid, boolean) to authenticated;

-- Totais de utilidade, só para quem pode publicar o artigo.
create or replace function public.estatisticas_faq()
returns table (artigo uuid, util_sim bigint, util_nao bigint)
language sql
stable
security definer
set search_path = public
as $$
  select f.artigo_id,
         count(*) filter (where f.util),
         count(*) filter (where not f.util)
    from public.faq_avaliacoes f
    join public.faq_artigos a on a.id = f.artigo_id
   where privado.pode_publicar_em(a.area_id)
   group by f.artigo_id;
$$;

revoke execute on function public.estatisticas_faq() from public, anon;
grant execute on function public.estatisticas_faq() to authenticated;

-- =====================================================================
-- 4. CONTEÚDO INICIAL (somente se a central estiver vazia)
--    Descreve o que o próprio sistema faz. Revise e ajuste à realidade da cooperativa.
-- =====================================================================
insert into public.faq_artigos (pergunta, resposta, categoria, area_id, publicado, ordem)
select v.pergunta, v.resposta, v.categoria, null, true, v.ordem
  from (values
    (10, 'Como faço meu cadastro?', 'Escolha o tipo de acesso na tela de primeiro acesso, preencha seus dados e aceite os termos e a política de privacidade. Seu cadastro passa por aprovação. Você recebe um aviso quando for aprovado.', 'Primeiros passos'),
    (20, 'Como altero meu nome ou celular?', 'Entre em Meus dados, altere o nome ou o celular e salve. CPF, e-mail e tipo de acesso são controlados pela cooperativa.', 'Conta'),
    (30, 'Como acompanho uma solicitação?', 'Em Atendimentos você vê todas as suas solicitações. Você recebe um aviso quando a equipe responder. Pode enviar anexos de até 2 MB, em PDF, JPG, PNG ou WEBP.', 'Atendimentos'),
    (40, 'Como avalio um atendimento?', 'Quando a equipe concluir o atendimento, você verá a opção de avaliar de 0 a 5 estrelas. O comentário é opcional e pode ter até 280 caracteres.', 'Atendimentos'),
    (50, 'Como funciona a carteirinha digital?', 'Em Conta, Carteirinha digital, você vê seu cartão com o QR code. Quem ler o código confirma se o seu acesso está ativo, sem ver seus dados pessoais. Se perder o acesso ao QR code, use Gerar novo código.', 'Conta'),
    (60, 'Como excluo minha conta?', 'Em Meus dados, escolha manter o histórico de forma anônima ou apagar tudo, informe sua senha e digite EXCLUIR. Essa ação não pode ser desfeita.', 'Privacidade')
  ) as v(ordem, pergunta, resposta, categoria)
 where not exists (select 1 from public.faq_artigos);

-- =====================================================================
-- 5. EXPORTAÇÃO (LGPD): inclui as avaliações de utilidade que a pessoa deu
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
    'ajuda_avaliacoes', coalesce((
      select jsonb_agg(jsonb_build_object('artigo', a.pergunta, 'resolveu', f.util, 'avaliado_em', f.criado_em) order by f.criado_em)
        from public.faq_avaliacoes f join public.faq_artigos a on a.id = f.artigo_id
       where f.usuario_id = v_uid
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
select 'tabelas_ajuda' as item, count(*)::text as resultado
  from information_schema.tables
 where table_schema = 'public' and table_name in ('faq_artigos', 'faq_avaliacoes')
union all
select 'funcoes_ajuda', count(*)::text
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where (n.nspname = 'public' and p.proname in ('salvar_artigo_faq', 'excluir_artigo_faq', 'avaliar_artigo_faq', 'estatisticas_faq'))
    or (n.nspname = 'privado' and p.proname = 'pode_ver_artigo')
union all
select 'artigos_publicados', count(*)::text from public.faq_artigos where publicado
union all
select 'artigos_total', count(*)::text from public.faq_artigos;
