// Recebe os avisos de etiqueta da Melhor Envio (webhook do aplicativo) e atualiza a situação da parte do pedido.
// Chamada pelo servidor da Melhor Envio, sem login. A assinatura (cabeçalho X-ME-Signature, HMAC-SHA256 do corpo,
// com a chave secreta do aplicativo guardada no Supabase Vault) é conferida antes de qualquer coisa.
// Um mesmo aviso repetido não muda nada: a chave do evento é o id da etiqueta, o tipo de evento e o hash do corpo.
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Eventos da Melhor Envio que mudam a situação da entrega. Os demais viram só histórico ou são ignorados.
const MAPA: Record<string, { status: string | null; data?: string; texto: string } | undefined> = {
  "order.posted": { status: "enviado", data: "posted_at", texto: "Postado na Melhor Envio" },
  "order.received": { status: "enviado", texto: "Recebido em ponto de postagem" },
  "order.delivered": { status: "entregue", data: "delivered_at", texto: "Entregue" },
  "order.undelivered": { status: "tentativa_falhou", texto: "Entrega não realizada" },
  "order.paused": { status: null, texto: "Entrega interrompida, aguardando ação do destinatário" },
  "order.suspended": { status: null, texto: "Encomenda suspensa" },
  "order.cancelled": { status: null, texto: "Etiqueta cancelada" },
};

const hex = (bytes: ArrayBuffer) => [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
const base64 = (bytes: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(bytes)));

// Comparação em tempo constante, para não vazar a assinatura pelo tempo de resposta
const iguais = (a: string, b: string) => {
  if (a.length !== b.length) return false;
  let diferenca = 0;
  for (let i = 0; i < a.length; i++) diferenca |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diferenca === 0;
};

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Método não permitido.", { status: 405 });

  const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
  const corpo = new Uint8Array(await req.arrayBuffer());

  const { data: segredo } = await admin.rpc("ler_segredo_loja", { p_nome: "melhor_envio_webhook_secret" });
  if (!segredo) return new Response("Webhook não configurado.", { status: 503 });

  const chave = await crypto.subtle.importKey("raw", new TextEncoder().encode(segredo), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const assinatura = await crypto.subtle.sign("HMAC", chave, corpo);
  const recebida = (req.headers.get("x-me-signature") ?? "").trim();
  // A codificação da assinatura (base64 ou hexadecimal) ainda será confirmada no sandbox. Aceita as duas, sem enfraquecer a conferência.
  const conferem = iguais(recebida, base64(assinatura)) || iguais(recebida.toLowerCase(), hex(assinatura));
  if (!recebida || !conferem) return new Response("Assinatura inválida.", { status: 401 });

  // deno-lint-ignore no-explicit-any
  let aviso: any;
  try {
    aviso = JSON.parse(new TextDecoder().decode(corpo));
  } catch (_) {
    return new Response("Corpo inválido.", { status: 400 });
  }

  const evento = String(aviso?.event ?? "");
  const etiqueta = aviso?.data ?? {};
  const regra = MAPA[evento];
  // Eventos sem regra (criação, pagamento, geração da etiqueta) não mudam a entrega
  if (!regra) return new Response(JSON.stringify({ ignorado: evento }), { status: 200, headers: { "Content-Type": "application/json" } });

  const codigo = String(etiqueta.tracking ?? "").trim();
  if (!codigo) return new Response(JSON.stringify({ ignorado: "sem código de rastreio" }), { status: 200, headers: { "Content-Type": "application/json" } });

  const { data: envio } = await admin.from("pedido_envios").select("id").eq("codigo_rastreio", codigo).limit(1).maybeSingle();
  if (!envio) return new Response(JSON.stringify({ ignorado: "envio não encontrado" }), { status: 200, headers: { "Content-Type": "application/json" } });

  const hashCorpo = hex(await crypto.subtle.digest("SHA-256", corpo)).slice(0, 24);
  const ocorrido = (regra.data && etiqueta[regra.data]) ? String(etiqueta[regra.data]) : new Date().toISOString();

  const { data: aplicado, error } = await admin.rpc("registrar_evento_envio_sistema", {
    p_envio: envio.id,
    p_status: regra.status,
    p_chave: `me:${etiqueta.id ?? codigo}:${evento}:${hashCorpo}`,
    p_descricao: regra.texto,
    p_origem: "melhor_envio",
    p_ocorrido: ocorrido,
  });
  if (error) {
    console.error("Falha ao registrar evento da Melhor Envio", error.message);
    return new Response("Erro ao registrar.", { status: 500 });
  }

  return new Response(JSON.stringify({ aplicado: aplicado === true }), { status: 200, headers: { "Content-Type": "application/json" } });
});
