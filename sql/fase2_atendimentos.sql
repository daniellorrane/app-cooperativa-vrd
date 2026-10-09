-- Fase 2: atendimentos (anexos até 2 MB, prazo com alerta de atraso, atribuição manual,
-- avaliação de 0 a 5 estrelas e respostas rápidas).
-- Executar no SQL Editor do Supabase (projeto yutsnhuhimijtzqhpopu). Pode rodar mais de uma vez.
-- Requer: sql/fase1_lgpd_auditoria_ouvidoria.sql (já rodado).

-- =====================================================================
-- 1. PRAZO POR ÁREA
-- =====================================================================
alter table public.areas add column if not exists prazo_horas integer not null default 48;
alter table public.areas drop constraint if exists areas_prazo_horas_check;
alter table public.areas add constraint areas_prazo_horas_check check (prazo_horas between 1 and 2160);

-- =====================================================================
-- 2. CAMPOS NOVOS EM ATENDIMENTOS
-- =====================================================================
alter table public.conversas add column if not exists prazo_em timestamptz;
alter table public.conversas add column if not exists responsavel_id uuid references public.usuarios(id) on delete set null;
alter table public.conversas add column if not exists alerta_atraso_em timestamptz;
alter table public.conversas add column if not exists avaliacao smallint;
alter table public.conversas add column if not exists avaliacao_comentario text;
alter table public.conversas add column if not exists avaliada_em timestamptz;

alter table public.conversas drop constraint if exists conversas_avaliacao_check;
alter table public.conversas add constraint conversas_avaliacao_check check (avaliacao is null or avaliacao between 0 and 5);
alter table public.conversas drop constraint if exists conversas_avaliacao_comentario_check;
alter table public.conversas add constraint conversas_avaliacao_comentario_check
  check (avaliacao_comentario is null or length(avaliacao_comentario) <= 280);

update public.conversas c
   set prazo_em = c.criado_em + make_interval(hours => a.prazo_horas)
  from public.areas a
 where a.id = c.area_id and c.prazo_em is null;

-- Prazo calculado pelo servidor, a partir da área, no momento da criação
create or replace function privado.define_prazo()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.prazo_em is null then
    select now() + make_interval(hours => a.prazo_horas) into new.prazo_em
      from public.areas a where a.id = new.area_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_define_prazo on public.conversas;
create trigger trg_define_prazo
  before insert on public.conversas
  for each row execute function privado.define_prazo();

-- Proteção: campos de controle só mudam pelas funções desta fase (ou pelo sistema).
-- O status continua podendo ser alterado pela equipe, como antes.
create or replace function privado.protege_conversa()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if coalesce(current_setting('app.excluindo_conta', true), '') = 'on'
     or coalesce(current_setting('app.sistema', true), '') = 'on' then
    return new;
  end if;
  new.solicitante_id := old.solicitante_id;
  new.area_id := old.area_id;
  new.assunto := old.assunto;
  new.tipo := old.tipo;
  new.prazo_em := old.prazo_em;
  new.responsavel_id := old.responsavel_id;
  new.alerta_atraso_em := old.alerta_atraso_em;
  new.avaliacao := old.avaliacao;
  new.avaliacao_comentario := old.avaliacao_comentario;
  new.avaliada_em := old.avaliada_em;
  return new;
end;
$$;

-- =====================================================================
-- 3. EQUIPE DA ÁREA (para escolher o responsável; funcionário vê só a equipe da própria área)
-- =====================================================================
create or replace function public.equipe_da_area(p_area uuid)
returns table (usuario_id uuid, nome text)
language sql
stable
security definer
set search_path = public
as $$
  select u.id, u.nome_completo
    from public.usuarios u
    join public.funcionarios_areas fa on fa.usuario_id = u.id
   where fa.area_id = p_area
     and u.status = 'aprovado'
     and (privado.e_funcionario_da_area(p_area) or privado.funcao_admin())
   order by u.nome_completo;
$$;

revoke execute on function public.equipe_da_area(uuid) from public, anon;
grant execute on function public.equipe_da_area(uuid) to authenticated;

-- =====================================================================
-- 4. ATRIBUIÇÃO MANUAL (sem responsável o atendimento fica pendente)
-- =====================================================================
create or replace function public.atribuir_atendimento(p_conversa uuid, p_responsavel uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c record;
begin
  select * into c from public.conversas where id = p_conversa;
  if not found then
    raise exception 'Atendimento não encontrado.';
  end if;

  if privado.funcao_admin() then
    null;
  elsif privado.e_funcionario_da_area(c.area_id) and (p_responsavel = auth.uid() or p_responsavel is null) then
    null;
  else
    raise exception 'Você não pode alterar o responsável deste atendimento.';
  end if;

  if p_responsavel is not null and not exists (
    select 1 from public.funcionarios_areas fa
      join public.usuarios u on u.id = fa.usuario_id
     where fa.usuario_id = p_responsavel and fa.area_id = c.area_id and u.status = 'aprovado'
  ) then
    raise exception 'O responsável precisa ser um funcionário aprovado da área.';
  end if;

  perform set_config('app.sistema', 'on', true);
  update public.conversas set responsavel_id = p_responsavel where id = p_conversa;

  if p_responsavel is not null and p_responsavel is distinct from c.responsavel_id then
    perform privado.notificar(array[p_responsavel],
      'Atendimento atribuído a você',
      'Um atendimento da sua área foi atribuído a você.',
      p_conversa);
  end if;

  perform privado.auditar('atendimento_atribuido', 'conversas', p_conversa::text,
    jsonb_build_object('responsavel_antes', c.responsavel_id, 'responsavel_depois', p_responsavel));
end;
$$;

revoke execute on function public.atribuir_atendimento(uuid, uuid) from public, anon;
grant execute on function public.atribuir_atendimento(uuid, uuid) to authenticated;

-- =====================================================================
-- 5. AVALIAÇÃO DO ATENDIMENTO (0 a 5 estrelas, comentário curto, uma vez)
-- =====================================================================
create or replace function public.avaliar_atendimento(p_conversa uuid, p_nota integer, p_comentario text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c record;
  v_comentario text := nullif(trim(coalesce(p_comentario, '')), '');
begin
  select * into c from public.conversas where id = p_conversa;
  if not found or c.solicitante_id is distinct from auth.uid() then
    raise exception 'Atendimento não encontrado.';
  end if;
  if c.status <> 'concluida' then
    raise exception 'Você poderá avaliar quando o atendimento for concluído.';
  end if;
  if c.avaliacao is not null then
    raise exception 'Este atendimento já foi avaliado.';
  end if;
  if p_nota is null or p_nota < 0 or p_nota > 5 then
    raise exception 'A nota deve ser de 0 a 5 estrelas.';
  end if;
  if v_comentario is not null and length(v_comentario) > 280 then
    raise exception 'O comentário pode ter até 280 caracteres.';
  end if;

  perform set_config('app.sistema', 'on', true);
  update public.conversas
     set avaliacao = p_nota, avaliacao_comentario = v_comentario, avaliada_em = now()
   where id = p_conversa;

  perform privado.notificar(privado.staff_da_area(c.area_id, null),
    'Atendimento avaliado',
    'Um atendimento da sua área recebeu uma avaliação.',
    p_conversa);
  perform privado.auditar('atendimento_avaliado', 'conversas', p_conversa::text,
    jsonb_build_object('nota', p_nota));
end;
$$;

revoke execute on function public.avaliar_atendimento(uuid, integer, text) from public, anon;
grant execute on function public.avaliar_atendimento(uuid, integer, text) to authenticated;

-- =====================================================================
-- 6. ALERTA DE ATRASO (executado a cada 15 minutos pelo pg_cron)
-- =====================================================================
create or replace function privado.verifica_atrasos()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  c record;
  v_total integer := 0;
begin
  perform set_config('app.sistema', 'on', true);
  for c in
    select id, area_id, responsavel_id from public.conversas
     where status in ('aberta', 'em_andamento')
       and prazo_em < now()
       and alerta_atraso_em is null
  loop
    update public.conversas set alerta_atraso_em = now() where id = c.id;
    perform privado.notificar(
      case when c.responsavel_id is not null then array[c.responsavel_id]
           else privado.staff_da_area(c.area_id, null) end,
      'Atendimento com prazo vencido',
      'Um atendimento da sua área passou do prazo de resposta.',
      c.id);
    perform privado.notificar(privado.administradores(),
      'Atendimento com prazo vencido',
      'Um atendimento passou do prazo de resposta.',
      c.id);
    perform privado.auditar('atraso_alertado', 'conversas', c.id::text, '{}'::jsonb);
    v_total := v_total + 1;
  end loop;
  return v_total;
end;
$$;

do $$
begin
  create extension if not exists pg_cron with schema pg_catalog;
exception when others then
  raise notice 'pg_cron não habilitado: %', sqlerrm;
end;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('alerta-atrasos', '*/15 * * * *', 'select privado.verifica_atrasos()');
    perform cron.schedule('limpeza-anexos', '30 3 * * *', 'select privado.limpa_anexos_orfaos()');
  end if;
end;
$$;

-- =====================================================================
-- 7. RESPOSTAS RÁPIDAS (por área; a equipe da área cria e usa)
-- =====================================================================
create table if not exists public.respostas_rapidas (
  id uuid primary key default gen_random_uuid(),
  area_id uuid not null references public.areas(id) on delete cascade,
  titulo text not null check (length(trim(titulo)) between 3 and 80),
  texto text not null check (length(trim(texto)) between 3 and 1000),
  criado_por uuid references public.usuarios(id) on delete set null,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

alter table public.respostas_rapidas enable row level security;
revoke all on public.respostas_rapidas from anon, authenticated;
grant select, insert, update, delete on public.respostas_rapidas to authenticated;
drop policy if exists respostas_ler on public.respostas_rapidas;
create policy respostas_ler on public.respostas_rapidas
  for select to authenticated
  using (privado.e_funcionario_da_area(area_id) or privado.funcao_admin());
drop policy if exists respostas_escrever on public.respostas_rapidas;
create policy respostas_escrever on public.respostas_rapidas
  for all to authenticated
  using (privado.e_funcionario_da_area(area_id) or privado.funcao_admin())
  with check (privado.e_funcionario_da_area(area_id) or privado.funcao_admin());

-- =====================================================================
-- 8. ANEXOS (até 2 MB; PDF, JPG, PNG ou WEBP; bucket privado)
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('anexos', 'anexos', false, 2097152, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = false,
      file_size_limit = 2097152,
      allowed_mime_types = excluded.allowed_mime_types;

create table if not exists public.anexos (
  id uuid primary key default gen_random_uuid(),
  mensagem_id uuid not null references public.mensagens(id) on delete cascade,
  conversa_id uuid not null references public.conversas(id) on delete cascade,
  nome_arquivo text not null check (length(trim(nome_arquivo)) between 1 and 200),
  tipo_mime text not null check (tipo_mime in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp')),
  tamanho integer not null check (tamanho > 0 and tamanho <= 2097152),
  caminho text not null unique,
  enviado_por uuid references public.usuarios(id) on delete set null,
  criado_em timestamptz not null default now()
);

alter table public.anexos enable row level security;
revoke all on public.anexos from anon, authenticated;
grant select, insert, delete on public.anexos to authenticated;
drop policy if exists anexos_ler on public.anexos;
create policy anexos_ler on public.anexos
  for select to authenticated
  using (privado.participa_conversa(conversa_id));
drop policy if exists anexos_enviar on public.anexos;
create policy anexos_enviar on public.anexos
  for insert to authenticated
  with check (
    enviado_por = auth.uid()
    and privado.participa_conversa(conversa_id)
    and exists (
      select 1 from public.mensagens m
       where m.id = mensagem_id and m.autor_id = auth.uid() and m.conversa_id = conversa_id
    )
  );
drop policy if exists anexos_admin_apagar on public.anexos;
create policy anexos_admin_apagar on public.anexos
  for delete to authenticated
  using (privado.funcao_admin());

-- Arquivos: pasta = id do atendimento. Só quem participa do atendimento lê ou envia.
drop policy if exists anexos_storage_enviar on storage.objects;
create policy anexos_storage_enviar on storage.objects
  for insert to authenticated
  with check (
    case when bucket_id = 'anexos'
      then privado.participa_conversa(((storage.foldername(name))[1])::uuid)
      else false
    end
  );

drop policy if exists anexos_storage_ler on storage.objects;
create policy anexos_storage_ler on storage.objects
  for select to authenticated
  using (
    case when bucket_id = 'anexos'
      then privado.participa_conversa(((storage.foldername(name))[1])::uuid)
      else false
    end
  );

drop policy if exists anexos_storage_apagar on storage.objects;
create policy anexos_storage_apagar on storage.objects
  for delete to authenticated
  using (bucket_id = 'anexos' and privado.funcao_admin());

-- Remove arquivos sem registro (de atendimentos apagados). Roda todo dia pelo pg_cron.
create or replace function privado.limpa_anexos_orfaos()
returns integer
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  v_total integer := 0;
begin
  perform set_config('storage.allow_delete_query', 'true', true);
  delete from storage.objects o
   where o.bucket_id = 'anexos'
     and o.created_at < now() - interval '1 day'
     and not exists (select 1 from public.anexos a where a.caminho = o.name);
  get diagnostics v_total = row_count;
  return v_total;
end;
$$;

-- =====================================================================
-- 9. EXPORTAÇÃO: inclui os anexos enviados pelo titular (nome e data)
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
-- 10. Verificação
-- =====================================================================
select 'colunas_conversas' as item, count(*)::text as resultado
  from information_schema.columns
 where table_schema = 'public' and table_name = 'conversas'
   and column_name in ('prazo_em', 'responsavel_id', 'alerta_atraso_em', 'avaliacao', 'avaliacao_comentario', 'avaliada_em')
union all
select 'bucket_anexos', count(*)::text from storage.buckets where id = 'anexos'
union all
select 'pg_cron', case when exists (select 1 from pg_extension where extname = 'pg_cron') then 'instalado' else 'não instalado' end;
