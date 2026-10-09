-- Notificações push: inscrição de aparelhos e disparo do envio quando uma notificação é criada.
-- Executar no SQL Editor do Supabase (projeto yutsnhuhimijtzqhpopu).
-- ANTES: troque <SEU_PUSH_SECRET> pelo mesmo valor que você configurar em PUSH_SECRET no painel de Edge Functions.

create extension if not exists pg_net with schema extensions;

-- 1. Segredo que protege a chamada do banco para a função de envio (fica só no Vault)
delete from vault.secrets where name = 'push_secret';
select vault.create_secret('<SEU_PUSH_SECRET>', 'push_secret', 'Segredo do gatilho de push');

-- 2. Aparelhos inscritos por usuário
create table if not exists public.push_inscricoes (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references public.usuarios(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  criado_em timestamptz not null default now()
);
alter table public.push_inscricoes enable row level security;
drop policy if exists push_leitura_propria on public.push_inscricoes;
create policy push_leitura_propria on public.push_inscricoes for select to authenticated
  using (usuario_id = auth.uid());
-- A escrita é feita apenas pelas funções abaixo, que usam o usuário logado.

-- 3. Funções para o próprio usuário registrar e remover o aparelho
create or replace function public.registrar_push(p_endpoint text, p_p256dh text, p_auth text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Sessão inválida.';
  end if;
  -- Se o aparelho já estava inscrito para outra conta, a inscrição passa para a conta atual.
  delete from public.push_inscricoes where endpoint = p_endpoint;
  insert into public.push_inscricoes (usuario_id, endpoint, p256dh, auth)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth);
end;
$$;

create or replace function public.remover_push(p_endpoint text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Sessão inválida.';
  end if;
  delete from public.push_inscricoes where endpoint = p_endpoint and usuario_id = auth.uid();
end;
$$;

revoke execute on function public.registrar_push(text, text, text) from public, anon;
grant execute on function public.registrar_push(text, text, text) to authenticated;
revoke execute on function public.remover_push(text) from public, anon;
grant execute on function public.remover_push(text) to authenticated;

-- 4. Gatilho: a cada notificação criada, chama a função de envio com o id da notificação
create or replace function privado.dispara_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_segredo text;
begin
  select decrypted_secret into v_segredo from vault.decrypted_secrets where name = 'push_secret';
  if v_segredo is null then
    return new;
  end if;
  perform net.http_post(
    url := 'https://yutsnhuhimijtzqhpopu.supabase.co/functions/v1/enviar-push',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_segredo),
    body := jsonb_build_object('notificacao_id', new.id)
  );
  return new;
end;
$$;

drop trigger if exists trg_dispara_push on public.notificacoes;
create trigger trg_dispara_push after insert on public.notificacoes
  for each row execute function privado.dispara_push();
