-- Fase 14: marketplace, telas e bloqueios.
-- 1. Fecha a execução anônima das funções novas (todas checam login e administrador por dentro).
-- 2. Vitrine e recomendações deixam de mostrar produtos de vendedor suspenso ou recusado.
-- 3. Pedido não aceita produto de vendedor que não esteja aprovado.
-- Rode no SQL Editor do Supabase e responda "feito".

-- 0. Verificação: fase 13 aplicada
do $$
begin
  if to_regprocedure('privado.vendedor_aprovado(uuid)') is null
     or to_regclass('public.loja_vendedores') is null then
    raise exception 'Fase 13 não encontrada. Aplique a fase 13 antes desta.';
  end if;
end $$;

-- 1. Permissões: visitante sem login não chama as funções do marketplace
revoke execute on function public.cadastrar_vendedor_loja(text, text, text, text) from anon, public;
revoke execute on function public.decidir_vendedor_loja(uuid, text) from anon, public;
revoke execute on function public.definir_comissao_vendedor_loja(uuid, numeric) from anon, public;
revoke execute on function public.salvar_segredo_entrega_loja(text, text, text) from anon, public;
revoke execute on function public.salvar_provedor_entrega_loja(text, boolean, text, jsonb) from anon, public;
grant execute on function public.cadastrar_vendedor_loja(text, text, text, text) to authenticated;
grant execute on function public.decidir_vendedor_loja(uuid, text) to authenticated;
grant execute on function public.definir_comissao_vendedor_loja(uuid, numeric) to authenticated;
grant execute on function public.salvar_segredo_entrega_loja(text, text, text) to authenticated;
grant execute on function public.salvar_provedor_entrega_loja(text, boolean, text, jsonb) to authenticated;

-- 2. Vitrine: mesma função da fase 7, com o filtro de vendedor aprovado.
create or replace function public.vitrine_loja(p_categoria uuid default null, p_busca text default null)
returns table (
  id uuid, nome text, preco_centavos integer, preco_promo_centavos integer, imagem_caminho text,
  estoque integer, categoria_id uuid, categoria_nome text, media numeric, avaliacoes bigint,
  favorito boolean, tem_variacoes boolean
)
language sql stable security definer set search_path = public, privado
as $$
  select p.id, p.nome,
         coalesce(v.minimo, p.preco_centavos),
         case when coalesce(v.total, 0) = 0 then p.preco_promo_centavos end,
         p.imagem_caminho,
         case when coalesce(v.total, 0) = 0 then p.estoque else coalesce(v.estoque_total, 0)::integer end,
         p.categoria_id, c.nome,
         r.media, coalesce(r.total, 0),
         exists (select 1 from public.favoritos f where f.produto_id = p.id and f.usuario_id = auth.uid()),
         coalesce(v.total, 0) > 0
    from public.loja_produtos p
    left join public.loja_categorias c on c.id = p.categoria_id
    left join lateral (
      select round(avg(a.nota)::numeric, 1) as media, count(*) as total
        from public.avaliacoes_produto a
       where a.produto_id = p.id and a.status = 'publicada'
    ) r on true
    left join lateral (
      select count(*) as total,
             min(coalesce(c2.preco_promo_centavos, c2.preco_centavos)) filter (where c2.ativo) as minimo,
             sum(c2.estoque) filter (where c2.ativo) as estoque_total
        from public.loja_produtos c2
       where c2.variacao_de = p.id
    ) v on true
   where p.variacao_de is null
     and p.ativo
     and privado.usuario_aprovado()
     and (p.vendedor_id is null or privado.vendedor_aprovado(p.vendedor_id))
     and (p_categoria is null or p.categoria_id = p_categoria)
     and (p_busca is null or length(trim(p_busca)) = 0
          or p.nome ilike '%' || replace(replace(trim(p_busca), '%', ''), '_', '') || '%')
   order by p.nome
   limit 200;
$$;

-- 3. Recomendações: mesma função da fase 10, com o filtro de vendedor aprovado.
-- (corpo copiado da versão em produção; só muda a linha do vendedor)
create or replace function public.recomendados_para_mim()
returns table (
  id uuid, nome text, preco_centavos integer, preco_promo_centavos integer, imagem_caminho text,
  estoque integer, categoria_id uuid, categoria_nome text, media numeric, avaliacoes bigint,
  favorito boolean, motivo text, tem_variacoes boolean
)
language sql stable security definer set search_path = public, privado
as $$
  with categorias_favoritas as (
    select distinct p.categoria_id
      from public.favoritos f
      join public.loja_produtos p on p.id = f.produto_id
     where f.usuario_id = auth.uid() and p.categoria_id is not null
  ),
  categorias_compradas as (
    select distinct p.categoria_id
      from public.pedidos o
      join public.pedido_itens i on i.pedido_id = o.id
      join public.loja_produtos p on p.id = i.produto_id
     where o.usuario_id = auth.uid()
       and o.status not in ('cancelado', 'expirado')
       and p.categoria_id is not null
  ),
  indicados as (
    select i.produto_id
      from public.indicacoes_loja i
      join public.indicacoes_loja_aceites a on a.indicacao_id = i.id
     where a.usuario_id = auth.uid() and i.produto_id is not null
    union
    select li.produto_id
      from public.indicacoes_loja i
      join public.indicacoes_loja_aceites a on a.indicacao_id = i.id
      join public.lista_loja_itens li on li.lista_id = i.lista_id
     where a.usuario_id = auth.uid() and i.lista_id is not null
  )
  select p.id, p.nome,
         coalesce(v.minimo, p.preco_centavos),
         case when coalesce(v.total, 0) = 0 then p.preco_promo_centavos end,
         p.imagem_caminho,
         case when coalesce(v.total, 0) = 0 then p.estoque else coalesce(v.estoque_total, 0)::integer end,
         p.categoria_id, c.nome,
         r.media, coalesce(r.total, 0), false,
         case
           when exists (select 1 from indicados x where x.produto_id = p.id) then 'Indicado por um amigo'
           when p.categoria_id in (select cf.categoria_id from categorias_favoritas cf) then 'Parecido com o que você favoritou'
           when p.categoria_id in (select cc.categoria_id from categorias_compradas cc) then 'Parecido com o que você já comprou'
           when coalesce(r.media, 0) >= 4 then 'Muito bem avaliado pelos cooperados'
           else 'Novidade na loja'
         end,
         coalesce(v.total, 0) > 0
    from public.loja_produtos p
    left join public.loja_categorias c on c.id = p.categoria_id
    left join lateral (
      select round(avg(a.nota)::numeric, 1) as media, count(*) as total
        from public.avaliacoes_produto a
       where a.produto_id = p.id and a.status = 'publicada'
    ) r on true
    left join lateral (
      select count(*) as total,
             min(coalesce(c2.preco_promo_centavos, c2.preco_centavos)) filter (where c2.ativo) as minimo,
             sum(c2.estoque) filter (where c2.ativo) as estoque_total
        from public.loja_produtos c2
       where c2.variacao_de = p.id
    ) v on true
   where p.variacao_de is null
     and p.ativo
     and (p.estoque > 0 or coalesce(v.estoque_total, 0) > 0)
     and privado.usuario_aprovado()
     and (p.vendedor_id is null or privado.vendedor_aprovado(p.vendedor_id))
     and not exists (select 1 from public.favoritos f where f.produto_id = p.id and f.usuario_id = auth.uid())
   order by
     exists (select 1 from indicados x where x.produto_id = p.id) desc,
     (p.categoria_id in (select cf.categoria_id from categorias_favoritas cf)) desc,
     (p.categoria_id in (select cc.categoria_id from categorias_compradas cc)) desc,
     r.media desc nulls last,
     coalesce(r.total, 0) desc,
     p.nome
   limit 12;
$$;

-- 4. Pedido: nenhum item de vendedor que não esteja aprovado entra no pedido.
create or replace function privado.confere_vendedor_item()
returns trigger language plpgsql security definer set search_path = public, privado
as $$
declare v_vendedor uuid;
begin
  select p.vendedor_id into v_vendedor from public.loja_produtos p where p.id = new.produto_id;
  if v_vendedor is not null and not privado.vendedor_aprovado(v_vendedor) then
    raise exception 'Um produto deste pedido não está mais disponível. Retire-o do carrinho e tente de novo.';
  end if;
  return new;
end $$;

drop trigger if exists pedido_itens_confere_vendedor on public.pedido_itens;
create trigger pedido_itens_confere_vendedor
  before insert on public.pedido_itens
  for each row execute function privado.confere_vendedor_item();
