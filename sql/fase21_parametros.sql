-- Fase 21: catálogo de parâmetros da loja.
-- Cada regra configurável fica cadastrada em loja_parametros (tipo, opções, limites e valor padrão).
-- O banco valida cada valor gravado em loja_configuracoes. A tela de configuração passa a ser montada a partir do catálogo.
-- Liga ao catálogo as regras que já existem: prazos de devolução e tentativas de entrega.
-- Rode no SQL Editor do Supabase e responda "feito".

-- 0. Verificação
do $$
begin
  if to_regclass('public.loja_configuracoes') is null
     or to_regprocedure('privado.aplicar_evento_envio(uuid,text,text,text,text,timestamptz)') is null
     or to_regprocedure('public.solicitar_devolucao_loja(uuid,text,text)') is null then
    raise exception 'Fases anteriores não encontradas. Aplique as fases 11, 19 e 20 antes desta.';
  end if;
end $$;

-- 1. Catálogo de parâmetros
create table if not exists public.loja_parametros (
  chave text primary key check (chave ~ '^[a-z][a-z0-9_]{2,60}$'),
  grupo text not null check (grupo in ('loja', 'pagamento', 'entrega', 'rastreio', 'devolucao', 'fiscal', 'vendedores')),
  rotulo text not null,
  ajuda text,
  tipo text not null check (tipo in ('texto', 'texto_longo', 'inteiro', 'centavos', 'percentual', 'escolha', 'url')),
  opcoes jsonb not null default '[]'::jsonb check (jsonb_typeof(opcoes) = 'array'),
  minimo numeric,
  maximo numeric,
  padrao text,
  ordem integer not null default 0,
  criado_em timestamptz not null default now()
);

alter table public.loja_parametros enable row level security;

drop policy if exists loja_parametros_ler on public.loja_parametros;
create policy loja_parametros_ler on public.loja_parametros
  for select to authenticated using (true);

revoke insert, update, delete on public.loja_parametros from anon, authenticated;
grant select on public.loja_parametros to authenticated;

-- 2. Catálogo inicial: todas as chaves que a loja já usa, mais as regras novas ligadas nesta fase
insert into public.loja_parametros (chave, grupo, rotulo, ajuda, tipo, opcoes, minimo, maximo, padrao, ordem) values
  -- Loja
  ('nome_loja', 'loja', 'Nome da loja', 'Aparece no topo da loja e nos e-mails.', 'texto', '[]', null, 120, null, 10),
  ('endereco_retirada', 'loja', 'Endereço para retirada', 'Mostrado ao cliente quando a retirada é escolhida.', 'texto_longo', '[]', null, 500, null, 20),
  ('horario_retirada', 'loja', 'Horário de retirada', 'Exemplo: segunda a sexta, 8h às 17h.', 'texto', '[]', null, 200, null, 30),
  ('url_publica_app', 'loja', 'Endereço do aplicativo', 'Usado em links de pagamento e notificações. Começa com https://.', 'url', '[]', null, 200, null, 40),
  -- Pagamento
  ('minutos_expiracao_pedido', 'pagamento', 'Minutos para pagar um pedido', 'Depois desse prazo o pedido expira e o estoque volta a ficar disponível.', 'inteiro', '[]', 5, 1440, '30', 10),
  ('mp_public_key', 'pagamento', 'Chave pública do Mercado Pago', 'Chave pública, não é segredo.', 'texto', '[]', null, 200, null, 20),
  -- Entrega
  ('cep_origem', 'entrega', 'CEP de origem da cooperativa', 'De onde os pacotes da cooperativa saem.', 'texto', '[]', null, 9, null, 10),
  ('entrega_local_ativa', 'entrega', 'Entrega local própria', 'Entregador da cooperativa, com taxa fixa por CEP.', 'escolha', '[{"valor":"sim","rotulo":"Ligada"},{"valor":"nao","rotulo":"Desligada"}]', null, null, 'nao', 20),
  ('entrega_local_ceps', 'entrega', 'CEPs da entrega local', 'Os 5 primeiros dígitos de cada CEP, separados por vírgula.', 'texto_longo', '[]', null, 500, null, 30),
  ('taxa_entrega_local_centavos', 'entrega', 'Taxa da entrega local (centavos)', 'Valor fixo cobrado pela entrega local.', 'centavos', '[]', 0, 1000000, '0', 40),
  ('melhor_envio_sandbox', 'entrega', 'Ambiente do Melhor Envio', 'Use o teste antes de vender de verdade.', 'escolha', '[{"valor":"sim","rotulo":"Teste (sandbox)"},{"valor":"nao","rotulo":"Produção"}]', null, null, 'nao', 50),
  ('frete_gratis_minimo_centavos', 'entrega', 'Frete grátis da cooperativa a partir de (centavos)', 'Deixe vazio para não oferecer frete grátis nos produtos da cooperativa.', 'centavos', '[]', 0, 100000000, null, 60),
  -- Rastreio
  ('rastreio_provedor', 'rastreio', 'Provedor de rastreio', 'Além da Melhor Envio, outros provedores aparecem aqui quando forem integrados.', 'escolha', '[{"valor":"nenhum","rotulo":"Nenhum (registro manual)"}]', null, null, 'nenhum', 10),
  ('rastreio_tentativas_maximo', 'rastreio', 'Tentativas de entrega antes do retorno', 'Quantas tentativas de entrega a transportadora faz antes de devolver o pacote ao remetente.', 'inteiro', '[]', 1, 5, '3', 20),
  -- Devolução
  ('devolvido_acao', 'devolucao', 'Pedido devolvido ao remetente', 'O que fazer quando a transportadora devolve o pedido.', 'escolha', '[{"valor":"aguardando_admin","rotulo":"Aguardar decisão do administrador"},{"valor":"reembolso","rotulo":"Marcar para reembolso"}]', null, null, 'aguardando_admin', 10),
  ('prazo_arrependimento_dias', 'devolucao', 'Prazo para arrependimento (dias)', 'Contado a partir da entrega. O mínimo legal é de 7 dias (CDC, art. 49).', 'inteiro', '[]', 7, 90, '7', 20),
  ('prazo_defeito_dias', 'devolucao', 'Prazo para defeito (dias)', 'Contado a partir da entrega. O mínimo é de 30 dias.', 'inteiro', '[]', 30, 365, '30', 30),
  ('prazo_troca_dias', 'devolucao', 'Prazo para troca (dias)', 'Contado a partir da entrega.', 'inteiro', '[]', 1, 365, '30', 40),
  -- Fiscal
  ('fiscal_ativo', 'fiscal', 'Emissão de nota fiscal', 'Ligue somente depois de configurar e homologar o Focus NFe.', 'escolha', '[{"valor":"sim","rotulo":"Ligada"},{"valor":"nao","rotulo":"Desligada"}]', null, null, 'nao', 10),
  ('fiscal_ambiente', 'fiscal', 'Ambiente da nota', 'Use o teste até a primeira nota ser validada pelo contador.', 'escolha', '[{"valor":"homologacao","rotulo":"Teste (homologação)"},{"valor":"producao","rotulo":"Produção"}]', null, null, 'homologacao', 20),
  ('fiscal_cnpj', 'fiscal', 'CNPJ da cooperativa', null, 'texto', '[]', null, 20, null, 30),
  ('fiscal_razao_social', 'fiscal', 'Razão social', null, 'texto', '[]', null, 200, null, 40),
  ('fiscal_ie', 'fiscal', 'Inscrição estadual', null, 'texto', '[]', null, 30, null, 50),
  ('fiscal_regime', 'fiscal', 'Regime tributário', 'Define se usamos CSOSN (Simples) ou CST (regime normal).', 'escolha', '[{"valor":"simples","rotulo":"Simples Nacional ou MEI"},{"valor":"normal","rotulo":"Regime normal (lucro presumido ou real)"}]', null, null, 'simples', 60),
  ('fiscal_logradouro', 'fiscal', 'Logradouro', null, 'texto', '[]', null, 200, null, 70),
  ('fiscal_numero', 'fiscal', 'Número', null, 'texto', '[]', null, 20, null, 80),
  ('fiscal_bairro', 'fiscal', 'Bairro', null, 'texto', '[]', null, 100, null, 90),
  ('fiscal_municipio', 'fiscal', 'Município', null, 'texto', '[]', null, 100, null, 100),
  ('fiscal_uf', 'fiscal', 'UF', 'Sigla com 2 letras.', 'texto', '[]', null, 2, null, 110),
  ('fiscal_cep', 'fiscal', 'CEP da sede', null, 'texto', '[]', null, 9, null, 120),
  ('fiscal_natureza_operacao', 'fiscal', 'Natureza da operação', null, 'texto', '[]', null, 120, 'Venda de mercadoria', 130),
  ('fiscal_cfop', 'fiscal', 'CFOP', 'Código fiscal da operação. Confirme com o contador.', 'texto', '[]', null, 4, null, 140),
  ('fiscal_csosn', 'fiscal', 'CSOSN', 'Usado pelo Simples Nacional. Confirme com o contador.', 'texto', '[]', null, 4, null, 150),
  ('fiscal_cst_icms', 'fiscal', 'CST do ICMS', 'Usado pelo regime normal. Confirme com o contador.', 'texto', '[]', null, 3, null, 160),
  ('fiscal_icms_aliquota', 'fiscal', 'Alíquota do ICMS (%)', null, 'percentual', '[]', 0, 100, null, 170),
  ('fiscal_origem', 'fiscal', 'Origem da mercadoria', '0 = nacional.', 'texto', '[]', null, 1, '0', 180),
  ('fiscal_cst_pis', 'fiscal', 'CST do PIS', 'Confirme com o contador.', 'texto', '[]', null, 2, null, 190),
  ('fiscal_cst_cofins', 'fiscal', 'CST da COFINS', 'Confirme com o contador.', 'texto', '[]', null, 2, null, 200),
  -- Vendedores
  ('comissao_padrao_percentual', 'vendedores', 'Comissão padrão da loja (%)', 'Vale para os vendedores que não têm comissão própria.', 'percentual', '[]', 0, 100, null, 10)
on conflict (chave) do update set
  grupo = excluded.grupo,
  rotulo = excluded.rotulo,
  ajuda = excluded.ajuda,
  tipo = excluded.tipo,
  opcoes = excluded.opcoes,
  minimo = excluded.minimo,
  maximo = excluded.maximo,
  padrao = excluded.padrao,
  ordem = excluded.ordem;

-- 3. Validação: a lista fixa de chaves dá lugar ao catálogo
alter table public.loja_configuracoes drop constraint if exists loja_configuracoes_chave_check;

create or replace function privado.valida_configuracao_loja()
returns trigger
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  p public.loja_parametros%rowtype;
  v text;
  n numeric;
begin
  select * into p from public.loja_parametros where chave = new.chave;
  if not found then
    raise exception 'Parâmetro desconhecido: %.', new.chave;
  end if;

  v := trim(coalesce(new.valor, ''));
  if p.tipo in ('inteiro', 'centavos', 'percentual') then
    v := replace(v, ',', '.');
  end if;
  new.valor := v;

  -- Vazio é permitido: o sistema usa o padrão do catálogo
  if v = '' then
    return new;
  end if;

  if p.tipo in ('texto', 'texto_longo') then
    if p.maximo is not null and char_length(v) > p.maximo then
      raise exception '% passou do limite de % caracteres.', p.rotulo, p.maximo;
    end if;
  elsif p.tipo = 'url' then
    if v !~* '^https://' or char_length(v) > coalesce(p.maximo, 200) then
      raise exception '% precisa começar com https://.', p.rotulo;
    end if;
  elsif p.tipo in ('inteiro', 'centavos', 'percentual') then
    begin
      n := v::numeric;
    exception when others then
      raise exception '% precisa ser um número.', p.rotulo;
    end;
    if p.tipo in ('inteiro', 'centavos') and n <> trunc(n) then
      raise exception '% precisa ser um número inteiro.', p.rotulo;
    end if;
    if p.minimo is not null and n < p.minimo then
      raise exception '% não pode ser menor que %.', p.rotulo, p.minimo;
    end if;
    if p.maximo is not null and n > p.maximo then
      raise exception '% não pode ser maior que %.', p.rotulo, p.maximo;
    end if;
  elsif p.tipo = 'escolha' then
    if not exists (select 1 from jsonb_array_elements(p.opcoes) o where o->>'valor' = v) then
      raise exception 'Opção inválida para %.', p.rotulo;
    end if;
  end if;

  return new;
end $$;

drop trigger if exists trg_valida_configuracao_loja on public.loja_configuracoes;
create trigger trg_valida_configuracao_loja
  before insert or update on public.loja_configuracoes
  for each row execute function privado.valida_configuracao_loja();

-- 4. Leitura do parâmetro com o padrão do catálogo (uso interno das funções)
create or replace function privado.parametro_loja(p_chave text)
returns text
language sql
stable
security definer
set search_path = public, privado
as $$
  select coalesce(
    nullif((select c.valor from public.loja_configuracoes c where c.chave = p_chave), ''),
    (select p.padrao from public.loja_parametros p where p.chave = p_chave))
$$;

revoke execute on function privado.parametro_loja(text) from public, anon, authenticated;
revoke execute on function privado.valida_configuracao_loja() from public, anon, authenticated;

-- 5. Devolução: prazos vêm do catálogo (arrependimento, defeito e troca)
create or replace function public.solicitar_devolucao_loja(p_pedido uuid, p_tipo text, p_motivo text)
returns uuid
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  p public.pedidos%rowtype;
  v_id uuid;
  v_dias integer;
begin
  if not privado.usuario_aprovado() then
    raise exception 'Sua conta precisa estar aprovada para pedir devolução.';
  end if;

  select * into p from public.pedidos where id = p_pedido and usuario_id = auth.uid();
  if not found then
    raise exception 'Pedido não encontrado.';
  end if;
  if p.status not in ('entregue', 'retirado') or p.entregue_em is null then
    raise exception 'Só é possível pedir devolução depois da entrega ou da retirada.';
  end if;
  if p_tipo not in ('arrependimento', 'defeito', 'troca') then
    raise exception 'Escolha o tipo do pedido de devolução.';
  end if;

  v_dias := case p_tipo
    when 'arrependimento' then coalesce(nullif(privado.parametro_loja('prazo_arrependimento_dias'), '')::integer, 7)
    when 'defeito' then coalesce(nullif(privado.parametro_loja('prazo_defeito_dias'), '')::integer, 30)
    else coalesce(nullif(privado.parametro_loja('prazo_troca_dias'), '')::integer, 30)
  end;
  if now() > p.entregue_em + make_interval(days => v_dias) then
    raise exception 'O prazo para este tipo de devolução terminou (% dias).', v_dias;
  end if;

  insert into public.devolucoes_loja (pedido_id, usuario_id, tipo, motivo)
  values (p_pedido, auth.uid(), p_tipo, trim(p_motivo))
  returning id into v_id;

  perform privado.notificar(array[auth.uid()], 'Pedido de devolução recebido',
                            'Recebemos seu pedido de devolução. Acompanhe em Meus pedidos.', null);
  perform privado.auditar('devolucao_solicitada', 'pedido', p_pedido::text, jsonb_build_object('tipo', p_tipo));
  return v_id;
exception when unique_violation then
  raise exception 'Este pedido já tem um pedido de devolução. Acompanhe em Meus pedidos.';
end;
$$;

-- 6. Rastreio: número de tentativas vem do catálogo (o padrão continua 3)
create or replace function privado.aplicar_evento_envio(
  p_envio uuid, p_status text, p_chave text, p_descricao text, p_origem text, p_ocorrido timestamptz)
returns boolean
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  v public.pedido_envios;
  v_linhas integer;
  v_usuario uuid;
  v_acao text;
  v_quando timestamptz := coalesce(p_ocorrido, now());
  v_titulo text;
  v_texto text;
  v_maximo integer;
begin
  if p_status is not null and p_status not in ('enviado', 'em_transporte', 'saiu_entrega', 'tentativa_falhou', 'devolvido', 'entregue') then
    raise exception 'Situação de entrega desconhecida: %', p_status;
  end if;

  v_maximo := coalesce(nullif(privado.parametro_loja('rastreio_tentativas_maximo'), '')::integer, 3);

  select * into v from public.pedido_envios e where e.id = p_envio for update;
  if not found then
    return false;
  end if;

  insert into public.envio_eventos (envio_id, status, descricao, origem, ocorrido_em, chave)
  values (p_envio, coalesce(p_status, v.status), p_descricao, p_origem, v_quando, p_chave)
  on conflict (chave) do nothing;
  get diagnostics v_linhas = row_count;
  if v_linhas = 0 then
    return false;
  end if;

  -- Sem situação nova (ex.: entrega pausada): só fica no histórico
  if p_status is null then
    return true;
  end if;

  -- Situação final não volta atrás, e evento mais antigo que o último aplicado não muda nada
  if v.status in ('entregue', 'cancelado', 'devolvido') then
    return true;
  end if;
  if v.atualizado_em is not null and v_quando < v.atualizado_em then
    return true;
  end if;

  update public.pedido_envios e
     set status = p_status,
         tentativas = case when p_status = 'tentativa_falhou' then least(e.tentativas + 1, v_maximo) else e.tentativas end,
         enviado_em = coalesce(e.enviado_em, v_quando),
         entregue_em = case when p_status = 'entregue' then v_quando else e.entregue_em end,
         atualizado_em = v_quando,
         ultimo_evento = p_descricao
   where e.id = p_envio;

  select p.usuario_id into v_usuario from public.pedidos p where p.id = v.pedido_id;

  if p_status = 'devolvido' then
    if coalesce(privado.parametro_loja('devolvido_acao'), '') = 'reembolso' then
      -- Entra na mesma fila de devoluções: o administrador reembolsa com um clique, pelo fluxo que já existe
      insert into public.devolucoes_loja (pedido_id, tipo, motivo, status)
      values (v.pedido_id, 'retorno_remetente', 'Pedido devolvido ao remetente pela transportadora.', 'aprovada')
      on conflict (pedido_id) do nothing;
      get diagnostics v_linhas = row_count;
      v_acao := case when v_linhas = 1 then 'reembolso_pendente' else 'aguardando_admin' end;
    else
      v_acao := 'aguardando_admin';
    end if;
    update public.pedido_envios set devolucao_status = v_acao where id = p_envio;
    perform privado.notificar(
      (select coalesce(array_agg(u.id), '{}') from public.usuarios u where u.tipo_acesso = 'administrador'),
      'Pedido devolvido ao remetente',
      case when v_acao = 'reembolso_pendente'
           then 'Reembolso pronto para conferir na tela de devoluções.'
           else 'Confira o pedido e a devolução na loja.' end,
      null);
  end if;

  if v_usuario is not null then
    v_titulo := case p_status
      when 'saiu_entrega' then 'Seu pedido saiu para entrega'
      when 'tentativa_falhou' then 'Tentativa de entrega não realizada'
      when 'devolvido' then 'Seu pedido voltou ao remetente'
      else null end;
    v_texto := case p_status
      when 'tentativa_falhou' then 'Veja em Meus pedidos o que a transportadora informou.'
      when 'devolvido' then 'Entre em contato com a loja para combinar a devolução.'
      else 'Acompanhe a entrega em Meus pedidos.' end;
    if v_titulo is not null then
      perform privado.notificar(array[v_usuario], v_titulo, v_texto, null);
    end if;
  end if;

  perform privado.atualizar_situacao_por_envios(v.pedido_id);
  return true;
end;
$$;

-- 7. Verificação final
do $$
declare
  v_qtd integer;
begin
  select count(*) into v_qtd from public.loja_parametros;
  if v_qtd < 39 then
    raise exception 'Catálogo incompleto (% parâmetros).', v_qtd;
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'trg_valida_configuracao_loja') then
    raise exception 'Validação dos parâmetros não criada.';
  end if;
  if coalesce(privado.parametro_loja('prazo_arrependimento_dias'), '') <> '7' then
    raise exception 'Padrão do prazo de arrependimento incorreto.';
  end if;

  -- Valor fora do limite tem de ser recusado
  begin
    insert into public.loja_configuracoes (chave, valor) values ('minutos_expiracao_pedido', '1');
    raise exception 'teste_sem_bloqueio';
  exception when others then
    if sqlerrm = 'teste_sem_bloqueio' then
      raise exception 'A validação não bloqueou um valor fora do limite.';
    end if;
  end;
end $$;
