// Carteirinha digital: cartão do cooperado com QR code e validação pública pelo QR.
// Quem lê o QR vê só o nome abreviado, o tipo de acesso e a situação. O CPF nunca aparece.
window.Carteirinha = (() => {
  const sb = () => window.sb;

  const TIPOS = { administrador: "Administrador", funcionario: "Funcionário", cooperado: "Cooperado" };

  function esc(texto) {
    const d = document.createElement("div");
    d.textContent = texto ?? "";
    return d.innerHTML;
  }

  function tipoLegivel(tipo) {
    return TIPOS[tipo] || (tipo ? tipo.charAt(0).toUpperCase() + tipo.slice(1).replace(/_/g, " ") : "");
  }

  function agrupar(codigo) {
    return String(codigo || "").toUpperCase().match(/.{1,4}/g)?.join(" ") || "";
  }

  // QR code em SVG, gerado localmente (vendor/qrcode.js). Não depende de rede.
  function qrSvg(texto) {
    try {
      const qr = qrcode(0, "M");
      qr.addData(texto);
      qr.make();
      return qr.createSvgTag({ cellSize: 5, margin: 2, scalable: true });
    } catch (_) {
      return '<p class="ajuda">Não foi possível gerar o QR code.</p>';
    }
  }

  function url(codigo) {
    return `${location.origin}${location.pathname}#validar/${codigo}`;
  }

  // ---------- Minha carteirinha ----------

  async function tela(alvo, perfil) {
    alvo.innerHTML = '<p class="ajuda">Carregando...</p>';
    const { data: eu, error } = await sb()
      .from("usuarios")
      .select("codigo_carteirinha, nome_completo, tipo_acesso, criado_em")
      .eq("id", perfil.id)
      .single();

    if (error || !eu) {
      alvo.innerHTML = `<p class="erro">Não foi possível carregar sua carteirinha: ${esc(error?.message)}</p>`;
      return;
    }

    alvo.innerHTML = `
      <h1>Carteirinha digital</h1>
      <p class="ajuda">Apresente o QR code quando for solicitado. Quem ler o código confirma se o seu acesso está ativo.</p>
      <section class="carteirinha" aria-label="Carteirinha">
        <div class="carteirinha-topo">
          <strong>Cooperativa Vale do Rio Doce</strong>
          <span>${esc(tipoLegivel(eu.tipo_acesso))}</span>
        </div>
        <div class="carteirinha-corpo">
          <div class="carteirinha-dados">
            <p class="carteirinha-nome">${esc(eu.nome_completo)}</p>
            <p class="ajuda">Cadastro desde ${esc(new Date(eu.criado_em).toLocaleDateString("pt-BR"))}</p>
            <p class="carteirinha-codigo">${esc(agrupar(eu.codigo_carteirinha))}</p>
          </div>
          <div class="carteirinha-qr">${qrSvg(url(eu.codigo_carteirinha))}</div>
        </div>
      </section>
      <div class="acoes-evento">
        <button type="button" id="renovar-carteirinha" class="btn-ghost">Gerar novo código</button>
      </div>
      <p class="ajuda">Use “Gerar novo código” se perder o acesso ao QR code. O código antigo deixa de valer.</p>
      <p class="erro" role="alert" hidden></p>`;

    const erro = alvo.querySelector(".erro");
    alvo.querySelector("#renovar-carteirinha").addEventListener("click", async () => {
      if (!confirm("Gerar um novo código? O QR code atual deixará de funcionar.")) return;
      const { error: falha } = await sb().rpc("renovar_carteirinha");
      if (falha) {
        erro.textContent = falha.message;
        erro.hidden = false;
        return;
      }
      tela(alvo, perfil);
    });
  }

  // ---------- Validação pública (página aberta pelo QR code) ----------

  async function validar(alvo, codigo) {
    alvo.innerHTML = '<section class="cartao"><p class="ajuda">Verificando carteirinha...</p></section>';
    const codigoLimpo = String(codigo || "").replace(/\s+/g, "").toLowerCase();
    const { data, error } = await sb().rpc("validar_carteirinha", { p_codigo: codigoLimpo });

    const linha = data && data[0];
    const valida = !error && linha && linha.situacao === "Ativo";

    alvo.innerHTML = `
      <section class="cartao validacao ${valida ? "valida" : "invalida"}">
        <h1>${linha ? (valida ? "Carteirinha válida" : "Acesso inativo") : "Carteirinha não encontrada"}</h1>
        ${linha ? `
          <p class="validacao-nome">${esc(linha.nome_exibicao)}</p>
          <p><strong>Tipo de acesso:</strong> ${esc(tipoLegivel(linha.tipo_acesso))}</p>
          <p><strong>Situação:</strong> ${esc(linha.situacao)}</p>
          <p class="ajuda">Cadastro desde ${esc(new Date(linha.cadastro_desde).toLocaleDateString("pt-BR"))}</p>`
          : `<p>Este código não corresponde a nenhum cadastro. Confira com a cooperativa.</p>`}
        ${error ? `<p class="erro">Não foi possível verificar agora. Tente novamente.</p>` : ""}
        <p class="rodape-form">Cooperativa Agropecuária Vale do Rio Doce</p>
      </section>`;
  }

  return { tela, validar };
})();
