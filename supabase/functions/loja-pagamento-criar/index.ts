// Cria a preferência de pagamento no Mercado Pago (Checkout Pro) para um pedido aguardando pagamento.
// Chamada pelo app com o login do cooperado. Só cria pagamento para pedido dele, ainda no prazo.
// O valor é lido do banco (pedido_itens), nunca enviado pelo navegador.
// Segredos: o token do Mercado Pago fica no Supabase Vault (configurado pelo administrador no app).
import { createClient } from "npm:@supabase/supabase-js@2";

const MP = "https://api.mercadopago.com";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const UUID = /^[0-9a-f-]{36}$/i;

Deno.serve(async (req) => {
  const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

  // Configuração pública (URL do app) define de onde o navegador pode chamar esta função.
  const { data: linhas } = await admin.from("loja_configuracoes").select("chave, valor");
  const conf: Record<string, string> = Object.fromEntries((linhas ?? []).map((l) => [l.chave, l.valor]));
  let appOrigem = "";
  try { appOrigem = new URL(conf.url_publica_app ?? "").origin; } catch (_) { /* não configurado */ }

  const cabecalhos = {
    "Access-Control-Allow-Origin": req.headers.get("origin") === appOrigem ? appOrigem : appOrigem || "null",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
  const json = (status: number, corpo: unknown) =>
    new Response(JSON.stringify(corpo), { status, headers: { ...cabecalhos, "Content-Type": "application/json" } });

  if (req.method === "OPTIONS") return new Response(null, { headers: cabecalhos });
  if (req.method !== "POST") return json(405, { erro: "Método não permitido." });

  // Quem chama precisa estar logado. O banco aplica as regras (RLS) com o login dele.
  const cooperado = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: req.headers.get("authorization") ?? "" } },
    auth: { persistSession: false },
  });
  const { data: { user } } = await cooperado.auth.getUser();
  if (!user) return json(401, { erro: "Entre no aplicativo para continuar." });

  const corpo = await req.json().catch(() => null);
  const pedidoId = String(corpo?.pedido_id ?? "");
  if (!UUID.test(pedidoId)) return json(400, { erro: "Pedido inválido." });

  const { data: pedido } = await cooperado.from("pedidos")
    .select("id, status, total_centavos, expira_em")
    .eq("id", pedidoId).maybeSingle();
  if (!pedido) return json(404, { erro: "Pedido não encontrado." });
  if (pedido.status !== "aguardando_pagamento") {
    return json(409, { erro: "Este pedido não está mais aguardando pagamento." });
  }
  if (new Date(pedido.expira_em).getTime() <= Date.now()) {
    return json(409, { erro: "O prazo deste pedido acabou. Monte o pedido de novo pelo carrinho." });
  }

  const { data: itens } = await cooperado.from("pedido_itens")
    .select("produto_id, nome_snapshot, preco_unitario_centavos, quantidade")
    .eq("pedido_id", pedidoId);
  if (!itens?.length) return json(409, { erro: "Este pedido não tem itens." });

  const { data: token } = await admin.rpc("ler_segredo_loja", { p_nome: "mp_access_token" });
  if (!token) {
    return json(503, { erro: "O pagamento ainda não foi configurado pelo administrador da loja." });
  }
  if (!appOrigem) {
    return json(503, { erro: "A loja ainda não tem o endereço do aplicativo configurado." });
  }

  const preferencia = {
    items: itens.map((i) => ({
      id: i.produto_id ?? "item",
      title: String(i.nome_snapshot).slice(0, 250),
      quantity: i.quantidade,
      unit_price: i.preco_unitario_centavos / 100,
      currency_id: "BRL",
    })),
    external_reference: pedido.id,
    notification_url: `${SUPABASE_URL}/functions/v1/loja-pagamento-webhook`,
    // O retorno fica na parte de consulta (antes do #), para o Mercado Pago poder acrescentar os dados dele.
    back_urls: {
      success: `${appOrigem}/?retorno=${pedido.id}#loja/pedido/${pedido.id}`,
      pending: `${appOrigem}/?retorno=${pedido.id}#loja/pedido/${pedido.id}`,
      failure: `${appOrigem}/?retorno=${pedido.id}#loja/pedido/${pedido.id}`,
    },
    auto_return: "approved",
    expires: true,
    expiration_date_to: new Date(pedido.expira_em).toISOString(),
  };

  const resposta = await fetch(`${MP}/checkout/preferences`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "X-Idempotency-Key": `pedido-${pedido.id}`,
    },
    body: JSON.stringify(preferencia),
  });
  const dados = await resposta.json().catch(() => ({}));
  if (!resposta.ok || !dados.init_point) {
    console.error("Mercado Pago recusou a preferência", resposta.status, JSON.stringify(dados));
    return json(502, { erro: "O Mercado Pago não aceitou o pagamento agora. Tente de novo em instantes." });
  }

  await admin.rpc("registrar_preferencia_loja", { p_pedido: pedido.id, p_preferencia: String(dados.id) });
  return json(200, { init_point: dados.init_point });
});
