-- Notificações automáticas (eventos do sistema) e manuais (avisos enviados por funcionários e administradores).
-- Executar no SQL Editor do Supabase (projeto yutsnhuhimijtzqhpopu). Pode rodar mais de uma vez.
-- Regra de privacidade: o aviso push é sempre genérico. O detalhe fica só dentro do sistema.

-- 1. Colunas nas notificações
alter table public.notificacoes add column if not exists tipo text not null default 'automatica';
alter table public.notificacoes drop constraint if exists notificacoes_tipo_check;
alter table public.notificacoes add constraint notificacoes_tipo_check check (tipo in ('automatica', 'manual'));
alter table public.notificacoes add column if not exists corpo text;

-- 2. Avisos manuais (histórico de envio)
create table if not exists public.comunicados (
  id uuid primary key default gen_random_uuid(),
  titulo text not null check (length(trim(titulo)) >= 3),
  corpo text not null check (length(trim(corpo)) >= 3),
  destinatarios text not null,
  total integer not null default 0,
  criado_por uuid not null references public.usuarios(id),
  criado_em timestamptz not null default now()
);
alter table public.comunicados enable row level security;
drop policy if exists comunicados_leitura on public.comunicados;
create policy comunicados_leitura on public.comunicados for select to authenticated
  using (criado_por = auth.uid() or privado.funcao_admin());

alter table public.notificacoes add column if not exists comunicado_id uuid references public.comunicados(id) on delete cascade;

-- 3. Quem pode enviar avisos: funcionário ou administrador aprovado
create or replace function privado.pode_comunicar()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.usuarios
     where id = auth.uid() and status = 'aprovado' and tipo_acesso in ('funcionario', 'administrador')
  );
$$;

create or replace function public.enviar_comunicado(p_titulo text, p_corpo text, p_destinatarios text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_total integer;
  v_titulo text := trim(p_titulo);
  v_corpo text := trim(p_corpo);
begin
  if not privado.pode_comunicar() then
    raise exception 'Apenas funcionários e administradores podem enviar avisos.';
  end if;
  if length(v_titulo) < 3 or length(v_corpo) < 3 then
    raise exception 'Preencha o título e a mensagem do aviso.';
  end if;
  if p_destinatarios not in ('todos', 'cooperado', 'cliente', 'funcionario', 'fornecedor', 'prestador_servico') then
    raise exception 'Destinatário inválido.';
  end if;

  insert into public.comunicados (titulo, corpo, destinatarios, criado_por)
  values (v_titulo, v_corpo, p_destinatarios, auth.uid())
  returning id into v_id;

  insert into public.notificacoes (usuario_id, titulo, corpo, tipo, comunicado_id)
  select u.id, v_titulo, v_corpo, 'manual', v_id
    from public.usuarios u
   where u.status = 'aprovado'
     and (p_destinatarios = 'todos' or u.tipo_acesso = p_destinatarios);
  get diagnostics v_total = row_count;

  update public.comunicados set total = v_total where id = v_id;
  return v_total;
end;
$$;

revoke execute on function public.enviar_comunicado(text, text, text) from public, anon;
grant execute on function public.enviar_comunicado(text, text, text) to authenticated;

-- 4. Automáticas: mudanças no cadastro
create or replace function privado.notifica_cadastro()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(current_setting('app.excluindo_conta', true), '') = 'on' then
    return new;
  end if;

  if new.status is distinct from old.status then
    insert into public.notificacoes (usuario_id, titulo, corpo, tipo)
    values (
      new.id,
      case new.status
        when 'aprovado' then 'Cadastro aprovado'
        when 'recusado' then 'Cadastro não aprovado'
        when 'bloqueado' then 'Acesso suspenso'
        else 'Cadastro atualizado'
      end,
      case new.status
        when 'aprovado' then 'Seu cadastro foi aprovado. Você já pode usar o sistema.'
        when 'recusado' then 'Seu cadastro não foi aprovado. Entre em contato com a cooperativa para mais informações.'
        when 'bloqueado' then 'Seu acesso está suspenso. Entre em contato com a cooperativa.'
        else 'Seu cadastro foi atualizado.'
      end,
      'automatica'
    );
  end if;

  if new.tipo_acesso is distinct from old.tipo_acesso then
    insert into public.notificacoes (usuario_id, titulo, corpo, tipo)
    values (new.id, 'Tipo de acesso atualizado', 'A cooperativa atualizou o seu tipo de acesso.', 'automatica');
  end if;

  if (new.nome_completo, new.telefone, new.email) is distinct from (old.nome_completo, old.telefone, old.email)
     and auth.uid() is distinct from new.id then
    insert into public.notificacoes (usuario_id, titulo, corpo, tipo)
    values (new.id, 'Dados cadastrais atualizados', 'A cooperativa atualizou os seus dados cadastrais. Confira em Meus dados.', 'automatica');
  end if;

  return new;
end;
$$;

drop trigger if exists trg_notifica_cadastro on public.usuarios;
create trigger trg_notifica_cadastro after update on public.usuarios
  for each row execute function privado.notifica_cadastro();

-- 5. Automáticas: status do atendimento
create or replace function privado.notifica_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.solicitante_id is not null then
    insert into public.notificacoes (usuario_id, conversa_id, titulo, corpo, tipo)
    values (
      new.solicitante_id,
      new.id,
      'Atendimento atualizado',
      'O status do seu atendimento mudou para: ' || case new.status
        when 'aberta' then 'Aberta'
        when 'em_andamento' then 'Em andamento'
        when 'concluida' then 'Concluída'
        when 'cancelada' then 'Cancelada'
        else new.status
      end || '.',
      'automatica'
    );
  end if;
  return new;
end;
$$;

-- 6. Automáticas: novas mensagens
create or replace function privado.notifica_mensagem()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  c record;
begin
  select * into c from public.conversas where id = new.conversa_id;
  update public.conversas set atualizado_em = now() where id = c.id;
  if c.solicitante_id is null then
    return new;
  end if;

  if new.autor_id = c.solicitante_id then
    insert into public.notificacoes (usuario_id, conversa_id, titulo, corpo, tipo)
    select fa.usuario_id, c.id, 'Novo atendimento na sua área',
           'Uma nova mensagem foi recebida em um atendimento da sua área.', 'automatica'
      from public.funcionarios_areas fa
     where fa.area_id = c.area_id and fa.usuario_id <> new.autor_id;
  else
    insert into public.notificacoes (usuario_id, conversa_id, titulo, corpo, tipo)
    values (c.solicitante_id, c.id, 'Você recebeu uma resposta',
            'A equipe respondeu no seu atendimento.', 'automatica');
  end if;
  return new;
end;
$$;

-- 7. Automáticas: nova versão de termos ou política (avisa todos os usuários aprovados)
create or replace function privado.notifica_nova_versao()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.notificacoes (usuario_id, titulo, corpo, tipo)
  select u.id,
         'Nova versão de documento',
         'Há uma nova versão de ' ||
           case when tg_table_name = 'termos_uso' then 'Termos e Condições de Uso' else 'Política de Privacidade' end ||
           '. Leia e aceite para continuar usando o sistema.',
         'automatica'
    from public.usuarios u
   where u.status = 'aprovado';
  return new;
end;
$$;

drop trigger if exists trg_nova_versao_termos on public.termos_uso;
create trigger trg_nova_versao_termos after insert on public.termos_uso
  for each row execute function privado.notifica_nova_versao();
drop trigger if exists trg_nova_versao_privacidade on public.politicas_privacidade;
create trigger trg_nova_versao_privacidade after insert on public.politicas_privacidade
  for each row execute function privado.notifica_nova_versao();

-- 8. Proteção: o usuário só marca como lida; título, texto, tipo e origem não mudam
create or replace function privado.protege_notificacao()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.usuario_id := old.usuario_id;
  new.conversa_id := old.conversa_id;
  new.titulo := old.titulo;
  new.corpo := old.corpo;
  new.tipo := old.tipo;
  new.comunicado_id := old.comunicado_id;
  return new;
end;
$$;
