-- Fase 1: LGPD (direitos do titular, histórico de aceites, exportação, incidentes, encarregado),
-- auditoria em pontos-chave e ouvidoria.
-- Executar no SQL Editor do Supabase (projeto yutsnhuhimijtzqhpopu). Pode rodar mais de uma vez.
-- Requer: sql/seguranca_hardening.sql e sql/seguranca_aceite.sql (já rodados).

-- =====================================================================
-- 1. AUDITORIA
-- Registra quem fez, quando e o que mudou, sem guardar dados pessoais no detalhe.
-- =====================================================================
create table if not exists public.auditoria (
  id bigint generated always as identity primary key,
  criado_em timestamptz not null default now(),
  ator_id uuid,
  acao text not null,
  entidade text not null,
  entidade_id text,
  detalhes jsonb not null default '{}'::jsonb
);

alter table public.auditoria enable row level security;
revoke all on public.auditoria from anon, authenticated;
grant select on public.auditoria to authenticated;
drop policy if exists auditoria_admin on public.auditoria;
create policy auditoria_admin on public.auditoria
  for select to authenticated
  using (privado.funcao_admin());

create or replace function privado.auditar(p_acao text, p_entidade text, p_entidade_id text, p_detalhes jsonb default '{}'::jsonb)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.auditoria (ator_id, acao, entidade, entidade_id, detalhes)
  values (auth.uid(), p_acao, p_entidade, p_entidade_id, coalesce(p_detalhes, '{}'::jsonb));
$$;

-- Cadastros: alteração de status ou tipo, e exclusão
create or replace function privado.audita_usuario()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    perform privado.auditar('usuario_excluido', 'usuarios', old.id::text,
      jsonb_build_object('tipo_acesso', old.tipo_acesso, 'status', old.status));
    return null;
  end if;
  if new.status is distinct from old.status or new.tipo_acesso is distinct from old.tipo_acesso then
    perform privado.auditar('usuario_alterado', 'usuarios', new.id::text,
      jsonb_build_object(
        'status_antes', old.status, 'status_depois', new.status,
        'tipo_antes', old.tipo_acesso, 'tipo_depois', new.tipo_acesso
      ));
  end if;
  return null;
end;
$$;

drop trigger if exists trg_audita_usuario on public.usuarios;
create trigger trg_audita_usuario
  after update or delete on public.usuarios
  for each row execute function privado.audita_usuario();

-- Áreas: criação, exclusão, ativação e troca de nome
create or replace function privado.audita_area()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    perform privado.auditar('area_criada', 'areas', new.id::text, jsonb_build_object('nome', new.nome));
  elsif tg_op = 'DELETE' then
    perform privado.auditar('area_excluida', 'areas', old.id::text, jsonb_build_object('nome', old.nome));
  elsif new.ativa is distinct from old.ativa or new.nome is distinct from old.nome then
    perform privado.auditar('area_alterada', 'areas', new.id::text,
      jsonb_build_object('ativa_antes', old.ativa, 'ativa_depois', new.ativa, 'nome_depois', new.nome));
  end if;
  return null;
end;
$$;

drop trigger if exists trg_audita_area on public.areas;
create trigger trg_audita_area
  after insert or update or delete on public.areas
  for each row execute function privado.audita_area();

-- Vínculo de funcionário a área
create or replace function privado.audita_vinculo()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    perform privado.auditar('vinculo_criado', 'funcionarios_areas', new.usuario_id::text || ':' || new.area_id::text,
      jsonb_build_object('area_id', new.area_id));
  else
    perform privado.auditar('vinculo_removido', 'funcionarios_areas', old.usuario_id::text || ':' || old.area_id::text,
      jsonb_build_object('area_id', old.area_id));
  end if;
  return null;
end;
$$;

drop trigger if exists trg_audita_vinculo on public.funcionarios_areas;
create trigger trg_audita_vinculo
  after insert or delete on public.funcionarios_areas
  for each row execute function privado.audita_vinculo();

-- Publicação de termos e política (versões são imutáveis)
create or replace function privado.audita_publicacao()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform privado.auditar('versao_publicada', tg_table_name, new.versao, '{}'::jsonb);
  return null;
end;
$$;

drop trigger if exists trg_audita_publicacao_termos on public.termos_uso;
create trigger trg_audita_publicacao_termos
  after insert on public.termos_uso
  for each row execute function privado.audita_publicacao();

drop trigger if exists trg_audita_publicacao_privacidade on public.politicas_privacidade;
create trigger trg_audita_publicacao_privacidade
  after insert on public.politicas_privacidade
  for each row execute function privado.audita_publicacao();

-- Avisos enviados à comunidade (sem o texto)
create or replace function privado.audita_comunicado()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform privado.auditar('aviso_enviado', 'comunicados', new.id::text,
    jsonb_build_object('destinatarios', new.destinatarios));
  return null;
end;
$$;

drop trigger if exists trg_audita_comunicado on public.comunicados;
create trigger trg_audita_comunicado
  after insert on public.comunicados
  for each row execute function privado.audita_comunicado();

-- Status do atendimento (sem o conteúdo)
create or replace function privado.audita_atendimento()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform privado.auditar('status_atendimento_alterado', 'conversas', new.id::text,
    jsonb_build_object('status_antes', old.status, 'status_depois', new.status));
  return null;
end;
$$;

drop trigger if exists trg_audita_atendimento on public.conversas;
create trigger trg_audita_atendimento
  after update of status on public.conversas
  for each row
  when (old.status is distinct from new.status)
  execute function privado.audita_atendimento();

-- Mensagem apagada por administrador (sem o texto)
create or replace function privado.audita_mensagem_apagada()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform privado.auditar('mensagem_apagada', 'mensagens', old.id::text,
    jsonb_build_object('conversa_id', old.conversa_id));
  return null;
end;
$$;

drop trigger if exists trg_audita_mensagem_apagada on public.mensagens;
create trigger trg_audita_mensagem_apagada
  after delete on public.mensagens
  for each row execute function privado.audita_mensagem_apagada();

-- =====================================================================
-- 2. HISTÓRICO DE ACEITES (prova do consentimento, uma linha por aceite)
-- =====================================================================
create table if not exists public.aceites (
  id bigint generated always as identity primary key,
  usuario_id uuid not null references public.usuarios(id) on delete cascade,
  documento text not null check (documento in ('termos', 'privacidade')),
  versao text not null,
  aceito_em timestamptz not null
);

alter table public.aceites enable row level security;
revoke all on public.aceites from anon, authenticated;
grant select on public.aceites to authenticated;
drop policy if exists aceites_leitura on public.aceites;
create policy aceites_leitura on public.aceites
  for select to authenticated
  using (usuario_id = auth.uid() or privado.funcao_admin());

create or replace function privado.registra_aceites()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.termo_aceito_em is not null then
      insert into public.aceites (usuario_id, documento, versao, aceito_em)
      values (new.id, 'termos', new.termo_versao, new.termo_aceito_em);
    end if;
    if new.privacidade_aceita_em is not null then
      insert into public.aceites (usuario_id, documento, versao, aceito_em)
      values (new.id, 'privacidade', new.privacidade_versao, new.privacidade_aceita_em);
    end if;
  else
    if new.termo_aceito_em is not null and new.termo_aceito_em is distinct from old.termo_aceito_em then
      insert into public.aceites (usuario_id, documento, versao, aceito_em)
      values (new.id, 'termos', new.termo_versao, new.termo_aceito_em);
    end if;
    if new.privacidade_aceita_em is not null and new.privacidade_aceita_em is distinct from old.privacidade_aceita_em then
      insert into public.aceites (usuario_id, documento, versao, aceito_em)
      values (new.id, 'privacidade', new.privacidade_versao, new.privacidade_aceita_em);
    end if;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_registra_aceites on public.usuarios;
create trigger trg_registra_aceites
  after insert or update of termo_aceito_em, privacidade_aceita_em on public.usuarios
  for each row execute function privado.registra_aceites();

-- Preenche o histórico com os aceites que já existem (executa uma vez, sem duplicar)
insert into public.aceites (usuario_id, documento, versao, aceito_em)
select u.id, 'termos', u.termo_versao, u.termo_aceito_em
  from public.usuarios u
 where u.termo_aceito_em is not null
   and not exists (select 1 from public.aceites a where a.usuario_id = u.id and a.documento = 'termos' and a.aceito_em = u.termo_aceito_em);

insert into public.aceites (usuario_id, documento, versao, aceito_em)
select u.id, 'privacidade', u.privacidade_versao, u.privacidade_aceita_em
  from public.usuarios u
 where u.privacidade_aceita_em is not null
   and not exists (select 1 from public.aceites a where a.usuario_id = u.id and a.documento = 'privacidade' and a.aceito_em = u.privacidade_aceita_em);

-- =====================================================================
-- 3. CONFIGURAÇÕES (encarregado de dados, visível a todos, alterado só por administradores)
-- =====================================================================
create table if not exists public.configuracoes (
  chave text primary key,
  valor text,
  atualizado_em timestamptz not null default now(),
  atualizado_por uuid references public.usuarios(id) on delete set null
);

insert into public.configuracoes (chave, valor)
values ('dpo_nome', null), ('dpo_email', null)
on conflict (chave) do nothing;

alter table public.configuracoes enable row level security;
revoke all on public.configuracoes from anon, authenticated;
grant select, insert, update on public.configuracoes to authenticated;
grant select on public.configuracoes to anon;
drop policy if exists configuracoes_leitura on public.configuracoes;
create policy configuracoes_leitura on public.configuracoes
  for select to anon, authenticated
  using (true);
drop policy if exists configuracoes_admin on public.configuracoes;
create policy configuracoes_admin on public.configuracoes
  for all to authenticated
  using (privado.funcao_admin())
  with check (privado.funcao_admin());

create or replace function privado.carimba_configuracao()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.atualizado_em := now();
  new.atualizado_por := auth.uid();
  perform privado.auditar('configuracao_alterada', 'configuracoes', new.chave, '{}'::jsonb);
  return new;
end;
$$;

drop trigger if exists trg_carimba_configuracao on public.configuracoes;
create trigger trg_carimba_configuracao
  before update on public.configuracoes
  for each row execute function privado.carimba_configuracao();

-- =====================================================================
-- 4. PEDIDOS DO TITULAR (art. 18 da LGPD), com prazo de 15 dias
-- =====================================================================
create table if not exists public.solicitacoes_titular (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references public.usuarios(id) on delete cascade,
  tipo text not null check (tipo in ('confirmacao', 'acesso', 'correcao', 'anonimizacao', 'eliminacao', 'portabilidade', 'informacao', 'revogacao')),
  descricao text check (descricao is null or length(descricao) <= 500),
  status text not null default 'recebida' check (status in ('recebida', 'em_analise', 'atendida', 'negada')),
  prazo timestamptz not null default now() + interval '15 days',
  resposta text check (resposta is null or length(resposta) <= 1000),
  respondido_por uuid references public.usuarios(id) on delete set null,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

alter table public.solicitacoes_titular enable row level security;
revoke all on public.solicitacoes_titular from anon, authenticated;
grant select, insert, update on public.solicitacoes_titular to authenticated;
drop policy if exists titular_criar on public.solicitacoes_titular;
create policy titular_criar on public.solicitacoes_titular
  for insert to authenticated
  with check (usuario_id = auth.uid() and status = 'recebida');
drop policy if exists titular_ler on public.solicitacoes_titular;
create policy titular_ler on public.solicitacoes_titular
  for select to authenticated
  using (usuario_id = auth.uid() or privado.funcao_admin());
drop policy if exists titular_responder on public.solicitacoes_titular;
create policy titular_responder on public.solicitacoes_titular
  for update to authenticated
  using (privado.funcao_admin())
  with check (privado.funcao_admin());

create or replace function privado.trata_solicitacao_titular()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rotulo text;
begin
  if tg_op = 'INSERT' then
    perform privado.notificar(array[new.usuario_id],
      'Pedido recebido',
      'Recebemos o seu pedido sobre os seus dados. Responderemos em até 15 dias, como prevê a LGPD. Acompanhe em Privacidade e dados.');
    perform privado.notificar(privado.administradores(),
      'Novo pedido sobre dados pessoais',
      'Há um novo pedido de titular de dados para atender em até 15 dias.');
    perform privado.auditar('pedido_titular_recebido', 'solicitacoes_titular', new.id::text,
      jsonb_build_object('tipo', new.tipo));
  else
    new.atualizado_em := now();
    if new.status is distinct from old.status then
      v_rotulo := case new.status
        when 'em_analise' then 'está em análise'
        when 'atendida' then 'foi atendido'
        when 'negada' then 'não pôde ser atendido. Veja a resposta'
        else 'foi atualizado'
      end;
      perform privado.notificar(array[new.usuario_id],
        'Atualização do seu pedido',
        'O seu pedido sobre os seus dados ' || v_rotulo || '.');
      perform privado.auditar('pedido_titular_' || new.status, 'solicitacoes_titular', new.id::text, '{}'::jsonb);
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_trata_solicitacao_titular on public.solicitacoes_titular;
drop trigger if exists trg_trata_solicitacao_titular_insert on public.solicitacoes_titular;
drop trigger if exists trg_trata_solicitacao_titular_update on public.solicitacoes_titular;
create trigger trg_trata_solicitacao_titular_insert
  after insert on public.solicitacoes_titular
  for each row execute function privado.trata_solicitacao_titular();
create trigger trg_trata_solicitacao_titular_update
  before update on public.solicitacoes_titular
  for each row execute function privado.trata_solicitacao_titular();

-- =====================================================================
-- 5. EXPORTAÇÃO DOS PRÓPRIOS DADOS (portabilidade e acesso, em JSON)
-- Inclui só dados do próprio titular. Mensagens de funcionários aparecem como "Equipe", sem nome.
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
        'mensagens', coalesce((
          select jsonb_agg(jsonb_build_object(
            'quando', m.criado_em,
            'autor', case when m.autor_id = v_uid then 'Você' else 'Equipe' end,
            'texto', m.texto
          ) order by m.criado_em)
          from public.mensagens m where m.conversa_id = c.id
        ), '[]'::jsonb)
      ) order by c.criado_em)
        from public.conversas c where c.solicitante_id = v_uid
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

revoke execute on function public.exportar_meus_dados() from public, anon;
grant execute on function public.exportar_meus_dados() to authenticated;

-- =====================================================================
-- 6. OUVIDORIA (reclamações, denúncias, sugestões e elogios)
-- Anônima: a identidade não é guardada. O protocolo permite acompanhar a resposta.
-- =====================================================================
create table if not exists public.ouvidoria (
  id uuid primary key default gen_random_uuid(),
  protocolo text not null unique default ('OUV-' || to_char(now(), 'YYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6))),
  usuario_id uuid references public.usuarios(id) on delete set null,
  tipo text not null check (tipo in ('reclamacao', 'denuncia', 'sugestao', 'elogio')),
  assunto text not null check (length(trim(assunto)) between 3 and 150),
  descricao text not null check (length(trim(descricao)) between 10 and 3000),
  anonima boolean not null default false,
  status text not null default 'recebida' check (status in ('recebida', 'em_analise', 'respondida', 'encerrada')),
  resposta text check (resposta is null or length(resposta) <= 3000),
  prazo timestamptz not null default now() + interval '30 days',
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint ouvidoria_anonima_sem_identidade check (not anonima or usuario_id is null)
);

alter table public.ouvidoria enable row level security;
revoke all on public.ouvidoria from anon, authenticated;
grant select, insert, update on public.ouvidoria to authenticated;
drop policy if exists ouvidoria_criar on public.ouvidoria;
create policy ouvidoria_criar on public.ouvidoria
  for insert to authenticated
  with check (
    (anonima = true and usuario_id is null)
    or (anonima = false and usuario_id = auth.uid())
  );
drop policy if exists ouvidoria_ler on public.ouvidoria;
create policy ouvidoria_ler on public.ouvidoria
  for select to authenticated
  using (usuario_id = auth.uid() or privado.funcao_admin());
drop policy if exists ouvidoria_responder on public.ouvidoria;
create policy ouvidoria_responder on public.ouvidoria
  for update to authenticated
  using (privado.funcao_admin())
  with check (privado.funcao_admin());

create or replace function privado.trata_ouvidoria()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    perform privado.notificar(privado.administradores(),
      'Nova manifestação na ouvidoria',
      'Há uma nova manifestação registrada na ouvidoria.');
    perform privado.auditar('ouvidoria_recebida', 'ouvidoria', new.protocolo,
      jsonb_build_object('tipo', new.tipo, 'anonima', new.anonima));
  else
    new.atualizado_em := now();
    if new.status is distinct from old.status or new.resposta is distinct from old.resposta then
      if new.usuario_id is not null then
        perform privado.notificar(array[new.usuario_id],
          'Atualização na ouvidoria',
          'Há uma atualização na sua manifestação. Acompanhe pelo protocolo em Ouvidoria.');
      end if;
      perform privado.auditar('ouvidoria_respondida', 'ouvidoria', new.protocolo,
        jsonb_build_object('status_depois', new.status));
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_trata_ouvidoria on public.ouvidoria;
drop trigger if exists trg_trata_ouvidoria_insert on public.ouvidoria;
drop trigger if exists trg_trata_ouvidoria_update on public.ouvidoria;
create trigger trg_trata_ouvidoria_insert
  after insert on public.ouvidoria
  for each row execute function privado.trata_ouvidoria();
create trigger trg_trata_ouvidoria_update
  before update on public.ouvidoria
  for each row execute function privado.trata_ouvidoria();

-- Acompanhamento pelo protocolo (também para quem registrou de forma anônima)
create or replace function public.consultar_ouvidoria(p_protocolo text)
returns table (protocolo text, status text, resposta text, prazo timestamptz, atualizado_em timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select o.protocolo, o.status, o.resposta, o.prazo, o.atualizado_em
    from public.ouvidoria o
   where o.protocolo = upper(trim(p_protocolo));
$$;

revoke execute on function public.consultar_ouvidoria(text) from public, anon;
grant execute on function public.consultar_ouvidoria(text) to authenticated;

-- =====================================================================
-- 7. INCIDENTES DE SEGURANÇA (art. 48 da LGPD). Somente administradores.
-- =====================================================================
create table if not exists public.incidentes_seguranca (
  id uuid primary key default gen_random_uuid(),
  descricao text not null check (length(trim(descricao)) >= 10),
  dados_afetados text,
  ocorrido_em timestamptz not null,
  detectado_em timestamptz not null default now(),
  comunicado_anpd_em timestamptz,
  comunicado_titulares_em timestamptz,
  medidas text,
  criado_por uuid references public.usuarios(id) on delete set null
);

alter table public.incidentes_seguranca enable row level security;
revoke all on public.incidentes_seguranca from anon, authenticated;
grant select, insert, update on public.incidentes_seguranca to authenticated;
drop policy if exists incidentes_admin on public.incidentes_seguranca;
create policy incidentes_admin on public.incidentes_seguranca
  for all to authenticated
  using (privado.funcao_admin())
  with check (privado.funcao_admin());

create or replace function privado.audita_incidente()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.criado_por := auth.uid();
    perform privado.auditar('incidente_registrado', 'incidentes_seguranca', new.id::text, '{}'::jsonb);
  else
    perform privado.auditar('incidente_atualizado', 'incidentes_seguranca', new.id::text, '{}'::jsonb);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_audita_incidente on public.incidentes_seguranca;
create trigger trg_audita_incidente
  before insert or update on public.incidentes_seguranca
  for each row execute function privado.audita_incidente();

-- =====================================================================
-- 8. Verificação
-- =====================================================================
select 'tabelas' as item, count(*)::text as resultado
  from information_schema.tables
 where table_schema = 'public'
   and table_name in ('auditoria', 'aceites', 'configuracoes', 'solicitacoes_titular', 'ouvidoria', 'incidentes_seguranca')
union all
select 'aceites_historicos', count(*)::text from public.aceites;
