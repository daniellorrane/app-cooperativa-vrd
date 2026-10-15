-- Fase 18: envios por pedido no painel do administrador.
-- Cada parte do pedido (cooperativa ou vendedor) é marcada como enviada pelo próprio envio.
-- Quando todas as partes saem, o pedido vira "enviado" e o comprador é avisado.
-- Rastreio é obrigatório só em pedido de uma parte enviado por transportadora (em pedido com várias partes,
-- o método do pedido é "transportadora" mesmo quando uma parte é entrega local, então a regra não se aplica).
-- Rode no SQL Editor do Supabase e responda "feito".

-- 0. Verificação
do $$
begin
  if to_regprocedure('privado.sincroniza_envios_pedido()') is null
     or to_regprocedure('public.marcar_envio_vendedor_loja(uuid,text)') is null then
    raise exception 'Fase 16 (parte 2) não encontrada. Aplique a fase 16b antes desta.';
  end if;
end $$;

-- 1. Situação do pedido conforme as partes: quando todas saem, o pedido vira "enviado"
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
  v_prontos integer;
  v_rastreio text;
begin
  select p.status, p.metodo_entrega, p.usuario_id into v_status, v_metodo, v_usuario
    from public.pedidos p where p.id = p_pedido;
  if not found or v_status <> 'em_separacao' or v_metodo = 'retirada' then
    return;
  end if;

  select count(*),
         count(*) filter (where e.status in ('enviado', 'entregue')),
         max(e.codigo_rastreio)
    into v_total, v_prontos, v_rastreio
    from public.pedido_envios e
   where e.pedido_id = p_pedido and e.status <> 'cancelado';

  if v_total = 0 or v_total <> v_prontos then
    return;
  end if;

  -- Com uma parte só, o rastreio dela vai para o pedido. Com várias, cada parte mostra o próprio.
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
end;
$$;

-- 2. Administrador marca uma parte do pedido como enviada (cooperativa ou vendedor)
create or replace function public.marcar_envio_admin_loja(p_envio uuid, p_codigo text default null)
returns public.pedido_envios
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  v public.pedido_envios;
  v_pedido public.pedidos;
  v_codigo text := nullif(trim(coalesce(p_codigo, '')), '');
  v_partes integer;
begin
  if not privado.eh_admin() then
    raise exception 'Apenas administradores.';
  end if;
  if v_codigo is not null and char_length(v_codigo) > 60 then
    raise exception 'O código de rastreio tem no máximo 60 caracteres.';
  end if;

  select * into v from public.pedido_envios e where e.id = p_envio for update;
  if not found then
    raise exception 'Envio não encontrado.';
  end if;

  select * into v_pedido from public.pedidos p where p.id = v.pedido_id;
  if v_pedido.status <> 'em_separacao' or v_pedido.metodo_entrega = 'retirada' then
    raise exception 'Só pedidos em separação para entrega podem ter envios marcados como enviados.';
  end if;
  if v.status <> 'aguardando' then
    raise exception 'Este envio já foi marcado como enviado.';
  end if;

  select count(*) into v_partes from public.pedido_envios e
   where e.pedido_id = v.pedido_id and e.status <> 'cancelado';
  if v_partes = 1 and v_pedido.metodo_entrega = 'transportadora' and v_codigo is null then
    raise exception 'Informe o código de rastreio da transportadora.';
  end if;

  update public.pedido_envios e
     set status = 'enviado', enviado_em = now(), codigo_rastreio = coalesce(v_codigo, e.codigo_rastreio)
   where e.id = p_envio
  returning * into v;

  perform privado.auditar('envio_admin_marcado', 'pedido_envio', v.id::text,
                          jsonb_build_object('pedido', v.pedido_id, 'vendedor', v.vendedor_id is not null));
  perform privado.atualizar_situacao_por_envios(v.pedido_id);
  return v;
end;
$$;

-- 3. Envio do vendedor também atualiza a situação do pedido
create or replace function public.marcar_envio_vendedor_loja(p_envio uuid, p_codigo text)
returns public.pedido_envios
language plpgsql
security definer
set search_path = public, privado
as $$
declare
  v public.pedido_envios;
  v_codigo text := nullif(trim(coalesce(p_codigo, '')), '');
begin
  if v_codigo is null or char_length(v_codigo) > 60 then
    raise exception 'Informe o código de rastreio (até 60 caracteres).';
  end if;

  update public.pedido_envios e
     set status = 'enviado', codigo_rastreio = v_codigo, enviado_em = now()
   where e.id = p_envio
     and e.status = 'aguardando'
     and e.vendedor_id in (select x.id from public.loja_vendedores x where x.usuario_id = auth.uid() and x.status = 'aprovado')
  returning * into v;
  if v.id is null then
    raise exception 'Envio não encontrado, já enviado ou não é da sua loja.';
  end if;

  perform privado.auditar('envio_vendedor_marcado', 'pedido_envio', v.id::text, jsonb_build_object('pedido', v.pedido_id));
  perform privado.atualizar_situacao_por_envios(v.pedido_id);
  return v;
end;
$$;

-- 4. Permissões. A função antiga marcava o pedido inteiro como enviado, então sai de uso.
revoke execute on function public.marcar_envio_loja(uuid, text) from anon, authenticated, public;
revoke execute on function privado.atualizar_situacao_por_envios(uuid) from anon, authenticated, public;
revoke execute on function public.marcar_envio_admin_loja(uuid, text) from anon, public;
grant execute on function public.marcar_envio_admin_loja(uuid, text) to authenticated;
revoke execute on function public.marcar_envio_vendedor_loja(uuid, text) from anon, public;
grant execute on function public.marcar_envio_vendedor_loja(uuid, text) to authenticated;

-- 5. Verificação final
do $$
begin
  if to_regprocedure('public.marcar_envio_admin_loja(uuid,text)') is null then
    raise exception 'Função marcar_envio_admin_loja não criada.';
  end if;
  if has_function_privilege('anon', 'public.marcar_envio_admin_loja(uuid,text)', 'execute') then
    raise exception 'anon não pode executar marcar_envio_admin_loja.';
  end if;
  if has_function_privilege('authenticated', 'public.marcar_envio_loja(uuid,text)', 'execute') then
    raise exception 'marcar_envio_loja ainda está liberada.';
  end if;
end $$;
