-- Exclusão de cadastro pelo administrador (pendente, aprovado, recusado ou inativo).
-- Remove o cadastro, as conversas e mensagens dele e o acesso de login.
-- Não permite excluir a própria conta nem outro administrador.
-- Executar no SQL Editor do Supabase (projeto yutsnhuhimijtzqhpopu). Pode rodar mais de uma vez.

create or replace function public.excluir_usuario(p_usuario uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tipo text;
begin
  if not privado.funcao_admin() then
    raise exception 'Apenas administradores podem excluir cadastros.';
  end if;
  if p_usuario = auth.uid() then
    raise exception 'Você não pode excluir a sua própria conta por aqui.';
  end if;

  select tipo_acesso into v_tipo from public.usuarios where id = p_usuario;
  if v_tipo is null then
    raise exception 'Cadastro não encontrado.';
  end if;
  if v_tipo = 'administrador' then
    raise exception 'Não é possível excluir outro administrador por aqui.';
  end if;

  -- Libera a proteção de campos apenas para esta operação controlada.
  perform set_config('app.excluindo_conta', 'on', true);

  update public.usuarios set aprovado_por = null where aprovado_por = p_usuario;
  -- Cascata: funcionarios_areas, conversas (e suas mensagens) e notificações
  delete from public.usuarios where id = p_usuario;
  delete from auth.users where id = p_usuario;
end;
$$;

revoke execute on function public.excluir_usuario(uuid) from public, anon;
grant execute on function public.excluir_usuario(uuid) to authenticated;
