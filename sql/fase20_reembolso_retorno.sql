-- Fase 20: pedido devolvido ao remetente entra na fila de reembolso.
-- Com o parâmetro "Marcar para reembolso", a parte devolvida cria uma devolução aprovada (tipo retorno_remetente).
-- O administrador reembolsa pelo fluxo que já existe na tela de devoluções. Quando o reembolso é feito,
-- a situação do envio passa a "reembolsado".
-- Rode no SQL Editor do Supabase e responda "feito".

-- 0. Verificação
do $$
begin
  if to_regprocedure('privado.aplicar_evento_envio(uuid,text,text,text,text,timestamptz)') is null then
    raise exception 'Fase 19 não encontrada. Aplique a fase 19 antes desta.';
  end if;
end $$;

-- 1. Novo tipo de devolução: retorno ao remetente (sem ação do cliente)
alter table public.devolucoes_loja drop constraint if exists devolucoes_loja_tipo_check;
alter table public.devolucoes_loja add constraint devolucoes_loja_tipo_check
  check (tipo = any (array['arrependimento'::text, 'defeito'::text, 'troca'::text, 'retorno_remetente'::text]));

-- 2. Aplicar evento: "devolvido" cria a devolução aprovada quando o parâmetro manda reembolsar
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
    if coalesce((select valor from public.loja_configuracoes where chave = 'devolvido_acao'), '') = 'reembolso' then
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


-- 3. Reembolso concluído: o envio devolvido passa a "reembolsado"
create or replace function privado.sincroniza_devolucao_envio()
returns trigger
language plpgsql
security definer
set search_path = public, privado
as $$
begin
  update public.pedido_envios
     set devolucao_status = 'reembolsado'
   where pedido_id = new.pedido_id and devolucao_status = 'reembolso_pendente';
  return new;
end;
$$;

drop trigger if exists devolucoes_sincroniza_envio on public.devolucoes_loja;
create trigger devolucoes_sincroniza_envio
  after update of status on public.devolucoes_loja
  for each row when (new.status = 'reembolsada' and old.status is distinct from new.status)
  execute function privado.sincroniza_devolucao_envio();

-- 4. Permissões
revoke execute on function privado.sincroniza_devolucao_envio() from public, anon, authenticated;

-- 5. Verificação final
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'devolucoes_loja_tipo_check' and pg_get_constraintdef(oid) like '%retorno_remetente%') then
    raise exception 'Tipo retorno_remetente não aceito.';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'devolucoes_sincroniza_envio') then
    raise exception 'Gatilho de reembolso não criado.';
  end if;
end $$;
