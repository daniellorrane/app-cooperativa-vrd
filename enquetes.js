// Enquetes e pesquisas: perguntas com opções, resposta única ou múltipla, anônimas ou identificadas.
// As regras ficam no banco. Esta tela só organiza a apresentação e envia as escolhas.
window.Enquetes = (() => {
  const sb = () => window.sb;

  function esc(texto) {
    const d = document.createElement("div");
    d.textContent = texto ?? "";
    return d.innerHTML;
  }

  function dataHora(valor) {
    return new Date(valor).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" });
  }

  function valorDataLocal(valor) {
    const d = new Date(valor);
    const dois = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${dois(d.getMonth() + 1)}-${dois(d.getDate())}T${dois(d.getHours())}:${dois(d.getMinutes())}`;
  }

  const ehAdmin = (perfil) => perfil.tipo_acesso === "administrador";
  const ehStaff = (perfil) => ehAdmin(perfil) || perfil.tipo_acesso === "funcionario";

  async function areasDePublicacao(perfil) {
    if (ehAdmin(perfil)) {
      const { data } = await sb().from("areas").select("id, nome").order("nome");
      return data || [];
    }
    const { data } = await sb().from("funcionarios_areas").select("areas(id, nome)").eq("usuario_id", perfil.id);
    return (data || []).map((v) => v.areas).filter(Boolean).sort((a, b) => a.nome.localeCompare(b.nome));
  }

  // ---------- Lista ----------

  async function lista(alvo, perfil) {
    alvo.innerHTML = '<p class="ajuda">Carregando...</p>';
    const { data: enquetes, error } = await sb().rpc("listar_enquetes");

    if (error) {
      alvo.innerHTML = `<p class="erro">Não foi possível carregar as enquetes: ${esc(error.message)}</p>`;
      return;
    }

    const agora = Date.now();
    const situacao = (e) => {
      if (new Date(e.encerra_em).getTime() <= agora) return "Encerrada";
      return e.ja_respondeu ? "Respondida" : "Aguardando sua resposta";
    };

    alvo.innerHTML = `
      <div class="cabecalho-pagina">
        <h1>Enquetes e pesquisas</h1>
        ${ehStaff(perfil) ? '<button type="button" id="nova-enquete" class="btn-primario">Nova enquete</button>' : ""}
      </div>
      <p class="ajuda">Responda quando puder. Os resultados aparecem depois que você responde ou quando a enquete é encerrada.</p>
      ${(enquetes || []).length ? `
        <div class="lista">
          ${enquetes.map((e) => `
            <a class="item evento" href="#enquetes/${esc(e.id)}">
              <span class="evento-texto">
                <strong>${esc(e.titulo)}</strong>
                <span class="ajuda">${esc(e.area || "Geral")} · encerra em ${esc(dataHora(e.encerra_em))}</span>
                <span class="marcas">
                  <span class="marca">${esc(situacao(e))}</span>
                  ${e.anonima ? '<span class="marca">Anônima</span>' : ""}
                </span>
              </span>
            </a>`).join("")}
        </div>`
        : '<p class="ajuda">Não há enquetes no momento.</p>'}`;

    alvo.querySelector("#nova-enquete")?.addEventListener("click", () => {
      location.hash = "#enquetes/novo";
    });
  }

  // ---------- Criar enquete ----------

  async function formulario(alvo, perfil) {
    const admin = ehAdmin(perfil);
    const areas = await areasDePublicacao(perfil);

    if (!admin && !areas.length) {
      alvo.innerHTML = `
        <p class="rodape-form"><a href="#enquetes">← Voltar para enquetes</a></p>
        <h1>Nova enquete</h1>
        <p class="ajuda">Você ainda não está vinculado a nenhuma área. Peça à administração para vincular você.</p>`;
      return;
    }

    const padrao = new Date(Date.now() + 7 * 24 * 3600 * 1000);

    alvo.innerHTML = `
      <p class="rodape-form"><a href="#enquetes">← Voltar para enquetes</a></p>
      <h1>Nova enquete</h1>
      <form id="form-enquete" class="formulario" novalidate>
        <label>Pergunta ou título
          <input type="text" name="titulo" required minlength="3" maxlength="160" />
        </label>
        <label>Descrição <small>(opcional)</small>
          <textarea name="descricao" rows="2" maxlength="1000"></textarea>
        </label>
        <label>Para quem
          <select name="area">
            ${admin ? '<option value="">Geral (todos os cooperados)</option>' : ""}
            ${areas.map((a) => `<option value="${esc(a.id)}">${esc(a.nome)}</option>`).join("")}
          </select>
        </label>
        <label>Encerra em
          <input type="datetime-local" name="encerra_em" required value="${valorDataLocal(padrao)}" />
        </label>
        <label>Opções <small>(uma por linha, de 2 a 10)</small>
          <textarea name="opcoes" rows="5" required placeholder="Sim&#10;Não&#10;Talvez"></textarea>
        </label>
        <fieldset class="tipos">
          <legend>Como responder</legend>
          <label class="opcao"><input type="checkbox" name="multipla" /><span>Permitir mais de uma opção</span></label>
          <label class="opcao"><input type="checkbox" name="anonima" checked /><span>Anônima (o sistema não mostra quem respondeu)</span></label>
          <label class="opcao"><input type="checkbox" name="aceita_comentario" /><span>Aceitar comentário livre</span></label>
        </fieldset>
        <p class="erro" role="alert" hidden></p>
        <button type="submit" class="btn-primario">Publicar enquete</button>
      </form>`;

    const form = document.getElementById("form-enquete");
    const erro = form.querySelector(".erro");
    const mostraErro = (mensagem) => {
      erro.textContent = mensagem;
      erro.hidden = false;
    };

    form.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      erro.hidden = true;
      const f = new FormData(form);
      const titulo = String(f.get("titulo") || "").trim();
      const encerra = f.get("encerra_em");
      const opcoes = String(f.get("opcoes") || "")
        .split("\n")
        .map((o) => o.trim())
        .filter(Boolean);

      if (titulo.length < 3) return mostraErro("O título precisa ter pelo menos 3 caracteres.");
      if (!encerra || new Date(encerra) <= new Date()) return mostraErro("Informe um encerramento depois de agora.");
      if (opcoes.length < 2 || opcoes.length > 10) return mostraErro("Informe de 2 a 10 opções, uma por linha.");

      const botao = form.querySelector("button[type=submit]");
      botao.disabled = true;
      const { error } = await sb().rpc("criar_enquete", {
        p_titulo: titulo,
        p_descricao: String(f.get("descricao") || "").trim() || null,
        p_area: f.get("area") || null,
        p_multipla: f.has("multipla"),
        p_anonima: f.has("anonima"),
        p_aceita_comentario: f.has("aceita_comentario"),
        p_encerra_em: new Date(encerra).toISOString(),
        p_opcoes: opcoes,
      });
      botao.disabled = false;

      if (error) return mostraErro(error.message);
      location.hash = "#enquetes";
    });
  }

  // ---------- Detalhe: responder e ver resultados ----------

  async function detalhe(alvo, perfil, id) {
    alvo.innerHTML = '<p class="ajuda">Carregando...</p>';
    const { data: e, error } = await sb().rpc("detalhe_enquete", { p_enquete: id });

    if (error || !e) {
      alvo.innerHTML = `
        <p class="rodape-form"><a href="#enquetes">← Voltar para enquetes</a></p>
        <p class="ajuda">${esc(error?.message || "Enquete não encontrada.")}</p>`;
      return;
    }

    const podeResponder = !e.ja_respondeu && !e.encerrada;
    const total = Number(e.total_respondentes) || 0;

    const opcoesHtml = e.opcoes.map((o) => {
      if (podeResponder) {
        const tipo = e.multipla_escolha ? "checkbox" : "radio";
        return `
          <label class="opcao">
            <input type="${tipo}" name="opcao" value="${esc(o.id)}" />
            <span>${esc(o.texto)}</span>
          </label>`;
      }
      if (!e.pode_ver_resultado) {
        return `<div class="resultado-opcao"><span>${esc(o.texto)}</span></div>`;
      }
      const votos = Number(o.votos) || 0;
      const pct = total ? Math.round((votos / total) * 100) : 0;
      return `
        <div class="resultado-opcao ${o.minha ? "minha" : ""}">
          <div class="resultado-linha">
            <span>${esc(o.texto)}${o.minha ? " (sua escolha)" : ""}</span>
            <span class="ajuda">${votos} · ${pct}%</span>
          </div>
          <div class="barra"><span style="width:${pct}%"></span></div>
        </div>`;
    }).join("");

    const aviso = e.encerrada
      ? "Enquete encerrada."
      : e.ja_respondeu
        ? "Obrigado por responder. Você já não pode alterar sua resposta."
        : `Encerra em ${dataHora(e.encerra_em)}.`;

    const comentarios = e.comentarios
      ? `<section class="cartao">
           <h2>Comentários</h2>
           ${e.comentarios.length
             ? `<ul class="lista-respostas">${e.comentarios.map((c) => `<li><span>${esc(c)}</span></li>`).join("")}</ul>`
             : '<p class="ajuda">Ainda não há comentários.</p>'}
         </section>`
      : "";

    const quemVotou = e.quem_votou
      ? `<section class="cartao">
           <h2>Quem respondeu</h2>
           ${e.quem_votou.length
             ? `<ul class="lista-respostas">${e.quem_votou.map((r) => `<li><span>${esc(r.nome)}</span><span class="ajuda">${esc(dataHora(r.respondido_em))}</span></li>`).join("")}</ul>`
             : '<p class="ajuda">Ninguém respondeu ainda.</p>'}
         </section>`
      : "";

    alvo.innerHTML = `
      <p class="rodape-form"><a href="#enquetes">← Voltar para enquetes</a></p>
      <h1>${esc(e.titulo)}</h1>
      <section class="cartao">
        ${e.descricao ? `<p class="texto-puro">${esc(e.descricao)}</p>` : ""}
        <p class="ajuda">${esc(e.area || "Geral")} · ${e.anonima ? "Resposta anônima" : "Resposta identificada"} · ${total} resposta(s)</p>
        <p class="ajuda">${esc(aviso)}</p>
        ${e.multipla_escolha && podeResponder ? '<p class="ajuda">Você pode escolher mais de uma opção.</p>' : ""}
      </section>

      ${podeResponder ? `
      <section class="cartao">
        <form id="form-responder" class="formulario" novalidate>
          <fieldset class="tipos">
            <legend>${esc(e.titulo)}</legend>
            <div class="opcoes-enquete">${opcoesHtml}</div>
          </fieldset>
          ${e.aceita_comentario ? `
          <label>Comentário <small>(opcional, até 500 caracteres)</small>
            <textarea name="comentario" rows="3" maxlength="500"></textarea>
          </label>` : ""}
          <p class="erro" role="alert" hidden></p>
          <button type="submit" class="btn-primario">Enviar resposta</button>
        </form>
      </section>` : `
      <section class="cartao">
        <h2>Resultado</h2>
        ${e.pode_ver_resultado ? "" : '<p class="ajuda">O resultado aparece depois que você responder ou quando a enquete for encerrada.</p>'}
        <div class="opcoes-enquete">${opcoesHtml}</div>
      </section>`}

      ${comentarios}
      ${quemVotou}

      ${e.gestor && !e.encerrada ? `
      <section class="cartao">
        <div class="acoes-evento">
          <button type="button" id="encerrar-enquete" class="btn-ghost">Encerrar agora</button>
        </div>
        <p class="erro" role="alert" hidden></p>
      </section>` : ""}`;

    const erro = alvo.querySelector(".erro");
    const mostraErro = (mensagem) => {
      if (!erro) return alert(mensagem);
      erro.textContent = mensagem;
      erro.hidden = false;
    };

    const form = alvo.querySelector("#form-responder");
    if (form) {
      form.addEventListener("submit", async (ev) => {
        ev.preventDefault();
        const escolhidas = [...form.querySelectorAll("input[name=opcao]:checked")].map((i) => i.value);
        if (!escolhidas.length) return mostraErro("Escolha pelo menos uma opção.");
        if (!e.multipla_escolha && escolhidas.length > 1) return mostraErro("Escolha apenas uma opção.");

        const botao = form.querySelector("button[type=submit]");
        botao.disabled = true;
        const comentario = form.querySelector("textarea[name=comentario]")?.value.trim() || null;
        const { error: falha } = await sb().rpc("responder_enquete", {
          p_enquete: id,
          p_opcoes: escolhidas,
          p_comentario: comentario,
        });
        if (falha) {
          botao.disabled = false;
          return mostraErro(falha.message);
        }
        detalhe(alvo, perfil, id);
      });
    }

    alvo.querySelector("#encerrar-enquete")?.addEventListener("click", async () => {
      if (!confirm("Encerrar a enquete agora? Ninguém mais poderá responder.")) return;
      const { error: falha } = await sb().rpc("encerrar_enquete", { p_enquete: id });
      if (falha) return mostraErro(falha.message);
      detalhe(alvo, perfil, id);
    });
  }

  // id: undefined = lista; "novo" = formulário; outro = detalhe da enquete.
  function tela(alvo, perfil, id) {
    if (id === "novo") return ehStaff(perfil) ? formulario(alvo, perfil) : lista(alvo, perfil);
    if (id) return detalhe(alvo, perfil, id);
    return lista(alvo, perfil);
  }

  return { tela };
})();
