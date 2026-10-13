// Recebe as notificações de pagamento do Mercado Pago.
// 1. Confere a assinatura (x-signature) com a chave secreta do webhook (guardada no Vault).
// 2. Consulta o pagamento na API do Mercado Pago. Não confia só no corpo da notificação.
// 3. Confirma o pedido no banco (idempotente).
// Esta função é pública (o Mercado Pago não envia login), por isso a assinatura é obrigatória.
import { createClient } from "npm:@supabase/supabase-js@2";

const MP = "https://api.mercadopago.com";
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

async function hmacHex(segredo: string, mensagem: string): Promise<string> {
  const chave = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(segredo), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const assinatura = await crypto.subtle.sign("HMAC", chave, new TextEncoder().encode(mensagem));
  return [...new Uint8Array(assinatura)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Comparação em tempo constante, para não vazar a assinatura por tempo de resposta.
function iguais(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diferenca = 0;
  for (let i = 0; i < a.length; i++) diferenca |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diferenca === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Método não permitido", { status: 405 });

  const url = new URL(req.url);
  const dataId = (url.searchParams.get("data.id") ?? "").toLowerCase();
  const tipo = url.searchParams.get("type") ?? url.searchParams.get("topic") ?? "";
  const requestId = req.headers.get("x-request-id") ?? "";
  const assinatura = req.headers.get("x-signature") ?? "";

  const partes: Record<string, string> = Object.fromEntries(
    assinatura.split(",").map((p) => p.trim().split("=")).filter((p) => p.length === 2),
  );
  const { ts, v1 } = partes;
  if (!ts || !v1 || !dataId) return new Response("Requisição inválida", { status: 400 });

  const { data: segredo } = await admin.rpc("ler_segredo_loja", { p_nome: "mp_webhook_secret" });
  const { data: token } = await admin.rpc("ler_segredo_loja", { p_nome: "mp_access_token" });
  if (!segredo || !token) {
    // 503 faz o Mercado Pago tentar de novo mais tarde, depois que o administrador configurar.
    return new Response("Pagamentos não configurados", { status: 503 });
  }

  const manifesto = `id:${dataId};request-id:${requestId};ts:${ts};`;
  if (!iguais(await hmacHex(segredo, manifesto), v1)) {
    return new Response("Assinatura inválida", { status: 401 });
  }

  if (tipo !== "payment") return new Response("Evento ignorado", { status: 200 });

  const resposta = await fetch(`${MP}/v1/payments/${dataId}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!resposta.ok) return new Response("Não foi possível consultar o pagamento", { status: 502 });
  const pagamento = await resposta.json();

  const pedidoId = pagamento.external_reference;
  if (!pedidoId) return new Response("Pagamento sem pedido", { status: 200 });

  const { data: resultado, error } = await admin.rpc("confirmar_pagamento_loja", {
    p_pedido: pedidoId,
    p_pagamento: String(pagamento.id),
    p_status: pagamento.status,
    p_valor_centavos: Math.round(Number(pagamento.transaction_amount ?? 0) * 100),
  });
  if (error) {
    console.error("Falha ao confirmar pagamento", error.message);
    return new Response("Falha ao registrar", { status: 500 });
  }
  return new Response(JSON.stringify({ resultado }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
