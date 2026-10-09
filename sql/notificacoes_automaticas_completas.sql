-- Notificações automáticas completas: cadastros, solicitações, atendimentos, dados,
-- áreas e funcionários, termos e privacidade.
-- Executar no SQL Editor do Supabase (projeto yutsnhuhimijtzqhpopu). Pode rodar mais de uma vez.
-- Requer: sql/notificacoes_automaticas_manuais.sql (já rodado).
-- Regra de privacidade: o push é sempre genérico. O detalhe fica só dentro do sistema.

-- 1. Função única para criar notificações automáticas.
--    Todo evento novo deve usar privado.notificar(...). Ela respeita a flag de exclusão de conta.
create or replace function privado.notificar(
  p_usuarios uuid[],
  p_titulo text,
  p_corpo text,
  p_conversa uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(current_setting('app.excluindo_conta', true), '') = 'on' then
    return;
  end if;

  insert into public.notificacoes (usuario_id, conversa_id, titulo, corpo, tipo)
  select distinct d.usuario_id, p_conversa, p_titulo, p_corpo, 'automatica'
    from unnest(p_usuarios) as d(usuario_id)
   where d.usuario_id is not null;
end;
$$;

-- Funcionários aprovados de uma área, sem o usuário indicado (quem gerou o evento).
create or replace function privado.staff_da_area(p_area uuid, p_excluir uuid default null)
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(fa.usuario_id), '{}'::uuid[])
    from public.funcionarios_areas fa
    join public.usuarios u on u.id = fa.usuario_id
   where fa.area_id = p_area
     and u.status = 'aprovado'
     and fa.usuario_id is distinct from p_excluir;
$$;

-- Administradores aprovados.
create or replace function privado.administradores()
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(u.id), '{}'::uuid[])
    from public.usuarios u
   where u.tipo_acesso = 'administrador' and u.status = 'aprovado';
$$;

-- 2. Cadastros: novo cadastro (para o solicitante e para os administradores)
create or replace function privado.notifica_novo_cadastro()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'pendente' then
    perform privado.notificar(
      array[new.id],
      'Cadastro recebido',
      'Recebemos o seu cadastro. Avisaremos assim que ele for analisado.'
    );
    perform privado.notificar(
      privado.administradores(),
      'Novo cadastro para aprovar',
      'Há um novo cadastro aguardando análise.'
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notifica_novo_cadastro on public.usuarios;
create trigger trg_notifica_novo_cadastro
  after insert on public.usuarios
  for each row execute function privado.notifica_novo_cadastro();

-- 3. Cadastros e dados: status, tipo de acesso e alteração de dados (pelo próprio usuário ou pela cooperativa)
create or replace function privado.notifica_cadastro()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status is distinct from old.status then
    perform privado.notificar(
      array[new.id],
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
      end
    );
  end if;

  if new.tipo_acesso is distinct from old.tipo_acesso then
    perform privado.notificar(
      array[new.id],
      'Tipo de acesso atualizado',
      'A cooperativa atualizou o seu tipo de acesso.'
    );
  end if;

  if (new.nome_completo, new.telefone, new.email) is distinct from (old.nome_completo, old.telefone, old.email) then
    if auth.uid() = new.id then
      perform privado.notificar(
        array[new.id],
        'Seus dados foram alterados',
        'Você alterou os seus dados cadastrais. Se não foi você, entre em contato com a cooperativa.'
      );
    else
      perform privado.notificar(
        array[new.id],
        'Dados cadastrais atualizados',
        'A cooperativa atualizou os seus dados cadastrais. Confira em Meus dados.'
      );
    end if;
  end if;

  return new;
end;
$$;

-- 4. Solicitações: nova solicitação (para o solicitante e para a área responsável)
create or replace function privado.notifica_nova_solicitacao()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.solicitante_id is not null then
    perform privado.notificar(
      array[new.solicitante_id],
      'Solicitação registrada',
      'Sua solicitação foi registrada e será atendida pela área responsável.',
      new.id
    );
  end if;

  perform privado.notificar(
    privado.staff_da_area(new.area_id, new.solicitante_id),
    'Nova solicitação na sua área',
    'Uma nova solicitação foi registrada na sua área.',
    new.id
  );
  return new;
end;
$$;

drop trigger if exists trg_notifica_nova_solicitacao on public.conversas;
create trigger trg_notifica_nova_solicitacao
  after insert on public.conversas
  for each row execute function privado.notifica_nova_solicitacao();

-- 5. Atendimentos: mudança de status
create or replace function privado.notifica_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform privado.notificar(
    array[new.solicitante_id],
    'Atendimento atualizado',
    'O status do seu atendimento mudou para: ' || case new.status
      when 'aberta' then 'Aberta'
      when 'em_andamento' then 'Em andamento'
      when 'concluida' then 'Concluída'
      when 'cancelada' then 'Cancelada'
      else new.status
    end || '.',
    new.id
  );
  return new;
end;
$$;

-- 6. Atendimentos: novas mensagens
create or replace function privado.notifica_mensagem()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  c record;
  v_mensagens integer;
begin
  select * into c from public.conversas where id = new.conversa_id;
  update public.conversas set atualizado_em = now() where id = c.id;
  if c.solicitante_id is null then
    return new;
  end if;

  if new.autor_id = c.solicitante_id then
    select count(*) into v_mensagens from public.mensagens where conversa_id = c.id;
    -- A primeira mensagem já foi avisada junto com a solicitação; não repete o aviso.
    if v_mensagens > 1 then
      perform privado.notificar(
        privado.staff_da_area(c.area_id, c.solicitante_id),
        'Nova mensagem em atendimento',
        'Uma nova mensagem foi recebida em um atendimento da sua área.',
        c.id
      );
    end if;
  else
    perform privado.notificar(
      array[c.solicitante_id],
      'Você recebeu uma resposta',
      'A equipe respondeu no seu atendimento.',
      c.id
    );
  end if;
  return new;
end;
$$;

-- 7. Áreas e funcionários: vínculo de funcionário a uma área
create or replace function privado.notifica_vinculo_area()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nome text;
begin
  if tg_op = 'INSERT' then
    select nome into v_nome from public.areas where id = new.area_id;
    perform privado.notificar(
      array[new.usuario_id],
      'Nova área de atendimento',
      'Você passou a atender a área ' || coalesce(v_nome, '') || '.'
    );
  else
    select nome into v_nome from public.areas where id = old.area_id;
    perform privado.notificar(
      array[old.usuario_id],
      'Área de atendimento removida',
      'Você deixou de atender a área ' || coalesce(v_nome, '') || '.'
    );
  end if;
  return null;
end;
$$;

drop trigger if exists trg_notifica_vinculo_area on public.funcionarios_areas;
create trigger trg_notifica_vinculo_area
  after insert or delete on public.funcionarios_areas
  for each row execute function privado.notifica_vinculo_area();

-- 8. Áreas: ativação, desativação ou troca de nome avisa os funcionários da área
create or replace function privado.notifica_area_alterada()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform privado.notificar(
    privado.staff_da_area(new.id, null),
    'Área de atendimento atualizada',
    case
      when new.ativa is distinct from old.ativa then
        'A área ' || new.nome || case when new.ativa then ' foi ativada.' else ' foi desativada.' end
      else
        'O nome da área foi alterado para ' || new.nome || '.'
    end
  );
  return null;
end;
$$;

drop trigger if exists trg_notifica_area on public.areas;
create trigger trg_notifica_area
  after update of ativa, nome on public.areas
  for each row
  when (old.ativa is distinct from new.ativa or old.nome is distinct from new.nome)
  execute function privado.notifica_area_alterada();

-- 9. Termos e privacidade: nova versão (já existente; recriada para usar privado.notificar)
create or replace function privado.notifica_nova_versao()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform privado.notificar(
    (select coalesce(array_agg(u.id), '{}'::uuid[]) from public.usuarios u where u.status = 'aprovado'),
    'Nova versão de documento',
    'Há uma nova versão de ' ||
      case when tg_table_name = 'termos_uso' then 'Termos e Condições de Uso' else 'Política de Privacidade' end ||
      '. Leia e aceite para continuar usando o sistema.'
  );
  return new;
end;
$$;

-- Para novos eventos no futuro, basta chamar, dentro de um trigger ou função:
--   perform privado.notificar(array[<usuario>], '<titulo curto>', '<texto sem dados sensíveis>', <conversa ou null>);
-- Exemplo: perform privado.notificar(privado.staff_da_area(<area>), 'Título', 'Texto');
