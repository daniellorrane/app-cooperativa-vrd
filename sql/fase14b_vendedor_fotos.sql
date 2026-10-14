-- Fase 14 (complemento): vendedor aprovado envia e troca fotos dos próprios produtos.
-- Regra: a pasta da foto é o id do produto. Vendedor só mexe em pasta de produto dele,
-- ou em pasta de produto novo (o produto ainda não existe no momento do envio).
-- Rode no SQL Editor do Supabase e responda "feito".

-- 0. Verificação
do $$
begin
  if to_regprocedure('privado.vendedor_do_usuario()') is null then
    raise exception 'Fase 13 não encontrada. Aplique a fase 13 antes desta.';
  end if;
end $$;

-- 1. Regra de acesso à pasta da foto
create or replace function privado.pode_gerir_foto(p_pasta text)
returns boolean language sql stable security definer set search_path = public, privado as $$
  select privado.eh_admin()
      or (
        privado.vendedor_do_usuario() is not null
        and (
          not exists (select 1 from public.loja_produtos p where p.id::text = p_pasta)
          or exists (
            select 1 from public.loja_produtos p
             where p.id::text = p_pasta and p.vendedor_id = privado.vendedor_do_usuario()
          )
        )
      )
$$;

-- 2. Políticas do bucket loja-fotos para vendedor (somam-se às políticas de administrador)
drop policy if exists loja_fotos_vendedor_enviar on storage.objects;
create policy loja_fotos_vendedor_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'loja-fotos' and privado.pode_gerir_foto((storage.foldername(name))[1]));

drop policy if exists loja_fotos_vendedor_trocar on storage.objects;
create policy loja_fotos_vendedor_trocar on storage.objects for update to authenticated
  using (bucket_id = 'loja-fotos' and privado.pode_gerir_foto((storage.foldername(name))[1]))
  with check (bucket_id = 'loja-fotos' and privado.pode_gerir_foto((storage.foldername(name))[1]));

drop policy if exists loja_fotos_vendedor_apagar on storage.objects;
create policy loja_fotos_vendedor_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'loja-fotos' and privado.pode_gerir_foto((storage.foldername(name))[1]));
