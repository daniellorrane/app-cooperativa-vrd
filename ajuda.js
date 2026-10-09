// Central de ajuda (FAQ): artigos para o cooperado resolver a dúvida antes de abrir um atendimento.
// As regras de acesso ficam no banco. Esta tela só organiza a apresentação.
window.Ajuda = (() => {
  const sb = () => window.sb;
  let cacheVisiveis = null;

  function esc(texto) {
    const d = document.createElement("div");
    d.textContent = texto ?? "";
    return d.innerHTML;
  }

  function normaliza(texto) {
    return String(texto || "")
      .toLowerCase()
      .normalize("NFD")
      .replace(/[̀-ͯ]/g, "");
  }

  const ehAdmin = (perfil) => perfil.tipo_acesso === "administrador";
  const ehStaff = (perfil) => ehAdmin(perfil) || perfil.tipo_acesso === "funcionario";

  // Artigos publicados que a pessoa pode ver. Guardados em memória até uma alteração.
  async function publicados(forcar = false) {
    if (cacheVisiveis && !forcar) return cacheVisiveis;
    const { data, error } = await sb()
      .from("faq_artigos")
      .select("id, pergunta, resposta, categoria, ordem, areas(nome)")
      .eq("publicado", true)
      .order("ordem")
      .order("pergunta");
    if (error) return [];
    cacheVisiveis = data || [];
    return cacheVisiveis;
  }

  // Quanto mais termos batem, maior a pontuação. A pergunta vale o dobro da resposta.
  function pontua(artigo, termos) {
    const pergunta = normaliza(artigo.pergunta);
    const resposta = normaliza(artigo.resposta);
    return termos.reduce((total, t) => total + (pergunta.includes(t) ? 2 : 0) + (resposta.includes(t) ? 1 : 0), 0);
  }

  // ---------- Sugestões na tela "Nova solicitação" ----------

  // Mostra até 3 artigos conforme o cooperado digita o assunto. Abrem em outra aba, sem perder o rascunho.
  async function sugerirParaAssunto(campo, destino) {
    const base = await publicados();
    campo.addEventListener("input", () => {
      const termos = normaliza(campo.value).split(/\s+/).filter((t) => t.length >= 4);
      const achados = termos.length
        ? base
            .map((a) => ({ a, p: pontua(a, termos) }))
            .filter((x) => x.p > 0)
            .sort((x, y) => y.p - x.p)
            .slice(0, 3)
        : [];

      if (!achados.length) {
        destino.hidden = true;
        destino.innerHTML = "";
        return;
      }

      destino.innerHTML = `
        <p class="ajuda"><strong>Sua dúvida pode já estar respondida:</strong></p>
        <ul class="lista-respostas">
          ${achados.map(({ a }) => `
            <li>
              <a href="#ajuda/${esc(a.id)}" target="_blank" rel="noopener">${esc(a.pergunta)}</a>
            </li>`).join("")}
        </ul>
        <p class="ajuda">Se não resolver, continue preenchendo abaixo para abrir a solicitação.</p>`;
      destino.hidden = false;
    });
  }

  // ---------- Lista pública da central ----------

  function linhasArtigos(artigos, termo) {
    const t = normaliza(termo).split(/\s+/).filter(Boolean);
    const filtrados = t.length ? artigos.filter((a) => pontua(a, t) > 0) : artigos;
    if (!filtrados.length) return '<p class="ajuda">Nenhum artigo encontrado. Tente outras palavras ou abra uma solicitação.</p>';

    const grupos = new Map();
    for (const a of filtrados) {
      const nome = a.categoria || "Geral";
      if (!grupos.has(nome)) grupos.set(nome, []);
      grupos.get(nome).push(a);
    }

    return [...grupos.entries()].map(([nome, itens]) => `
      <h2 class="dia-agenda">${esc(nome)}</h2>
      <div class="lista">
        ${itens.map((a) => `
          <a class="item evento" href="#ajuda/${esc(a.id)}">
            <span class="evento-texto">
              <strong>${esc(a.pergunta)}</strong>
              ${a.areas?.nome ? `<span class="ajuda">${esc(a.areas.nome)}</span>` : ""}
            </span>
          </a>`).join("")}
      </div>`).join("");
  }

  async function lista(alvo, perfil) {
    alvo.innerHTML = '<p class="ajuda">Carregando...</p>';
    const artigos = await publicados(true);

    alvo.innerHTML = `
      <div class="cabecalho-pagina">
        <h1>Central de ajuda</h1>
        ${ehStaff(perfil) ? '<a class="btn-ghost" href="#ajuda/gerenciar">Gerenciar artigos</a>' : ""}
      </div>
      <p class="ajuda">Respostas para as dúvidas mais comuns. Se não encontrar o que procura, abra uma solicitação.</p>
      <form class="formulario" role="search">
        <label>Buscar
          <input type="search" name="busca" placeholder="Ex.: senha, anexo, carteirinha" autocomplete="off" />
        </label>
      </form>
      <div id="lista-ajuda">${linhasArtigos(artigos, "")}</div>
      <div class="acoes-evento">
        <a class="btn-primario" href="#nova">Abrir uma solicitação</a>
      </div>`;

    const campo = alvo.querySelector("input[name=busca]");
    campo.form.addEventListener("submit", (ev) => ev.preventDefault());
    campo.addEventListener("input", () => {
      alvo.querySelector("#lista-ajuda").innerHTML = linhasArtigos(artigos, campo.value);
    });
  }

  // ---------- Artigo ----------

  async function artigo(alvo, perfil, id) {
    alvo.innerHTML = '<p class="ajuda">Carregando...</p>';
    const [{ data: a, error }, { data: minha }] = await Promise.all([
      sb().from("faq_artigos").select("id, pergunta, resposta, categoria, publicado, areas(nome)").eq("id", id).maybeSingle(),
      sb().from("faq_avaliacoes").select("util").eq("artigo_id", id).eq("usuario_id", perfil.id).maybeSingle(),
    ]);

    if (error || !a) {
      alvo.innerHTML = `
        <p class="rodape-form"><a href="#ajuda">← Voltar para a central de ajuda</a></p>
        <p class="ajuda">Artigo não encontrado.</p>`;
      return;
    }

    const rascunho = !a.publicado ? '<p class="marcas"><span class="marca">Rascunho: ainda não publicado</span></p>' : "";

    alvo.innerHTML = `
      <p class="rodape-form"><a href="#ajuda">← Voltar para a central de ajuda</a></p>
      ${rascunho}
      <h1>${esc(a.pergunta)}</h1>
      ${a.areas?.nome ? `<p class="ajuda">${esc(a.areas.nome)}</p>` : ""}
      <section class="cartao">
        <p class="texto-puro">${esc(a.resposta)}</p>
      </section>
      <section class="cartao" id="feedback">
        ${minha
          ? `<p>Você respondeu: ${minha.util ? "esta resposta resolveu" : "esta resposta não resolveu"} sua dúvida.</p>`
          : `<h2>Isso resolveu sua dúvida?</h2>
             <div class="acoes-evento">
               <button type="button" class="btn-primario" data-util="true">Sim, resolveu</button>
               <button type="button" class="btn-ghost" data-util="false">Não resolveu</button>
             </div>`}
        ${!minha || !minha.util ? '<p class="ajuda">Ainda precisa de ajuda? <a href="#nova">Abrir uma solicitação</a></p>' : ""}
        <p class="erro" role="alert" hidden></p>
      </section>`;

    alvo.querySelectorAll("[data-util]").forEach((botao) => {
      botao.addEventListener("click", async () => {
        const util = botao.dataset.util === "true";
        botao.disabled = true;
        const { error: falha } = await sb().rpc("avaliar_artigo_faq", { p_artigo: id, p_util: util });
        if (falha) {
          const erro = alvo.querySelector("#feedback .erro");
          erro.textContent = falha.message;
          erro.hidden = false;
          botao.disabled = false;
          return;
        }
        artigo(alvo, perfil, id);
      });
    });
  }

  // ---------- Gestão (administradores e funcionários) ----------

  async function gerenciar(alvo, perfil) {
    alvo.innerHTML = '<p class="ajuda">Carregando...</p>';
    const [{ data: artigos, error }, { data: estatisticas }] = await Promise.all([
      sb().from("faq_artigos").select("id, pergunta, categoria, publicado, ordem, areas(nome)").order("ordem").order("pergunta"),
      sb().rpc("estatisticas_faq"),
    ]);

    if (error) {
      alvo.innerHTML = `<p class="erro">${esc(error.message)}</p>`;
      return;
    }

    const contagem = new Map((estatisticas || []).map((s) => [s.artigo, s]));

    alvo.innerHTML = `
      <p class="rodape-form"><a href="#ajuda">← Voltar para a central de ajuda</a></p>
      <div class="cabecalho-pagina">
        <h1>Gerenciar artigos</h1>
        <a class="btn-primario" href="#ajuda/gerenciar/novo">Novo artigo</a>
      </div>
      <p class="ajuda">Você vê os artigos gerais e das áreas que pode publicar. Rascunhos não aparecem para os cooperados.</p>
      ${(artigos || []).length ? `
        <div class="lista">
          ${artigos.map((a) => {
            const s = contagem.get(a.id);
            return `
              <a class="item evento" href="#ajuda/gerenciar/${esc(a.id)}">
                <span class="evento-texto">
                  <strong>${esc(a.pergunta)}</strong>
                  <span class="ajuda">${esc(a.areas?.nome || "Geral")}${a.categoria ? " · " + esc(a.categoria) : ""} · ${s ? `${Number(s.util_sim)} resolveram · ${Number(s.util_nao)} não` : "sem avaliações"}</span>
                  <span class="marcas"><span class="marca">${a.publicado ? "Publicado" : "Rascunho"}</span></span>
                </span>
              </a>`;
          }).join("")}
        </div>`
        : '<p class="ajuda">Nenhum artigo ainda.</p>'}`;
  }

  async function formularioArtigo(alvo, perfil, id) {
    const admin = ehAdmin(perfil);
    let areas = [];
    if (admin) {
      const { data } = await sb().from("areas").select("id, nome").order("nome");
      areas = data || [];
    } else {
      const { data } = await sb().from("funcionarios_areas").select("areas(id, nome)").eq("usuario_id", perfil.id);
      areas = (data || []).map((v) => v.areas).filter(Boolean).sort((a, b) => a.nome.localeCompare(b.nome));
    }

    let atual = null;
    if (id) {
      const { data, error } = await sb().from("faq_artigos").select("*").eq("id", id).maybeSingle();
      if (error || !data) {
        alvo.innerHTML = `<p class="rodape-form"><a href="#ajuda/gerenciar">← Voltar</a></p><p class="ajuda">Artigo não encontrado.</p>`;
        return;
      }
      atual = data;
    }

    alvo.innerHTML = `
      <p class="rodape-form"><a href="#ajuda/gerenciar">← Voltar para gerenciar artigos</a></p>
      <h1>${atual ? "Editar artigo" : "Novo artigo"}</h1>
      <form id="form-artigo" class="formulario" novalidate>
        <label>Pergunta
          <input type="text" name="pergunta" required minlength="5" maxlength="200" value="${esc(atual?.pergunta || "")}" />
        </label>
        <label>Resposta
          <textarea name="resposta" rows="8" required minlength="10" maxlength="4000">${esc(atual?.resposta || "")}</textarea>
        </label>
        <label>Categoria <small>(opcional)</small>
          <input type="text" name="categoria" maxlength="60" value="${esc(atual?.categoria || "")}" />
        </label>
        <label>Para quem
          <select name="area">
            ${admin ? `<option value="" ${!atual?.area_id ? "selected" : ""}>Geral (todos os cooperados)</option>` : ""}
            ${areas.map((a) => `<option value="${esc(a.id)}" ${atual?.area_id === a.id ? "selected" : ""}>${esc(a.nome)}</option>`).join("")}
          </select>
        </label>
        <label>Ordem <small>(menor aparece primeiro)</small>
          <input type="number" name="ordem" min="0" max="999" step="1" value="${Number(atual?.ordem ?? 0)}" />
        </label>
        <label class="opcao">
          <input type="checkbox" name="publicado" ${atual?.publicado ? "checked" : ""} />
          <span>Publicado (visível para quem tem acesso)</span>
        </label>
        <p class="erro" role="alert" hidden></p>
        <button type="submit" class="btn-primario">Salvar artigo</button>
        ${atual ? '<button type="button" id="excluir-artigo" class="btn-perigo">Excluir artigo</button>' : ""}
      </form>`;

    const form = document.getElementById("form-artigo");
    const erro = form.querySelector(".erro");
    const mostraErro = (mensagem) => {
      erro.textContent = mensagem;
      erro.hidden = false;
    };

    form.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      erro.hidden = true;
      const f = new FormData(form);
      const botao = form.querySelector("button[type=submit]");
      botao.disabled = true;
      const { error } = await sb().rpc("salvar_artigo_faq", {
        p_id: atual?.id || null,
        p_pergunta: String(f.get("pergunta") || "").trim(),
        p_resposta: String(f.get("resposta") || "").trim(),
        p_categoria: String(f.get("categoria") || "").trim() || null,
        p_area: f.get("area") || null,
        p_publicado: f.has("publicado"),
        p_ordem: Number(f.get("ordem") || 0),
      });
      botao.disabled = false;
      if (error) return mostraErro(error.message);
      publicados(true);
      location.hash = "#ajuda/gerenciar";
    });

    form.querySelector("#excluir-artigo")?.addEventListener("click", async () => {
      if (!confirm("Excluir este artigo? Esta ação não pode ser desfeita.")) return;
      const { error } = await sb().rpc("excluir_artigo_faq", { p_id: atual.id });
      if (error) return mostraErro(error.message);
      publicados(true);
      location.hash = "#ajuda/gerenciar";
    });
  }

  // caminho: partes do endereço após "ajuda". Ex.: ["ajuda", "gerenciar", "novo"].
  function tela(alvo, perfil, caminho) {
    const [, primeiro, segundo] = caminho;
    if (primeiro === "gerenciar") {
      if (!ehStaff(perfil)) return lista(alvo, perfil);
      if (segundo === "novo") return formularioArtigo(alvo, perfil, null);
      if (segundo) return formularioArtigo(alvo, perfil, segundo);
      return gerenciar(alvo, perfil);
    }
    if (primeiro) return artigo(alvo, perfil, primeiro);
    return lista(alvo, perfil);
  }

  return { tela, sugerirParaAssunto };
})();
