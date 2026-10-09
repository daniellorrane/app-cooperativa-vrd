-- Termos de uso, aceite global, exclusão de conta (apagar ou manter histórico anônimo)
-- Executar no SQL Editor do Supabase (projeto yutsnhuhimijtzqhpopu). Idempotente, pode rodar mais de uma vez.

-- 1. Termos e condições (versionados, legíveis publicamente)
create table if not exists public.termos_uso (
  versao text primary key,
  texto text not null,
  publicado_em timestamptz not null default now()
);
alter table public.termos_uso enable row level security;
drop policy if exists termos_leitura on public.termos_uso;
create policy termos_leitura on public.termos_uso for select to anon, authenticated using (true);

insert into public.termos_uso (versao, texto) values ('1.0', $t$TERMOS E CONDIÇÕES DE USO
Versão 1.0

1. Objeto
Estes termos regulam o uso do sistema de acesso da Cooperativa Agropecuária Vale do Rio Doce (Cooperativa), disponível pelo navegador e como aplicativo instalável, com recursos como notificações, conversas com as áreas da Cooperativa e solicitações de serviços e documentos.

2. Cadastro e responsabilidade
Você deve informar dados verdadeiros e manter sua senha em sigilo. Você é responsável pelas ações realizadas com a sua conta. O acesso depende de aprovação e pode ser recusado ou suspenso pela Cooperativa.

3. Uso adequado
O sistema deve ser usado apenas para assuntos relacionados à sua relação com a Cooperativa. É proibido publicar conteúdo ofensivo, falso ou discriminatório, violar direitos de terceiros e tentar acessar dados de outras pessoas.

4. Atendimento e áreas
As conversas são direcionadas às áreas da Cooperativa. Os funcionários acessam somente os atendimentos da área à qual estão vinculados. A Cooperativa pode registrar status, prazos e respostas para organizar o atendimento.

5. Dados pessoais e LGPD
Os dados são tratados de acordo com a Lei Geral de Proteção de Dados (Lei 13.709/2018), para cadastro, comunicação e atendimento. Coletamos apenas os dados necessários. As notificações não trazem o conteúdo das mensagens. O acesso aos dados é restrito conforme a função de cada pessoa.

6. Seus direitos
Você pode consultar e corrigir seus dados em Meus dados, solicitar informações sobre o tratamento dos seus dados e solicitar a exclusão da sua conta pela opção Excluir minha conta.

7. Exclusão da conta
Você pode excluir sua conta a qualquer momento, escolhendo uma das opções:
(a) apagar tudo: removem-se seus dados e o histórico de conversas e solicitações;
(b) manter o histórico de forma anônima: sua identidade é removida e o registro passa a servir apenas para estatísticas, sem permitir identificar você.
A exclusão é definitiva e não pode ser desfeita.

8. Registro do aceite
O aceite destes termos é registrado com a versão aceita e a data e hora do aceite.

9. Alterações
Estes termos podem ser atualizados. Quando houver nova versão, será solicitado novo aceite para continuar usando o sistema.

10. Foro
Fica eleito o foro da Comarca de Governador Valadares, MG, para dirimir questões decorrentes destes termos.$t$)
on conflict (versao) do nothing;

-- 2. Aceite dos termos no cadastro
alter table public.usuarios add column if not exists termo_versao text references public.termos_uso(versao);

-- 3. Histórico anonimizável: perfil do solicitante guardado como estatística
alter table public.conversas add column if not exists perfil_solicitante text;
update public.conversas c set perfil_solicitante = u.tipo_acesso
  from public.usuarios u
 where u.id = c.solicitante_id and c.perfil_solicitante is null;

alter table public.conversas alter column solicitante_id drop not null;
alter table public.mensagens alter column autor_id drop not null;

create or replace function privado.registra_perfil_solicitante()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.perfil_solicitante is null and new.solicitante_id is not null then
    new.perfil_solicitante := (select u.tipo_acesso from public.usuarios u where u.id = new.solicitante_id);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_registra_perfil on public.conversas;
create trigger trg_registra_perfil before insert on public.conversas
  for each row execute function privado.registra_perfil_solicitante();

-- 4. Triggers com guarda para histórico anonimizado e bypass controlado durante a exclusão
create or replace function privado.notifica_mensagem()
returns trigger language plpgsql security definer set search_path = public
as $$
declare c record;
begin
  select * into c from public.conversas where id = new.conversa_id;
  update public.conversas set atualizado_em = now() where id = c.id;
  if c.solicitante_id is null then
    return new;
  end if;
  if new.autor_id = c.solicitante_id then
    insert into public.notificacoes (usuario_id, conversa_id, titulo)
    select fa.usuario_id, c.id, 'Nova mensagem na sua área'
    from public.funcionarios_areas fa
    where fa.area_id = c.area_id and fa.usuario_id <> new.autor_id;
  else
    insert into public.notificacoes (usuario_id, conversa_id, titulo)
    values (c.solicitante_id, c.id, 'Você recebeu uma resposta');
  end if;
  return new;
end;
$$;

create or replace function privado.notifica_status()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.solicitante_id is not null then
    insert into public.notificacoes (usuario_id, conversa_id, titulo)
    values (new.solicitante_id, new.id, 'Sua solicitação foi atualizada');
  end if;
  return new;
end;
$$;

create or replace function privado.protege_conversa()
returns trigger language plpgsql set search_path = public
as $$
begin
  if coalesce(current_setting('app.excluindo_conta', true), '') = 'on' then
    return new;
  end if;
  new.solicitante_id := old.solicitante_id;
  new.area_id := old.area_id;
  new.assunto := old.assunto;
  new.tipo := old.tipo;
  return new;
end;
$$;

create or replace function public.protege_campos_sensiveis()
returns trigger language plpgsql set search_path = public
as $$
begin
  if coalesce(current_setting('app.excluindo_conta', true), '') = 'on' then
    return new;
  end if;
  if not privado.funcao_admin() then
    new.status := old.status;
    new.tipo_acesso := old.tipo_acesso;
    new.aprovado_por := old.aprovado_por;
    new.aprovado_em := old.aprovado_em;
    new.motivo_recusa := old.motivo_recusa;
  end if;
  new.atualizado_em := now();
  return new;
end;
$$;

-- 5. Políticas: cadastro e criação de conversa exigem o termo vigente
drop policy if exists usuario_cria_proprio_cadastro on public.usuarios;
create policy usuario_cria_proprio_cadastro on public.usuarios for insert to authenticated
  with check (
    id = auth.uid()
    and status = 'pendente'
    and termo_aceito_em is not null
    and termo_versao = (select versao from public.termos_uso order by publicado_em desc limit 1)
  );

drop policy if exists conversas_criar on public.conversas;
create policy conversas_criar on public.conversas for insert to authenticated
  with check (
    solicitante_id = auth.uid()
    and exists (
      select 1 from public.usuarios u
       where u.id = auth.uid()
         and u.status = 'aprovado'
         and u.termo_aceito_em is not null
         and u.termo_versao = (select versao from public.termos_uso order by publicado_em desc limit 1)
    )
  );

-- 6. Exclusão de conta pelo próprio usuário
create or replace function public.excluir_minha_conta(p_modo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Sessão inválida.';
  end if;
  if p_modo not in ('apagar', 'anonimizar') then
    raise exception 'Modo de exclusão inválido.';
  end if;

  perform set_config('app.excluindo_conta', 'on', true);

  if p_modo = 'anonimizar' then
    update public.conversas c
       set perfil_solicitante = coalesce(c.perfil_solicitante, u.tipo_acesso),
           solicitante_id = null
      from public.usuarios u
     where c.solicitante_id = v_uid and u.id = v_uid;
    update public.mensagens set autor_id = null where autor_id = v_uid;
    delete from public.notificacoes where usuario_id = v_uid;
  end if;

  update public.usuarios set aprovado_por = null where aprovado_por = v_uid;
  -- Cascata: funcionarios_areas; no modo apagar também conversas, mensagens e notificações
  delete from public.usuarios where id = v_uid;
  delete from auth.users where id = v_uid;
end;
$$;

revoke execute on function public.excluir_minha_conta(text) from public, anon;
grant execute on function public.excluir_minha_conta(text) to authenticated;
