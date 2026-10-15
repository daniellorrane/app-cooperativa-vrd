-- Fase 19: situação detalhada da entrega (rastreio) por parte do pedido.
-- Estados do envio: aguardando envio, recolhido/enviado, em transporte, saiu para entrega,
-- tentativa de entrega falhou (até 3), devolvido ao remetente, entregue, cancelado.
-- Eventos chegam por três caminhos: webhook da Melhor Envio, agregador de rastreio (escolhido
-- pelo administrador) e registro manual pelo administrador ou pelo vendedor. Cada evento entra uma vez só.
-- Parâmetros do administrador: provedor de rastreio e o que fazer quando o pedido volta ao remetente.
-- Rode no SQL Editor do Supabase e responda "feito".

-- 0. Verificação
do $$
begin
  if to_regprocedure('privado.atualizar_situacao_por_envios(uuid)') is null
     or to_regprocedure('privado.gravar_segredo(text,text)') is null then
    raise exception 'Fase 18 não encontrada. Aplique a fase 18 antes desta.';
  end if;
end $$;

-- 1. Estados e contador de tentativas no envio
alter table public.pedido_envios drop constraint if exists pedido_envios_status_check;
alter table public.pedido_envios add constraint pedido_envios_status_check check (status in (
  'aguardando', 'enviado', 'em_transporte', 'saiu_entrega', 'tentativa_falhou', 'devolvido', 'entregue', 'cancelado'));

alter table public.pedido_envios
  add column if not exists tentativas smallint not null default 0 check (tentativas between 0 and 3),
  add column if not exists atualizado_em timestamptz,
  add column if not exists ultimo_evento text,
  add column if not exists devolucao_status text
    check (devolucao_status in ('aguardando_admin', 'reembolso_pendente', 'reembolsado'));

-- 2. Histórico de eventos do envio (linha do tempo). A chave evita duplicar o mesmo evento.
create table if not exists public.envio_eventos (
  id uuid primary key default gen_random_uuid(),
  envio_id uuid not null references public.pedido_envios(id) on delete cascade,
  status text not null,
  descricao text,
  origem text not null check (origem in ('manual', 'melhor_envio', 'agregador', 'sistema')),
  ocorrido_em timestamptz not null default now(),
  criado_em timestamptz not null default now(),
  chave text not null unique
);
create index if not exists envio_eventos_envio_idx on public.envio_eventos (envio_id, ocorrido_em);

alter table public.envio_eventos enable row level security;

drop policy if exists eventos_admin on public.envio_eventos;
create policy eventos_admin on public.envio_eventos for all to authenticated
  using (privado.eh_admin()) with check (privado.eh_admin());

drop policy if exists eventos_comprador_ler on public.envio_eventos;
create policy eventos_comprador_ler on public.envio_eventos for select to authenticated
  using (exists (select 1 from public.pedido_envios e join public.pedidos p on p.id = e.pedido_id
                  where e.id = envio_eventos.envio_id and p.usuario_id = auth.uid()));

drop policy if exists eventos_vendedor_ler on public.envio_eventos;
create policy eventos_vendedor_ler on public.envio_eventos for select to authenticated
  using (exists (select 1 from public.pedido_envios e join public.loja_vendedores v on v.id = e.vendedor_id
                  where e.id = envio_eventos.envio_id and v.usuario_id = auth.uid()));

revoke all on public.envio_eventos from anon;

-- 3. Parâmetros do administrador: aceita as chaves novas e grava os valores padrão (a tela de configuração altera)
alter table public.loja_configuracoes drop constraint if exists loja_configuracoes_chave_check;
alter table public.loja_configuracoes add constraint loja_configuracoes_chave_check check (chave = any (array[
  'nome_loja', 'endereco_retirada', 'horario_retirada', 'minutos_expiracao_pedido', 'url_publica_app',
  'mp_public_key', 'cep_origem', 'entrega_local_ativa', 'entrega_local_ceps', 'taxa_entrega_local_centavos',
  'melhor_envio_sandbox',
  'fiscal_ativo', 'fiscal_ambiente', 'fiscal_cnpj', 'fiscal_razao_social', 'fiscal_ie', 'fiscal_regime',
  'fiscal_logradouro', 'fiscal_numero', 'fiscal_bairro', 'fiscal_municipio', 'fiscal_uf', 'fiscal_cep',
  'fiscal_natureza_operacao', 'fiscal_cfop', 'fiscal_csosn', 'fiscal_cst_icms', 'fiscal_icms_aliquota',
  'fiscal_origem', 'fiscal_cst_pis', 'fiscal_cst_cofins',
  'comissao_padrao_percentual', 'frete_gratis_minimo_centavos',
  'rastreio_provedor', 'devolvido_acao'
]::text[]));

insert into public.loja_configuracoes (chave, valor)
select 'rastreio_provedor', 'nenhum'
 where not exists (select 1 from public.loja_configuracoes where chave = 'rastreio_provedor');
insert into public.loja_configuracoes (chave, valor)
select 'devolvido_acao', 'aguardando_admin'
 where not exists (select 1 from public.loja_configuracoes where chave = 'devolvido_acao');

-- 4. Segredos novos: webhook da Melhor Envio e token do agregador de rastreio
create or replace function privado.gravar_segredo(p_nome text, p_valor text)
returns void
language plpgsql
security definer
set search_path = public, vault
as $$
declare
  v_id uuid;
begin
  if p_nome not in ('mp_access_token', 'mp_webhook_secret', 'melhor_envio_token', 'focus_nfe_token',
                    'melhor_envio_webhook_secret', 'rastreio_provedor_token') then
    raise exception 'Segredo desconhecido.';
  end if;
  if p_valor is null or length(trim(p_valor)) < 8 then
    raise exception 'O valor parece curto demais. Copie a chave completa.';
  end if;

  select s.id into v_id from vault.secrets s where s.name = p_nome;
  if v_id is null then
    perform vault.create_secret(trim(p_valor), p_nome, 'Loja: ' || p_nome);
  else
    perform vault.update_secret(v_id, trim(p_valor), p_nome, 'Loja: ' || p_nome);
  end if;

  perform privado.auditar('segredo_loja_alterado', 'loja_configuracao', p_nome, '{}'::jsonb);
end;
$$;

-- 5. Situação do pedido conforme as partes.
-- Pedido em separação vai para "enviado" quando todas as partes saíram.
-- Pedido enviado vai para "entregue" quando todas as partes foram entregues.
create or replace function privado.atualizar_situacao_por_envios(p_pedido uuid)
returns void
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  v_status text;
  v_metodo text;
  v_usuario uuid;
  v_total integer;
  v_saidas integer;
  v_entregues integer;
  v_rastreio text;
begin
  select p.status, p.metodo_entrega, p.usuario_id into v_status, v_metodo, v_usuario
    from public.pedidos p where p.id = p_pedido;
  if not found or v_metodo = 'retirada' or v_status not in ('em_separacao', 'enviado') then
    return;
  end if;

  select count(*) filter (where e.status <> 'cancelado'),
         count(*) filter (where e.status in ('enviado', 'em_transporte', 'saiu_entrega', 'tentativa_falhou', 'devolvido', 'entregue')),
         count(*) filter (where e.status = 'entregue'),
         max(e.codigo_rastreio)
    into v_total, v_saidas, v_entregues, v_rastreio
    from public.pedido_envios e
   where e.pedido_id = p_pedido;

  if v_total = 0 then
    return;
  end if;

  if v_status = 'em_separacao' and v_saidas = v_total then
    update public.pedidos
       set status = 'enviado',
           codigo_rastreio = case when v_total = 1 then v_rastreio else codigo_rastreio end,
           atualizado_em = now()
     where id = p_pedido;
    if v_usuario is not null then
      perform privado.notificar(array[v_usuario], 'Seu pedido foi enviado',
                                'Acompanhe a entrega em Meus pedidos.', null);
    end if;
    perform privado.auditar('pedido_enviado', 'pedido', p_pedido::text, jsonb_build_object('partes', v_total));
  elsif v_status = 'enviado' and v_entregues = v_total then
    update public.pedidos
       set status = 'entregue', entregue_em = now(), atualizado_em = now()
     where id = p_pedido;
    if v_usuario is not null then
      perform privado.notificar(array[v_usuario], 'Seu pedido foi entregue',
                                'Confira o pedido em Meus pedidos.', null);
    end if;
    perform privado.auditar('pedido_entregue', 'pedido', p_pedido::text, jsonb_build_object('partes', v_total));
  end if;
end;
$$;

-- 6. Aplica um evento de entrega ao envio. Evento repetido não faz nada.
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
begin
  if p_status is not null and p_status not in ('enviado', 'em_transporte', 'saiu_entrega', 'tentativa_falhou', 'devolvido', 'entregue') then
    raise exception 'Situação de entrega desconhecida: %', p_status;
  end if;

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
         tentativas = case when p_status = 'tentativa_falhou' then least(e.tentativas + 1, 3) else e.tentativas end,
         enviado_em = coalesce(e.enviado_em, v_quando),
         entregue_em = case when p_status = 'entregue' then v_quando else e.entregue_em end,
         atualizado_em = v_quando,
         ultimo_evento = p_descricao
   where e.id = p_envio;

  select p.usuario_id into v_usuario from public.pedidos p where p.id = v.pedido_id;

  if p_status = 'devolvido' then
    select case when coalesce((select valor from public.loja_configuracoes where chave = 'devolvido_acao'), '') = 'reembolso'
                then 'reembolso_pendente' else 'aguardando_admin' end
      into v_acao;
    update public.pedido_envios set devolucao_status = v_acao where id = p_envio;
    perform privado.notificar(
      (select coalesce(array_agg(u.id), '{}') from public.usuarios u where u.tipo_acesso = 'administrador'),
      'Pedido devolvido ao remetente',
      'Confira o pedido e a devolução na loja.', null);
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

-- 7. Registro pelo administrador (manual)
create or replace function public.registrar_situacao_envio_admin_loja(p_envio uuid, p_status text, p_descricao text default null)
returns void
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  v_status_atual text;
begin
  if not privado.eh_admin() then
    raise exception 'Apenas administradores.';
  end if;
  if p_status not in ('em_transporte', 'saiu_entrega', 'tentativa_falhou', 'devolvido', 'entregue') then
    raise exception 'Escolha uma situação válida para registrar.';
  end if;
  select e.status into v_status_atual from public.pedido_envios e where e.id = p_envio;
  if v_status_atual is null then
    raise exception 'Envio não encontrado.';
  end if;
  if v_status_atual = 'aguardando' then
    raise exception 'Marque a parte como enviada antes de registrar a entrega.';
  end if;

  perform privado.aplicar_evento_envio(p_envio, p_status, 'manual:' || gen_random_uuid()::text,
                                       nullif(trim(coalesce(p_descricao, '')), ''), 'manual', now());
  perform privado.auditar('envio_situacao_manual', 'pedido_envio', p_envio::text, jsonb_build_object('status', p_status));
end;
$$;

-- 8. Registro pelo vendedor dono do envio (manual)
create or replace function public.registrar_situacao_envio_vendedor_loja(p_envio uuid, p_status text, p_descricao text default null)
returns void
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  v_status_atual text;
begin
  if p_status not in ('em_transporte', 'saiu_entrega', 'tentativa_falhou', 'devolvido', 'entregue') then
    raise exception 'Escolha uma situação válida para registrar.';
  end if;
  select e.status into v_status_atual from public.pedido_envios e
   where e.id = p_envio
     and e.vendedor_id in (select x.id from public.loja_vendedores x where x.usuario_id = auth.uid() and x.status = 'aprovado');
  if v_status_atual is null then
    raise exception 'Envio não encontrado ou não é da sua loja.';
  end if;
  if v_status_atual = 'aguardando' then
    raise exception 'Registre o código de rastreio antes de informar a entrega.';
  end if;

  perform privado.aplicar_evento_envio(p_envio, p_status, 'manual:' || gen_random_uuid()::text,
                                       nullif(trim(coalesce(p_descricao, '')), ''), 'manual', now());
  perform privado.auditar('envio_situacao_vendedor', 'pedido_envio', p_envio::text, jsonb_build_object('status', p_status));
end;
$$;

-- 9. Registro vindo das Edge Functions de rastreio (webhook e agregador). Só a função de serviço executa.
create or replace function public.registrar_evento_envio_sistema(
  p_envio uuid, p_status text, p_chave text, p_descricao text, p_origem text, p_ocorrido timestamptz)
returns boolean
language plpgsql
security definer
set search_path = public, privado
as $$
begin
  if p_origem not in ('melhor_envio', 'agregador') then
    raise exception 'Origem de evento inválida.';
  end if;
  return privado.aplicar_evento_envio(p_envio, p_status, p_chave, p_descricao, p_origem, p_ocorrido);
end;
$$;

-- 10. Permissões
revoke execute on function privado.aplicar_evento_envio(uuid, text, text, text, text, timestamptz) from public, anon, authenticated;
revoke execute on function privado.atualizar_situacao_por_envios(uuid) from public, anon, authenticated;

revoke execute on function public.registrar_situacao_envio_admin_loja(uuid, text, text) from public, anon;
grant execute on function public.registrar_situacao_envio_admin_loja(uuid, text, text) to authenticated;
revoke execute on function public.registrar_situacao_envio_vendedor_loja(uuid, text, text) from public, anon;
grant execute on function public.registrar_situacao_envio_vendedor_loja(uuid, text, text) to authenticated;

revoke execute on function public.registrar_evento_envio_sistema(uuid, text, text, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.registrar_evento_envio_sistema(uuid, text, text, text, text, timestamptz) to service_role;

-- 11. Verificação final
do $$
begin
  if to_regclass('public.envio_eventos') is null then
    raise exception 'Tabela envio_eventos não criada.';
  end if;
  if has_function_privilege('authenticated', 'public.registrar_evento_envio_sistema(uuid,text,text,text,text,timestamptz)', 'execute') then
    raise exception 'Função de sistema liberada para usuário comum.';
  end if;
  if not exists (select 1 from public.loja_configuracoes where chave = 'rastreio_provedor') then
    raise exception 'Parâmetro rastreio_provedor não criado.';
  end if;
end $$;
