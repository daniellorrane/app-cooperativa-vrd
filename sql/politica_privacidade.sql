-- Política de privacidade versionada, com aceite obrigatório no cadastro e a cada nova versão.
-- Executar no SQL Editor do Supabase (projeto yutsnhuhimijtzqhpopu). Pode rodar mais de uma vez.

-- 1. Tabela de versões da política (mesmo modelo dos termos)
create table if not exists public.politicas_privacidade (
  versao text primary key,
  texto text not null,
  publicado_em timestamptz not null default now()
);
alter table public.politicas_privacidade enable row level security;
drop policy if exists privacidade_leitura on public.politicas_privacidade;
create policy privacidade_leitura on public.politicas_privacidade for select to anon, authenticated using (true);
drop policy if exists privacidade_admin_publicar on public.politicas_privacidade;
create policy privacidade_admin_publicar on public.politicas_privacidade for insert to authenticated
  with check (privado.funcao_admin());

insert into public.politicas_privacidade (versao, texto) values ('1.0', $p$POLÍTICA DE PRIVACIDADE
Versão 1.0

1. Quem trata os dados
A Cooperativa Agropecuária Vale do Rio Doce (Cooperativa) é responsável pelo tratamento dos dados pessoais coletados neste sistema. O contato do encarregado pelo tratamento de dados será divulgado pela Cooperativa em seus canais oficiais.

2. Dados coletados
Nome completo, CPF, e-mail, celular, tipo de acesso e a senha, que é armazenada de forma protegida e não fica visível para a equipe. Também são tratados o conteúdo das conversas, solicitações e mensagens que você enviar.

3. Finalidades
Cadastro e verificação de acesso; comunicação com as áreas da Cooperativa; atendimento de solicitações de documentos e serviços; envio de notificações do sistema; cumprimento de obrigações legais; e produção de estatísticas sem identificação de pessoas.

4. Base legal
O tratamento se baseia na execução do atendimento que você solicita, no cumprimento de obrigações legais e no seu consentimento, registrado no aceite desta política. Você pode revogar o consentimento excluindo a sua conta.

5. Quem tem acesso
Você e o administrador do sistema. Os funcionários acessam somente as conversas da área à qual estão vinculados; funcionários de outras áreas não veem essas conversas. Os dados não são vendidos. Podem ser compartilhados apenas com fornecedores de hospedagem e banco de dados contratados para operar o sistema, sob dever de sigilo.

6. Notificações
Os avisos enviados pelo sistema não trazem o assunto nem o conteúdo das mensagens.

7. Armazenamento e segurança
Os dados ficam em serviços de hospedagem e banco de dados com controle de acesso por perfil e conexão criptografada. Cada pessoa vê apenas os dados necessários à sua função.

8. Prazo de guarda
Os dados ficam armazenados enquanto a conta estiver ativa e pelo prazo necessário ao atendimento e ao cumprimento de obrigações legais. Ao excluir a conta, os dados são apagados ou, se você escolher o histórico anônimo, o vínculo com a sua identidade é removido. Nesse caso, o conteúdo escrito das conversas é mantido, sem nome ou e-mail associados, apenas para estatísticas.

9. Seus direitos
Você pode confirmar a existência do tratamento; acessar e corrigir seus dados em Meus dados; solicitar informações sobre o compartilhamento dos seus dados; solicitar a anonimização ou a eliminação de dados desnecessários; e revogar o consentimento, excluindo a sua conta.

10. Exclusão da conta
Você pode excluir a sua conta em Meus dados, escolhendo entre apagar tudo ou manter o histórico de forma anônima. A exclusão é definitiva.

11. Alterações
Esta política pode ser atualizada. Quando houver nova versão, será solicitado novo aceite para continuar usando o sistema.

12. Dúvidas
Dúvidas sobre o tratamento de dados podem ser enviadas pelos canais oficiais de atendimento da Cooperativa.$p$)
on conflict (versao) do nothing;

-- 2. Campos de aceite da política no cadastro do usuário
alter table public.usuarios add column if not exists privacidade_versao text references public.politicas_privacidade(versao);
alter table public.usuarios add column if not exists privacidade_aceita_em timestamptz;

-- 3. Cadastro e criação de conversa exigem os dois aceites vigentes
drop policy if exists usuario_cria_proprio_cadastro on public.usuarios;
create policy usuario_cria_proprio_cadastro on public.usuarios for insert to authenticated
  with check (
    id = auth.uid()
    and status = 'pendente'
    and termo_aceito_em is not null
    and termo_versao = (select versao from public.termos_uso order by publicado_em desc limit 1)
    and privacidade_aceita_em is not null
    and privacidade_versao = (select versao from public.politicas_privacidade order by publicado_em desc limit 1)
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
         and u.privacidade_aceita_em is not null
         and u.privacidade_versao = (select versao from public.politicas_privacidade order by publicado_em desc limit 1)
    )
  );
