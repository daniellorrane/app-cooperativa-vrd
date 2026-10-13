// Calcula as opções de entrega de um carrinho para um CEP.
// Opções: retirada na cooperativa, entrega local (taxa fixa, CEPs configurados) e
// transportadoras pelo Melhor Envio (Correios e outras). O resultado fica guardado no servidor
// (cotacoes_frete) para o pedido usar o valor exato que foi cotado.
// Chamada pelo app com o login do cooperado.
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const VALIDADE_MINUTOS = 15;

Deno.serve(async (req) => {
  const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

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

  const cooperado = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: req.headers.get("authorization") ?? "" } },
    auth: { persistSession: false },
  });
  const { data: { user } } = await cooperado.auth.getUser();
  if (!user) return json(401, { erro: "Entre no aplicativo para continuar." });

  const corpo = await req.json().catch(() => null);
  const cep = String(corpo?.cep ?? "").replace(/\D/g, "");
  if (!/^\d{8}$/.test(cep)) return json(400, { erro: "Informe um CEP válido, com 8 números." });

  const { data: itens } = await cooperado.from("carrinho_itens")
    .select("produto_id, quantidade, produto:loja_produtos(id, nome, preco_centavos, preco_promo_centavos, ativo, estoque, peso_g, altura_cm, largura_cm, comprimento_cm)")
    .order("produto_id");
  if (!(itens ?? []).length) return json(409, { erro: "Seu carrinho está vazio." });
  // Produto inativo some para o cooperado (RLS): conta como indisponível, para a assinatura bater com o banco.
  if ((itens ?? []).some((i) => !i.produto || !i.produto.ativo || i.produto.estoque < i.quantidade)) {
    return json(409, { erro: "Há produtos indisponíveis no carrinho. Revise antes de calcular a entrega." });
  }

  const linhasCarrinho = itens!.map((i) => ({ ...i, produto: i.produto! }));
  const opcoes: Array<Record<string, unknown>> = [];

  // 1. Retirada na cooperativa: sempre disponível, sem custo.
  opcoes.push({ id: "retirada", nome: "Retirada na cooperativa", metodo: "retirada", preco_centavos: 0, prazo_dias: 0 });

  // 2. Entrega local: taxa fixa para os CEPs configurados (5 primeiros dígitos).
  const prefixosLocais = (conf.entrega_local_ceps ?? "").split(",").map((p) => p.trim()).filter(Boolean);
  if (conf.entrega_local_ativa === "sim" && prefixosLocais.includes(cep.slice(0, 5))) {
    opcoes.push({
      id: "entrega-local",
      nome: "Entrega local",
      metodo: "entrega_local",
      preco_centavos: Math.max(0, parseInt(conf.taxa_entrega_local_centavos || "0", 10) || 0),
      prazo_dias: 1,
    });
  }

  // 3. Transportadoras pelo Melhor Envio (Correios e outras), quando configurado.
  const { data: tokenME } = await admin.rpc("ler_segredo_loja", { p_nome: "melhor_envio_token" });
  if (tokenME) {
    if (!/^\d{8}$/.test(conf.cep_origem ?? "")) {
      return json(503, { erro: "A loja ainda não tem o CEP de origem configurado." });
    }
    const semMedidas = linhasCarrinho.filter((i) =>
      !i.produto.peso_g || !i.produto.altura_cm || !i.produto.largura_cm || !i.produto.comprimento_cm);
    if (semMedidas.length) {
      return json(409, {
        erro: `Faltam peso e medidas nestes produtos: ${semMedidas.map((i) => i.produto.nome).join(", ")}. Peça à cooperativa para completar o cadastro.`,
      });
    }

    const base = conf.melhor_envio_sandbox === "sim"
      ? "https://sandbox.melhorenvio.com.br"
      : "https://melhorenvio.com.br";

    const resposta = await fetch(`${base}/api/v2/me/shipment/calculate`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${tokenME}`,
        Accept: "application/json",
        "Content-Type": "application/json",
        "User-Agent": `Loja ${conf.nome_loja || "Cooperativa"}`,
      },
      body: JSON.stringify({
        from: { postal_code: conf.cep_origem },
        to: { postal_code: cep },
        products: linhasCarrinho.map((i) => ({
          id: i.produto_id,
          width: i.produto.largura_cm,
          height: i.produto.altura_cm,
          length: i.produto.comprimento_cm,
          weight: i.produto.peso_g / 1000,
          insurance_value: (i.produto.preco_promo_centavos ?? i.produto.preco_centavos) / 100,
          quantity: i.quantidade,
        })),
        options: { receipt: false, own_hand: false },
      }),
    });

    if (!resposta.ok) {
      console.error("Melhor Envio recusou a cotação", resposta.status, await resposta.text());
      return json(502, { erro: "Não foi possível calcular o frete agora. Tente de novo em instantes." });
    }
    const servicos = await resposta.json().catch(() => []);
    for (const s of Array.isArray(servicos) ? servicos : []) {
      if (s.error) continue;
      const preco = Number(s.custom_price ?? s.price);
      if (!Number.isFinite(preco)) continue;
      const nome = [s.company?.name, s.name].filter(Boolean).join(" ").trim() || "Transportadora";
      opcoes.push({
        id: `me-${s.id}`,
        nome,
        metodo: "transportadora",
        preco_centavos: Math.round(preco * 100),
        prazo_dias: Number(s.custom_delivery_time ?? s.delivery_time) || 0,
      });
    }
  }

  // Guarda a cotação no servidor. O pedido só aceita opções daqui.
  const assinatura = linhasCarrinho
    .map((i) => `${i.produto_id}:${i.quantidade}`)
    .sort()
    .join(",");
  const expiraEm = new Date(Date.now() + VALIDADE_MINUTOS * 60_000).toISOString();
  const { data: cotacao, error } = await admin.from("cotacoes_frete").insert({
    usuario_id: user.id,
    cep,
    carrinho_assinatura: assinatura,
    opcoes,
    expira_em: expiraEm,
  }).select("id").single();
  if (error) {
    console.error("Falha ao guardar cotação", error.message);
    return json(500, { erro: "Não foi possível calcular a entrega agora." });
  }

  return json(200, {
    cotacao_id: cotacao.id,
    expira_em: expiraEm,
    opcoes: opcoes.map(({ id, nome, metodo, preco_centavos, prazo_dias }) => ({ id, nome, metodo, preco_centavos, prazo_dias })),
  });
});
