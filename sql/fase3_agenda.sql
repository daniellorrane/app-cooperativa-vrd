-- Fase 3: agenda (eventos), confirmação de presença, confirmação de leitura e lembretes.
-- Executar no SQL Editor do Supabase (projeto yutsnhuhimijtzqhpopu). Pode rodar mais de uma vez.
-- Requer: sql/fase2_atendimentos.sql (já rodado).
--
-- Regras de visibilidade:
--   Evento geral (sem área): todos os cooperados e funcionários aprovados veem.
--   Evento de área: somente os funcionários daquela área e administradores veem.
--   Quem cria: administradores (geral ou de qualquer área) e funcionários (somente das suas áreas).
--   Respostas de presença e leitura: quem vê o evento responde. Quem criou o evento e administradores veem quem respondeu.

-- =====================================================================
-- 1. TABELAS
-- =====================================================================
create table if not exists public.eventos (
  id uuid primary key default gen_random_uuid(),
  titulo text not null check (length(trim(titulo)) between 3 and 120),
  descricao text check (descricao is null or length(descricao) <= 2000),
  local_evento text check (local_evento is null or length(local_evento) <= 160),
  inicio timestamptz not null,
  fim timestamptz,
  area_id uuid references public.areas(id) on delete cascade,
  exige_presenca boolean not null default false,
  exige_leitura boolean not null default false,
  criado_por uuid references public.usuarios(id) on delete set null,
  criado_em timestamptz not null default now(),
  lembrete_enviado_em timestamptz,
  constraint eventos_fim_check check (fim is null or fim > inicio)
);
create index if not exists eventos_inicio_idx on public.eventos (inicio);

create table if not exists public.eventos_respostas (
  evento_id uuid not null references public.eventos(id) on delete cascade,
  usuario_id uuid not null references public.usuarios(id) on delete cascade,
  tipo text not null check (tipo in ('presenca', 'leitura')),
  resposta text not null,
  respondido_em timestamptz not null default now(),
  primary key (evento_id, usuario_id, tipo),
  constraint eventos_respostas_valor_check check (
    (tipo = 'presenca' and resposta in ('confirmada', 'nao_vai'))
    or (tipo = 'leitura' and resposta = 'lida')
  )
);

alter table public.eventos enable row level security;
alter table public.eventos_respostas enable row level security;
revoke all on public.eventos from anon, authenticated;
revoke all on public.eventos_respostas from anon, authenticated;
-- Escrita só pelas funções abaixo (controle de regra no banco).
grant select on public.eventos to authenticated;
grant select on public.eventos_respostas to authenticated;

-- =====================================================================
-- 2. REGRAS DE ACESSO
-- =====================================================================
create or replace function privado.pode_ver_evento(p_evento uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.eventos e
     where e.id = p_evento
       and (
         privado.funcao_admin()
         or (e.area_id is null and exists (
               select 1 from public.usuarios u where u.id = auth.uid() and u.status = 'aprovado'))
         or (e.area_id is not null and privado.e_funcionario_da_area(e.area_id))
       )
  );
$$;

-- Público de um evento: todos os aprovados (geral) ou os funcionários da área.
create or replace function privado.publico_do_evento(p_area uuid)
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(u.id), '{}'::uuid[])
    from public.usuarios u
   where u.status = 'aprovado'
     and (
       p_area is null
       or exists (select 1 from public.funcionarios_areas fa
                   where fa.usuario_id = u.id and fa.area_id = p_area)
     );
$$;

drop policy if exists eventos_ler on public.eventos;
create policy eventos_ler on public.eventos
  for select to authenticated
  using (privado.pode_ver_evento(id));

drop policy if exists eventos_respostas_ler on public.eventos_respostas;
create policy eventos_respostas_ler on public.eventos_respostas
  for select to authenticated
  using (usuario_id = auth.uid() or privado.funcao_admin());

-- =====================================================================
-- 3. CRIAR, EXCLUIR E RESPONDER
-- =====================================================================
create or replace function public.criar_evento(
  p_titulo text,
  p_descricao text,
  p_local text,
  p_inicio timestamptz,
  p_fim timestamptz,
  p_area uuid,
  p_exige_presenca boolean,
  p_exige_leitura boolean
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
  v_local text := nullif(trim(coalesce(p_local, '')), '');
begin
  if not (privado.funcao_admin() or (p_area is not null and privado.e_funcionario_da_area(p_area))) then
    raise exception 'Você não pode criar eventos para esta área.';
  end if;
  if length(v_titulo) < 3 or length(v_titulo) > 120 then
    raise exception 'O título precisa ter de 3 a 120 caracteres.';
  end if;
  if p_inicio is null then
    raise exception 'Informe a data e hora de início.';
  end if;
  if p_fim is not null and p_fim <= p_inicio then
    raise exception 'O término deve ser depois do início.';
  end if;
  if v_descricao is not null and length(v_descricao) > 2000 then
    raise exception 'A descrição pode ter até 2000 caracteres.';
  end if;
  if v_local is not null and length(v_local) > 160 then
    raise exception 'O local pode ter até 160 caracteres.';
  end if;

  insert into public.eventos
    (titulo, descricao, local_evento, inicio, fim, area_id, exige_presenca, exige_leitura, criado_por)
  values
    (v_titulo, v_descricao, v_local, p_inicio, p_fim, p_area,
     coalesce(p_exige_presenca, false), coalesce(p_exige_leitura, false), auth.uid())
  returning id into v_id;

  -- Aviso genérico: o título e os detalhes ficam só dentro do sistema.
  perform privado.notificar(
    privado.publico_do_evento(p_area),
    'Novo evento na agenda',
    'Há um novo evento na agenda. Abra o sistema para ver os detalhes.',
    null);

  perform privado.auditar('evento_criado', 'eventos', v_id::text,
    jsonb_build_object('area_id', p_area, 'inicio', p_inicio));
  return v_id;
end;
$$;

revoke execute on function public.criar_evento(text, text, text, timestamptz, timestamptz, uuid, boolean, boolean) from public, anon;
grant execute on function public.criar_evento(text, text, text, timestamptz, timestamptz, uuid, boolean, boolean) to authenticated;

create or replace function public.excluir_evento(p_evento uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  e record;
begin
  select * into e from public.eventos where id = p_evento;
  if not found then
    raise exception 'Evento não encontrado.';
  end if;
  if not (privado.funcao_admin() or e.criado_por = auth.uid()) then
    raise exception 'Você não pode excluir este evento.';
  end if;

  delete from public.eventos where id = p_evento;
  perform privado.auditar('evento_excluido', 'eventos', p_evento::text, '{}'::jsonb);
end;
$$;

revoke execute on function public.excluir_evento(uuid) from public, anon;
grant execute on function public.excluir_evento(uuid) to authenticated;

create or replace function public.responder_evento(p_evento uuid, p_tipo text, p_resposta text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  e record;
begin
  select * into e from public.eventos where id = p_evento;
  if not found or not privado.pode_ver_evento(p_evento) then
    raise exception 'Evento não encontrado.';
  end if;

  if p_tipo = 'presenca' then
    if not e.exige_presenca then
      raise exception 'Este evento não pede confirmação de presença.';
    end if;
    if p_resposta not in ('confirmada', 'nao_vai') then
      raise exception 'Resposta inválida.';
    end if;
  elsif p_tipo = 'leitura' then
    if not e.exige_leitura then
      raise exception 'Este evento não pede confirmação de leitura.';
    end if;
    if p_resposta <> 'lida' then
      raise exception 'Resposta inválida.';
    end if;
  else
    raise exception 'Tipo de resposta inválido.';
  end if;

  insert into public.eventos_respostas (evento_id, usuario_id, tipo, resposta, respondido_em)
  values (p_evento, auth.uid(), p_tipo, p_resposta, now())
  on conflict (evento_id, usuario_id, tipo)
  do update set resposta = excluded.resposta, respondido_em = excluded.respondido_em;

  perform privado.auditar('evento_respondido', 'eventos', p_evento::text,
    jsonb_build_object('tipo', p_tipo, 'resposta', p_resposta));
end;
$$;

revoke execute on function public.responder_evento(uuid, text, text) from public, anon;
grant execute on function public.responder_evento(uuid, text, text) to authenticated;

-- Quem respondeu (somente quem criou o evento e administradores).
create or replace function public.respostas_do_evento(p_evento uuid)
returns table (usuario uuid, nome text, presenca text, leitura text, ultima_resposta timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.eventos e
     where e.id = p_evento and (privado.funcao_admin() or e.criado_por = auth.uid())
  ) then
    raise exception 'Você não pode ver as respostas deste evento.';
  end if;

  return query
  select u.id,
         u.nome_completo,
         (select r.resposta from public.eventos_respostas r
           where r.evento_id = e.id and r.usuario_id = u.id and r.tipo = 'presenca'),
         (select r.resposta from public.eventos_respostas r
           where r.evento_id = e.id and r.usuario_id = u.id and r.tipo = 'leitura'),
         (select max(r.respondido_em) from public.eventos_respostas r
           where r.evento_id = e.id and r.usuario_id = u.id)
    from public.eventos e
    join public.usuarios u on u.status = 'aprovado'
   where e.id = p_evento
     and (e.area_id is null or exists (
            select 1 from public.funcionarios_areas fa
             where fa.usuario_id = u.id and fa.area_id = e.area_id))
   order by u.nome_completo;
end;
$$;

revoke execute on function public.respostas_do_evento(uuid) from public, anon;
grant execute on function public.respostas_do_evento(uuid) to authenticated;

-- =====================================================================
-- 4. LEMBRETES AUTOMÁTICOS (pg_cron a cada 15 minutos)
--    Avisa, até 24 horas antes, quem ainda não confirmou presença ou leitura.
-- =====================================================================
create or replace function privado.lembretes_eventos()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  e record;
  v_pendentes uuid[];
  v_total integer := 0;
begin
  perform set_config('app.sistema', 'on', true);

  for e in
    select * from public.eventos
     where lembrete_enviado_em is null
       and (exige_presenca or exige_leitura)
       and inicio > now()
       and inicio <= now() + interval '24 hours'
  loop
    select coalesce(array_agg(x.usuario), '{}'::uuid[]) into v_pendentes
      from (
        select u.id as usuario
          from public.usuarios u
         where u.status = 'aprovado'
           and (e.area_id is null or exists (
                 select 1 from public.funcionarios_areas fa
                  where fa.usuario_id = u.id and fa.area_id = e.area_id))
           and (
             (e.exige_presenca and not exists (
                select 1 from public.eventos_respostas r
                 where r.evento_id = e.id and r.usuario_id = u.id and r.tipo = 'presenca'))
             or (e.exige_leitura and not exists (
                select 1 from public.eventos_respostas r
                 where r.evento_id = e.id and r.usuario_id = u.id and r.tipo = 'leitura'))
           )
      ) x;

    perform privado.notificar(v_pendentes,
      'Confirmação pendente',
      'Você tem uma confirmação pendente na agenda.',
      null);

    update public.eventos set lembrete_enviado_em = now() where id = e.id;
    v_total := v_total + 1;
  end loop;

  return v_total;
end;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('lembretes-eventos', '*/15 * * * *', 'select privado.lembretes_eventos()');
  end if;
end;
$$;

-- =====================================================================
-- 5. EXPORTAÇÃO (LGPD): inclui eventos criados e confirmações do titular
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
select 'tabela_eventos' as item, count(*)::text as resultado
  from information_schema.tables where table_schema = 'public' and table_name = 'eventos'
union all
select 'tabela_eventos_respostas', count(*)::text
  from information_schema.tables where table_schema = 'public' and table_name = 'eventos_respostas'
union all
select 'funcoes_agenda', count(*)::text
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where (n.nspname = 'public' and p.proname in ('criar_evento', 'excluir_evento', 'responder_evento', 'respostas_do_evento'))
    or (n.nspname = 'privado' and p.proname in ('pode_ver_evento', 'publico_do_evento', 'lembretes_eventos'))
union all
select 'pg_cron', case when exists (select 1 from pg_extension where extname = 'pg_cron') then 'instalado' else 'não instalado' end;
