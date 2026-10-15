// Emite, consulta e cancela a nota fiscal de um grupo do pedido pelo Focus NFe.
// Grupo: a cooperativa (vendedor_id ausente) ou um vendedor. A nota de cada vendedor sai pela conta de emissão dele.
// Chamada pelo app com o login do administrador. O banco confere o administrador, os dados fiscais e o pedido.
// Os tokens do Focus NFe ficam no Supabase Vault (focus_nfe_token da cooperativa; nf_vendedor_<id>_token de cada vendedor).
// A referência da nota é nova a cada tentativa (ver preparar_nota_loja), então nada é enviado duas vezes.
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const UUID = /^[0-9a-f-]{36}$/i;
const BASES: Record<string, string> = {
  homologacao: "https://homologacao.focusnfe.com.br",
  producao: "https://api.focusnfe.com.br",
};

type Estado = { status: "processando" | "autorizada" | "erro" | "cancelada"; numero?: string; chave?: string; danfe?: string; erro?: string };

const soDigitos = (valor: unknown) => String(valor ?? "").replace(/\D/g, "");
const reais = (centavos: number) => Number((centavos / 100).toFixed(2));

// Monta o corpo da NF-e no formato do Focus NFe. Os campos tributários vêm da tela de configuração.
// Validar em homologação antes de emitir nota real.
// deno-lint-ignore no-explicit-any
function montarNota(d: any) {
  const c = d.config;
  const simples = d.regime === "simples";
  const agora = new Date(Date.now() - 3 * 3600_000).toISOString().slice(0, 19) + "-03:00";
  const dest = d.destinatario;
  const e = dest.endereco;

  const destinatario: Record<string, unknown> = {
    nome_destinatario: String(dest.nome).slice(0, 60),
    indicador_inscricao_estadual_destinatario: "9",
  };
  if (dest.cpf) destinatario.cpf_destinatario = soDigitos(dest.cpf);
  if (dest.email) destinatario.email_destinatario = dest.email;
  if (dest.telefone) destinatario.telefone_destinatario = soDigitos(dest.telefone);
  if (e) {
    Object.assign(destinatario, {
      logradouro_destinatario: e.logradouro,
      numero_destinatario: e.numero,
      bairro_destinatario: e.bairro,
      municipio_destinatario: e.cidade,
      uf_destinatario: e.uf,
      cep_destinatario: soDigitos(e.cep),
    });
    if (e.complemento) destinatario.complemento_destinatario = e.complemento;
  }

  // deno-lint-ignore no-explicit-any
  const itens = d.itens.map((i: any, n: number) => {
    const bruto = reais(i.quantidade * i.valor_unitario_centavos);
    const item: Record<string, unknown> = {
      numero_item: String(n + 1),
      codigo_produto: i.produto_id,
      descricao: String(i.descricao).slice(0, 120),
      cfop: c.fiscal_cfop,
      ncm: i.ncm,
      unidade_comercial: i.unidade,
      quantidade_comercial: i.quantidade,
      valor_unitario_comercial: reais(i.valor_unitario_centavos),
      valor_bruto: bruto,
      unidade_tributavel: i.unidade,
      quantidade_tributavel: i.quantidade,
      valor_unitario_tributavel: reais(i.valor_unitario_centavos),
      icms_origem: c.fiscal_origem || "0",
      icms_situacao_tributaria: simples ? c.fiscal_csosn : c.fiscal_cst_icms,
      pis_situacao_tributaria: c.fiscal_cst_pis || "07",
      cofins_situacao_tributaria: c.fiscal_cst_cofins || "07",
    };
    // Tributação integral (CST 00) pede base e alíquota. Outras situações: o contador ajusta.
    if (!simples && c.fiscal_cst_icms === "00") {
      const aliquota = Number(String(c.fiscal_icms_aliquota).replace(",", "."));
      item.icms_modalidade_base_calculo = "3";
      item.icms_base_calculo = bruto;
      item.icms_aliquota = aliquota;
      item.icms_valor = Number((bruto * aliquota / 100).toFixed(2));
    }
    return item;
  });

  return {
    natureza_operacao: c.fiscal_natureza_operacao,
    data_emissao: agora,
    tipo_documento: "1",
    finalidade_emissao: "1",
    consumidor_final: "1",
    presenca_comprador: "2",
    modalidade_frete: d.metodo_entrega === "retirada" ? "9" : "1",
    cnpj_emitente: soDigitos(c.fiscal_cnpj),
    nome_emitente: c.fiscal_razao_social,
    inscricao_estadual: soDigitos(c.fiscal_ie),
    regime_tributario_emitente: simples ? "1" : "3",
    logradouro_emitente: c.fiscal_logradouro,
    numero_emitente: c.fiscal_numero,
    bairro_emitente: c.fiscal_bairro,
    municipio_emitente: c.fiscal_municipio,
    uf_emitente: c.fiscal_uf,
    cep_emitente: soDigitos(c.fiscal_cep),
    ...destinatario,
    valor_frete: reais(d.frete_centavos),
    valor_desconto: reais(d.desconto_centavos),
    itens,
  };
}

// Traduz a resposta do Focus NFe para a situação usada no sistema.
// deno-lint-ignore no-explicit-any
function interpretar(base: string, corpo: any): Estado {
  const caminho = corpo?.caminho_danfe ? (String(corpo.caminho_danfe).startsWith("http") ? corpo.caminho_danfe : `${base}${corpo.caminho_danfe}`) : undefined;
  switch (corpo?.status) {
    case "autorizado":
      return { status: "autorizada", numero: corpo.numero ? String(corpo.numero) : undefined, chave: corpo.chave_nfe, danfe: caminho };
    case "cancelado":
      return { status: "cancelada", numero: corpo.numero ? String(corpo.numero) : undefined, chave: corpo.chave_nfe };
    case "erro_autorizacao":
    case "rejeitado":
    case "denegado":
      return { status: "erro", erro: corpo.mensagem_sefaz || corpo.mensagem || "A SEFAZ recusou a nota." };
    default:
      return { status: "processando" };
  }
}

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
  const pedidoId = String(corpo?.pedido_id ?? "");
  const acao = String(corpo?.acao ?? "");
  const justificativa = String(corpo?.justificativa ?? "").trim();
  const vendedorId = corpo?.vendedor_id ? String(corpo.vendedor_id) : null;
  if (!UUID.test(pedidoId)) return json(400, { erro: "Pedido inválido." });
  if (vendedorId !== null && !UUID.test(vendedorId)) return json(400, { erro: "Vendedor inválido." });
  if (!["emitir", "consultar", "cancelar"].includes(acao)) return json(400, { erro: "Ação inválida." });

  const registrar = async (estado: Estado) => {
    await admin.rpc("confirmar_nota_loja", {
      p_pedido: pedidoId,
      p_vendedor: vendedorId,
      p_status: estado.status,
      p_numero: estado.numero ?? null,
      p_chave: estado.chave ?? null,
      p_danfe: estado.danfe ?? null,
      p_erro: estado.erro ?? null,
    });
  };

  // Token do grupo: o da cooperativa ou o do vendedor, conforme a conta de emissão dele
  const cabecalhoPara = async (tokenNome: string) => {
    const { data: token } = await admin.rpc("ler_segredo_loja", { p_nome: tokenNome });
    if (!token) {
      return null;
    }
    return { Authorization: `Basic ${btoa(`${token}:`)}`, "Content-Type": "application/json", Accept: "application/json" };
  };
  const semToken = (tokenNome: string) => json(503, {
    erro: tokenNome === "focus_nfe_token"
      ? "O token do Focus NFe ainda não foi configurado em Pagamento e configurações."
      : "A conta de emissão deste vendedor não está conectada.",
  });

  // Consulta a nota pela referência, nos dois ambientes conforme configurado.
  // deno-lint-ignore no-explicit-any
  const consultar = async (base: string, ref: string, cabecalhoAuth: Record<string, string>): Promise<{ estado: Estado; corpo: any; ok: boolean }> => {
    const resposta = await fetch(`${base}/v2/nfe/${encodeURIComponent(ref)}`, { headers: cabecalhoAuth });
    const dados = await resposta.json().catch(() => ({}));
    if (resposta.status === 404) return { estado: { status: "processando" }, corpo: dados, ok: true };
    return { estado: interpretar(base, dados), corpo: dados, ok: resposta.ok };
  };

  try {
    if (acao === "emitir") {
      // Passo 1: o banco confere administrador, dados fiscais, NCM e situação do pedido.
      const { data: dados, error: erroPreparo } = await cooperado.rpc("preparar_nota_loja", {
        p_pedido: pedidoId,
        p_vendedor: vendedorId,
      });
      if (erroPreparo) return json(409, { erro: erroPreparo.message });

      const cabecalhoAuth = await cabecalhoPara(dados.token_nome);
      if (!cabecalhoAuth) return semToken(dados.token_nome);
      const base = BASES[dados.ambiente] ?? BASES.homologacao;

      // Passo 2: envia a nota.
      const resposta = await fetch(`${base}/v2/nfe?ref=${encodeURIComponent(dados.ref)}`, {
        method: "POST",
        headers: cabecalhoAuth,
        body: JSON.stringify(montarNota(dados)),
      });
      const retorno = await resposta.json().catch(() => ({}));
      if (!resposta.ok && resposta.status !== 202) {
        const mensagem = retorno?.mensagem || retorno?.erros?.map((e: { mensagem: string }) => e.mensagem).join("; ") || `Erro ${resposta.status} do Focus NFe.`;
        console.error("Focus NFe recusou a nota", resposta.status, JSON.stringify(retorno));
        await registrar({ status: "erro", erro: mensagem });
        return json(422, { erro: mensagem });
      }

      // Passo 3: a SEFAZ responde em alguns segundos. Consulta uma vez; se ainda estiver processando, o admin atualiza.
      await new Promise((r) => setTimeout(r, 3000));
      const { estado } = await consultar(base, dados.ref, cabecalhoAuth);
      await registrar(estado);
      return json(200, { situacao: estado.status, numero: estado.numero ?? null });
    }

    // Consultar e cancelar usam a referência já guardada na nota do grupo.
    const { data: ref, error: erroRef } = await cooperado.rpc("referencia_nota_loja", {
      p_pedido: pedidoId,
      p_vendedor: vendedorId,
    });
    if (erroRef) return json(409, { erro: erroRef.message });
    const cabecalhoAuth = await cabecalhoPara(ref.token_nome);
    if (!cabecalhoAuth) return semToken(ref.token_nome);
    const base = BASES[ref.ambiente] ?? BASES.homologacao;

    if (acao === "consultar") {
      const { estado } = await consultar(base, ref.ref, cabecalhoAuth);
      await registrar(estado);
      return json(200, { situacao: estado.status, numero: estado.numero ?? null });
    }

    // Cancelamento: a SEFAZ aceita só dentro do prazo fiscal. A justificativa precisa ser clara (mínimo 15 caracteres).
    if (ref.nf_status !== "autorizada") {
      return json(409, { erro: "Só é possível cancelar nota autorizada." });
    }
    if (justificativa.length < 15) {
      return json(400, { erro: "Escreva a justificativa do cancelamento com pelo menos 15 caracteres." });
    }
    const resposta = await fetch(`${base}/v2/nfe/${encodeURIComponent(ref.ref)}`, {
      method: "DELETE",
      headers: cabecalhoAuth,
      body: JSON.stringify({ justificativa }),
    });
    const retorno = await resposta.json().catch(() => ({}));
    if (!resposta.ok) {
      const mensagem = retorno?.mensagem || `Erro ${resposta.status} ao cancelar a nota.`;
      return json(422, { erro: mensagem });
    }
    if (retorno?.status === "cancelado") {
      await registrar({ status: "cancelada", numero: ref.numero ?? undefined });
      return json(200, { situacao: "cancelada" });
    }
    // Cancelamento em andamento: a situação muda quando o admin atualizar.
    return json(202, { situacao: "processando", mensagem: "Cancelamento enviado. Atualize a situação em alguns minutos." });
  } catch (erro) {
    console.error("Falha de rede com o Focus NFe", String(erro));
    // Em falha de rede a nota pode ter chegado ao Focus NFe. Fica "processando" para o admin consultar antes de reemitir.
    if (acao === "emitir" || acao === "consultar") {
      await registrar({ status: "processando", erro: "Não foi possível falar com o Focus NFe agora. Consulte a situação antes de emitir de novo." });
    }
    return json(502, { erro: "Não foi possível falar com o Focus NFe agora. Tente de novo em instantes." });
  }
});
