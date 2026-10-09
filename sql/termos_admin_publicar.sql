-- Permite que administradores publiquem novas versões dos Termos e Condições.
-- Versões publicadas não podem ser editadas nem apagadas (sem políticas de update/delete), para manter o histórico do aceite.
-- Executar no SQL Editor do Supabase (projeto yutsnhuhimijtzqhpopu). Pode rodar mais de uma vez.

drop policy if exists termos_admin_publicar on public.termos_uso;
create policy termos_admin_publicar on public.termos_uso for insert to authenticated
  with check (privado.funcao_admin());
