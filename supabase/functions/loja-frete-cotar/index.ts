// Calcula as opções de entrega de um carrinho para um CEP, separadas por grupo.
// Cada grupo envia os próprios produtos: a cooperativa (produtos sem vendedor) e cada vendedor.
// Opções por grupo:
//   - retirada na cooperativa (só quando o carrinho é todo da cooperativa);
//   - entrega local (taxa fixa, CEPs configurados; só a cooperativa);
//   - transportadoras pelo Melhor Envio, cotadas a partir do CEP de origem do grupo.
// Frete grátis: se o subtotal do grupo atinge o mínimo (do vendedor, ou da cooperativa), as opções pagas saem por zero.
// O resultado fica guardado no servidor (cotacoes_frete). O pedido só aceita opções daqui.
// Chamada pelo app com o login do cooperado.
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const VALIDADE_MINUTOS = 15;
const CHAVE_COOPERATIVA = "coop";

type Produto = {
  id: string; nome: string; preco_centavos: number; preco_promo_centavos: number | null;
  ativo: boolean; estoque: number; peso_g: number | null; altura_cm: number | null;
  largura_cm: number | null; comprimento_cm: number | null; vendedor_id: string | null;
};
type Linha = { produto_id: string; quantidade: number; produto: Produto };
type Vendedor = { id: string; nome_loja: string; cep_origem: string | null; status: string; frete_gratis_minimo_centavos: number | null };

const precoUnitario = (p: Produto) => p.preco_promo_centavos ?? p.preco_centavos;

// Limite de frete grátis vindo da configuração (texto). Vazio ou inválido = sem frete grátis.
function limite(valor: unknown): number | null {
  if (valor === undefined || valor === null || valor === "") return null;
  const n = Number(valor);
  return Number.isFinite(n) && n >= 0 ? n : null;
}

Deno.serve(async (req) => {
  const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

  const { data: linhasConf } = await admin.from("loja_configuracoes").select("chave, valor");
  const conf: Record<string, string> = Object.fromEntries((linhasConf ?? []).map((l) => [l.chave, l.valor]));
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
    .select("produto_id, quantidade, produto:loja_produtos(id, nome, preco_centavos, preco_promo_centavos, ativo, estoque, peso_g, altura_cm, largura_cm, comprimento_cm, vendedor_id)")
    .order("produto_id");
  if (!(itens ?? []).length) return json(409, { erro: "Seu carrinho está vazio." });
  // Produto inativo some para o cooperado (RLS): conta como indisponível, para a assinatura bater com o banco.
  if ((itens ?? []).some((i) => !i.produto || !i.produto.ativo || i.produto.estoque < i.quantidade)) {
    return json(409, { erro: "Há produtos indisponíveis no carrinho. Revise antes de calcular a entrega." });
  }

  const linhas: Linha[] = itens!.map((i) => ({ ...i, produto: i.produto! }));

  // Grupos: cooperativa e cada vendedor
  const grupoDe = new Map<string, Linha[]>();
  for (const l of linhas) {
    const chave = l.produto.vendedor_id ?? CHAVE_COOPERATIVA;
    grupoDe.set(chave, [...(grupoDe.get(chave) ?? []), l]);
  }

  // Dados dos vendedores pelo service role (o cooperado não lê a tabela de vendedores)
  const idsVendedores = [...grupoDe.keys()].filter((k) => k !== CHAVE_COOPERATIVA);
  const vendedores = new Map<string, Vendedor>();
  if (idsVendedores.length) {
    const { data: lista } = await admin.from("loja_vendedores")
      .select("id, nome_loja, cep_origem, status, frete_gratis_minimo_centavos")
      .in("id", idsVendedores);
    for (const v of (lista ?? []) as Vendedor[]) vendedores.set(v.id, v);
  }

  const { data: tokenME } = await admin.rpc("ler_segredo_loja", { p_nome: "melhor_envio_token" });
  const baseME = conf.melhor_envio_sandbox === "sim"
    ? "https://sandbox.melhorenvio.com.br"
    : "https://melhorenvio.com.br";
  const apenasCooperativa = grupoDe.size === 1 && grupoDe.has(CHAVE_COOPERATIVA);

  const grupos: Array<Record<string, unknown>> = [];

  for (const [chave, itensDoGrupo] of grupoDe) {
    const coop = chave === CHAVE_COOPERATIVA;
    const vendedor = coop ? null : vendedores.get(chave);
    if (!coop && (!vendedor || vendedor.status !== "aprovado")) {
      return json(409, { erro: "Há produtos de um vendedor que não está disponível agora. Revise o carrinho." });
    }
    const nome = coop ? "Cooperativa" : vendedor!.nome_loja;
    const subtotal = itensDoGrupo.reduce((soma, l) => soma + l.quantidade * precoUnitario(l.produto), 0);
    const minimoGratis = coop ? limite(conf.frete_gratis_minimo_centavos) : limite(vendedor!.frete_gratis_minimo_centavos);
    const gratis = minimoGratis !== null && subtotal >= minimoGratis;

    const opcoes: Array<Record<string, unknown>> = [];

    // 1. Retirada na cooperativa: só quando o carrinho é todo da cooperativa. Sem custo.
    if (coop && apenasCooperativa) {
      opcoes.push({ id: "retirada", nome: "Retirada na cooperativa", metodo: "retirada", preco_centavos: 0, prazo_dias: 0 });
    }

    // 2. Entrega local: taxa fixa para os CEPs configurados (5 primeiros dígitos). Só a cooperativa.
    if (coop) {
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
    }

    // 3. Transportadoras pelo Melhor Envio, a partir do CEP de origem do grupo.
    if (tokenME) {
      const origem = coop ? conf.cep_origem : vendedor!.cep_origem;
      if (!/^\d{8}$/.test(origem ?? "")) {
        return json(409, {
          erro: coop
            ? "A loja ainda não tem o CEP de origem configurado."
            : `${nome} ainda não informou o CEP de onde saem os produtos. Peça ao vendedor para completar o cadastro da loja.`,
        });
      }
      const semMedidas = itensDoGrupo.filter((l) =>
        !l.produto.peso_g || !l.produto.altura_cm || !l.produto.largura_cm || !l.produto.comprimento_cm);
      if (semMedidas.length) {
        return json(409, {
          erro: `Faltam peso e medidas nestes produtos: ${semMedidas.map((l) => l.produto.nome).join(", ")}. Peça à cooperativa ou ao vendedor para completar o cadastro.`,
        });
      }

      const resposta = await fetch(`${baseME}/api/v2/me/shipment/calculate`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${tokenME}`,
          Accept: "application/json",
          "Content-Type": "application/json",
          "User-Agent": `Loja ${conf.nome_loja || "Cooperativa"}`,
        },
        body: JSON.stringify({
          from: { postal_code: origem },
          to: { postal_code: cep },
          products: itensDoGrupo.map((l) => ({
            id: l.produto_id,
            width: l.produto.largura_cm,
            height: l.produto.altura_cm,
            length: l.produto.comprimento_cm,
            weight: l.produto.peso_g! / 1000,
            insurance_value: precoUnitario(l.produto) / 100,
            quantity: l.quantidade,
          })),
          options: { receipt: false, own_hand: false },
        }),
      });

      if (!resposta.ok) {
        console.error("Melhor Envio recusou a cotação", chave, resposta.status, await resposta.text());
        return json(502, { erro: "Não foi possível calcular o frete agora. Tente de novo em instantes." });
      }
      const servicos = await resposta.json().catch(() => []);
      for (const s of Array.isArray(servicos) ? servicos : []) {
        if (s.error) continue;
        const preco = Number(s.custom_price ?? s.price);
        if (!Number.isFinite(preco)) continue;
        const nomeServico = [s.company?.name, s.name].filter(Boolean).join(" ").trim() || "Transportadora";
        opcoes.push({
          id: `me-${s.id}`,
          nome: nomeServico,
          metodo: "transportadora",
          preco_centavos: Math.round(preco * 100),
          prazo_dias: Number(s.custom_delivery_time ?? s.delivery_time) || 0,
        });
      }
    }

    if (!opcoes.length) {
      return json(409, { erro: `Não há forma de entrega disponível para ${nome} neste CEP.` });
    }

    // Frete grátis do grupo: as opções pagas viram zero. Quem envia arca com o custo fora do extrato.
    for (const o of opcoes) {
      o.gratis = gratis;
      if (gratis) o.preco_centavos = 0;
    }

    grupos.push({
      chave,
      vendedor_id: coop ? null : chave,
      nome,
      subtotal_centavos: subtotal,
      gratis,
      itens: itensDoGrupo.map((l) => ({ nome: l.produto.nome, quantidade: l.quantidade })),
      opcoes,
    });
  }

  // Guarda a cotação no servidor. O pedido só aceita opções daqui.
  const assinatura = linhas
    .map((l) => `${l.produto_id}:${l.quantidade}`)
    .sort()
    .join(",");
  const expiraEm = new Date(Date.now() + VALIDADE_MINUTOS * 60_000).toISOString();
  const { data: cotacao, error } = await admin.from("cotacoes_frete").insert({
    usuario_id: user.id,
    cep,
    carrinho_assinatura: assinatura,
    grupos,
    expira_em: expiraEm,
  }).select("id").single();
  if (error) {
    console.error("Falha ao guardar cotação", error.message);
    return json(500, { erro: "Não foi possível calcular a entrega agora." });
  }

  return json(200, {
    cotacao_id: cotacao.id,
    expira_em: expiraEm,
    grupos: grupos.map((g) => ({
      chave: g.chave,
      nome: g.nome,
      subtotal_centavos: g.subtotal_centavos,
      gratis: g.gratis,
      itens: g.itens,
      opcoes: (g.opcoes as Array<Record<string, unknown>>).map(({ id, nome, metodo, preco_centavos, prazo_dias, gratis }) =>
        ({ id, nome, metodo, preco_centavos, prazo_dias, gratis })),
    })),
  });
});
