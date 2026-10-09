-- Fase 6: endurecimento final após a revisão de segurança e desempenho.
-- Executar no SQL Editor do Supabase (projeto yutsnhuhimijtzqhpopu). Pode rodar mais de uma vez.
-- Requer: sql/fase5_central_ajuda.sql (já rodado).
--
-- O que este script faz:
--   1. Limita a leitura pública da tabela de configurações ao contato do encarregado (DPO).
--   2. Cria índices nas chaves estrangeiras usadas nas telas (filtros do dia a dia).
-- O que NÃO muda, de propósito:
--   - validar_carteirinha pode ser chamada sem login (é a validação do QR code). O código tem 128 bits.
--   - As funções SECURITY DEFINER chamadas por usuários logados checam o próprio acesso dentro da função.

-- =====================================================================
-- 1. CONFIGURAÇÕES: leitura pública só do contato do encarregado
-- =====================================================================
drop policy if exists configuracoes_leitura on public.configuracoes;
create policy configuracoes_leitura on public.configuracoes
  for select to anon, authenticated
  using (chave in ('dpo_nome', 'dpo_email'));

-- =====================================================================
-- 2. ÍNDICES NAS CHAVES ESTRANGEIRAS DE USO FREQUENTE
-- =====================================================================
create index if not exists funcionarios_areas_area_idx on public.funcionarios_areas (area_id);
create index if not exists conversas_area_idx on public.conversas (area_id);
create index if not exists conversas_solicitante_idx on public.conversas (solicitante_id);
create index if not exists conversas_responsavel_idx on public.conversas (responsavel_id);
create index if not exists mensagens_autor_idx on public.mensagens (autor_id);
create index if not exists anexos_conversa_idx on public.anexos (conversa_id);
create index if not exists anexos_mensagem_idx on public.anexos (mensagem_id);
create index if not exists eventos_area_idx on public.eventos (area_id);
create index if not exists eventos_respostas_usuario_idx on public.eventos_respostas (usuario_id);
create index if not exists documentos_area_idx on public.documentos (area_id);
create index if not exists enquetes_area_idx on public.enquetes (area_id);
create index if not exists enquete_respostas_usuario_idx on public.enquete_respostas (usuario_id);
create index if not exists faq_artigos_area_idx on public.faq_artigos (area_id);
create index if not exists faq_avaliacoes_usuario_idx on public.faq_avaliacoes (usuario_id);

-- =====================================================================
-- 3. Verificação
-- =====================================================================
select 'politica_configuracoes' as item,
       string_agg(policyname || ' ' || cmd, ', ') as resultado
  from pg_policies where tablename = 'configuracoes'
union all
select 'chaves_publicas_configuracoes', string_agg(chave, ', ' order by chave)
  from public.configuracoes
 where chave in ('dpo_nome', 'dpo_email')
union all
select 'indices_criados', count(*)::text
  from pg_indexes
 where schemaname = 'public'
   and indexname in (
     'funcionarios_areas_area_idx', 'conversas_area_idx', 'conversas_solicitante_idx',
     'conversas_responsavel_idx', 'mensagens_autor_idx', 'anexos_conversa_idx',
     'anexos_mensagem_idx', 'eventos_area_idx', 'eventos_respostas_usuario_idx',
     'documentos_area_idx', 'enquetes_area_idx', 'enquete_respostas_usuario_idx',
     'faq_artigos_area_idx', 'faq_avaliacoes_usuario_idx');
