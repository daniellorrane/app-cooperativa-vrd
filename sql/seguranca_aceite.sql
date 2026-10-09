-- Aceite de documentos gravado pelo banco (data e versão não podem ser forjadas pelo navegador).
-- Executar no SQL Editor do Supabase (projeto yutsnhuhimijtzqhpopu) depois de sql/seguranca_hardening.sql.
-- Pode rodar mais de uma vez.

-- 1. Protege os campos de aceite: só a função abaixo pode alterá-los (ou o administrador).
create or replace function public.protege_campos_sensiveis()
returns trigger
language plpgsql
set search_path = public
as $function$
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
    if coalesce(current_setting('app.aceitando_documentos', true), '') <> 'on' then
      new.termo_aceito_em := old.termo_aceito_em;
      new.termo_versao := old.termo_versao;
      new.privacidade_aceita_em := old.privacidade_aceita_em;
      new.privacidade_versao := old.privacidade_versao;
    end if;
  end if;
  new.atualizado_em := now();
  return new;
end;
$function$;

-- 2. No cadastro, a data do aceite é sempre a do servidor.
create or replace function privado.carimba_aceite()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.termo_aceito_em is not null then
    new.termo_aceito_em := now();
  end if;
  if new.privacidade_aceita_em is not null then
    new.privacidade_aceita_em := now();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_carimba_aceite on public.usuarios;
create trigger trg_carimba_aceite
  before insert on public.usuarios
  for each row execute function privado.carimba_aceite();

-- 3. Função de aceite: confere a versão vigente e grava a data pelo servidor.
create or replace function public.aceitar_documentos(p_termo_versao text default null, p_privacidade_versao text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Sessão inválida.';
  end if;
  if p_termo_versao is null and p_privacidade_versao is null then
    raise exception 'Nenhum documento informado.';
  end if;
  if p_termo_versao is not null and p_termo_versao is distinct from
     (select versao from public.termos_uso order by publicado_em desc limit 1) then
    raise exception 'A versão dos Termos mudou. Recarregue a página.';
  end if;
  if p_privacidade_versao is not null and p_privacidade_versao is distinct from
     (select versao from public.politicas_privacidade order by publicado_em desc limit 1) then
    raise exception 'A versão da Política de Privacidade mudou. Recarregue a página.';
  end if;

  perform set_config('app.aceitando_documentos', 'on', true);
  update public.usuarios set
    termo_versao = coalesce(p_termo_versao, termo_versao),
    termo_aceito_em = case when p_termo_versao is not null then now() else termo_aceito_em end,
    privacidade_versao = coalesce(p_privacidade_versao, privacidade_versao),
    privacidade_aceita_em = case when p_privacidade_versao is not null then now() else privacidade_aceita_em end
  where id = auth.uid();
end;
$$;

revoke execute on function public.aceitar_documentos(text, text) from public, anon;
grant execute on function public.aceitar_documentos(text, text) to authenticated;
