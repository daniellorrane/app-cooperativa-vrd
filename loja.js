// Loja (e-commerce, etapa E1): catálogo, carrinho, favoritos, listas de presentes e avaliações.
// As regras de acesso ficam no banco (RLS, gatilhos e funções). Esta tela só organiza a apresentação.
window.Loja = (() => {
  const sb = () => window.sb;
  const LIMITE_FOTO = 2 * 1024 * 1024;
  const TIPOS_FOTO = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" };
  const MAX_QUANTIDADE = 20;

  const ESTRELA = "M12 3l2.8 5.7 6.2.9-4.5 4.4 1.1 6.2L12 17.2 6.4 20.2l1.1-6.2-4.5-4.4 6.2-.9z";
  const ICONE_SACOLA = '<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M5 8h14l-1 12H6zM9 8V6a3 3 0 0 1 6 0v2"/></svg>';
  const ERRO_GERAL = '<p class="erro erro-geral" role="alert" hidden></p>';
  const AVISO_GERAL = '<p class="aviso-geral" role="status" hidden></p>';

  const esc = (texto) => String(texto ?? "").replace(/[&<>"']/g, (c) => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
  ));
  const reais = (centavos) => (Number(centavos) / 100).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
  const numeroPt = (valor) => String(valor).replace(".", ",");
  const dataCurta = (valor) => new Date(valor).toLocaleDateString("pt-BR");
  const ehAdmin = (perfil) => perfil.tipo_acesso === "administrador";
  const precoAtual = (p) => p.preco_promo_centavos ?? p.preco_centavos;
  const maximoNoCarrinho = (p) => Math.min(p.estoque, MAX_QUANTIDADE);
  const urlApp = (rota) => `${location.origin}${location.pathname}#${rota}`;
  const urlFoto = (caminho) => `${window.APP_CONFIG.SUPABASE_URL}/storage/v1/object/public/loja-fotos/${caminho.split("/").map(encodeURIComponent).join("/")}`;

  // "12,90", "R$ 1.299,00" e "12.90" viram centavos. Retorna NaN se não for valor.
  function parseReais(texto) {
    let t = String(texto ?? "").trim().replace(/\s|R\$/g, "");
    if (!t) return NaN;
    if (t.includes(",")) t = t.replace(/\./g, "").replace(",", ".");
    const valor = Number(t);
    return Number.isFinite(valor) ? Math.round(valor * 100) : NaN;
  }

  function estrelas(media) {
    const n = Math.round(Number(media) || 0);
    const icones = [1, 2, 3, 4, 5]
      .map((i) => `<svg viewBox="0 0 24 24" aria-hidden="true" class="loja-estrela${i <= n ? " cheia" : ""}"><path d="${ESTRELA}"/></svg>`)
      .join("");
    const rotulo = media ? `Nota ${numeroPt(media)} de 5` : "Sem avaliações";
    return `<span class="loja-estrelas" role="img" aria-label="${esc(rotulo)}">${icones}</span>`;
  }

  const foto = (caminho, nome) => caminho
    ? `<img src="${esc(urlFoto(caminho))}" alt="${esc(nome)}" loading="lazy" />`
    : `<span class="sem-foto">${ICONE_SACOLA}</span>`;

  const precoHtml = (p) => p.preco_promo_centavos
    ? `<span class="loja-preco"><s>${reais(p.preco_centavos)}</s> <strong>${reais(p.preco_promo_centavos)}</strong></span>`
    : `<span class="loja-preco"><strong>${reais(p.preco_centavos)}</strong></span>`;

  function erroNa(alvo, mensagem) {
    const area = alvo.querySelector(".erro-geral");
    if (!area) return;
    area.textContent = mensagem;
    area.hidden = false;
  }

  function avisoNa(alvo, mensagem) {
    const area = alvo.querySelector(".aviso-geral");
    if (!area) return;
    area.textContent = mensagem;
    area.hidden = !mensagem;
  }

  // Compartilha pelo recurso do celular. Sem ele, copia o link.
  async function compartilhar(titulo, url) {
    try {
      if (navigator.share) {
        await navigator.share({ title: titulo, url });
        return "Compartilhado.";
      }
      await navigator.clipboard.writeText(url);
      return "Link copiado. Cole onde quiser para enviar.";
    } catch (erro) {
      if (erro.name === "AbortError") return "";
      return "Não foi possível compartilhar. Copie o endereço da barra do navegador.";
    }
  }

  const carregando = (alvo) => { alvo.innerHTML = '<p class="ajuda">Carregando...</p>'; };

  // ---------- Vitrine ----------

  function cartao(p) {
    const avaliacao = p.media
      ? `${estrelas(p.media)} <span class="ajuda">${numeroPt(p.media)} (${Number(p.avaliacoes)})</span>`
      : '<span class="ajuda">Sem avaliações ainda</span>';
    return `
      <a class="loja-card" href="#loja/produto/${esc(p.id)}">
        <span class="loja-foto">${foto(p.imagem_caminho, p.nome)}</span>
        <span class="loja-texto">
          <strong>${esc(p.nome)}</strong>
          ${precoHtml(p)}
          <span>${avaliacao}</span>
          ${p.motivo ? `<span class="ajuda">${esc(p.motivo)}</span>` : ""}
          ${p.estoque === 0 ? '<span class="marcas"><span class="marca">Esgotado</span></span>' : ""}
        </span>
      </a>`;
  }

  async function vitrine(alvo) {
    carregando(alvo);
    const [{ data: categorias }, { data: recomendados }] = await Promise.all([
      sb().from("loja_categorias").select("id, nome").eq("ativa", true).order("ordem").order("nome"),
      sb().rpc("recomendados_para_mim"),
    ]);

    alvo.innerHTML = `
      <div class="cabecalho-pagina">
        <h1>Loja</h1>
        <div class="acoes-evento">
          <a class="btn-ghost" href="#loja/favoritos">Favoritos</a>
          <a class="btn-ghost" href="#loja/listas">Listas de presentes</a>
          <a class="btn-primario" href="#loja/carrinho">Carrinho</a>
        </div>
      </div>
      <form class="formulario" role="search">
        <label>Buscar produtos
          <input type="search" name="busca" placeholder="Ex.: panela, presente, camiseta" autocomplete="off" maxlength="80" />
        </label>
      </form>
      <div class="chips" role="group" aria-label="Categorias">
        <button type="button" class="chip" data-categoria="" aria-pressed="true">Todas</button>
        ${(categorias || []).map((c) => `<button type="button" class="chip" data-categoria="${esc(c.id)}" aria-pressed="false">${esc(c.nome)}</button>`).join("")}
      </div>
      <div id="loja-recomendados"></div>
      <div id="loja-resultado"></div>`;

    let categoria = null;
    let busca = "";
    let espera = null;

    const desenhar = async () => {
      const semFiltro = !categoria && !busca.trim();
      alvo.querySelector("#loja-recomendados").innerHTML = semFiltro && (recomendados || []).length
        ? `<h2 class="dia-agenda">Para você</h2><div class="loja-grade">${recomendados.map(cartao).join("")}</div>`
        : "";

      const resultado = alvo.querySelector("#loja-resultado");
      const { data, error } = await sb().rpc("vitrine_loja", {
        p_categoria: categoria,
        p_busca: busca.trim() || null,
      });
      if (error) {
        resultado.innerHTML = `<p class="erro" role="alert">${esc(error.message)}</p>`;
        return;
      }
      resultado.innerHTML = (data || []).length
        ? `<h2 class="dia-agenda">${semFiltro ? "Todos os produtos" : "Resultados"}</h2><div class="loja-grade">${data.map(cartao).join("")}</div>`
        : '<p class="ajuda">Nenhum produto encontrado. Tente outras palavras ou outra categoria.</p>';
    };

    alvo.querySelectorAll(".chip").forEach((botao) => {
      botao.addEventListener("click", () => {
        categoria = botao.dataset.categoria || null;
        alvo.querySelectorAll(".chip").forEach((c) => c.setAttribute("aria-pressed", String(c === botao)));
        desenhar();
      });
    });

    const campo = alvo.querySelector("input[name=busca]");
    campo.form.addEventListener("submit", (ev) => ev.preventDefault());
    campo.addEventListener("input", () => {
      clearTimeout(espera);
      espera = setTimeout(() => {
        busca = campo.value;
        desenhar();
      }, 300);
    });

    desenhar();
  }

  // ---------- Produto ----------

  async function produto(alvo, perfil, id) {
    carregando(alvo);
    const [
      { data: p },
      { data: todas },
      { data: favorito },
      { data: noCarrinho },
      { data: listas },
    ] = await Promise.all([
      sb().from("loja_produtos")
        .select("id, nome, descricao, preco_centavos, preco_promo_centavos, estoque, imagem_caminho, ativo, loja_categorias(nome)")
        .eq("id", id).maybeSingle(),
      sb().from("avaliacoes_produto")
        .select("id, nota, comentario, criado_em, usuario_id, status")
        .eq("produto_id", id).order("criado_em", { ascending: false }),
      sb().from("favoritos").select("produto_id").eq("produto_id", id).eq("usuario_id", perfil.id).maybeSingle(),
      sb().from("carrinho_itens").select("quantidade").eq("produto_id", id).eq("usuario_id", perfil.id).maybeSingle(),
      sb().from("listas_loja").select("id, titulo").eq("usuario_id", perfil.id).order("criado_em", { ascending: false }),
    ]);

    if (!p) {
      alvo.innerHTML = `<p class="rodape-form"><a href="#loja">← Voltar para a loja</a></p><p class="ajuda">Produto não encontrado.</p>`;
      return;
    }

    const publicadas = (todas || []).filter((a) => a.status === "publicada");
    const media = publicadas.length
      ? publicadas.reduce((soma, a) => soma + a.nota, 0) / publicadas.length
      : null;
    const minha = (todas || []).find((a) => a.usuario_id === perfil.id);
    const admin = ehAdmin(perfil);
    const disponivel = p.ativo && p.estoque > 0;
    const maximo = maximoNoCarrinho(p);
    const qtdNoCarrinho = noCarrinho?.quantidade || 0;
    const categoriaNome = p.loja_categorias?.nome;

    const opcoesQuantidade = Array.from({ length: maximo }, (_, i) => i + 1)
      .map((n) => `<option value="${n}">${n}</option>`).join("");

    const linhaAvaliacao = (a) => `
      <article class="item avaliacao-item">
        <div class="avaliacao-topo">
          ${estrelas(a.nota)}
          <span class="ajuda">${dataCurta(a.criado_em)}${a.status === "oculta" ? " · oculta pela cooperativa" : ""}</span>
        </div>
        ${a.comentario ? `<p class="texto-puro">${esc(a.comentario)}</p>` : ""}
        ${admin ? `<button type="button" class="btn-ghost" data-moderar="${esc(a.id)}" data-status="${a.status}">${a.status === "oculta" ? "Mostrar avaliação" : "Ocultar avaliação"}</button>` : ""}
      </article>`;

    const blocoMinha = minha
      ? `<div class="cartao-interno">
           <p><strong>Sua avaliação:</strong> ${estrelas(minha.nota)}</p>
           ${minha.comentario ? `<p class="texto-puro">${esc(minha.comentario)}</p>` : ""}
           ${minha.status === "oculta" ? '<p class="ajuda">Esta avaliação foi ocultada pela cooperativa.</p>' : ""}
           <button type="button" class="btn-ghost" id="apagar-avaliacao">Excluir minha avaliação</button>
         </div>`
      : `<form id="form-avaliacao" class="formulario" novalidate>
           <fieldset class="nota-estrelas">
             <legend>Sua nota</legend>
             ${[5, 4, 3, 2, 1].map((n) => `
               <label class="opcao-nota">
                 <input type="radio" name="nota" value="${n}" required />
                 <span>${n} ${n === 1 ? "estrela" : "estrelas"}</span>
               </label>`).join("")}
           </fieldset>
           <label>Comentário <small>(opcional)</small>
             <textarea name="comentario" rows="3" maxlength="600"></textarea>
           </label>
           ${ERRO_GERAL}
           <button type="submit" class="btn-primario">Enviar avaliação</button>
         </form>`;

    const outras = (todas || []).filter((a) => a.usuario_id !== perfil.id && (a.status === "publicada" || admin));

    alvo.innerHTML = `
      <p class="rodape-form"><a href="#loja">← Voltar para a loja</a></p>
      ${!p.ativo ? '<p class="marcas"><span class="marca">Não publicado: visível só para administradores</span></p>' : ""}
      <div class="produto-detalhe">
        <div class="loja-foto-grande">${foto(p.imagem_caminho, p.nome)}</div>
        <div class="produto-info">
          ${categoriaNome ? `<p class="ajuda">${esc(categoriaNome)}</p>` : ""}
          <h1>${esc(p.nome)}</h1>
          <p>${media ? `${estrelas(media)} <span>${numeroPt(media.toFixed(1))} de 5 · ${publicadas.length} avaliação(ões)</span>` : '<span class="ajuda">Sem avaliações ainda</span>'}</p>
          ${precoHtml(p)}
          <p class="marcas">${p.estoque === 0 ? '<span class="marca">Esgotado</span>' : `<span class="marca">${p.estoque <= 5 ? `Últimas ${p.estoque} unidades` : "Em estoque"}</span>`}</p>

          ${disponivel
            ? `<form id="form-carrinho" class="formulario">
                 <label>Quantidade <select name="quantidade">${opcoesQuantidade}</select></label>
                 <button type="submit" class="btn-primario">Adicionar ao carrinho</button>
                 ${qtdNoCarrinho ? `<p class="ajuda">Já há ${qtdNoCarrinho} unidade(s) no seu carrinho.</p>` : ""}
               </form>`
            : '<p class="ajuda">Este produto não está disponível no momento.</p>'}

          <div class="acoes-evento">
            <button type="button" class="btn-ghost" id="favoritar" aria-pressed="${favorito ? "true" : "false"}">
              ${favorito ? "Remover dos favoritos" : "Favoritar"}
            </button>
            <button type="button" class="btn-ghost" id="compartilhar">Compartilhar</button>
            <button type="button" class="btn-ghost" id="indicar">Indicar a um amigo</button>
          </div>

          ${(listas || []).length
            ? `<form id="form-lista" class="formulario">
                 <label>Salvar em uma lista
                   <select name="lista">${listas.map((l) => `<option value="${esc(l.id)}">${esc(l.titulo)}</option>`).join("")}</select>
                 </label>
                 <button type="submit" class="btn-ghost">Adicionar à lista</button>
               </form>`
            : '<p class="ajuda">Crie uma lista de presentes em <a href="#loja/listas">Listas de presentes</a> para salvar este produto.</p>'}

          ${ERRO_GERAL}
          ${AVISO_GERAL}
        </div>
      </div>

      <section class="cartao">
        <h2>Sobre o produto</h2>
        <p class="texto-puro">${esc(p.descricao || "Sem descrição.")}</p>
      </section>

      <section class="cartao" id="avaliacoes">
        <h2>Avaliações</h2>
        ${blocoMinha}
        ${outras.length ? `<div class="lista">${outras.map(linhaAvaliacao).join("")}</div>` : '<p class="ajuda">Ainda não há outras avaliações.</p>'}
      </section>`;

    // Carrinho: soma com o que já está lá, sem passar do limite.
    alvo.querySelector("#form-carrinho")?.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      const quantidade = Number(new FormData(ev.currentTarget).get("quantidade"));
      const total = Math.min(qtdNoCarrinho + quantidade, maximo);
      const { error } = await sb().from("carrinho_itens").upsert(
        { usuario_id: perfil.id, produto_id: p.id, quantidade: total, atualizado_em: new Date().toISOString() },
        { onConflict: "usuario_id,produto_id" }
      );
      if (error) return erroNa(alvo, error.message);
      location.hash = "#loja/carrinho";
    });

    alvo.querySelector("#favoritar").addEventListener("click", async (ev) => {
      const botao = ev.currentTarget;
      const estava = botao.getAttribute("aria-pressed") === "true";
      botao.disabled = true;
      const { error } = estava
        ? await sb().from("favoritos").delete().eq("produto_id", p.id).eq("usuario_id", perfil.id)
        : await sb().from("favoritos").insert({ usuario_id: perfil.id, produto_id: p.id });
      if (error) {
        botao.disabled = false;
        return erroNa(alvo, error.message);
      }
      produto(alvo, perfil, p.id);
    });

    alvo.querySelector("#compartilhar").addEventListener("click", async () => {
      avisoNa(alvo, await compartilhar(p.nome, urlApp(`loja/produto/${p.id}`)));
    });

    alvo.querySelector("#indicar").addEventListener("click", async (ev) => {
      const botao = ev.currentTarget;
      botao.disabled = true;
      const { data: token, error } = await sb().rpc("criar_indicacao_loja", { p_produto: p.id });
      botao.disabled = false;
      if (error) return erroNa(alvo, error.message);
      avisoNa(alvo, await compartilhar(`Indicação: ${p.nome}`, urlApp(`loja/indicacao/${token}`)));
    });

    alvo.querySelector("#form-lista")?.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      const listaId = new FormData(ev.currentTarget).get("lista");
      const { error } = await sb().from("lista_loja_itens").upsert(
        { lista_id: listaId, produto_id: p.id, quantidade_desejada: 1 },
        { onConflict: "lista_id,produto_id", ignoreDuplicates: true }
      );
      if (error) return erroNa(alvo, error.message);
      location.hash = `#loja/lista/${listaId}`;
    });

    alvo.querySelector("#apagar-avaliacao")?.addEventListener("click", async () => {
      if (!confirm("Excluir sua avaliação deste produto?")) return;
      const { error } = await sb().from("avaliacoes_produto").delete().eq("id", minha.id);
      if (error) return erroNa(alvo, error.message);
      produto(alvo, perfil, p.id);
    });

    alvo.querySelector("#form-avaliacao")?.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      const f = new FormData(ev.currentTarget);
      const nota = Number(f.get("nota"));
      if (!nota) return erroNa(alvo, "Escolha uma nota de 1 a 5 estrelas.");
      const { error } = await sb().from("avaliacoes_produto").insert({
        produto_id: p.id,
        usuario_id: perfil.id,
        nota,
        comentario: String(f.get("comentario") || "").trim() || null,
      });
      if (error) return erroNa(alvo, error.message);
      produto(alvo, perfil, p.id);
    });

    alvo.querySelectorAll("[data-moderar]").forEach((botao) => {
      botao.addEventListener("click", async () => {
        const novo = botao.dataset.status === "oculta" ? "publicada" : "oculta";
        botao.disabled = true;
        const { error } = await sb().from("avaliacoes_produto").update({ status: novo }).eq("id", botao.dataset.moderar);
        if (error) {
          botao.disabled = false;
          return erroNa(alvo, error.message);
        }
        produto(alvo, perfil, p.id);
      });
    });
  }

  // ---------- Carrinho ----------

  async function carrinho(alvo, perfil) {
    carregando(alvo);
    const { data, error } = await sb().from("carrinho_itens")
      .select("produto_id, quantidade, produto:loja_produtos(id, nome, preco_centavos, preco_promo_centavos, imagem_caminho, estoque, ativo)")
      .eq("usuario_id", perfil.id)
      .order("atualizado_em", { ascending: false });

    if (error) {
      alvo.innerHTML = `<p class="erro" role="alert">${esc(error.message)}</p>`;
      return;
    }

    const itens = data || [];
    const disponiveis = itens.filter((i) => i.produto?.ativo && i.produto.estoque > 0);
    const total = disponiveis.reduce(
      (soma, i) => soma + Math.min(i.quantidade, i.produto.estoque) * precoAtual(i.produto),
      0
    );

    alvo.innerHTML = `
      <p class="rodape-form"><a href="#loja">← Voltar para a loja</a></p>
      <h1>Carrinho</h1>
      ${ERRO_GERAL}
      ${!itens.length
        ? '<p class="ajuda">Seu carrinho está vazio. <a href="#loja">Ver produtos</a></p>'
        : `<div class="lista">
             ${itens.map((i) => {
               const p = i.produto;
               if (!p) return "";
               const indisponivel = !p.ativo || p.estoque === 0;
               const maximo = Math.max(1, maximoNoCarrinho(p));
               const quantidade = Math.min(i.quantidade, maximo);
               const opcoes = Array.from({ length: maximo }, (_, n) => n + 1)
                 .map((n) => `<option value="${n}" ${n === quantidade ? "selected" : ""}>${n}</option>`).join("");
               return `
                 <article class="item loja-linha" data-produto="${esc(p.id)}">
                   <a class="loja-foto-mini" href="#loja/produto/${esc(p.id)}">${foto(p.imagem_caminho, p.nome)}</a>
                   <div class="loja-linha-texto">
                     <a href="#loja/produto/${esc(p.id)}"><strong>${esc(p.nome)}</strong></a>
                     ${precoHtml(p)}
                     ${indisponivel
                       ? '<span class="marcas"><span class="marca">Indisponível. Remova para continuar.</span></span>'
                       : `<label class="qtd">Quantidade <select data-qtd>${opcoes}</select></label>`}
                     <div class="acoes-evento">
                       <button type="button" class="btn-ghost" data-remover>Remover</button>
                     </div>
                   </div>
                 </article>`;
             }).join("")}
           </div>
           <section class="cartao resumo-carrinho">
             <p>Itens disponíveis: ${disponiveis.length}</p>
             <p><strong>Subtotal: ${reais(total)}</strong></p>
             <p class="ajuda">Retirada na cooperativa. Entrega e frete chegam em breve.</p>
             <button type="button" class="btn-primario" id="finalizar" ${disponiveis.length && disponiveis.length === itens.length ? "" : "disabled"}>Finalizar compra</button>
             ${disponiveis.length && disponiveis.length !== itens.length ? '<p class="ajuda">Remova os itens indisponíveis para finalizar.</p>' : ""}
           </section>`}`;

    alvo.querySelectorAll("[data-qtd]").forEach((campo) => {
      campo.addEventListener("change", async () => {
        const linha = campo.closest("[data-produto]");
        const { error: falha } = await sb().from("carrinho_itens")
          .update({ quantidade: Number(campo.value), atualizado_em: new Date().toISOString() })
          .eq("usuario_id", perfil.id).eq("produto_id", linha.dataset.produto);
        if (falha) return erroNa(alvo, falha.message);
        carrinho(alvo, perfil);
      });
    });

    alvo.querySelectorAll("[data-remover]").forEach((botao) => {
      botao.addEventListener("click", async () => {
        const linha = botao.closest("[data-produto]");
        const { error: falha } = await sb().from("carrinho_itens").delete()
          .eq("usuario_id", perfil.id).eq("produto_id", linha.dataset.produto);
        if (falha) return erroNa(alvo, falha.message);
        carrinho(alvo, perfil);
      });
    });

    alvo.querySelector("#finalizar")?.addEventListener("click", () => { location.hash = "#loja/finalizar"; });
  }

  // ---------- Favoritos ----------

  async function favoritos(alvo, perfil) {
    carregando(alvo);
    const { data, error } = await sb().from("favoritos")
      .select("produto_id, produto:loja_produtos(id, nome, preco_centavos, preco_promo_centavos, imagem_caminho, estoque, ativo)")
      .eq("usuario_id", perfil.id)
      .order("criado_em", { ascending: false });

    if (error) {
      alvo.innerHTML = `<p class="erro" role="alert">${esc(error.message)}</p>`;
      return;
    }

    const itens = (data || []).filter((f) => f.produto);
    alvo.innerHTML = `
      <p class="rodape-form"><a href="#loja">← Voltar para a loja</a></p>
      <h1>Favoritos</h1>
      <p class="ajuda">Produtos que você salvou para ver depois. Eles ajudam a montar suas recomendações.</p>
      ${ERRO_GERAL}
      ${itens.length
        ? `<div class="lista">
             ${itens.map((f) => {
               const p = f.produto;
               return `
                 <article class="item loja-linha" data-produto="${esc(p.id)}">
                   <a class="loja-foto-mini" href="#loja/produto/${esc(p.id)}">${foto(p.imagem_caminho, p.nome)}</a>
                   <div class="loja-linha-texto">
                     <a href="#loja/produto/${esc(p.id)}"><strong>${esc(p.nome)}</strong></a>
                     ${precoHtml(p)}
                     ${p.ativo && p.estoque > 0 ? "" : '<span class="marcas"><span class="marca">Indisponível</span></span>'}
                     <div class="acoes-evento">
                       <button type="button" class="btn-ghost" data-remover>Remover dos favoritos</button>
                     </div>
                   </div>
                 </article>`;
             }).join("")}
           </div>`
        : '<p class="ajuda">Você ainda não favoritou nenhum produto. Toque em “Favoritar” na página de um produto.</p>'}`;

    alvo.querySelectorAll("[data-remover]").forEach((botao) => {
      botao.addEventListener("click", async () => {
        const linha = botao.closest("[data-produto]");
        const { error: falha } = await sb().from("favoritos").delete()
          .eq("usuario_id", perfil.id).eq("produto_id", linha.dataset.produto);
        if (falha) return erroNa(alvo, falha.message);
        favoritos(alvo, perfil);
      });
    });
  }

  // ---------- Listas de presentes ----------

  async function listas(alvo, perfil) {
    carregando(alvo);
    const { data, error } = await sb().from("listas_loja")
      .select("id, titulo, tipo, criado_em")
      .eq("usuario_id", perfil.id)
      .order("criado_em", { ascending: false });

    if (error) {
      alvo.innerHTML = `<p class="erro" role="alert">${esc(error.message)}</p>`;
      return;
    }

    const rotuloTipo = { presentes: "Lista de presentes", desejos: "Lista de desejos" };
    alvo.innerHTML = `
      <p class="rodape-form"><a href="#loja">← Voltar para a loja</a></p>
      <h1>Listas de presentes</h1>
      <p class="ajuda">Monte uma lista e envie o link para quem quiser presentear você. A pessoa escolhe o item e não precisa de conta extra, mas precisa estar logada no app.</p>
      <p class="rodape-form"><a href="#loja/indicacoes">Minhas indicações</a></p>
      ${ERRO_GERAL}
      ${(data || []).length
        ? `<div class="lista">
             ${data.map((l) => `
               <a class="item evento" href="#loja/lista/${esc(l.id)}">
                 <span class="evento-texto">
                   <strong>${esc(l.titulo)}</strong>
                   <span class="ajuda">${esc(rotuloTipo[l.tipo] || "Lista")} · criada em ${dataCurta(l.criado_em)}</span>
                 </span>
               </a>`).join("")}
           </div>`
        : '<p class="ajuda">Você ainda não tem listas.</p>'}

      <section class="cartao">
        <h2>Nova lista</h2>
        <form id="form-nova-lista" class="formulario" novalidate>
          <label>Nome da lista
            <input type="text" name="titulo" required minlength="2" maxlength="100" placeholder="Ex.: Casamento da Ana" />
          </label>
          <label>Tipo
            <select name="tipo">
              <option value="presentes">Lista de presentes</option>
              <option value="desejos">Lista de desejos</option>
            </select>
          </label>
          <button type="submit" class="btn-primario">Criar lista</button>
        </form>
      </section>`;

    alvo.querySelector("#form-nova-lista").addEventListener("submit", async (ev) => {
      ev.preventDefault();
      const f = new FormData(ev.currentTarget);
      const titulo = String(f.get("titulo") || "").trim();
      if (titulo.length < 2) return erroNa(alvo, "Dê um nome com pelo menos 2 letras.");
      const { data: criada, error: falha } = await sb().from("listas_loja")
        .insert({ usuario_id: perfil.id, titulo, tipo: f.get("tipo") })
        .select("id").single();
      if (falha) return erroNa(alvo, falha.message);
      location.hash = `#loja/lista/${criada.id}`;
    });
  }

  async function lista(alvo, perfil, id) {
    carregando(alvo);
    const [{ data: l }, { data: itens }] = await Promise.all([
      sb().from("listas_loja").select("id, titulo, tipo, token").eq("id", id).maybeSingle(),
      sb().from("lista_loja_itens")
        .select("quantidade_desejada, quantidade_comprada, produto:loja_produtos(id, nome, preco_centavos, preco_promo_centavos, imagem_caminho, estoque, ativo)")
        .eq("lista_id", id)
        .order("adicionado_em"),
    ]);

    if (!l) {
      alvo.innerHTML = `<p class="rodape-form"><a href="#loja/listas">← Voltar para as listas</a></p><p class="ajuda">Lista não encontrada.</p>`;
      return;
    }

    const linhas = (itens || []).filter((i) => i.produto);
    const link = urlApp(`loja/compartilhada/${l.token}`);

    alvo.innerHTML = `
      <p class="rodape-form"><a href="#loja/listas">← Voltar para as listas</a></p>
      <div class="cabecalho-pagina">
        <h1>${esc(l.titulo)}</h1>
        <div class="acoes-evento">
          <button type="button" class="btn-primario" id="compartilhar-lista">Compartilhar lista</button>
          <button type="button" class="btn-ghost" id="indicar-lista">Indicar a um amigo</button>
          <button type="button" class="btn-perigo" id="excluir-lista">Excluir lista</button>
        </div>
      </div>
      ${ERRO_GERAL}
      ${AVISO_GERAL}
      ${linhas.length
        ? `<div class="lista">
             ${linhas.map((i) => {
               const p = i.produto;
               return `
                 <article class="item loja-linha" data-produto="${esc(p.id)}">
                   <a class="loja-foto-mini" href="#loja/produto/${esc(p.id)}">${foto(p.imagem_caminho, p.nome)}</a>
                   <div class="loja-linha-texto">
                     <a href="#loja/produto/${esc(p.id)}"><strong>${esc(p.nome)}</strong></a>
                     ${precoHtml(p)}
                     <label class="qtd">Quantidade desejada
                       <input type="number" data-quantidade min="1" max="50" step="1" value="${Number(i.quantidade_desejada)}" />
                     </label>
                     <span class="ajuda">Comprados: ${Number(i.quantidade_comprada)} de ${Number(i.quantidade_desejada)}</span>
                     <div class="acoes-evento">
                       <button type="button" class="btn-ghost" data-remover>Tirar da lista</button>
                     </div>
                   </div>
                 </article>`;
             }).join("")}
           </div>`
        : `<p class="ajuda">Esta lista ainda está vazia. Abra um produto e toque em “Adicionar à lista”. <a href="#loja">Ver produtos</a></p>`}`;

    alvo.querySelector("#compartilhar-lista").addEventListener("click", async () => {
      avisoNa(alvo, await compartilhar(l.titulo, link));
    });

    alvo.querySelector("#indicar-lista").addEventListener("click", async (ev) => {
      const botao = ev.currentTarget;
      botao.disabled = true;
      const { data: token, error: falha } = await sb().rpc("criar_indicacao_loja", { p_lista: l.id });
      botao.disabled = false;
      if (falha) return erroNa(alvo, falha.message);
      avisoNa(alvo, await compartilhar(`Lista: ${l.titulo}`, urlApp(`loja/indicacao/${token}`)));
    });

    alvo.querySelector("#excluir-lista").addEventListener("click", async () => {
      if (!confirm("Excluir esta lista e todos os itens dela? Esta ação não pode ser desfeita.")) return;
      const { error: falha } = await sb().from("listas_loja").delete().eq("id", l.id);
      if (falha) return erroNa(alvo, falha.message);
      location.hash = "#loja/listas";
    });

    alvo.querySelectorAll("[data-quantidade]").forEach((campo) => {
      campo.addEventListener("change", async () => {
        const linha = campo.closest("[data-produto]");
        const quantidade = Math.min(50, Math.max(1, Math.round(Number(campo.value)) || 1));
        const { error: falha } = await sb().from("lista_loja_itens")
          .update({ quantidade_desejada: quantidade })
          .eq("lista_id", l.id).eq("produto_id", linha.dataset.produto);
        if (falha) return erroNa(alvo, falha.message);
        lista(alvo, perfil, id);
      });
    });

    alvo.querySelectorAll("[data-remover]").forEach((botao) => {
      botao.addEventListener("click", async () => {
        const linha = botao.closest("[data-produto]");
        const { error: falha } = await sb().from("lista_loja_itens").delete()
          .eq("lista_id", l.id).eq("produto_id", linha.dataset.produto);
        if (falha) return erroNa(alvo, falha.message);
        lista(alvo, perfil, id);
      });
    });
  }

  // Quem recebe o link precisa estar logado e aprovado. O banco não mostra quem comprou.
  async function compartilhada(alvo, perfil, token) {
    carregando(alvo);
    const { data, error } = await sb().rpc("ver_lista_compartilhada", { p_token: token });

    if (error || !data) {
      alvo.innerHTML = `
        <p class="rodape-form"><a href="#loja">← Voltar para a loja</a></p>
        <p class="ajuda">Lista não encontrada. Confira se o link está completo.</p>`;
      return;
    }

    const itens = data.itens || [];
    alvo.innerHTML = `
      <p class="rodape-form"><a href="#loja">← Voltar para a loja</a></p>
      <h1>${esc(data.titulo)}</h1>
      <p class="ajuda">Lista de ${esc(data.dono)}. Escolha um presente abrindo o produto.</p>
      ${itens.length
        ? `<div class="loja-grade">
             ${itens.map((i) => `
               <a class="loja-card" href="#loja/produto/${esc(i.produto_id)}">
                 <span class="loja-foto">${foto(i.imagem, i.nome)}</span>
                 <span class="loja-texto">
                   <strong>${esc(i.nome)}</strong>
                   <span class="loja-preco"><strong>${reais(i.preco_centavos)}</strong></span>
                   <span class="ajuda">Desejados: ${Number(i.desejada)} · Já comprados: ${Number(i.comprada)}</span>
                   ${i.disponivel ? "" : '<span class="marcas"><span class="marca">Indisponível</span></span>'}
                 </span>
               </a>`).join("")}
           </div>`
        : '<p class="ajuda">Esta lista ainda não tem produtos.</p>'}`;
  }

  // ---------- Gestão (administradores) ----------

  async function gerenciar(alvo) {
    carregando(alvo);
    const [{ data: categorias }, { data: produtos }] = await Promise.all([
      sb().from("loja_categorias").select("id, nome, ordem, ativa").order("ordem").order("nome"),
      sb().from("loja_produtos").select("id, nome, preco_centavos, preco_promo_centavos, estoque, ativo").order("nome"),
    ]);

    alvo.innerHTML = `
      <p class="rodape-form"><a href="#loja">← Voltar para a loja</a></p>
      <div class="cabecalho-pagina">
        <h1>Gerenciar loja</h1>
        <div class="acoes-evento">
          <a class="btn-ghost" href="#loja/gerenciar/pedidos">Pedidos</a>
          <a class="btn-ghost" href="#loja/gerenciar/cupons">Cupons</a>
          <a class="btn-ghost" href="#loja/gerenciar/devolucoes">Devoluções</a>
          <a class="btn-ghost" href="#loja/gerenciar/relatorios">Relatórios</a>
          <a class="btn-ghost" href="#loja/gerenciar/pagamento">Pagamento e configurações</a>
          <a class="btn-primario" href="#loja/gerenciar/novo">Novo produto</a>
        </div>
      </div>
      <p class="ajuda">Preços, estoque e publicação. Mudanças de preço ficam registradas na auditoria.</p>
      ${ERRO_GERAL}

      <section class="cartao">
        <h2>Categorias</h2>
        ${(categorias || []).length
          ? `<div class="lista">${categorias.map((c) => `
               <div class="item linha-categoria" data-categoria="${esc(c.id)}">
                 <span><strong>${esc(c.nome)}</strong> <span class="ajuda">${c.ativa ? "Ativa" : "Oculta"}</span></span>
                 <span class="acoes-evento">
                   <button type="button" class="btn-ghost" data-alterna>${c.ativa ? "Ocultar" : "Mostrar"}</button>
                   <button type="button" class="btn-perigo" data-apagar>Excluir</button>
                 </span>
               </div>`).join("")}</div>`
          : '<p class="ajuda">Nenhuma categoria ainda.</p>'}
        <form id="form-categoria" class="formulario" novalidate>
          <label>Nova categoria
            <input type="text" name="nome" required minlength="2" maxlength="60" placeholder="Ex.: Casa e cozinha" />
          </label>
          <label>Ordem <small>(menor aparece primeiro)</small>
            <input type="number" name="ordem" min="0" max="999" step="1" value="0" />
          </label>
          <button type="submit" class="btn-primario">Adicionar categoria</button>
        </form>
      </section>

      <section class="cartao">
        <h2>Produtos</h2>
        ${(produtos || []).length
          ? `<div class="lista">${produtos.map((p) => `
               <a class="item evento" href="#loja/gerenciar/${esc(p.id)}">
                 <span class="evento-texto">
                   <strong>${esc(p.nome)}</strong>
                   <span class="ajuda">${reais(precoAtual(p))} · estoque ${Number(p.estoque)}</span>
                   <span class="marcas"><span class="marca">${p.ativo ? "Publicado" : "Rascunho"}</span></span>
                 </span>
               </a>`).join("")}</div>`
          : '<p class="ajuda">Nenhum produto ainda.</p>'}
      </section>`;

    alvo.querySelector("#form-categoria").addEventListener("submit", async (ev) => {
      ev.preventDefault();
      const f = new FormData(ev.currentTarget);
      const nome = String(f.get("nome") || "").trim();
      if (nome.length < 2) return erroNa(alvo, "Dê um nome com pelo menos 2 letras.");
      const { error: falha } = await sb().from("loja_categorias").insert({ nome, ordem: Number(f.get("ordem") || 0) });
      if (falha) return erroNa(alvo, falha.message);
      gerenciar(alvo);
    });

    alvo.querySelectorAll(".linha-categoria").forEach((linha) => {
      const id = linha.dataset.categoria;
      const atual = (categorias || []).find((c) => c.id === id);
      linha.querySelector("[data-alterna]").addEventListener("click", async () => {
        const { error: falha } = await sb().from("loja_categorias").update({ ativa: !atual.ativa }).eq("id", id);
        if (falha) return erroNa(alvo, falha.message);
        gerenciar(alvo);
      });
      linha.querySelector("[data-apagar]").addEventListener("click", async () => {
        if (!confirm(`Excluir a categoria “${atual.nome}”? Os produtos dela ficam sem categoria.`)) return;
        const { error: falha } = await sb().from("loja_categorias").delete().eq("id", id);
        if (falha) return erroNa(alvo, falha.message);
        gerenciar(alvo);
      });
    });
  }

  async function formularioProduto(alvo, perfil, id) {
    carregando(alvo);
    const [{ data: categorias }, { data: atual, error }] = await Promise.all([
      sb().from("loja_categorias").select("id, nome").order("ordem").order("nome"),
      id
        ? sb().from("loja_produtos").select("*").eq("id", id).maybeSingle()
        : Promise.resolve({ data: null, error: null }),
    ]);

    if (error || (id && !atual)) {
      alvo.innerHTML = `<p class="rodape-form"><a href="#loja/gerenciar">← Voltar</a></p><p class="ajuda">Produto não encontrado.</p>`;
      return;
    }

    const reaisParaCampo = (c) => (Number(c) / 100).toFixed(2).replace(".", ",");

    alvo.innerHTML = `
      <p class="rodape-form"><a href="#loja/gerenciar">← Voltar para gerenciar loja</a></p>
      <h1>${atual ? "Editar produto" : "Novo produto"}</h1>
      <form id="form-produto" class="formulario" novalidate>
        <label>Nome
          <input type="text" name="nome" required minlength="3" maxlength="150" value="${esc(atual?.nome || "")}" />
        </label>
        <label>Descrição
          <textarea name="descricao" rows="6" maxlength="4000">${esc(atual?.descricao || "")}</textarea>
        </label>
        <label>Categoria
          <select name="categoria">
            <option value="">Sem categoria</option>
            ${(categorias || []).map((c) => `<option value="${esc(c.id)}" ${atual?.categoria_id === c.id ? "selected" : ""}>${esc(c.nome)}</option>`).join("")}
          </select>
        </label>
        <label>Preço (R$)
          <input type="text" name="preco" inputmode="decimal" required placeholder="Ex.: 129,90" value="${atual ? reaisParaCampo(atual.preco_centavos) : ""}" />
        </label>
        <label>Preço promocional (R$) <small>(opcional)</small>
          <input type="text" name="promo" inputmode="decimal" placeholder="Deixe vazio se não houver" value="${atual?.preco_promo_centavos ? reaisParaCampo(atual.preco_promo_centavos) : ""}" />
        </label>
        <label>Estoque
          <input type="number" name="estoque" min="0" max="1000000" step="1" required value="${Number(atual?.estoque ?? 0)}" />
        </label>
        <fieldset class="medidas">
          <legend>Para calcular o frete <small>(obrigatório para transportadora)</small></legend>
          <label>Peso (g) <input type="number" name="peso_g" min="1" max="100000" step="1" value="${esc(atual?.peso_g ?? "")}" /></label>
          <label>Altura (cm) <input type="number" name="altura_cm" min="1" max="200" step="1" value="${esc(atual?.altura_cm ?? "")}" /></label>
          <label>Largura (cm) <input type="number" name="largura_cm" min="1" max="200" step="1" value="${esc(atual?.largura_cm ?? "")}" /></label>
          <label>Comprimento (cm) <input type="number" name="comprimento_cm" min="1" max="200" step="1" value="${esc(atual?.comprimento_cm ?? "")}" /></label>
        </fieldset>
        <label>Foto <small>(JPG, PNG ou WEBP, até 2 MB)</small>
          <input type="file" name="foto" accept="image/jpeg,image/png,image/webp" />
        </label>
        ${atual?.imagem_caminho ? `<div class="loja-foto-mini">${foto(atual.imagem_caminho, atual.nome)}</div>` : ""}
        <label class="opcao">
          <input type="checkbox" name="ativo" ${atual?.ativo ? "checked" : ""} />
          <span>Publicado (aparece para os cooperados)</span>
        </label>
        ${ERRO_GERAL}
        <button type="submit" class="btn-primario">Salvar produto</button>
      </form>`;

    const form = document.getElementById("form-produto");
    const mostraErro = (mensagem) => erroNa(alvo, mensagem);

    form.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      const f = new FormData(form);
      const nome = String(f.get("nome") || "").trim();
      const preco = parseReais(f.get("preco"));
      const promoTexto = String(f.get("promo") || "").trim();
      const promo = promoTexto ? parseReais(promoTexto) : null;
      const estoque = Number(f.get("estoque"));
      const arquivo = f.get("foto");

      if (nome.length < 3) return mostraErro("O nome precisa ter pelo menos 3 letras.");
      if (!Number.isFinite(preco) || preco < 1) return mostraErro("Informe um preço válido, por exemplo 129,90.");
      if (promoTexto && (!Number.isFinite(promo) || promo < 1)) return mostraErro("Informe um preço promocional válido.");
      if (promo !== null && promo >= preco) return mostraErro("O preço promocional precisa ser menor que o preço normal.");
      if (!Number.isInteger(estoque) || estoque < 0) return mostraErro("O estoque precisa ser um número inteiro, zero ou maior.");
      const medidas = ["peso_g", "altura_cm", "largura_cm", "comprimento_cm"].map((c) => numeroOuNulo(f.get(c)));
      if (medidas.some((m) => m !== null && !Number.isInteger(m))) return mostraErro("Peso e medidas precisam ser números inteiros.");
      const novaFoto = arquivo instanceof File && arquivo.size > 0;
      if (novaFoto && !TIPOS_FOTO[arquivo.type]) return mostraErro("A foto precisa ser JPG, PNG ou WEBP.");
      if (novaFoto && arquivo.size > LIMITE_FOTO) return mostraErro("A foto passou de 2 MB. Reduza o tamanho e tente de novo.");

      const botao = form.querySelector("button[type=submit]");
      botao.disabled = true;

      const produtoId = atual?.id || crypto.randomUUID();
      let caminho = atual?.imagem_caminho ?? null;
      let caminhoAntigo = null;
      if (novaFoto) {
        const novo = `${produtoId}/${Date.now()}.${TIPOS_FOTO[arquivo.type]}`;
        const { error: falhaEnvio } = await sb().storage.from("loja-fotos").upload(novo, arquivo, {
          contentType: arquivo.type,
          cacheControl: "3600",
        });
        if (falhaEnvio) {
          botao.disabled = false;
          return mostraErro(falhaEnvio.message);
        }
        caminhoAntigo = caminho;
        caminho = novo;
      }

      const dados = {
        nome,
        descricao: String(f.get("descricao") || "").trim() || null,
        categoria_id: f.get("categoria") || null,
        preco_centavos: preco,
        preco_promo_centavos: promo,
        estoque,
        ativo: f.has("ativo"),
        imagem_caminho: caminho,
        peso_g: numeroOuNulo(f.get("peso_g")),
        altura_cm: numeroOuNulo(f.get("altura_cm")),
        largura_cm: numeroOuNulo(f.get("largura_cm")),
        comprimento_cm: numeroOuNulo(f.get("comprimento_cm")),
      };

      const resposta = atual
        ? await sb().from("loja_produtos").update(dados).eq("id", produtoId)
        : await sb().from("loja_produtos").insert({ id: produtoId, ...dados, criado_por: perfil.id });

      if (resposta.error) {
        if (novaFoto) await sb().storage.from("loja-fotos").remove([caminho]);
        botao.disabled = false;
        return mostraErro(resposta.error.message);
      }

      if (caminhoAntigo) await sb().storage.from("loja-fotos").remove([caminhoAntigo]);
      location.hash = "#loja/gerenciar";
    });
  }

  // ---------- Pedidos e pagamento (E2) ----------

  const STATUS_PEDIDO = {
    aguardando_pagamento: "Aguardando pagamento",
    pago: "Pago",
    em_separacao: "Em separação",
    pronto_retirada: "Pronto para retirada",
    retirado: "Retirado",
    cancelado: "Cancelado",
    enviado: "Enviado",
    entregue: "Entregue",
    expirado: "Expirado",
  };
  const numeroOuNulo = (valor) => {
    const t = String(valor ?? "").trim();
    return t === "" ? null : Number(t);
  };
  const dataHora = (valor) => new Date(valor).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" });
  const pedidoAberto = (p) => p.status === "aguardando_pagamento" && new Date(p.expira_em).getTime() > Date.now();

  // O SDK devolve uma mensagem genérica. A Edge Function manda o motivo real no corpo.
  async function mensagemFuncao(erro) {
    try {
      const corpo = await erro.context?.json();
      if (corpo?.erro) return corpo.erro;
    } catch (_) { /* sem corpo legível */ }
    return "Não foi possível abrir o pagamento agora. Tente de novo em instantes.";
  }

  async function pagarPedido(pedidoId) {
    const { data, error } = await sb().functions.invoke("loja-pagamento-criar", { body: { pedido_id: pedidoId } });
    if (error) return { erro: await mensagemFuncao(error) };
    return { url: data?.init_point };
  }

  async function pedido(alvo, perfil, id, retorno) {
    carregando(alvo);
    const [{ data: p, error }, { data: config }, { data: devolucao }] = await Promise.all([
      sb().from("pedidos")
        .select("id, codigo, status, metodo_entrega, subtotal_centavos, desconto_centavos, cupom_codigo, frete_centavos, total_centavos, frete_servico, prazo_dias, endereco, codigo_rastreio, expira_em, entregue_em, criado_em, pedido_itens(nome_snapshot, preco_unitario_centavos, quantidade)")
        .eq("id", id).maybeSingle(),
      sb().from("loja_configuracoes").select("chave, valor").in("chave", ["nome_loja", "endereco_retirada", "horario_retirada"]),
      sb().from("devolucoes_loja").select("id, tipo, motivo, status, observacao_admin").eq("pedido_id", id).maybeSingle(),
    ]);

    let aviso = "";
    try {
      aviso = sessionStorage.getItem("loja-aviso") || "";
      sessionStorage.removeItem("loja-aviso");
    } catch (_) { /* sem armazenamento */ }

    if (error || !p) {
      alvo.innerHTML = `<p class="rodape-form"><a href="#loja/pedidos">← Meus pedidos</a></p><p class="ajuda">Pedido não encontrado.</p>`;
      return;
    }

    const cfg = Object.fromEntries((config || []).map((c) => [c.chave, c.valor]));
    const aberto = pedidoAberto(p);
    const confirmando = retorno && p.status === "aguardando_pagamento";
    const itens = p.pedido_itens || [];
    const retirada = p.metodo_entrega === "retirada";
    const e = p.endereco;

    // Devolução: pedido já feito, ou formulário para pedir (o servidor confere o prazo).
    const podePedirDevolucao = !devolucao && (p.status === "entregue" || p.status === "retirado") && p.entregue_em;
    const blocoDevolucao = devolucao
      ? `<section class="cartao">
           <h2>Devolução</h2>
           <p><strong>${esc(DEVOLUCAO_STATUS[devolucao.status] || devolucao.status)}</strong></p>
           <p class="texto-puro">${esc(devolucao.motivo)}</p>
           ${devolucao.status === "aprovada" ? `<p class="ajuda">Envie ou leve o produto para: ${esc(cfg.endereco_retirada || "o endereço informado pela cooperativa")}. Guarde o comprovante de envio.</p>` : ""}
           ${devolucao.observacao_admin ? `<p class="ajuda">Observação da loja: ${esc(devolucao.observacao_admin)}</p>` : ""}
         </section>`
      : podePedirDevolucao
        ? `<section class="cartao">
             <h2>Pedir devolução</h2>
             <p class="ajuda">Arrependimento: até 7 dias depois da entrega. Defeito ou troca: até 30 dias.</p>
             <form id="form-devolucao" class="formulario" novalidate>
               <label>Tipo
                 <select name="tipo">
                   <option value="arrependimento">Arrependimento (desisti da compra)</option>
                   <option value="defeito">Defeito ou produto errado</option>
                   <option value="troca">Troca</option>
                 </select>
               </label>
               <label>Motivo <small>(conte o que aconteceu)</small>
                 <textarea name="motivo" rows="3" maxlength="500" required></textarea>
               </label>
               <button type="submit" class="btn-ghost">Enviar pedido de devolução</button>
             </form>
           </section>`
        : "";

    const blocoEntrega = retirada
      ? `<section class="cartao">
           <h2>Retirada na cooperativa</h2>
           <p><strong>${esc(cfg.nome_loja || "Cooperativa")}</strong></p>
           <p class="texto-puro">${esc(cfg.endereco_retirada || "O endereço será informado pela cooperativa.")}</p>
           ${cfg.horario_retirada ? `<p class="ajuda">Horário: ${esc(cfg.horario_retirada)}</p>` : ""}
           <p class="ajuda">Você será avisado no aplicativo quando o pedido estiver pronto para retirada.</p>
         </section>`
      : `<section class="cartao">
           <h2>Entrega</h2>
           <p><strong>${esc(p.frete_servico || "Entrega")}</strong></p>
           ${p.prazo_dias ? `<p class="ajuda">Prazo estimado: ${Number(p.prazo_dias)} dia(s) úteis após o envio</p>` : ""}
           ${p.codigo_rastreio ? `<p>Código de rastreio: <strong>${esc(p.codigo_rastreio)}</strong></p>` : ""}
           ${e ? `<p class="texto-puro">${esc(e.logradouro)}, ${esc(e.numero)}${e.complemento ? " - " + esc(e.complemento) : ""}<br />${esc(e.bairro)} · ${esc(e.cidade)}/${esc(e.uf)} · CEP ${esc(e.cep)}</p>` : ""}
         </section>`;

    alvo.innerHTML = `
      <p class="rodape-form"><a href="#loja/pedidos">← Meus pedidos</a></p>
      <h1>Pedido ${esc(p.codigo)}</h1>
      <p class="marcas"><span class="marca">${esc(STATUS_PEDIDO[p.status] || p.status)}</span></p>
      ${aviso ? `<p class="erro" role="alert">${esc(aviso)}</p>` : ""}
      ${confirmando ? '<p class="aviso-geral" role="status">Estamos confirmando seu pagamento. Esta página se atualiza sozinha.</p>' : ""}
      ${ERRO_GERAL}
      ${AVISO_GERAL}
      <section class="cartao">
        <h2>Itens</h2>
        <div class="lista">
          ${itens.map((i) => `
            <article class="item">
              <strong>${esc(i.nome_snapshot)}</strong>
              <span class="ajuda">${Number(i.quantidade)} × ${reais(i.preco_unitario_centavos)}</span>
            </article>`).join("")}
        </div>
        <p>Subtotal: ${reais(p.subtotal_centavos)}${p.desconto_centavos ? ` · Desconto${p.cupom_codigo ? ` (${esc(p.cupom_codigo)})` : ""}: -${reais(p.desconto_centavos)}` : ""}${p.frete_centavos ? ` · Frete: ${reais(p.frete_centavos)}` : " · Frete: sem custo"}</p>
        <p><strong>Total: ${reais(p.total_centavos)}</strong></p>
      </section>
      ${blocoEntrega}
      ${blocoDevolucao}
      ${aberto
        ? `<section class="cartao">
             <p>Pague até ${dataHora(p.expira_em)}. Depois desse prazo, o pedido é cancelado e os produtos voltam ao estoque.</p>
             <div class="acoes-evento">
               <button type="button" class="btn-primario" id="pagar">Pagar agora</button>
               <button type="button" class="btn-ghost" id="cancelar">Cancelar pedido</button>
             </div>
           </section>`
        : ""}`;

    alvo.querySelector("#pagar")?.addEventListener("click", async (ev) => {
      const botao = ev.currentTarget;
      botao.disabled = true;
      const { url, erro } = await pagarPedido(p.id);
      if (erro || !url) {
        botao.disabled = false;
        return erroNa(alvo, erro || "Pagamento indisponível.");
      }
      window.location.href = url;
    });

    alvo.querySelector("#form-devolucao")?.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      const f = new FormData(ev.currentTarget);
      const motivo = String(f.get("motivo") || "").trim();
      if (motivo.length < 5) return erroNa(alvo, "Conte o motivo com pelo menos 5 letras.");
      const botao = ev.currentTarget.querySelector("button[type=submit]");
      botao.disabled = true;
      const { error: falha } = await sb().rpc("solicitar_devolucao_loja", {
        p_pedido: p.id,
        p_tipo: String(f.get("tipo")),
        p_motivo: motivo,
      });
      if (falha) {
        botao.disabled = false;
        return erroNa(alvo, falha.message);
      }
      pedido(alvo, perfil, p.id, false);
    });

    alvo.querySelector("#cancelar")?.addEventListener("click", async () => {
      if (!confirm("Cancelar este pedido? Os produtos voltam ao estoque.")) return;
      const { error: falha } = await sb().rpc("cancelar_pedido_loja", { p_pedido: p.id });
      if (falha) return erroNa(alvo, falha.message);
      location.hash = "#loja/pedidos";
    });

    // Depois de voltar do Mercado Pago, espera a confirmação chegar (até 1 minuto).
    if (confirmando) {
      const hashAtual = location.hash;
      let tentativas = 0;
      const ciclo = setInterval(async () => {
        tentativas += 1;
        if (location.hash !== hashAtual || tentativas > 12) return clearInterval(ciclo);
        const { data: atual } = await sb().from("pedidos").select("status").eq("id", p.id).maybeSingle();
        if (atual && atual.status !== "aguardando_pagamento") {
          clearInterval(ciclo);
          pedido(alvo, perfil, p.id, false);
        }
      }, 5000);
    }
  }

  async function pedidos(alvo) {
    carregando(alvo);
    const { data, error } = await sb().from("pedidos")
      .select("id, codigo, status, total_centavos, criado_em")
      .order("criado_em", { ascending: false })
      .limit(50);

    if (error) {
      alvo.innerHTML = `<p class="erro" role="alert">${esc(error.message)}</p>`;
      return;
    }

    alvo.innerHTML = `
      <p class="rodape-form"><a href="#loja">← Voltar para a loja</a></p>
      <h1>Meus pedidos</h1>
      ${(data || []).length
        ? `<div class="lista">
             ${data.map((p) => `
               <a class="item evento" href="#loja/pedido/${esc(p.id)}">
                 <span class="evento-texto">
                   <strong>${esc(p.codigo)}</strong>
                   <span class="ajuda">${dataHora(p.criado_em)} · ${reais(p.total_centavos)}</span>
                   <span class="marcas"><span class="marca">${esc(STATUS_PEDIDO[p.status] || p.status)}</span></span>
                 </span>
               </a>`).join("")}
           </div>`
        : '<p class="ajuda">Você ainda não fez pedidos. <a href="#loja">Ver produtos</a></p>'}`;
  }

  const ACOES_PEDIDO = (p) => {
    const cancelar = ["cancelado", "Cancelar e devolver estoque"];
    if (p.status === "pago") return [["em_separacao", "Iniciar separação"], cancelar];
    if (p.status === "em_separacao") {
      return p.metodo_entrega === "retirada" ? [["pronto_retirada", "Pronto para retirada"], cancelar] : [cancelar];
    }
    if (p.status === "pronto_retirada") return [["retirado", "Marcar como retirado"]];
    if (p.status === "enviado") return [["entregue", "Marcar como entregue"]];
    return [];
  };

  async function gerenciarPedidos(alvo) {
    carregando(alvo);
    const { data, error } = await sb().from("pedidos")
      .select("id, codigo, status, metodo_entrega, frete_servico, endereco, codigo_rastreio, total_centavos, criado_em, observacao_admin, usuarios(nome_completo), pedido_itens(nome_snapshot, quantidade)")
      .order("criado_em", { ascending: false })
      .limit(60);

    if (error) {
      alvo.innerHTML = `<p class="erro" role="alert">${esc(error.message)}</p>`;
      return;
    }

    alvo.innerHTML = `
      <p class="rodape-form"><a href="#loja/gerenciar">← Voltar para gerenciar loja</a></p>
      <h1>Pedidos da loja</h1>
      <p class="ajuda">Pedidos pagos aparecem aqui para separação. Cancelar um pedido pago devolve o estoque, mas o reembolso é feito no Mercado Pago.</p>
      ${ERRO_GERAL}
      ${(data || []).length
        ? `<div class="lista">
             ${data.map((p) => {
               const acoes = ACOES_PEDIDO(p);
               const envio = p.status === "em_separacao" && p.metodo_entrega !== "retirada";
               return `
                 <article class="item avaliacao-item" data-pedido="${esc(p.id)}">
                   <span class="evento-texto">
                     <strong>${esc(p.codigo)}</strong>
                     <span class="ajuda">${esc(p.usuarios?.nome_completo || "Cooperado")} · ${dataHora(p.criado_em)} · ${reais(p.total_centavos)}</span>
                     <span class="ajuda">${p.metodo_entrega === "retirada" ? "Retirada na cooperativa" : esc(p.frete_servico || "Entrega")}</span>
                   </span>
                   <span class="marcas"><span class="marca">${esc(STATUS_PEDIDO[p.status] || p.status)}</span></span>
                   ${p.endereco ? `<p class="texto-puro">${esc(p.endereco.logradouro)}, ${esc(p.endereco.numero)} · ${esc(p.endereco.bairro)} · ${esc(p.endereco.cidade)}/${esc(p.endereco.uf)} · CEP ${esc(p.endereco.cep)}</p>` : ""}
                   ${p.codigo_rastreio ? `<p>Rastreio: <strong>${esc(p.codigo_rastreio)}</strong></p>` : ""}
                   <ul class="ajuda">
                     ${(p.pedido_itens || []).map((i) => `<li>${Number(i.quantidade)} × ${esc(i.nome_snapshot)}</li>`).join("")}
                   </ul>
                   ${p.observacao_admin ? `<p class="erro">${esc(p.observacao_admin)}</p>` : ""}
                   ${envio ? `
                     <label>Código de rastreio <small>(obrigatório para transportadora)</small>
                       <input type="text" data-rastreio maxlength="60" />
                     </label>
                     <div class="acoes-evento">
                       <button type="button" class="btn-primario" data-enviar="${esc(p.id)}">Marcar como enviado</button>
                     </div>` : ""}
                   <div class="acoes-evento">
                     ${acoes.map(([status, rotulo]) =>
                       `<button type="button" class="btn-ghost" data-pedido-id="${esc(p.id)}" data-status="${status}">${rotulo}</button>`).join("")}
                   </div>
                 </article>`;
             }).join("")}
           </div>`
        : '<p class="ajuda">Nenhum pedido ainda.</p>'}`;

    alvo.querySelectorAll("[data-enviar]").forEach((botao) => {
      botao.addEventListener("click", async () => {
        const campo = botao.closest("[data-pedido]").querySelector("[data-rastreio]");
        botao.disabled = true;
        const { error: falha } = await sb().rpc("marcar_envio_loja", {
          p_pedido: botao.dataset.enviar,
          p_codigo: campo.value.trim() || null,
        });
        if (falha) {
          botao.disabled = false;
          return erroNa(alvo, falha.message);
        }
        gerenciarPedidos(alvo);
      });
    });

    alvo.querySelectorAll("[data-pedido-id]").forEach((botao) => {
      botao.addEventListener("click", async () => {
        if (botao.dataset.status === "cancelado" && !confirm("Cancelar este pedido e devolver os produtos ao estoque?")) return;
        botao.disabled = true;
        const { error: falha } = await sb().rpc("avancar_pedido_loja", {
          p_pedido: botao.dataset.pedidoId,
          p_status: botao.dataset.status,
        });
        if (falha) {
          botao.disabled = false;
          return erroNa(alvo, falha.message);
        }
        gerenciarPedidos(alvo);
      });
    });
  }

  async function configuracoesPagamento(alvo) {
    carregando(alvo);
    const [{ data: linhas }, { data: situacao }] = await Promise.all([
      sb().from("loja_configuracoes").select("chave, valor"),
      sb().rpc("status_loja_pagamento"),
    ]);
    const v = Object.fromEntries((linhas || []).map((l) => [l.chave, l.valor]));
    const situacaoTexto = (ok) => (ok ? "configurado" : "não configurado");
    const centavosParaCampo = (c) => (Number(c || 0) / 100).toFixed(2).replace(".", ",");
    const selecionado = (ok, valor) => (ok === valor ? "selected" : "");

    alvo.innerHTML = `
      <p class="rodape-form"><a href="#loja/gerenciar">← Voltar para gerenciar loja</a></p>
      <h1>Pagamento e configurações</h1>
      <p class="ajuda">Preencha os dados da loja, de entrega e as chaves de pagamento e frete. As chaves secretas são guardadas de forma protegida. Depois de salvas, o sistema só mostra se estão configuradas.</p>
      ${ERRO_GERAL}
      ${AVISO_GERAL}
      <form id="form-config" class="formulario" novalidate>
        <h2>Dados da loja</h2>
        <label>Nome da loja
          <input type="text" name="nome_loja" maxlength="120" value="${esc(v.nome_loja || "")}" />
        </label>
        <label>Endereço para retirada
          <textarea name="endereco_retirada" rows="3" maxlength="500">${esc(v.endereco_retirada || "")}</textarea>
        </label>
        <label>Horário de retirada
          <input type="text" name="horario_retirada" maxlength="200" placeholder="Ex.: segunda a sexta, 8h às 17h" value="${esc(v.horario_retirada || "")}" />
        </label>
        <label>Minutos para pagar um pedido
          <input type="number" name="minutos_expiracao_pedido" min="5" max="1440" step="1" value="${esc(v.minutos_expiracao_pedido || "30")}" />
        </label>
        <label>Endereço do aplicativo <small>(começa com https://)</small>
          <input type="url" name="url_publica_app" maxlength="200" placeholder="https://seu-app.vercel.app" value="${esc(v.url_publica_app || "")}" />
        </label>

        <h2>Entrega</h2>
        <label>CEP de origem <small>(de onde os pacotes saem)</small>
          <input type="text" name="cep_origem" inputmode="numeric" maxlength="9" placeholder="00000-000" value="${esc(v.cep_origem || "")}" />
        </label>
        <label>Entrega local
          <select name="entrega_local_ativa">
            <option value="nao" ${selecionado(v.entrega_local_ativa === "sim" ? "sim" : "nao", "nao")}>Desligada</option>
            <option value="sim" ${selecionado(v.entrega_local_ativa === "sim" ? "sim" : "nao", "sim")}>Ligada</option>
          </select>
        </label>
        <label>CEPs da entrega local <small>(5 primeiros números, separados por vírgula)</small>
          <input type="text" name="entrega_local_ceps" maxlength="200" placeholder="Ex.: 35160, 35161" value="${esc(v.entrega_local_ceps || "")}" />
        </label>
        <label>Taxa da entrega local (R$)
          <input type="text" name="taxa_entrega_local" inputmode="decimal" placeholder="Ex.: 10,00" value="${centavosParaCampo(v.taxa_entrega_local_centavos)}" />
        </label>

        <h2>Mercado Pago</h2>
        <label>Chave pública
          <input type="text" name="mp_public_key" maxlength="200" value="${esc(v.mp_public_key || "")}" />
        </label>
        <label>Token de acesso <small>(${situacaoTexto(situacao?.mp_access_token)})</small>
          <input type="text" name="mp_access_token" autocomplete="off" spellcheck="false" maxlength="300"
            placeholder="${situacao?.mp_access_token ? "Configurado. Digite um novo token só para trocar" : "Cole o token de acesso"}" />
        </label>
        <label>Chave secreta do webhook <small>(${situacaoTexto(situacao?.mp_webhook_secret)})</small>
          <input type="text" name="mp_webhook_secret" autocomplete="off" spellcheck="false" maxlength="300"
            placeholder="${situacao?.mp_webhook_secret ? "Configurada. Digite uma nova chave só para trocar" : "Cole a chave secreta do webhook"}" />
        </label>
        <p class="ajuda">Endereço de notificação para cadastrar no Mercado Pago:<br />
          <code>${esc(window.APP_CONFIG.SUPABASE_URL)}/functions/v1/loja-pagamento-webhook</code></p>

        <h2>Transportadoras (Melhor Envio)</h2>
        <label>Ambiente
          <select name="melhor_envio_sandbox">
            <option value="sim" ${selecionado(v.melhor_envio_sandbox === "sim" ? "sim" : "nao", "sim")}>Teste (sandbox)</option>
            <option value="nao" ${selecionado(v.melhor_envio_sandbox === "sim" ? "sim" : "nao", "nao")}>Produção</option>
          </select>
        </label>
        <label>Token de acesso <small>(${situacaoTexto(situacao?.melhor_envio_token)})</small>
          <input type="text" name="melhor_envio_token" autocomplete="off" spellcheck="false" maxlength="2000"
            placeholder="${situacao?.melhor_envio_token ? "Configurado. Digite um novo token só para trocar" : "Cole o token do Melhor Envio"}" />
        </label>
        <button type="submit" class="btn-primario">Salvar configurações</button>
      </form>`;

    alvo.querySelector("#form-config").addEventListener("submit", async (ev) => {
      ev.preventDefault();
      const form = ev.currentTarget;
      const f = new FormData(form);
      const minutos = Number(f.get("minutos_expiracao_pedido"));
      const url = String(f.get("url_publica_app") || "").trim();
      const cepOrigem = String(f.get("cep_origem") || "").replace(/\D/g, "");
      const taxa = String(f.get("taxa_entrega_local") || "").trim();
      const taxaCentavos = taxa ? parseReais(taxa) : 0;

      if (!Number.isInteger(minutos) || minutos < 5 || minutos > 1440) {
        return erroNa(alvo, "O prazo para pagar precisa estar entre 5 e 1440 minutos.");
      }
      if (url) {
        try {
          if (new URL(url).protocol !== "https:") throw new Error();
        } catch (_) {
          return erroNa(alvo, "O endereço do aplicativo precisa começar com https://");
        }
      }
      if (cepOrigem && cepOrigem.length !== 8) {
        return erroNa(alvo, "O CEP de origem precisa ter 8 números.");
      }
      if (!Number.isFinite(taxaCentavos) || taxaCentavos < 0) {
        return erroNa(alvo, "Informe a taxa da entrega local no formato 10,00.");
      }

      const botao = form.querySelector("button[type=submit]");
      botao.disabled = true;
      const campos = [
        "nome_loja", "endereco_retirada", "horario_retirada", "minutos_expiracao_pedido",
        "url_publica_app", "mp_public_key", "entrega_local_ativa", "entrega_local_ceps", "melhor_envio_sandbox",
      ];
      const linhasSalvar = campos.map((chave) => ({ chave, valor: String(f.get(chave) || "").trim(), atualizado_em: new Date().toISOString() }));
      linhasSalvar.push({ chave: "cep_origem", valor: cepOrigem, atualizado_em: new Date().toISOString() });
      linhasSalvar.push({ chave: "taxa_entrega_local_centavos", valor: String(taxaCentavos), atualizado_em: new Date().toISOString() });

      const { error: falha } = await sb().from("loja_configuracoes").upsert(linhasSalvar, { onConflict: "chave" });
      if (falha) {
        botao.disabled = false;
        return erroNa(alvo, falha.message);
      }

      for (const nome of ["mp_access_token", "mp_webhook_secret", "melhor_envio_token"]) {
        const valor = String(f.get(nome) || "").trim();
        if (!valor) continue;
        const { error: falhaSegredo } = await sb().rpc("salvar_segredo_loja", { p_nome: nome, p_valor: valor });
        if (falhaSegredo) {
          botao.disabled = false;
          return erroNa(alvo, falhaSegredo.message);
        }
      }

      configuracoesPagamento(alvo);
      avisoNa(alvo, "Configurações salvas.");
    });
  }

  // ---------- Entrega e pagamento (checkout) ----------

  const formatarCep = (valor) => {
    const d = String(valor || "").replace(/\D/g, "").slice(0, 8);
    return d.length > 5 ? `${d.slice(0, 5)}-${d.slice(5)}` : d;
  };

  async function buscarCep(cep) {
    try {
      const r = await fetch(`https://viacep.com.br/ws/${cep}/json/`);
      const dados = await r.json();
      return dados.erro ? null : dados;
    } catch (_) {
      return null;
    }
  }

  async function finalizar(alvo, perfil) {
    carregando(alvo);
    const { data: itens, error } = await sb().from("carrinho_itens")
      .select("quantidade, produto:loja_produtos(preco_centavos, preco_promo_centavos)")
      .eq("usuario_id", perfil.id);
    const linhas = (itens || []).filter((i) => i.produto);

    if (error || !linhas.length) {
      alvo.innerHTML = `<p class="rodape-form"><a href="#loja/carrinho">← Voltar ao carrinho</a></p><p class="ajuda">Seu carrinho está vazio.</p>`;
      return;
    }

    const subtotal = linhas.reduce((soma, i) => soma + i.quantidade * (i.produto.preco_promo_centavos ?? i.produto.preco_centavos), 0);
    let cotacao = null;
    let frete = null;
    // Cupom aplicado: o servidor confere de novo na hora de criar o pedido.
    let cupom = null;

    alvo.innerHTML = `
      <p class="rodape-form"><a href="#loja/carrinho">← Voltar ao carrinho</a></p>
      <h1>Entrega e pagamento</h1>
      <section class="cartao"><p>Subtotal dos produtos: <strong>${reais(subtotal)}</strong></p></section>
      <section class="cartao">
        <label>Cupom de desconto <small>(opcional)</small>
          <input type="text" name="cupom" maxlength="20" autocomplete="off" placeholder="Ex.: BEMVINDO10" />
        </label>
        <button type="button" class="btn-ghost" id="aplicar-cupom">Aplicar cupom</button>
        <p class="ajuda" id="cupom-msg" role="status"></p>
      </section>
      ${ERRO_GERAL}
      ${AVISO_GERAL}
      <form id="form-entrega" class="formulario" novalidate>
        <h2>Como receber</h2>
        <label>CEP <small>(para calcular a entrega)</small>
          <input type="text" name="cep" inputmode="numeric" autocomplete="postal-code" maxlength="9" placeholder="00000-000" />
        </label>
        <button type="button" class="btn-ghost" id="calcular">Calcular entrega</button>
        <div id="opcoes"></div>
        <div id="endereco" hidden>
          <h2>Endereço de entrega</h2>
          <label>Rua, avenida ou praça <input type="text" name="logradouro" maxlength="150" /></label>
          <div class="linha-campos">
            <label>Número <input type="text" name="numero" maxlength="20" /></label>
            <label>Complemento <small>(opcional)</small> <input type="text" name="complemento" maxlength="60" /></label>
          </div>
          <label>Bairro <input type="text" name="bairro" maxlength="100" /></label>
          <div class="linha-campos">
            <label>Cidade <input type="text" name="cidade" maxlength="100" /></label>
            <label>UF <input type="text" name="uf" maxlength="2" /></label>
          </div>
        </div>
        <p class="total" id="total"></p>
        <button type="submit" class="btn-primario" id="continuar" disabled>Ir para o pagamento</button>
      </form>`;

    const form = alvo.querySelector("#form-entrega");
    const campoCep = form.querySelector("[name=cep]");
    const enderecoBox = alvo.querySelector("#endereco");
    const atualizarTotal = () => {
      const botaoContinuar = alvo.querySelector("#continuar");
      if (!frete) {
        alvo.querySelector("#total").textContent = "";
        botaoContinuar.disabled = true;
        return;
      }
      const desconto = cupom?.desconto_centavos || 0;
      const total = subtotal - desconto + frete.preco_centavos;
      alvo.querySelector("#total").textContent = `Total: ${reais(total)} (produtos ${reais(subtotal)}${desconto ? ` − desconto ${reais(desconto)}` : ""} + entrega ${reais(frete.preco_centavos)})`;
      botaoContinuar.disabled = false;
    };

    const campoCupom = alvo.querySelector("[name=cupom]");
    const msgCupom = alvo.querySelector("#cupom-msg");
    const mostrarCupom = (texto, erro) => {
      msgCupom.textContent = texto;
      msgCupom.className = erro ? "erro" : "ajuda";
    };

    alvo.querySelector("#aplicar-cupom").addEventListener("click", async (ev) => {
      const codigo = campoCupom.value.trim();
      if (!codigo) {
        cupom = null;
        mostrarCupom("", false);
        atualizarTotal();
        return;
      }
      const botao = ev.currentTarget;
      botao.disabled = true;
      const { data, error: falha } = await sb().rpc("validar_cupom_loja", { p_codigo: codigo });
      botao.disabled = false;
      if (falha) {
        cupom = null;
        mostrarCupom(falha.message, true);
        atualizarTotal();
        return;
      }
      cupom = { codigo: data.codigo, desconto_centavos: data.desconto_centavos };
      mostrarCupom(`Cupom ${data.codigo} aplicado: ${reais(data.desconto_centavos)} de desconto.`, false);
      atualizarTotal();
    });

    campoCep.addEventListener("input", () => { campoCep.value = formatarCep(campoCep.value); });

    alvo.querySelector("#calcular").addEventListener("click", async (ev) => {
      const cep = campoCep.value.replace(/\D/g, "");
      if (cep.length !== 8) return erroNa(alvo, "Informe um CEP com 8 números.");
      const botao = ev.currentTarget;
      botao.disabled = true;
      avisoNa(alvo, "");
      alvo.querySelector(".erro-geral").hidden = true;

      const { data, error: falha } = await sb().functions.invoke("loja-frete-cotar", { body: { cep } });
      botao.disabled = false;
      if (falha) return erroNa(alvo, await mensagemFuncao(falha));

      cotacao = data;
      frete = null;
      alvo.querySelector("#opcoes").innerHTML = `
        <fieldset class="opcoes-entrega">
          <legend>Escolha a forma de entrega</legend>
          ${data.opcoes.map((o) => `
            <label class="opcao-entrega">
              <input type="radio" name="opcao" value="${esc(o.id)}" data-metodo="${esc(o.metodo)}" data-preco="${Number(o.preco_centavos)}" />
              <span>
                <strong>${esc(o.nome)}</strong>
                <span class="ajuda">${o.preco_centavos ? reais(o.preco_centavos) : "Sem custo"}${o.prazo_dias ? ` · prazo de ${Number(o.prazo_dias)} dia(s) úteis` : ""}</span>
              </span>
            </label>`).join("")}
        </fieldset>`;

      // Preenche o endereço pelo CEP (quando o serviço responde). O cooperado confere e completa.
      const dadosCep = await buscarCep(cep);
      if (dadosCep) {
        form.logradouro.value = dadosCep.logradouro || "";
        form.bairro.value = dadosCep.bairro || "";
        form.cidade.value = dadosCep.localidade || "";
        form.uf.value = dadosCep.uf || "";
      }
      enderecoBox.hidden = true;
      atualizarTotal();
    });

    alvo.querySelector("#opcoes").addEventListener("change", (ev) => {
      const escolhida = ev.target.closest("input[name=opcao]");
      if (!escolhida) return;
      frete = { id: escolhida.value, metodo: escolhida.dataset.metodo, preco_centavos: Number(escolhida.dataset.preco) };
      enderecoBox.hidden = frete.metodo === "retirada";
      atualizarTotal();
    });

    form.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      if (!cotacao || !frete) return erroNa(alvo, "Escolha uma forma de entrega.");

      let endereco = null;
      if (frete.metodo !== "retirada") {
        const f = new FormData(form);
        endereco = {
          cep: campoCep.value.replace(/\D/g, ""),
          logradouro: String(f.get("logradouro") || "").trim(),
          numero: String(f.get("numero") || "").trim(),
          complemento: String(f.get("complemento") || "").trim() || null,
          bairro: String(f.get("bairro") || "").trim(),
          cidade: String(f.get("cidade") || "").trim(),
          uf: String(f.get("uf") || "").trim().toUpperCase(),
        };
        if (!endereco.logradouro || !endereco.numero || !endereco.bairro || !endereco.cidade || endereco.uf.length !== 2) {
          return erroNa(alvo, "Preencha o endereço de entrega: rua, número, bairro, cidade e UF.");
        }
      }

      const botao = alvo.querySelector("#continuar");
      botao.disabled = true;
      const { data: pedidoId, error: falha } = await sb().rpc("criar_pedido_loja", {
        p_cotacao: cotacao.cotacao_id,
        p_opcao: frete.id,
        p_endereco: endereco,
        ...(cupom ? { p_cupom: cupom.codigo } : {}),
      });
      if (falha) {
        botao.disabled = false;
        return erroNa(alvo, falha.message);
      }

      const { url, erro } = await pagarPedido(pedidoId);
      if (erro || !url) {
        try { sessionStorage.setItem("loja-aviso", erro || "Pagamento indisponível."); } catch (_) { /* sem armazenamento */ }
        location.hash = `#loja/pedido/${pedidoId}`;
        return;
      }
      window.location.href = url;
    });
  }

  // ---------- Indicações ----------

  async function indicacoes(alvo) {
    carregando(alvo);
    const { data, error } = await sb().rpc("minhas_indicacoes_loja");
    if (error) {
      alvo.innerHTML = `<p class="erro" role="alert">${esc(error.message)}</p>`;
      return;
    }

    const lista = data || [];
    alvo.innerHTML = `
      <p class="rodape-form"><a href="#loja/listas">← Voltar para as listas</a></p>
      <h1>Minhas indicações</h1>
      <p class="ajuda">Envie o link para um amigo. Quando ele abrir o link logado no aplicativo, a indicação conta aqui. O aplicativo não guarda o contato de quem você indicou.</p>
      ${ERRO_GERAL}
      ${AVISO_GERAL}
      ${lista.length
        ? `<div class="lista">
             ${lista.map((i) => `
               <article class="item">
                 <strong>${esc(i.nome || "Item indisponível")}</strong>
                 <span class="ajuda">${i.tipo === "lista" ? "Lista" : "Produto"} · ${Number(i.aceites) === 1 ? "1 amigo aceitou" : `${Number(i.aceites)} amigos aceitaram`}</span>
                 <div class="acoes-evento">
                   <button type="button" class="btn-ghost" data-enviar="${esc(i.token)}" data-titulo="${esc(i.nome || "Loja")}">Enviar de novo</button>
                 </div>
               </article>`).join("")}
           </div>`
        : '<p class="ajuda">Você ainda não indicou nada. Abra um produto ou uma lista e toque em “Indicar a um amigo”. <a href="#loja">Ver produtos</a></p>'}`;

    alvo.querySelectorAll("[data-enviar]").forEach((botao) => {
      botao.addEventListener("click", async () => {
        avisoNa(alvo, await compartilhar(botao.dataset.titulo, urlApp(`loja/indicacao/${botao.dataset.enviar}`)));
      });
    });
  }

  // Quem abre o link de indicação aceita e segue para o produto ou a lista.
  async function aceitarIndicacao(alvo, perfil, token) {
    carregando(alvo);
    const { data, error } = await sb().rpc("aceitar_indicacao_loja", { p_token: token });
    if (error || !data) {
      alvo.innerHTML = `<p class="rodape-form"><a href="#loja">← Voltar para a loja</a></p><p class="erro" role="alert">${esc(error?.message || "Indicação indisponível.")}</p>`;
      return;
    }
    location.hash = data.tipo === "produto" ? `#loja/produto/${data.id}` : `#loja/compartilhada/${data.token}`;
  }

  // ---------- Cupons (administrador) ----------

  async function cuponsAdmin(alvo) {
    carregando(alvo);
    const { data: cupons, error } = await sb().from("cupons_loja")
      .select("id, codigo, tipo, valor, minimo_centavos, limite_usos, limite_por_usuario, validade_ate, ativo")
      .order("criado_em", { ascending: false });
    if (error) {
      alvo.innerHTML = `<p class="erro" role="alert">${esc(error.message)}</p>`;
      return;
    }

    const lista = cupons || [];
    const campoReais = (centavos) => (Number(centavos) / 100).toFixed(2).replace(".", ",");
    const dataCampo = (valor) => {
      const d = new Date(valor);
      return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
    };
    const descreve = (c) => (c.tipo === "percentual" ? `${Number(c.valor)}%` : reais(c.valor));

    alvo.innerHTML = `
      <p class="rodape-form"><a href="#loja/gerenciar">← Voltar para gerenciar loja</a></p>
      <h1>Cupons de desconto</h1>
      <p class="ajuda">O desconto é calculado pelo servidor no fechamento do pedido. Pedidos cancelados ou expirados liberam o uso do cupom.</p>
      ${ERRO_GERAL}
      ${AVISO_GERAL}
      <section class="cartao">
        <h2>Cupons cadastrados</h2>
        ${lista.length
          ? `<div class="lista">
               ${lista.map((c) => `
                 <article class="item">
                   <strong>${esc(c.codigo)}</strong>
                   <span class="ajuda">${esc(descreve(c))} de desconto${c.minimo_centavos ? ` · a partir de ${reais(c.minimo_centavos)}` : ""}${c.validade_ate ? ` · até ${dataHora(c.validade_ate)}` : ""}${c.limite_usos ? ` · limite de ${Number(c.limite_usos)} uso(s)` : ""} · ${Number(c.limite_por_usuario)} por pessoa</span>
                   <span class="marcas"><span class="marca">${c.ativo ? "Ativo" : "Desativado"}</span></span>
                   <div class="acoes-evento"><button type="button" class="btn-ghost" data-editar="${esc(c.id)}">Editar</button></div>
                 </article>`).join("")}
             </div>`
          : '<p class="ajuda">Nenhum cupom cadastrado ainda.</p>'}
      </section>
      <form id="form-cupom" class="formulario cartao" novalidate>
        <h2 id="titulo-cupom">Novo cupom</h2>
        <input type="hidden" name="id" />
        <label>Código <small>(letras, números, - ou _; de 3 a 20)</small>
          <input type="text" name="codigo" maxlength="20" autocomplete="off" />
        </label>
        <div class="linha-campos">
          <label>Tipo
            <select name="tipo">
              <option value="percentual">Percentual (%)</option>
              <option value="valor">Valor fixo (R$)</option>
            </select>
          </label>
          <label>Valor do desconto <input type="text" name="valor" inputmode="decimal" placeholder="10 ou 15,90" /></label>
        </div>
        <div class="linha-campos">
          <label>Compra mínima (R$) <small>(opcional)</small> <input type="text" name="minimo" inputmode="decimal" /></label>
          <label>Limite de usos no total <small>(opcional)</small> <input type="number" name="limite_usos" min="1" step="1" /></label>
        </div>
        <div class="linha-campos">
          <label>Usos por pessoa <input type="number" name="limite_por_usuario" min="1" max="20" step="1" value="1" /></label>
          <label>Válido até <small>(opcional)</small> <input type="date" name="validade" /></label>
        </div>
        <label><input type="checkbox" name="ativo" checked /> Cupom ativo</label>
        <div class="acoes-evento">
          <button type="submit" class="btn-primario" id="salvar-cupom">Salvar cupom</button>
          <button type="button" class="btn-ghost" id="limpar-cupom">Limpar formulário</button>
        </div>
      </form>`;

    const form = alvo.querySelector("#form-cupom");
    const limpar = () => {
      form.reset();
      form.elements.id.value = "";
      alvo.querySelector("#titulo-cupom").textContent = "Novo cupom";
    };

    alvo.querySelector("#limpar-cupom").addEventListener("click", limpar);

    alvo.querySelectorAll("[data-editar]").forEach((botao) => {
      botao.addEventListener("click", () => {
        const c = lista.find((x) => x.id === botao.dataset.editar);
        if (!c) return;
        form.elements.id.value = c.id;
        form.codigo.value = c.codigo;
        form.tipo.value = c.tipo;
        form.valor.value = c.tipo === "percentual" ? String(c.valor) : campoReais(c.valor);
        form.minimo.value = c.minimo_centavos ? campoReais(c.minimo_centavos) : "";
        form.limite_usos.value = c.limite_usos ?? "";
        form.limite_por_usuario.value = c.limite_por_usuario;
        form.validade.value = c.validade_ate ? dataCampo(c.validade_ate) : "";
        form.ativo.checked = c.ativo;
        alvo.querySelector("#titulo-cupom").textContent = "Editar cupom";
        form.scrollIntoView({ behavior: "smooth", block: "start" });
      });
    });

    form.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      const f = new FormData(form);
      const tipo = String(f.get("tipo"));

      let valor;
      if (tipo === "percentual") {
        valor = Number(String(f.get("valor")).trim());
        if (!Number.isInteger(valor) || valor < 1 || valor > 100) return erroNa(alvo, "Percentual: informe um número inteiro de 1 a 100.");
      } else {
        valor = parseReais(f.get("valor"));
        if (!(valor > 0)) return erroNa(alvo, "Informe o valor do desconto em reais.");
      }

      const minimoTexto = String(f.get("minimo") || "").trim();
      const minimo = minimoTexto ? parseReais(minimoTexto) : 0;
      if (Number.isNaN(minimo)) return erroNa(alvo, "Compra mínima: informe um valor em reais.");

      const usosTexto = String(f.get("limite_usos") || "").trim();
      const limiteUsos = usosTexto ? Number(usosTexto) : null;
      if (usosTexto && !(Number.isInteger(limiteUsos) && limiteUsos > 0)) return erroNa(alvo, "Limite de usos: informe um número inteiro maior que zero.");

      const porPessoa = Number(f.get("limite_por_usuario"));
      if (!Number.isInteger(porPessoa) || porPessoa < 1 || porPessoa > 20) return erroNa(alvo, "Usos por pessoa: de 1 a 20.");

      const validade = f.get("validade") ? new Date(`${f.get("validade")}T23:59:59`).toISOString() : null;

      const botao = alvo.querySelector("#salvar-cupom");
      botao.disabled = true;
      const { error: falha } = await sb().rpc("salvar_cupom_loja", {
        p_id: f.get("id") || null,
        p_codigo: String(f.get("codigo") || "").trim(),
        p_tipo: tipo,
        p_valor: valor,
        p_minimo_centavos: minimo,
        p_limite_usos: limiteUsos,
        p_limite_por_usuario: porPessoa,
        p_validade: validade,
        p_ativo: form.ativo.checked,
      });
      botao.disabled = false;
      if (falha) return erroNa(alvo, falha.message);

      await cuponsAdmin(alvo);
      avisoNa(alvo, "Cupom salvo.");
    });
  }

  // ---------- Devoluções ----------

  const DEVOLUCAO_STATUS = {
    solicitada: "Em análise",
    aprovada: "Aprovada: aguardando o produto",
    recusada: "Recusada",
    recebida: "Produto recebido: reembolso pendente",
    reembolsada: "Reembolsado",
  };
  const TIPO_DEVOLUCAO = { arrependimento: "Arrependimento", defeito: "Defeito", troca: "Troca" };

  async function devolucoesAdmin(alvo) {
    carregando(alvo);
    const { data, error } = await sb().from("devolucoes_loja")
      .select("id, tipo, motivo, status, observacao_admin, criado_em, pedido:pedidos(codigo, total_centavos, mp_pagamento_id, mp_status)")
      .order("criado_em", { ascending: false });
    if (error) {
      alvo.innerHTML = `<p class="erro" role="alert">${esc(error.message)}</p>`;
      return;
    }

    const lista = data || [];
    alvo.innerHTML = `
      <p class="rodape-form"><a href="#loja/gerenciar">← Voltar para gerenciar loja</a></p>
      <h1>Devoluções</h1>
      <p class="ajuda">Aprove ou recuse o pedido, marque o produto como recebido e faça o reembolso pelo Mercado Pago. O estoque volta ao receber o produto.</p>
      ${ERRO_GERAL}
      ${AVISO_GERAL}
      ${lista.length
        ? `<div class="lista">
             ${lista.map((d) => {
               const acoes = [];
               if (d.status === "solicitada") {
                 acoes.push('<button type="button" class="btn-primario" data-acao="aprovar">Aprovar</button>');
                 acoes.push('<button type="button" class="btn-perigo" data-acao="recusar">Recusar</button>');
               }
               if (d.status === "aprovada") acoes.push('<button type="button" class="btn-ghost" data-acao="recebida">Marcar como recebida</button>');
               if ((d.status === "aprovada" || d.status === "recebida") && d.tipo !== "troca") {
                 acoes.push('<button type="button" class="btn-primario" data-acao="reembolsar">Reembolsar</button>');
               }
               return `
                 <article class="item" data-devolucao="${esc(d.id)}">
                   <strong>${esc(d.pedido?.codigo || "Pedido")} · ${esc(TIPO_DEVOLUCAO[d.tipo] || d.tipo)}</strong>
                   <span class="marcas"><span class="marca">${esc(DEVOLUCAO_STATUS[d.status] || d.status)}</span></span>
                   <span class="ajuda">Motivo: ${esc(d.motivo)}</span>
                   ${d.pedido ? `<span class="ajuda">Valor do pedido: ${reais(d.pedido.total_centavos)}${d.pedido.mp_pagamento_id ? "" : " · sem pagamento registrado no Mercado Pago"}</span>` : ""}
                   ${d.observacao_admin ? `<span class="ajuda">Observação: ${esc(d.observacao_admin)}</span>` : ""}
                   ${acoes.length ? `<div class="acoes-evento">${acoes.join("")}</div>` : ""}
                 </article>`;
             }).join("")}
           </div>`
        : '<p class="ajuda">Nenhuma devolução por enquanto.</p>'}`;

    alvo.querySelectorAll("[data-acao]").forEach((botao) => {
      botao.addEventListener("click", async () => {
        const id = botao.closest("[data-devolucao]").dataset.devolucao;
        const acao = botao.dataset.acao;

        if (acao === "reembolsar") {
          if (!confirm("Reembolsar o valor total deste pedido pelo Mercado Pago?")) return;
          botao.disabled = true;
          const { error: falha } = await sb().functions.invoke("loja-reembolso", { body: { devolucao_id: id } });
          if (falha) {
            botao.disabled = false;
            return erroNa(alvo, await mensagemFuncao(falha));
          }
          await devolucoesAdmin(alvo);
          return avisoNa(alvo, "Reembolso enviado ao Mercado Pago.");
        }

        let observacao = null;
        if (acao === "recusar") {
          observacao = prompt("Motivo da recusa (o cooperado vê este texto):");
          if (!observacao || !observacao.trim()) return;
        }

        botao.disabled = true;
        const { error: falha } = await sb().rpc("decidir_devolucao_loja", {
          p_devolucao: id,
          p_acao: acao,
          p_observacao: observacao,
        });
        if (falha) {
          botao.disabled = false;
          return erroNa(alvo, falha.message);
        }
        await devolucoesAdmin(alvo);
      });
    });
  }

  // ---------- Relatórios (administrador) ----------

  async function relatoriosAdmin(alvo) {
    const hoje = new Date();
    const dataCampo = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
    const inicioPadrao = new Date(hoje.getTime() - 29 * 86400000);

    alvo.innerHTML = `
      <p class="rodape-form"><a href="#loja/gerenciar">← Voltar para gerenciar loja</a></p>
      <h1>Relatórios da loja</h1>
      <form id="form-periodo" class="formulario cartao">
        <div class="linha-campos">
          <label>De <input type="date" name="inicio" value="${dataCampo(inicioPadrao)}" required /></label>
          <label>Até <input type="date" name="fim" value="${dataCampo(hoje)}" required /></label>
        </div>
        <button type="submit" class="btn-primario">Ver relatório</button>
      </form>
      ${ERRO_GERAL}
      <div id="resultado-relatorio"></div>`;

    const desenhar = async (ev) => {
      ev?.preventDefault();
      const f = new FormData(alvo.querySelector("#form-periodo"));
      const inicio = new Date(`${f.get("inicio")}T00:00:00`);
      const fim = new Date(`${f.get("fim")}T00:00:00`);
      fim.setDate(fim.getDate() + 1);
      if (!(inicio < fim)) return erroNa(alvo, "A data inicial precisa ser antes da final.");

      const area = alvo.querySelector("#resultado-relatorio");
      area.innerHTML = '<p class="ajuda">Calculando...</p>';
      const { data: r, error } = await sb().rpc("relatorio_loja", { p_inicio: inicio.toISOString(), p_fim: fim.toISOString() });
      if (error) {
        area.innerHTML = `<p class="erro" role="alert">${esc(error.message)}</p>`;
        return;
      }
      if (!r) {
        area.innerHTML = '<p class="ajuda">Sem dados para este período.</p>';
        return;
      }

      const nomeEntrega = { retirada: "Retirada", entrega_local: "Entrega local", transportadora: "Transportadora" };
      const porEntrega = Object.entries(r.por_entrega || {});
      area.innerHTML = `
        <section class="cartao">
          <h2>Vendas</h2>
          <p>Pedidos pagos: <strong>${Number(r.pedidos)}</strong></p>
          <p>Faturamento: <strong>${reais(r.faturamento_centavos)}</strong></p>
          <p class="ajuda">Produtos ${reais(r.produtos_centavos)} · Frete ${reais(r.frete_centavos)} · Descontos ${reais(r.descontos_centavos)}</p>
          <p>Ticket médio: ${reais(r.ticket_medio_centavos)}</p>
        </section>
        <section class="cartao">
          <h2>Entrega</h2>
          ${porEntrega.length
            ? `<ul>${porEntrega.map(([k, v]) => `<li>${esc(nomeEntrega[k] || k)}: ${Number(v)}</li>`).join("")}</ul>`
            : '<p class="ajuda">Sem pedidos no período.</p>'}
        </section>
        <section class="cartao">
          <h2>Devoluções</h2>
          <p>Reembolsadas: <strong>${Number(r.devolucoes)}</strong> · Total devolvido: <strong>${reais(r.reembolsado_centavos)}</strong></p>
        </section>
        <section class="cartao">
          <h2>Mais vendidos</h2>
          ${(r.mais_vendidos || []).length
            ? `<div class="lista">${r.mais_vendidos.map((x, n) => `
                 <article class="item">
                   <strong>${n + 1}. ${esc(x.nome || "Produto removido")}</strong>
                   <span class="ajuda">${Number(x.quantidade)} un. · ${reais(x.valor_centavos)}</span>
                 </article>`).join("")}</div>`
            : '<p class="ajuda">Sem vendas no período.</p>'}
        </section>`;
    };

    alvo.querySelector("#form-periodo").addEventListener("submit", desenhar);
    desenhar();
  }

  // caminho: partes do endereço após "loja". Ex.: ["loja", "produto", "<id>"].
  function tela(alvo, perfil, caminho) {
    const [, primeiro, segundo] = caminho;
    if (primeiro === "produto" && segundo) return produto(alvo, perfil, segundo);
    if (primeiro === "carrinho") return carrinho(alvo, perfil);
    if (primeiro === "favoritos") return favoritos(alvo, perfil);
    if (primeiro === "listas") return listas(alvo, perfil);
    if (primeiro === "lista" && segundo) return lista(alvo, perfil, segundo);
    if (primeiro === "compartilhada" && segundo) return compartilhada(alvo, perfil, segundo);
    if (primeiro === "indicacoes") return indicacoes(alvo);
    if (primeiro === "indicacao" && segundo) return aceitarIndicacao(alvo, perfil, segundo);
    if (primeiro === "finalizar") return finalizar(alvo, perfil);
    if (primeiro === "pedidos") return pedidos(alvo);
    if (primeiro === "pedido" && segundo) return pedido(alvo, perfil, segundo, location.search.includes("retorno="));
    if (primeiro === "gerenciar") {
      if (!ehAdmin(perfil)) return vitrine(alvo, perfil);
      if (segundo === "pedidos") return gerenciarPedidos(alvo);
      if (segundo === "pagamento") return configuracoesPagamento(alvo);
      if (segundo === "cupons") return cuponsAdmin(alvo);
      if (segundo === "devolucoes") return devolucoesAdmin(alvo);
      if (segundo === "relatorios") return relatoriosAdmin(alvo);
      if (segundo === "novo") return formularioProduto(alvo, perfil, null);
      if (segundo) return formularioProduto(alvo, perfil, segundo);
      return gerenciar(alvo);
    }
    return vitrine(alvo, perfil);
  }

  return { tela };
})();
