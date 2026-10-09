// Comunicação interna: conversas por área, solicitações, notificações e política de privacidade.
// Todas as regras de acesso são aplicadas pelo banco (RLS). Esta tela apenas apresenta os dados.
(() => {
  const sb = () => window.sb;
  let uid = null;
  let perfilAtual = null;
  let canalMensagens = null;
  let canalNotificacoes = null;

  const STATUS = {
    aberta: "Aberta",
    em_andamento: "Em andamento",
    concluida: "Concluída",
    cancelada: "Cancelada",
  };
  const TIPOS = {
    conversa: "Conversa",
    documento: "Solicitação de documento",
    servico: "Solicitação de serviço",
  };

  function esc(texto) {
    const d = document.createElement("div");
    d.textContent = texto ?? "";
    return d.innerHTML;
  }

  function dataCurta(valor) {
    return new Date(valor).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" });
  }

  function alvo() {
    return document.getElementById("conteudo-interno");
  }

  function sairDaConversa() {
    if (canalMensagens) {
      sb().removeChannel(canalMensagens);
      canalMensagens = null;
    }
  }

  function ir(visao, extra) {
    sairDaConversa();
    if (visao === "inicio") return telaConversas();
    if (visao === "nova") return telaNova();
    if (visao === "notif") return telaNotificacoes();
    if (visao === "privacidade") return telaPrivacidade();
    if (visao === "areas") return telaAreas();
    if (visao === "conversa") return telaConversa(extra);
  }

  // ---------- Entrada ----------

  async function montar(perfil, raiz) {
    perfilAtual = perfil;
    uid = perfil.id;

    raiz.innerHTML = `
      <nav class="nav-interna" aria-label="Comunicação interna">
        <button data-visao="inicio" class="chip ativo">Conversas</button>
        <button data-visao="nova" class="chip">Nova solicitação</button>
        <button data-visao="notif" class="chip">Notificações <span id="contador-notif" class="badge" hidden>0</span></button>
        <button data-visao="privacidade" class="chip">Privacidade</button>
        ${perfil.tipo_acesso === "administrador" ? '<button data-visao="areas" class="chip">Áreas e funcionários</button>' : ""}
      </nav>
      <div id="conteudo-interno"></div>`;

    raiz.querySelectorAll("[data-visao]").forEach((botao) => {
      botao.addEventListener("click", () => {
        raiz.querySelectorAll("[data-visao]").forEach((b) => b.classList.remove("ativo"));
        botao.classList.add("ativo");
        ir(botao.dataset.visao);
      });
    });

    assinarNotificacoes();
    atualizarContador();
    ir("inicio");
  }

  // ---------- Notificações ----------

  async function atualizarContador() {
    const { count } = await sb()
      .from("notificacoes")
      .select("id", { count: "exact", head: true })
      .eq("lida", false);
    const badge = document.getElementById("contador-notif");
    if (!badge) return;
    badge.textContent = count || 0;
    badge.hidden = !count;
  }

  function assinarNotificacoes() {
    if (canalNotificacoes) sb().removeChannel(canalNotificacoes);
    canalNotificacoes = sb()
      .channel("notif-" + uid)
      .on("postgres_changes", {
        event: "INSERT", schema: "public", table: "notificacoes",
        filter: "usuario_id=eq." + uid,
      }, () => atualizarContador())
      .subscribe();
  }

  async function telaNotificacoes() {
    alvo().innerHTML = '<p class="ajuda">Carregando...</p>';
    const { data, error } = await sb()
      .from("notificacoes")
      .select("id, titulo, lida, conversa_id, criado_em")
      .order("criado_em", { ascending: false })
      .limit(50);
    if (error) return (alvo().innerHTML = `<p class="erro">${esc(error.message)}</p>`);

    alvo().innerHTML = `
      <div class="acoes">
        <button id="marcar-todas" class="btn-ghost">Marcar todas como lidas</button>
      </div>
      <div class="lista">
        ${data.length ? data.map((n) => `
          <article class="item clicavel ${n.lida ? "" : "nao-lida"}" data-id="${n.id}" data-conversa="${n.conversa_id ?? ""}">
            <strong>${esc(n.titulo)}</strong>
            <p class="ajuda">${dataCurta(n.criado_em)}${n.lida ? "" : " · nova"}</p>
          </article>`).join("") : '<p class="ajuda">Nenhuma notificação.</p>'}
      </div>`;

    alvo().querySelectorAll("[data-id]").forEach((el) => {
      el.addEventListener("click", async () => {
        await sb().from("notificacoes").update({ lida: true }).eq("id", el.dataset.id);
        atualizarContador();
        if (el.dataset.conversa) ir("conversa", el.dataset.conversa);
        else telaNotificacoes();
      });
    });

    document.getElementById("marcar-todas").addEventListener("click", async () => {
      await sb().from("notificacoes").update({ lida: true }).eq("lida", false);
      atualizarContador();
      telaNotificacoes();
    });
  }

  // ---------- Conversas ----------

  async function telaConversas() {
    alvo().innerHTML = '<p class="ajuda">Carregando...</p>';
    const { data, error } = await sb()
      .from("conversas")
      .select("id, assunto, tipo, status, atualizado_em, solicitante_id, areas(nome)")
      .order("atualizado_em", { ascending: false });
    if (error) return (alvo().innerHTML = `<p class="erro">${esc(error.message)}</p>`);

    if (!data.length) {
      alvo().innerHTML = '<p class="ajuda">Nenhuma conversa ainda. Use "Nova solicitação" para começar.</p>';
      return;
    }

    alvo().innerHTML = `<div class="lista">${data.map((c) => `
      <article class="item clicavel" data-id="${c.id}">
        <div>
          <strong>${esc(c.assunto)}</strong>
          <span class="etiqueta">${c.solicitante_id === uid ? "Minha" : "Recebida"}</span>
        </div>
        <p class="ajuda">${esc(TIPOS[c.tipo])} · ${esc(c.areas?.nome)} · ${STATUS[c.status]} · ${dataCurta(c.atualizado_em)}</p>
      </article>`).join("")}</div>`;

    alvo().querySelectorAll("[data-id]").forEach((el) => {
      el.addEventListener("click", () => ir("conversa", el.dataset.id));
    });
  }

  async function telaNova() {
    const { data: areas } = await sb().from("areas").select("id, nome").eq("ativa", true).order("nome");
    alvo().innerHTML = `
      <section class="cartao">
        <h2>Nova solicitação</h2>
        <form id="form-nova" novalidate>
          <label>Área
            <select name="area" required>
              ${(areas || []).map((a) => `<option value="${a.id}">${esc(a.nome)}</option>`).join("")}
            </select>
          </label>
          <label>Tipo
            <select name="tipo" required>
              <option value="conversa">Conversa</option>
              <option value="documento">Solicitação de documento</option>
              <option value="servico">Solicitação de serviço</option>
            </select>
          </label>
          <label>Assunto
            <input type="text" name="assunto" required minlength="3" maxlength="150" />
          </label>
          <label>Mensagem
            <textarea name="texto" rows="5" required maxlength="4000"></textarea>
          </label>
          <p class="erro" role="alert" hidden></p>
          <button type="submit" class="btn-primario">Enviar</button>
        </form>
      </section>`;

    const form = document.getElementById("form-nova");
    const erro = form.querySelector(".erro");
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      erro.hidden = true;
      const assunto = form.assunto.value.trim();
      const texto = form.texto.value.trim();
      if (assunto.length < 3 || !texto) {
        erro.textContent = "Preencha o assunto e a mensagem.";
        erro.hidden = false;
        return;
      }
      const botao = form.querySelector("button");
      botao.disabled = true;
      const { data: conversa, error } = await sb()
        .from("conversas")
        .insert({ area_id: form.area.value, tipo: form.tipo.value, assunto, solicitante_id: uid })
        .select("id")
        .single();
      if (error) {
        erro.textContent = "Não foi possível abrir a solicitação: " + error.message;
        erro.hidden = false;
        botao.disabled = false;
        return;
      }
      const { error: erroMsg } = await sb()
        .from("mensagens")
        .insert({ conversa_id: conversa.id, autor_id: uid, texto });
      if (erroMsg) {
        erro.textContent = "Solicitação criada, mas a mensagem não foi enviada: " + erroMsg.message;
        erro.hidden = false;
        botao.disabled = false;
        return;
      }
      ir("conversa", conversa.id);
    });
  }

  async function telaConversa(id) {
    alvo().innerHTML = '<p class="ajuda">Carregando...</p>';
    const { data: conversa, error } = await sb()
      .from("conversas")
      .select("id, assunto, tipo, status, solicitante_id, areas(nome)")
      .eq("id", id)
      .single();
    if (error) return (alvo().innerHTML = `<p class="erro">${esc(error.message)}</p>`);

    const souSolicitante = conversa.solicitante_id === uid;
    const nomeArea = conversa.areas?.nome || "Atendimento";

    alvo().innerHTML = `
      <section class="cartao">
        <button id="voltar" class="btn-ghost">Voltar às conversas</button>
        <h2>${esc(conversa.assunto)}</h2>
        <p class="ajuda">${esc(TIPOS[conversa.tipo])} · ${esc(nomeArea)}</p>
        ${souSolicitante ? "" : `
          <label>Status
            <select id="status" class="seletor-status">
              ${Object.entries(STATUS).map(([v, r]) => `<option value="${v}" ${v === conversa.status ? "selected" : ""}>${r}</option>`).join("")}
            </select>
          </label>`}
        <div id="chat" class="chat" aria-live="polite"></div>
        <form id="form-mensagem" class="form-mensagem" novalidate>
          <textarea name="texto" rows="2" maxlength="4000" required placeholder="Escreva uma mensagem"></textarea>
          <button type="submit" class="btn-primario">Enviar</button>
        </form>
        <p class="erro" role="alert" hidden></p>
      </section>`;

    document.getElementById("voltar").addEventListener("click", () => ir("inicio"));

    const selectStatus = document.getElementById("status");
    if (selectStatus) {
      selectStatus.addEventListener("change", async () => {
        const { error: erroStatus } = await sb()
          .from("conversas")
          .update({ status: selectStatus.value })
          .eq("id", id);
        if (erroStatus) alert("Não foi possível alterar o status: " + erroStatus.message);
      });
    }

    const chat = document.getElementById("chat");
    const exibidas = new Set();

    function adicionar(msg) {
      if (exibidas.has(msg.id)) return;
      exibidas.add(msg.id);
      const eu = msg.autor_id === uid;
      const cooperado = msg.autor_id !== null && msg.autor_id === conversa.solicitante_id;
      // Autor nulo: conta excluída com histórico mantido de forma anônima.
      const autor = msg.autor_id === null ? "Usuário removido"
        : eu ? "Você"
        : cooperado ? "Cooperado"
        : "Equipe " + nomeArea;
      const item = document.createElement("div");
      item.className = "msg " + (eu ? "eu" : "outro");
      item.innerHTML = `<small>${esc(autor)} · ${dataCurta(msg.criado_em)}</small>${esc(msg.texto).replace(/\n/g, "<br>")}`;
      chat.appendChild(item);
      chat.scrollTop = chat.scrollHeight;
    }

    const { data: mensagens } = await sb()
      .from("mensagens")
      .select("id, texto, autor_id, criado_em")
      .eq("conversa_id", id)
      .order("criado_em", { ascending: true });
    (mensagens || []).forEach(adicionar);

    canalMensagens = sb()
      .channel("msg-" + id)
      .on("postgres_changes", {
        event: "INSERT", schema: "public", table: "mensagens",
        filter: "conversa_id=eq." + id,
      }, (payload) => adicionar(payload.new))
      .subscribe();

    const form = document.getElementById("form-mensagem");
    const erro = form.parentElement.querySelector(".erro");
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      erro.hidden = true;
      const texto = form.texto.value.trim();
      if (!texto) return;
      const { data: nova, error: erroEnvio } = await sb()
        .from("mensagens")
        .insert({ conversa_id: id, autor_id: uid, texto })
        .select("id, texto, autor_id, criado_em")
        .single();
      if (erroEnvio) {
        erro.textContent = "Não foi possível enviar: " + erroEnvio.message;
        erro.hidden = false;
        return;
      }
      form.texto.value = "";
      adicionar(nova);
    });
  }

  // ---------- Privacidade (LGPD) ----------

  async function telaPrivacidade() {
    alvo().innerHTML = '<p class="ajuda">Carregando...</p>';
    const { data: termo } = await sb()
      .from("termos_uso")
      .select("versao, texto")
      .order("publicado_em", { ascending: false })
      .limit(1)
      .maybeSingle();

    alvo().innerHTML = `
      <section class="cartao texto-legal">
        <h2>Política de privacidade</h2>
        <p><strong>Dados tratados:</strong> nome, CPF, e-mail, celular e o conteúdo das conversas e solicitações que você abrir.</p>
        <p><strong>Finalidade:</strong> atendimento ao cooperado e às pessoas que se relacionam com a cooperativa, incluindo solicitações de documentos e serviços.</p>
        <p><strong>Quem tem acesso:</strong> você, o administrador e somente os funcionários vinculados à área para a qual a solicitação foi enviada. Funcionários de outras áreas não veem essas conversas.</p>
        <p><strong>Notificações:</strong> os avisos não trazem o assunto nem o conteúdo das mensagens.</p>
        <p><strong>Retenção:</strong> as conversas são mantidas pelo prazo necessário ao atendimento e ao cumprimento de obrigações legais, conforme regras definidas pela cooperativa.</p>
        <p><strong>Seus direitos (LGPD):</strong> confirmar o tratamento, acessar, corrigir, solicitar a eliminação dos seus dados, obter informações sobre compartilhamento e revogar seu consentimento. Você pode corrigir seus dados em <a href="#meus-dados">Meus dados</a> e excluir sua conta na mesma tela.</p>
      </section>
      <section class="cartao texto-legal">
        <h2>Termos e Condições de Uso</h2>
        ${termo
          ? `<p class="ajuda">Versão ${esc(termo.versao)}. Você aceitou esta versão ao entrar no sistema.</p>
             <div class="texto-puro">${esc(termo.texto)}</div>`
          : '<p class="erro">Não foi possível carregar os termos agora.</p>'}
      </section>`;
  }

  // ---------- Áreas e funcionários (administrador) ----------

  async function telaAreas() {
    alvo().innerHTML = '<p class="ajuda">Carregando...</p>';
    const [{ data: areas }, { data: funcionarios }, { data: vinculos }] = await Promise.all([
      sb().from("areas").select("id, nome").order("nome"),
      sb().from("usuarios").select("id, nome_completo").eq("tipo_acesso", "funcionario").eq("status", "aprovado").order("nome_completo"),
      sb().from("funcionarios_areas").select("usuario_id, area_id"),
    ]);

    if (!funcionarios.length) {
      alvo().innerHTML = '<p class="ajuda">Ainda não há funcionários aprovados para vincular às áreas.</p>';
      return;
    }

    const vinculado = (usuario, area) => vinculos.some((v) => v.usuario_id === usuario && v.area_id === area);

    alvo().innerHTML = `<div class="lista">${funcionarios.map((f) => `
      <article class="item">
        <strong>${esc(f.nome_completo)}</strong>
        <div class="opcoes-areas">
          ${areas.map((a) => `
            <label class="opcao">
              <input type="checkbox" data-usuario="${f.id}" data-area="${a.id}" ${vinculado(f.id, a.id) ? "checked" : ""} />
              <span>${esc(a.nome)}</span>
            </label>`).join("")}
        </div>
      </article>`).join("")}</div>
      <p class="erro" hidden></p>`;

    alvo().querySelectorAll("input[type=checkbox]").forEach((caixa) => {
      caixa.addEventListener("change", async () => {
        const { usuario, area } = caixa.dataset;
        const operacao = caixa.checked
          ? sb().from("funcionarios_areas").insert({ usuario_id: usuario, area_id: area })
          : sb().from("funcionarios_areas").delete().eq("usuario_id", usuario).eq("area_id", area);
        const { error } = await operacao;
        if (error) {
          caixa.checked = !caixa.checked;
          alert("Não foi possível alterar o vínculo: " + error.message);
        }
      });
    });
  }

  window.Interno = { montar };
})();
