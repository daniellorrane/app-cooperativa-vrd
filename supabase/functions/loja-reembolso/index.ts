// Reembolsa um pedido de devolução pelo Mercado Pago (reembolso total do pagamento).
// Chamada pelo app com o login do administrador. O banco confere se ele é administrador e se a devolução
// está em situação de reembolso. O token fica no Supabase Vault (configurado pelo administrador no app).
// Idempotência: a chave é "devolucao-<id>", então um duplo clique não reembolsa duas vezes.
import { createClient } from "npm:@supabase/supabase-js@2";

const MP = "https://api.mercadopago.com";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const UUID = /^[0-9a-f-]{36}$/i;

Deno.serve(async (req) => {
  const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

  const { data: linhas } = await admin.from("loja_configuracoes").select("chave, valor").eq("chave", "url_publica_app");
  let appOrigem = "";
  try { appOrigem = new URL(linhas?.[0]?.valor ?? "").origin; } catch (_) { /* não configurado */ }

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

  const cooperado = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: req.headers.get("authorization") ?? "" } },
    auth: { persistSession: false },
  });
  const { data: { user } } = await cooperado.auth.getUser();
  if (!user) return json(401, { erro: "Entre no aplicativo para continuar." });

  const corpo = await req.json().catch(() => null);
  const devolucaoId = String(corpo?.devolucao_id ?? "");
  if (!UUID.test(devolucaoId)) return json(400, { erro: "Devolução inválida." });

  // Passo 1: o banco confere administrador, situação e pagamento aprovado.
  const { data: preparo, error: erroPreparo } = await cooperado.rpc("preparar_reembolso_loja", { p_devolucao: devolucaoId });
  if (erroPreparo) return json(409, { erro: erroPreparo.message });

  const { data: token } = await admin.rpc("ler_segredo_loja", { p_nome: "mp_access_token" });
  if (!token) return json(503, { erro: "O pagamento ainda não foi configurado pelo administrador da loja." });

  // Passo 2: pede o reembolso total no Mercado Pago.
  let refundId: string | null = null;
  let falha: string | null = null;
  try {
    const resposta = await fetch(`${MP}/v1/payments/${preparo.pagamento_id}/refunds`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
        "X-Idempotency-Key": `devolucao-${devolucaoId}`,
      },
      body: JSON.stringify({}),
    });
    const dados = await resposta.json().catch(() => ({}));
    if (resposta.ok && dados.id && dados.status === "approved") {
      refundId = String(dados.id);
    } else {
      console.error("Mercado Pago recusou o reembolso", resposta.status, JSON.stringify(dados));
      falha = "O Mercado Pago não aprovou o reembolso. Tente de novo ou faça pelo painel do Mercado Pago.";
    }
  } catch (erro) {
    console.error("Falha de rede no reembolso", String(erro));
    falha = "Não foi possível falar com o Mercado Pago agora. Tente de novo em instantes.";
  }

  // Passo 3: registra o resultado no banco (só o servidor pode fazer isso).
  await admin.rpc("confirmar_reembolso_loja", {
    p_devolucao: devolucaoId,
    p_ok: refundId !== null,
    p_refund: refundId,
    p_erro: falha,
  });

  if (!refundId) return json(502, { erro: falha });
  return json(200, { refund_id: refundId });
});
