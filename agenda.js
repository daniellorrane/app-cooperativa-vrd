// Agenda: eventos da cooperativa e das áreas, com confirmação de presença e de leitura.
// As regras de acesso ficam no banco (RLS e funções). Esta tela só organiza a apresentação.
window.Agenda = (() => {
  const sb = () => window.sb;

  const RESPOSTA_PRESENCA = { confirmada: "Presença confirmada", nao_vai: "Não vai" };

  function esc(texto) {
    const d = document.createElement("div");
    d.textContent = texto ?? "";
    return d.innerHTML;
  }

  function dataHora(valor) {
    return new Date(valor).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" });
  }

  function horaCurta(valor) {
    return new Date(valor).toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" });
  }

  function diaTitulo(valor) {
    return new Date(valor).toLocaleDateString("pt-BR", { weekday: "long", day: "numeric", month: "long" });
  }

  function chaveDia(valor) {
    const d = new Date(valor);
    const dois = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${dois(d.getMonth() + 1)}-${dois(d.getDate())}`;
  }

  const ehAdmin = (perfil) => perfil.tipo_acesso === "administrador";
  const ehStaff = (perfil) => ehAdmin(perfil) || perfil.tipo_acesso === "funcionario";

  // ---------- Lista de eventos ----------

  async function lista(alvo, perfil) {
    alvo.innerHTML = '<p class="ajuda">Carregando...</p>';
    const desde = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
    const [{ data: eventos, error }, { data: minhas }] = await Promise.all([
      sb().from("eventos")
        .select("id, titulo, local_evento, inicio, fim, area_id, exige_presenca, exige_leitura, areas(nome)")
        .gte("inicio", desde)
        .order("inicio")
        .limit(200),
      sb().from("eventos_respostas").select("evento_id, tipo, resposta").eq("usuario_id", perfil.id),
    ]);

    if (error) {
      alvo.innerHTML = `<p class="erro">Não foi possível carregar a agenda: ${esc(error.message)}</p>`;
      return;
    }

    const minhaResposta = (evento, tipo) => (minhas || []).find((r) => r.evento_id === evento && r.tipo === tipo);

    const dias = new Map();
    for (const e of eventos || []) {
      const chave = chaveDia(e.inicio);
      if (!dias.has(chave)) dias.set(chave, []);
      dias.get(chave).push(e);
    }

    const linhaEvento = (e) => {
      const marcas = [];
      if (e.exige_presenca) {
        const r = minhaResposta(e.id, "presenca");
        marcas.push(r ? RESPOSTA_PRESENCA[r.resposta] : "Presença pendente");
      }
      if (e.exige_leitura) {
        marcas.push(minhaResposta(e.id, "leitura") ? "Leitura confirmada" : "Leitura pendente");
      }
      return `
        <a class="item evento" href="#agenda/${esc(e.id)}">
          <span class="evento-hora">${esc(horaCurta(e.inicio))}</span>
          <span class="evento-texto">
            <strong>${esc(e.titulo)}</strong>
            <span class="ajuda">${esc(e.areas?.nome || "Geral")}${e.local_evento ? " · " + esc(e.local_evento) : ""}</span>
            ${marcas.length ? `<span class="marcas">${marcas.map((m) => `<span class="marca">${esc(m)}</span>`).join("")}</span>` : ""}
          </span>
        </a>`;
    };

    alvo.innerHTML = `
      <div class="cabecalho-pagina">
        <h1>Agenda</h1>
        ${ehStaff(perfil) ? '<button type="button" id="novo-evento" class="btn-primario">Novo evento</button>' : ""}
      </div>
      <p class="ajuda">Eventos da cooperativa e das áreas, do mais próximo ao mais distante.</p>
      ${dias.size
        ? [...dias.values()].map((itens) => `
            <h2 class="dia-agenda">${esc(diaTitulo(itens[0].inicio))}</h2>
            <div class="lista">${itens.map(linhaEvento).join("")}</div>`).join("")
        : '<p class="ajuda">Não há eventos próximos.</p>'}`;

    alvo.querySelector("#novo-evento")?.addEventListener("click", () => {
      location.hash = "#agenda/novo";
    });
  }

  // ---------- Criar evento (administradores e funcionários) ----------

  async function formulario(alvo, perfil) {
    const admin = ehAdmin(perfil);
    let areas = [];

    if (admin) {
      const { data } = await sb().from("areas").select("id, nome").order("nome");
      areas = data || [];
    } else {
      const { data } = await sb().from("funcionarios_areas").select("areas(id, nome)").eq("usuario_id", perfil.id);
      areas = (data || []).map((v) => v.areas).filter(Boolean).sort((a, b) => a.nome.localeCompare(b.nome));
    }

    if (!admin && !areas.length) {
      alvo.innerHTML = `
        <p class="rodape-form"><a href="#agenda">← Voltar para a agenda</a></p>
        <h1>Novo evento</h1>
        <p class="ajuda">Você ainda não está vinculado a nenhuma área. Peça à administração para vincular você para criar eventos.</p>`;
      return;
    }

    alvo.innerHTML = `
      <p class="rodape-form"><a href="#agenda">← Voltar para a agenda</a></p>
      <h1>Novo evento</h1>
      <form id="form-evento" class="formulario" novalidate>
        <label>Título
          <input type="text" name="titulo" required minlength="3" maxlength="120" />
        </label>
        <label>Início
          <input type="datetime-local" name="inicio" required />
        </label>
        <label>Término <small>(opcional)</small>
          <input type="datetime-local" name="fim" />
        </label>
        <label>Local <small>(opcional)</small>
          <input type="text" name="local" maxlength="160" />
        </label>
        <label>Para quem
          <select name="area">
            ${admin ? '<option value="">Geral (todos os cooperados)</option>' : ""}
            ${areas.map((a) => `<option value="${esc(a.id)}">${esc(a.nome)}</option>`).join("")}
          </select>
        </label>
        <label>Descrição <small>(opcional)</small>
          <textarea name="descricao" rows="4" maxlength="2000"></textarea>
        </label>
        <fieldset class="tipos">
          <legend>Confirmações</legend>
          <label class="opcao">
            <input type="checkbox" name="exige_presenca" />
            <span>Pedir confirmação de presença</span>
          </label>
          <label class="opcao">
            <input type="checkbox" name="exige_leitura" />
            <span>Pedir confirmação de leitura</span>
          </label>
        </fieldset>
        <p class="erro" role="alert" hidden></p>
        <button type="submit" class="btn-primario">Publicar evento</button>
      </form>`;

    const form = document.getElementById("form-evento");
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
      const inicio = f.get("inicio");
      const fim = f.get("fim");

      if (titulo.length < 3) return mostraErro("O título precisa ter pelo menos 3 caracteres.");
      if (!inicio) return mostraErro("Informe a data e hora de início.");
      if (fim && new Date(fim) <= new Date(inicio)) return mostraErro("O término deve ser depois do início.");

      const botao = form.querySelector("button[type=submit]");
      botao.disabled = true;
      const { error } = await sb().rpc("criar_evento", {
        p_titulo: titulo,
        p_descricao: String(f.get("descricao") || "").trim() || null,
        p_local: String(f.get("local") || "").trim() || null,
        p_inicio: new Date(inicio).toISOString(),
        p_fim: fim ? new Date(fim).toISOString() : null,
        p_area: f.get("area") || null,
        p_exige_presenca: f.has("exige_presenca"),
        p_exige_leitura: f.has("exige_leitura"),
      });
      botao.disabled = false;

      if (error) return mostraErro(error.message);
      location.hash = "#agenda";
    });
  }

  // ---------- Detalhe do evento ----------

  async function detalhe(alvo, perfil, id) {
    alvo.innerHTML = '<p class="ajuda">Carregando...</p>';
    const [{ data: e, error }, { data: minhas }] = await Promise.all([
      sb().from("eventos").select("*, areas(nome)").eq("id", id).maybeSingle(),
      sb().from("eventos_respostas").select("tipo, resposta, respondido_em").eq("evento_id", id).eq("usuario_id", perfil.id),
    ]);

    if (error || !e) {
      alvo.innerHTML = `
        <p class="rodape-form"><a href="#agenda">← Voltar para a agenda</a></p>
        <p class="ajuda">Evento não encontrado.</p>`;
      return;
    }

    const minha = (tipo) => (minhas || []).find((r) => r.tipo === tipo);
    const gestor = ehAdmin(perfil) || e.criado_por === perfil.id;

    const blocoPresenca = e.exige_presenca ? `
      <section class="cartao">
        <h2>Presença</h2>
        <p>${minha("presenca") ? esc(RESPOSTA_PRESENCA[minha("presenca").resposta]) : "Você ainda não respondeu."}</p>
        <div class="acoes-evento">
          <button type="button" class="btn-primario" data-tipo="presenca" data-resposta="confirmada">Vou participar</button>
          <button type="button" class="btn-ghost" data-tipo="presenca" data-resposta="nao_vai">Não vou</button>
        </div>
      </section>` : "";

    const blocoLeitura = e.exige_leitura ? `
      <section class="cartao">
        <h2>Leitura</h2>
        ${minha("leitura")
          ? `<p>Leitura confirmada em ${esc(dataHora(minha("leitura").respondido_em))}.</p>`
          : `<p>Confirme que leu as informações deste evento.</p>
             <div class="acoes-evento">
               <button type="button" class="btn-primario" data-tipo="leitura" data-resposta="lida">Confirmar leitura</button>
             </div>`}
      </section>` : "";

    const blocoGestao = gestor ? `
      <section class="cartao">
        <h2>Respostas</h2>
        <div id="respostas-evento"><p class="ajuda">Carregando...</p></div>
        <div class="acoes-evento">
          <button type="button" id="excluir-evento" class="btn-perigo">Excluir evento</button>
        </div>
      </section>` : "";

    alvo.innerHTML = `
      <p class="rodape-form"><a href="#agenda">← Voltar para a agenda</a></p>
      <h1>${esc(e.titulo)}</h1>
      <section class="cartao">
        <p><strong>Quando:</strong> ${esc(dataHora(e.inicio))}${e.fim ? " até " + esc(dataHora(e.fim)) : ""}</p>
        <p><strong>Local:</strong> ${esc(e.local_evento || "A definir")}</p>
        <p><strong>Para:</strong> ${esc(e.areas?.nome || "Todos os cooperados")}</p>
        ${e.descricao ? `<p class="texto-puro">${esc(e.descricao)}</p>` : ""}
      </section>
      ${blocoPresenca}
      ${blocoLeitura}
      ${blocoGestao}
      <p class="erro" role="alert" hidden></p>`;

    const erro = alvo.querySelector(".erro");

    alvo.querySelectorAll("[data-tipo]").forEach((botao) => {
      botao.addEventListener("click", async () => {
        botao.disabled = true;
        const { error: falha } = await sb().rpc("responder_evento", {
          p_evento: id,
          p_tipo: botao.dataset.tipo,
          p_resposta: botao.dataset.resposta,
        });
        if (falha) {
          erro.textContent = falha.message;
          erro.hidden = false;
          botao.disabled = false;
          return;
        }
        detalhe(alvo, perfil, id);
      });
    });

    if (gestor) {
      carregarRespostas(e, alvo.querySelector("#respostas-evento"));
      alvo.querySelector("#excluir-evento").addEventListener("click", async () => {
        if (!confirm("Excluir este evento? As confirmações também serão removidas.")) return;
        const { error: falha } = await sb().rpc("excluir_evento", { p_evento: id });
        if (falha) {
          erro.textContent = falha.message;
          erro.hidden = false;
          return;
        }
        location.hash = "#agenda";
      });
    }
  }

  async function carregarRespostas(e, destino) {
    const { data, error } = await sb().rpc("respostas_do_evento", { p_evento: e.id });
    if (error) {
      destino.innerHTML = `<p class="erro">${esc(error.message)}</p>`;
      return;
    }
    if (!data || !data.length) {
      destino.innerHTML = '<p class="ajuda">Nenhum cooperado ou funcionário está no público deste evento.</p>';
      return;
    }

    const situacao = (r) => [
      e.exige_presenca ? (RESPOSTA_PRESENCA[r.presenca] || "Presença sem resposta") : null,
      e.exige_leitura ? (r.leitura ? "Leitura confirmada" : "Leitura pendente") : null,
    ].filter(Boolean).join(" · ");

    const contagem = [
      e.exige_presenca ? `${data.filter((r) => r.presenca === "confirmada").length} confirmaram presença` : null,
      e.exige_leitura ? `${data.filter((r) => r.leitura === "lida").length} leram` : null,
    ].filter(Boolean).join(" · ");

    destino.innerHTML = `
      <p class="ajuda">${esc(contagem)} de ${data.length} no público.</p>
      <ul class="lista-respostas">
        ${data.map((r) => `<li><span>${esc(r.nome)}</span><span class="ajuda">${esc(situacao(r))}</span></li>`).join("")}
      </ul>`;
  }

  // ---------- Entrada ----------

  // id: undefined = lista; "novo" = formulário; outro = detalhe do evento.
  function tela(alvo, perfil, id) {
    if (id === "novo") return ehStaff(perfil) ? formulario(alvo, perfil) : lista(alvo, perfil);
    if (id) return detalhe(alvo, perfil, id);
    return lista(alvo, perfil);
  }

  return { tela };
})();
