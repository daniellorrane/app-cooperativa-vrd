-- E-commerce E5: devolução (arrependimento, defeito e troca), reembolso pelo Mercado Pago e relatórios.
-- Rodar inteiro no SQL Editor do Supabase, uma vez. Não apaga dados.
-- Nota fiscal fica para depois: depende da escolha do emissor fiscal pela cooperativa.

-- =====================================================================
-- 1. DATA DA ENTREGA (base do prazo de devolução)
-- =====================================================================
alter table public.pedidos add column if not exists entregue_em timestamptz;

-- Pedidos já entregues ou retirados antes desta fase: usa a última atualização como data de entrega.
update public.pedidos
   set entregue_em = atualizado_em
 where status in ('entregue', 'retirado') and entregue_em is null;

-- Mesma regra da E3, mais a data de entrega (ou retirada).
create or replace function public.avancar_pedido_loja(p_pedido uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  v_atual text;
  v_metodo text;
  v_usuario uuid;
begin
  if not privado.eh_admin() then
    raise exception 'Apenas administradores.';
  end if;

  select p.status, p.metodo_entrega, p.usuario_id into v_atual, v_metodo, v_usuario
    from public.pedidos p where p.id = p_pedido for update;
  if not found then
    raise exception 'Pedido não encontrado.';
  end if;

  if not (
       (v_atual = 'pago' and p_status in ('em_separacao', 'cancelado'))
    or (v_atual = 'em_separacao' and v_metodo = 'retirada' and p_status in ('pronto_retirada', 'cancelado'))
    or (v_atual = 'em_separacao' and v_metodo <> 'retirada' and p_status = 'cancelado')
    or (v_atual = 'pronto_retirada' and p_status = 'retirado')
    or (v_atual = 'enviado' and p_status = 'entregue')
  ) then
    raise exception 'Não é possível mudar o pedido de "%" para "%".', v_atual, p_status;
  end if;

  if p_status = 'cancelado' then
    perform privado.devolver_estoque_pedido(p_pedido);
  end if;

  update public.pedidos
     set status = p_status,
         entregue_em = case when p_status in ('entregue', 'retirado') then now() else entregue_em end,
         observacao_admin = case when p_status = 'cancelado'
           then 'Cancelado pela loja. Se houve pagamento, fazer o reembolso no Mercado Pago.'
           else observacao_admin end,
         atualizado_em = now()
   where id = p_pedido;

  if p_status in ('pronto_retirada', 'entregue') and v_usuario is not null then
    perform privado.notificar(array[v_usuario], 'Atualização do seu pedido',
                              'Seu pedido da loja mudou de situação. Veja em Meus pedidos.', null);
  end if;

  perform privado.auditar('pedido_status_alterado', 'pedido', p_pedido::text,
                          jsonb_build_object('de', v_atual, 'para', p_status));
end;
$$;

-- =====================================================================
-- 2. DEVOLUÇÕES
-- Um pedido de devolução por pedido. Estados: solicitada, aprovada, recusada, recebida, reembolsada.
-- Troca não gera reembolso: a loja cria um novo pedido.
-- =====================================================================
create table if not exists public.devolucoes_loja (
  id uuid primary key default gen_random_uuid(),
  pedido_id uuid not null unique references public.pedidos(id) on delete cascade,
  usuario_id uuid references auth.users(id) on delete set null,
  tipo text not null check (tipo in ('arrependimento', 'defeito', 'troca')),
  motivo text not null check (length(trim(motivo)) between 5 and 500),
  status text not null default 'solicitada'
    check (status in ('solicitada', 'aprovada', 'recusada', 'recebida', 'reembolsada')),
  valor_reembolso_centavos integer check (valor_reembolso_centavos is null or valor_reembolso_centavos >= 0),
  mp_refund_id text,
  observacao_admin text check (observacao_admin is null or length(observacao_admin) <= 500),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

alter table public.devolucoes_loja enable row level security;

drop policy if exists devolucoes_ler on public.devolucoes_loja;
create policy devolucoes_ler on public.devolucoes_loja
  for select using (usuario_id = auth.uid() or privado.eh_admin());

-- Cooperado pede devolução de um pedido entregue ou retirado, dentro do prazo.
create or replace function public.solicitar_devolucao_loja(p_pedido uuid, p_tipo text, p_motivo text)
returns uuid
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  p public.pedidos%rowtype;
  v_id uuid;
  v_prazo interval;
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

  -- Arrependimento: 7 dias (CDC art. 49). Defeito e troca: 30 dias. Revisão jurídica pendente.
  v_prazo := case when p_tipo = 'arrependimento' then interval '7 days' else interval '30 days' end;
  if now() > p.entregue_em + v_prazo then
    raise exception 'O prazo para este tipo de devolução terminou (% dias).',
      case when p_tipo = 'arrependimento' then 7 else 30 end;
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

-- Administrador aprova, recusa ou marca como recebida. Ao receber, o estoque volta.
create or replace function public.decidir_devolucao_loja(p_devolucao uuid, p_acao text, p_observacao text default null)
returns void
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  d public.devolucoes_loja%rowtype;
  v_novo text;
begin
  if not privado.eh_admin() then
    raise exception 'Apenas administradores.';
  end if;

  select * into d from public.devolucoes_loja where id = p_devolucao for update;
  if not found then
    raise exception 'Pedido de devolução não encontrado.';
  end if;

  if p_acao = 'aprovar' and d.status = 'solicitada' then
    v_novo := 'aprovada';
  elsif p_acao = 'recusar' and d.status = 'solicitada' then
    if nullif(trim(coalesce(p_observacao, '')), '') is null then
      raise exception 'Informe o motivo da recusa.';
    end if;
    v_novo := 'recusada';
  elsif p_acao = 'recebida' and d.status = 'aprovada' then
    v_novo := 'recebida';
    update public.loja_produtos p
       set estoque = p.estoque + i.quantidade
      from public.pedido_itens i
     where i.pedido_id = d.pedido_id and i.produto_id = p.id;
  else
    raise exception 'Não é possível fazer esta ação agora (situação atual: %).', d.status;
  end if;

  update public.devolucoes_loja
     set status = v_novo,
         observacao_admin = coalesce(nullif(trim(coalesce(p_observacao, '')), ''), observacao_admin),
         atualizado_em = now()
   where id = p_devolucao;

  if d.usuario_id is not null then
    perform privado.notificar(array[d.usuario_id], 'Atualização da sua devolução',
                              'Sua solicitação de devolução mudou de situação. Veja em Meus pedidos.', null);
  end if;
  perform privado.auditar('devolucao_' || v_novo, 'devolucao', p_devolucao::text,
                          jsonb_build_object('de', d.status, 'para', v_novo));
end;
$$;

-- Passo 1 do reembolso: confere e devolve os dados para a Edge Function chamar o Mercado Pago.
create or replace function public.preparar_reembolso_loja(p_devolucao uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  d public.devolucoes_loja%rowtype;
  p public.pedidos%rowtype;
begin
  if not privado.eh_admin() then
    raise exception 'Apenas administradores.';
  end if;

  select * into d from public.devolucoes_loja where id = p_devolucao;
  if not found then
    raise exception 'Pedido de devolução não encontrado.';
  end if;
  if d.tipo = 'troca' then
    raise exception 'Troca não gera reembolso. Crie um novo pedido para o cooperado.';
  end if;
  if d.status not in ('aprovada', 'recebida') then
    raise exception 'Só é possível reembolsar devolução aprovada ou recebida.';
  end if;

  select * into p from public.pedidos where id = d.pedido_id;
  if p.mp_pagamento_id is null or p.mp_status is distinct from 'approved' then
    raise exception 'Este pedido não tem pagamento aprovado no Mercado Pago. Reembolse pelo painel do Mercado Pago e registre na observação.';
  end if;

  return jsonb_build_object('pagamento_id', p.mp_pagamento_id, 'valor_centavos', p.total_centavos);
end;
$$;

-- Passo 2 do reembolso: a Edge Function registra o resultado (só o servidor chama).
create or replace function public.confirmar_reembolso_loja(p_devolucao uuid, p_ok boolean, p_refund text, p_erro text default null)
returns void
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  d public.devolucoes_loja%rowtype;
begin
  select * into d from public.devolucoes_loja where id = p_devolucao for update;
  if not found then
    return;
  end if;

  if p_ok then
    update public.devolucoes_loja dv
       set status = 'reembolsada',
           valor_reembolso_centavos = (select pe.total_centavos from public.pedidos pe where pe.id = dv.pedido_id),
           mp_refund_id = p_refund,
           atualizado_em = now()
     where dv.id = p_devolucao;

    if d.usuario_id is not null then
      perform privado.notificar(array[d.usuario_id], 'Reembolso feito',
                                'Seu reembolso foi enviado pelo Mercado Pago. O prazo para aparecer depende do seu banco ou cartão.', null);
    end if;
    perform privado.auditar('devolucao_reembolsada', 'devolucao', p_devolucao::text, jsonb_build_object('refund', p_refund));
  else
    update public.devolucoes_loja
       set observacao_admin = left('Reembolso não concluído: ' || coalesce(p_erro, 'erro desconhecido'), 500),
           atualizado_em = now()
     where id = p_devolucao;
    perform privado.auditar('devolucao_reembolso_erro', 'devolucao', p_devolucao::text, jsonb_build_object('erro', p_erro));
  end if;
end;
$$;

-- =====================================================================
-- 3. RELATÓRIOS (administrador)
-- Conta pedidos pagos no período (sem cancelados e expirados).
-- =====================================================================
create or replace function public.relatorio_loja(p_inicio timestamptz, p_fim timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, privado
as $$
begin
  if not privado.eh_admin() then
    raise exception 'Apenas administradores.';
  end if;

  return (
    with vendas as (
      select p.* from public.pedidos p
       where p.pago_em is not null and p.pago_em >= p_inicio and p.pago_em < p_fim
         and p.status not in ('cancelado', 'expirado')
    )
    select jsonb_build_object(
      'pedidos', (select count(*) from vendas),
      'faturamento_centavos', coalesce((select sum(total_centavos) from vendas), 0),
      'produtos_centavos', coalesce((select sum(subtotal_centavos) from vendas), 0),
      'frete_centavos', coalesce((select sum(frete_centavos) from vendas), 0),
      'descontos_centavos', coalesce((select sum(desconto_centavos) from vendas), 0),
      'ticket_medio_centavos', coalesce((select round(avg(total_centavos))::integer from vendas), 0),
      'por_entrega', coalesce((select jsonb_object_agg(x.metodo, x.qtd)
                                 from (select metodo_entrega as metodo, count(*) as qtd from vendas group by 1) x), '{}'::jsonb),
      'devolucoes', (select count(*) from public.devolucoes_loja d
                      where d.status = 'reembolsada' and d.atualizado_em >= p_inicio and d.atualizado_em < p_fim),
      'reembolsado_centavos', coalesce((select sum(d.valor_reembolso_centavos) from public.devolucoes_loja d
                      where d.status = 'reembolsada' and d.atualizado_em >= p_inicio and d.atualizado_em < p_fim), 0),
      'mais_vendidos', coalesce((select jsonb_agg(x order by x.quantidade desc)
                                   from (select i.produto_id, max(i.nome_snapshot) as nome,
                                                sum(i.quantidade) as quantidade,
                                                sum(i.quantidade * i.preco_unitario_centavos) as valor_centavos
                                           from public.pedido_itens i
                                           join vendas v on v.id = i.pedido_id
                                          group by i.produto_id
                                          order by sum(i.quantidade) desc
                                          limit 10) x), '[]'::jsonb)
    )
  );
end;
$$;

-- =====================================================================
-- 4. PERMISSÕES
-- =====================================================================
revoke all on function public.avancar_pedido_loja(uuid, text) from public, anon;
grant execute on function public.avancar_pedido_loja(uuid, text) to authenticated;

revoke all on function public.solicitar_devolucao_loja(uuid, text, text) from public, anon;
grant execute on function public.solicitar_devolucao_loja(uuid, text, text) to authenticated;

revoke all on function public.decidir_devolucao_loja(uuid, text, text) from public, anon;
grant execute on function public.decidir_devolucao_loja(uuid, text, text) to authenticated;

revoke all on function public.preparar_reembolso_loja(uuid) from public, anon;
grant execute on function public.preparar_reembolso_loja(uuid) to authenticated;

revoke all on function public.confirmar_reembolso_loja(uuid, boolean, text, text) from public, anon, authenticated;
grant execute on function public.confirmar_reembolso_loja(uuid, boolean, text, text) to service_role;

revoke all on function public.relatorio_loja(timestamptz, timestamptz) from public, anon;
grant execute on function public.relatorio_loja(timestamptz, timestamptz) to authenticated;
