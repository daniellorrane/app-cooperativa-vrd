-- Endurecimento de segurança do banco (revisão geral).
-- Executar no SQL Editor do Supabase (projeto yutsnhuhimijtzqhpopu). Pode rodar mais de uma vez.
-- Não altera as regras de acesso (RLS) que já funcionam. Remove privilégios que o app não usa.

-- 1. TRUNCATE e REFERENCES ignoram o RLS. Nenhum usuário do app precisa deles.
revoke truncate, references, trigger on all tables in schema public from anon, authenticated;

-- 2. Visitantes (anon) só leem os documentos públicos e a lista de tipos de acesso.
revoke all on all tables in schema public from anon;
grant select on public.termos_uso, public.politicas_privacidade, public.tipos_acesso to anon;

-- 3. Usuário logado: sem exclusão direta de cadastros, atendimentos e notificações
--    (a exclusão passa pelas funções controladas). Mensagens seguem a política de administrador.
revoke delete on public.usuarios, public.conversas, public.notificacoes from authenticated;

-- 4. Funções de gatilho não devem ser chamadas pela API.
revoke execute on function public.protege_campos_sensiveis() from public, anon, authenticated;

-- 5. Cadastro público não pode escolher o perfil de administrador, mesmo chamando a API direto.
drop policy if exists usuario_cria_proprio_cadastro on public.usuarios;
create policy usuario_cria_proprio_cadastro on public.usuarios
  for insert to authenticated
  with check (
    id = auth.uid()
    and status = 'pendente'
    and tipo_acesso <> 'administrador'
    and termo_aceito_em is not null
    and termo_versao = (select versao from public.termos_uso order by publicado_em desc limit 1)
    and privacidade_aceita_em is not null
    and privacidade_versao = (select versao from public.politicas_privacidade order by publicado_em desc limit 1)
  );

-- 6. Confirmação: privilégios que sobraram para anon e authenticated em tabelas públicas.
select table_name, grantee, string_agg(privilege_type, ', ' order by privilege_type) as privilegios
  from information_schema.role_table_grants
 where table_schema = 'public' and grantee in ('anon', 'authenticated')
 group by table_name, grantee
 order by table_name, grantee;
