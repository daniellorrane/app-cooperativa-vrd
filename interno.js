// Painel interno: menu, início, conversas por área, solicitações, notificações e administração.
// Regras de acesso são aplicadas pelo banco (RLS). Esta camada apenas organiza a tela.
(() => {
  const sb = () => window.sb;
  const alvo = () => document.getElementById("conteudo-interno");
  let perfil = null;
  let canalMensagens = null;
  let canalNotificacoes = null;

  const STATUS = {
    aberta: "Aberta",
    em_andamento: "Em andamento",
    concluida: "Concluída",
    cancelada: "Cancelada",
  };
  const TIPOS = {
    conversa: "Atendimento",
    documento: "Solicitação de documento",
    servico: "Solicitação de serviço",
  };

  // Documentos versionados que exigem aceite: cadastro e a cada nova versão publicada.
  const DOCS = {
    termos: {
      tabela: "termos_uso",
      titulo: "Termos e Condições de Uso",
      campoVersao: "termo_versao",
      campoAceite: "termo_aceito_em",
    },
    privacidade: {
      tabela: "politicas_privacidade",
      titulo: "Política de Privacidade",
      campoVersao: "privacidade_versao",
      campoAceite: "privacidade_aceita_em",
    },
  };

  // Menu do painel. "rota" é o trecho após o # do endereço.
  const MENU = [
    { grupo: "Principal", rota: "inicio", titulo: "Início", icone: "home" },
    { grupo: "Principal", rota: "conversas", titulo: "Atendimentos", icone: "chat" },
    { grupo: "Principal", rota: "nova", titulo: "Nova solicitação", icone: "plus" },
    { grupo: "Principal", rota: "notificacoes", titulo: "Notificações", icone: "bell", badge: true },
    { grupo: "Principal", rota: "avisos", titulo: "Enviar aviso", icone: "send", staff: true },
    { grupo: "Principal", rota: "ouvidoria", titulo: "Ouvidoria", icone: "flag" },
    { grupo: "Conta", rota: "meus-dados", titulo: "Meus dados", icone: "user" },
    { grupo: "Conta", rota: "meus-direitos", titulo: "Privacidade e dados", icone: "shield" },
    { grupo: "Administração", rota: "admin/cadastros", titulo: "Cadastros", icone: "check", admin: true },
    { grupo: "Administração", rota: "admin/areas", titulo: "Áreas e funcionários", icone: "map", admin: true },
    { grupo: "Administração", rota: "admin/documentos", titulo: "Termos e privacidade", icone: "doc", admin: true },
    { grupo: "Administração", rota: "admin/privacidade", titulo: "Privacidade e ouvidoria", icone: "shield", admin: true },
  ];

  const ICONES = {
    home: "M3 11l9-8 9 8v9a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z",
    chat: "M4 5h16v11H8l-4 4z",
    plus: "M12 5v14M5 12h14",
    bell: "M6 16v-5a6 6 0 0 1 12 0v5l2 2H4zM10 20h4",
    user: "M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21a8 8 0 0 1 16 0",
    check: "M5 12l5 5 9-10",
    map: "M9 4L3 6v14l6-2 6 2 6-2V4l-6 2z",
    doc: "M7 3h7l5 5v13H7z",
    send: "M4 12l16-8-6 16-3-7z",
    shield: "M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z",
    flag: "M5 21V4h12l-2 4 2 4H5",
  };
  const icone = (nome) => `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="${ICONES[nome]}"/></svg>`;

  function esc(texto) {
    const d = document.createElement("div");
    d.textContent = texto ?? "";
    return d.innerHTML;
  }

  function dataCurta(valor) {
    return new Date(valor).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" });
  }

  function sairDaConversa() {
    if (canalMensagens) {
      sb().removeChannel(canalMensagens);
      canalMensagens = null;
    }
  }

  // ---------- Casca do painel ----------

  // Monta o menu e a área de conteúdo. "extras" traz as telas que vivem em app.js (Meus dados, aprovação de cadastros).
  async function abrirPainel(usuario, raiz, hash, extras = {}) {
    perfil = usuario;
    sairDaConversa();

    const admin = perfil.tipo_acesso === "administrador";
    const equipe = admin || perfil.tipo_acesso === "funcionario";
    const caminho = (hash || "inicio").split("/");
    const chave = caminho[0] === "admin" ? caminho.join("/") : caminho[0];
    const ativo = caminho[0] === "conversa" ? "conversas" : chave;

    const itens = MENU.filter((i) => (!i.admin || admin) && (!i.staff || equipe));
    const grupos = [...new Set(itens.map((i) => i.grupo))];

    raiz.className = "conteudo painel";
    raiz.innerHTML = `
      <div class="casca">
        <aside class="menu-lateral">
          <div class="usuario">
            <strong>${esc(perfil.nome_completo.split(" ")[0])}</strong>
            <span>${esc(perfil.tipo_acesso.replace("_", " "))}</span>
          </div>
          <nav aria-label="Menu principal">
            ${grupos.map((grupo) => `
              <p class="grupo-menu">${esc(grupo)}</p>
              ${itens.filter((i) => i.grupo === grupo).map((i) => `
                <a href="#${i.rota}" class="item-menu ${i.rota === ativo ? "ativo" : ""}"${i.rota === ativo ? ' aria-current="page"' : ""}>
                  ${icone(i.icone)}
                  <span>${esc(i.titulo)}</span>
                  ${i.badge ? '<span id="contador-notif" class="badge" hidden>0</span>' : ""}
                </a>`).join("")}`).join("")}
          </nav>
        </aside>
        <section id="conteudo-interno" class="conteudo-interno" aria-live="polite"></section>
      </div>`;

    assinarNotificacoes();
    atualizarContador();

    const telas = {
      inicio: telaInicio,
      conversas: telaConversas,
      conversa: () => telaConversa(caminho[1]),
      nova: telaNova,
      notificacoes: telaNotificacoes,
      avisos: () => (equipe ? telaAvisos() : telaInicio()),
      "meus-dados": () => extras["meus-dados"]?.(alvo()),
      "meus-direitos": () => window.Privacidade.meusDireitos(alvo(), perfil),
      ouvidoria: () => window.Privacidade.ouvidoria(alvo(), perfil),
      "admin/privacidade": () => (admin ? window.Privacidade.adminPrivacidade(alvo(), perfil) : telaInicio()),
      "admin/cadastros": () => (admin ? extras["admin/cadastros"]?.(alvo()) : telaInicio()),
      "admin/areas": () => (admin ? telaAreas() : telaInicio()),
      "admin/documentos": () => (admin ? telaDocumentos() : telaInicio()),
    };
    return (telas[chave] || telaInicio)();
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
      .channel("notif-" + perfil.id)
      .on("postgres_changes", {
        event: "INSERT", schema: "public", table: "notificacoes",
        filter: "usuario_id=eq." + perfil.id,
      }, () => atualizarContador())
      .subscribe();
  }

  async function telaNotificacoes() {
    alvo().innerHTML = '<p class="ajuda">Carregando...</p>';
    const { data, error } = await sb()
      .from("notificacoes")
      .select("id, titulo, corpo, tipo, lida, conversa_id, criado_em")
      .order("criado_em", { ascending: false })
      .limit(50);
    if (error) return (alvo().innerHTML = `<p class="erro">${esc(error.message)}</p>`);

    alvo().innerHTML = `
      <h1>Notificações</h1>
      <div class="acoes">
        <button id="marcar-todas" class="btn-ghost">Marcar todas como lidas</button>
      </div>
      <div class="lista">
        ${data.length ? data.map((n) => `
          <article class="item ${n.conversa_id ? "clicavel" : ""} ${n.lida ? "" : "nao-lida"}" data-id="${n.id}" data-conversa="${n.conversa_id ?? ""}">
            <div>
              <strong>${esc(n.titulo)}</strong>
              ${n.tipo === "manual" ? '<span class="etiqueta">Aviso da cooperativa</span>' : ""}
            </div>
            ${n.corpo ? `<p>${esc(n.corpo)}</p>` : ""}
            <p class="ajuda">${dataCurta(n.criado_em)}${n.lida ? "" : " · nova"}</p>
          </article>`).join("") : '<p class="ajuda">Nenhuma notificação.</p>'}
      </div>`;

    alvo().querySelectorAll("[data-id]").forEach((el) => {
      el.addEventListener("click", async () => {
        await sb().from("notificacoes").update({ lida: true }).eq("id", el.dataset.id);
        atualizarContador();
        if (el.dataset.conversa) location.hash = "conversa/" + el.dataset.conversa;
        else telaNotificacoes();
      });
    });

    document.getElementById("marcar-todas").addEventListener("click", async () => {
      await sb().from("notificacoes").update({ lida: true }).eq("lida", false);
      atualizarContador();
      telaNotificacoes();
    });
  }

  // ---------- Início ----------

  async function telaInicio() {
    alvo().innerHTML = '<p class="ajuda">Carregando...</p>';
    const [{ count: naoLidas }, { data: abertas }] = await Promise.all([
      sb().from("notificacoes").select("id", { count: "exact", head: true }).eq("lida", false),
      sb().from("conversas").select("id").in("status", ["aberta", "em_andamento"]),
    ]);
    const primeiroNome = perfil.nome_completo.split(" ")[0];

    alvo().innerHTML = `
      <h1>Olá, ${esc(primeiroNome)}</h1>
      <p class="ajuda">Acompanhe suas solicitações e notificações por aqui.</p>
      <div class="indicadores">
        <a class="indicador" href="#notificacoes">
          <strong>${naoLidas || 0}</strong>
          <span>Notificações não lidas</span>
        </a>
        <a class="indicador" href="#conversas">
          <strong>${abertas?.length || 0}</strong>
          <span>Solicitações em aberto</span>
        </a>
      </div>
      <div class="acoes">
        <a href="#nova" class="btn-primario">Nova solicitação</a>
      </div>`;
  }

  // ---------- Conversas e solicitações ----------

  async function telaConversas() {
    alvo().innerHTML = '<p class="ajuda">Carregando...</p>';
    const { data, error } = await sb()
      .from("conversas")
      .select("id, assunto, tipo, status, atualizado_em, solicitante_id, areas(nome)")
      .order("atualizado_em", { ascending: false });
    if (error) return (alvo().innerHTML = `<p class="erro">${esc(error.message)}</p>`);

    const filtros = [["todas", "Todas"], ["aberta", "Abertas"], ["em_andamento", "Em andamento"], ["concluida", "Concluídas"]];
    let filtroAtivo = "todas";

    alvo().innerHTML = `
      <h1>Atendimentos</h1>
      <p class="ajuda">Solicitações enviadas por você e, para funcionários, as da sua área.</p>
      <div class="filtros">
        ${filtros.map(([valor, rotulo]) => `<button class="chip ${valor === filtroAtivo ? "ativo" : ""}" data-filtro="${valor}">${rotulo}</button>`).join("")}
      </div>
      <div id="lista-conversas" class="lista"></div>`;

    const lista = document.getElementById("lista-conversas");
    function desenhar() {
      if (!data.length) {
        lista.innerHTML = '<p class="ajuda">Nenhum atendimento ainda. Use "Nova solicitação" para começar.</p>';
        return;
      }
      const visiveis = data.filter((c) => filtroAtivo === "todas" || c.status === filtroAtivo);
      lista.innerHTML = visiveis.length ? visiveis.map((c) => `
        <article class="item clicavel" data-id="${c.id}">
          <div>
            <strong>${esc(c.assunto)}</strong>
            <span class="etiqueta">${c.solicitante_id === perfil.id ? "Minha" : "Recebida"}</span>
          </div>
          <p class="ajuda">${esc(TIPOS[c.tipo])} · ${esc(c.areas?.nome)} · ${STATUS[c.status]} · ${dataCurta(c.atualizado_em)}</p>
        </article>`).join("") : '<p class="ajuda">Nenhuma solicitação nesta situação.</p>';

      lista.querySelectorAll("[data-id]").forEach((el) => {
        el.addEventListener("click", () => { location.hash = "conversa/" + el.dataset.id; });
      });
    }

    alvo().querySelectorAll("[data-filtro]").forEach((botao) => {
      botao.addEventListener("click", () => {
        filtroAtivo = botao.dataset.filtro;
        alvo().querySelectorAll("[data-filtro]").forEach((b) => b.classList.toggle("ativo", b === botao));
        desenhar();
      });
    });
    desenhar();
  }

  async function telaNova() {
    const { data: areas } = await sb().from("areas").select("id, nome").eq("ativa", true).order("nome");
    alvo().innerHTML = `
      <section class="cartao">
        <h1>Nova solicitação</h1>
        <p class="ajuda">Escolha a área, o tipo e descreva o que precisa. A equipe responde por aqui.</p>
        <form id="form-nova" novalidate>
          <label>Área
            <select name="area" required>
              ${(areas || []).map((a) => `<option value="${a.id}">${esc(a.nome)}</option>`).join("")}
            </select>
          </label>
          <label>Tipo
            <select name="tipo" required>
              <option value="conversa">Atendimento</option>
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
        .insert({ area_id: form.area.value, tipo: form.tipo.value, assunto, solicitante_id: perfil.id })
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
        .insert({ conversa_id: conversa.id, autor_id: perfil.id, texto });
      if (erroMsg) {
        erro.textContent = "Solicitação criada, mas a mensagem não foi enviada: " + erroMsg.message;
        erro.hidden = false;
        botao.disabled = false;
        return;
      }
      location.hash = "conversa/" + conversa.id;
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

    const souSolicitante = conversa.solicitante_id === perfil.id;
    const nomeArea = conversa.areas?.nome || "Atendimento";

    alvo().innerHTML = `
      <section class="cartao">
        <a href="#conversas" class="btn-ghost">Voltar aos atendimentos</a>
        <h1 class="titulo-conversa">${esc(conversa.assunto)}</h1>
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
      const eu = msg.autor_id === perfil.id;
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
        .insert({ conversa_id: id, autor_id: perfil.id, texto })
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

  // ---------- Avisos manuais (funcionários e administrador) ----------

  const DESTINATARIOS = [
    ["todos", "Todos os usuários aprovados"],
    ["cooperado", "Cooperados"],
    ["cliente", "Clientes"],
    ["fornecedor", "Fornecedores"],
    ["prestador_servico", "Prestadores de serviço"],
    ["funcionario", "Funcionários"],
  ];
  const nomeDestino = (valor) => (DESTINATARIOS.find(([v]) => v === valor) || [null, valor])[1];

  async function telaAvisos() {
    alvo().innerHTML = '<p class="ajuda">Carregando...</p>';
    const { data: enviados, error } = await sb()
      .from("comunicados")
      .select("id, titulo, destinatarios, total, criado_em")
      .order("criado_em", { ascending: false })
      .limit(30);
    if (error) return (alvo().innerHTML = `<p class="erro">${esc(error.message)}</p>`);

    alvo().innerHTML = `
      <h1>Enviar aviso</h1>
      <p class="ajuda">A pessoa recebe um alerta genérico no aparelho e o texto completo dentro do sistema. O texto fica registrado com o seu nome, então evite dados pessoais de terceiros.</p>
      <section class="cartao">
        <form id="form-aviso" novalidate>
          <label>Para quem
            <select name="destinatarios" required>
              ${DESTINATARIOS.map(([v, r]) => `<option value="${v}">${esc(r)}</option>`).join("")}
            </select>
          </label>
          <label>Título <small>(aparece na lista de notificações)</small>
            <input type="text" name="titulo" maxlength="80" required minlength="3" />
          </label>
          <label>Mensagem
            <textarea name="corpo" rows="5" maxlength="1000" required></textarea>
          </label>
          <p class="erro" role="alert" hidden></p>
          <p class="sucesso" role="status" hidden></p>
          <button type="submit" class="btn-primario">Enviar aviso</button>
        </form>
      </section>
      <h2>Avisos enviados</h2>
      <div class="lista">
        ${enviados.length ? enviados.map((c) => `
          <article class="item">
            <strong>${esc(c.titulo)}</strong>
            <p class="ajuda">${esc(nomeDestino(c.destinatarios))} · ${c.total} destinatário(s) · ${dataCurta(c.criado_em)}</p>
          </article>`).join("") : '<p class="ajuda">Nenhum aviso enviado ainda.</p>'}
      </div>`;

    const form = document.getElementById("form-aviso");
    const erro = form.querySelector(".erro");
    const sucesso = form.querySelector(".sucesso");
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      erro.hidden = true;
      sucesso.hidden = true;
      const titulo = form.titulo.value.trim();
      const corpo = form.corpo.value.trim();
      const destinatarios = form.destinatarios.value;
      if (titulo.length < 3 || corpo.length < 3) {
        erro.textContent = "Preencha o título e a mensagem do aviso.";
        erro.hidden = false;
        return;
      }
      if (!confirm(`Enviar este aviso para: ${nomeDestino(destinatarios)}?`)) return;

      const botao = form.querySelector("button");
      botao.disabled = true;
      const { data: quantidade, error: erroEnvio } = await sb().rpc("enviar_comunicado", {
        p_titulo: titulo,
        p_corpo: corpo,
        p_destinatarios: destinatarios,
      });
      if (erroEnvio) {
        botao.disabled = false;
        erro.textContent = "Não foi possível enviar: " + erroEnvio.message;
        erro.hidden = false;
        return;
      }
      await telaAvisos();
      const aviso = alvo().querySelector(".sucesso");
      aviso.textContent = `Aviso enviado para ${quantidade} pessoa(s).`;
      aviso.hidden = false;
    });
  }

  // ---------- Administração ----------

  async function telaAreas() {
    alvo().innerHTML = '<p class="ajuda">Carregando...</p>';
    const [{ data: areas }, { data: funcionarios }, { data: vinculos }] = await Promise.all([
      sb().from("areas").select("id, nome").order("nome"),
      sb().from("usuarios").select("id, nome_completo").eq("tipo_acesso", "funcionario").eq("status", "aprovado").order("nome_completo"),
      sb().from("funcionarios_areas").select("usuario_id, area_id"),
    ]);

    alvo().innerHTML = `
      <h1>Áreas e funcionários</h1>
      <p class="ajuda">Marque em quais áreas cada funcionário atua. Ele verá somente as solicitações dessas áreas.</p>
      <div id="lista-vinculos"></div>
      <p class="erro" hidden></p>`;

    if (!funcionarios.length) {
      document.getElementById("lista-vinculos").innerHTML = '<p class="ajuda">Ainda não há funcionários aprovados para vincular às áreas.</p>';
      return;
    }

    const vinculado = (usuario, area) => vinculos.some((v) => v.usuario_id === usuario && v.area_id === area);

    document.getElementById("lista-vinculos").innerHTML = `<div class="lista">${funcionarios.map((f) => `
      <article class="item">
        <strong>${esc(f.nome_completo)}</strong>
        <div class="opcoes-areas">
          ${areas.map((a) => `
            <label class="opcao">
              <input type="checkbox" data-usuario="${f.id}" data-area="${a.id}" ${vinculado(f.id, a.id) ? "checked" : ""} />
              <span>${esc(a.nome)}</span>
            </label>`).join("")}
        </div>
      </article>`).join("")}</div>`;

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

  // Termos e política: escolhe o documento e publica nova versão.
  function telaDocumentos(tipo = "termos") {
    alvo().innerHTML = `
      <h1>Termos e privacidade</h1>
      <p class="ajuda">Ao publicar uma nova versão, todos os usuários, novos e já cadastrados, precisam aceitá-la para continuar usando o sistema.</p>
      <div class="filtros">
        <button class="chip ${tipo === "termos" ? "ativo" : ""}" data-doc="termos">Termos de uso</button>
        <button class="chip ${tipo === "privacidade" ? "ativo" : ""}" data-doc="privacidade">Política de privacidade</button>
      </div>
      <div id="publicar-doc"></div>`;
    alvo().querySelectorAll("[data-doc]").forEach((botao) => {
      botao.addEventListener("click", () => telaDocumentos(botao.dataset.doc));
    });
    return telaPublicarDocumento(tipo, document.getElementById("publicar-doc"));
  }

  // Sugere o próximo número: 1.0 vira 1.1.
  function proximaVersao(versao) {
    const partes = String(versao).split(".");
    const ultimo = Number(partes.pop());
    return Number.isInteger(ultimo) ? [...partes, ultimo + 1].join(".") : "";
  }

  // Versão vigente de um documento (a publicada mais recente). Retorna null se não for possível ler.
  async function carregarVigente(tipo) {
    const { data, error } = await sb()
      .from(DOCS[tipo].tabela)
      .select("versao, texto, publicado_em")
      .order("publicado_em", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (error || !data) return null;
    return data;
  }

  async function telaPublicarDocumento(tipo, destino) {
    const doc = DOCS[tipo];
    destino.innerHTML = '<p class="ajuda">Carregando...</p>';
    const { data: versoes, error } = await sb()
      .from(doc.tabela)
      .select("versao, texto, publicado_em")
      .order("publicado_em", { ascending: false });
    if (error) return (destino.innerHTML = `<p class="erro">${esc(error.message)}</p>`);

    const atual = versoes[0];
    destino.innerHTML = `
      <section class="cartao">
        <h2>Nova versão: ${esc(doc.titulo)}</h2>
        <p class="ajuda">O texto inicia com a versão atual para você editar uma cópia. O primeiro bloco é o título; as cláusulas começam com número, como "2. Cadastro". Separe os blocos com uma linha em branco. Versões publicadas não podem ser alteradas nem apagadas.</p>
        <form id="form-termo" novalidate>
          <label>Número da versão <small>(ex.: 1.1)</small>
            <input type="text" name="versao" maxlength="20" value="${esc(atual ? proximaVersao(atual.versao) : "1.0")}" required />
          </label>
          <label>Texto
            <textarea name="texto" rows="18" maxlength="50000" required>${esc(atual ? atual.texto : "")}</textarea>
          </label>
          <p class="erro" role="alert" hidden></p>
          <p class="sucesso" role="status" hidden></p>
          <button type="submit" class="btn-primario">Publicar versão</button>
        </form>
      </section>
      <section class="cartao">
        <h2>Versões publicadas</h2>
        <div class="lista">${versoes.map((v) => `
          <article class="item">
            <strong>Versão ${esc(v.versao)}</strong>
            <p class="ajuda">Publicada em ${dataCurta(v.publicado_em)}${atual && v.versao === atual.versao ? " · vigente" : ""}</p>
          </article>`).join("")}</div>
      </section>`;

    const form = document.getElementById("form-termo");
    const erro = form.querySelector(".erro");
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      erro.hidden = true;
      destino.querySelector(".sucesso").hidden = true;
      const versao = form.versao.value.trim();
      const texto = form.texto.value.trim();

      const mostrarErro = (msg) => { erro.textContent = msg; erro.hidden = false; };
      if (!/^[\w.-]{1,20}$/.test(versao)) return mostrarErro("Número de versão inválido. Use letras, números, ponto ou hífen.");
      if (versoes.some((v) => v.versao === versao)) return mostrarErro("Esta versão já existe. Escolha outro número.");
      if (texto.length < 200) return mostrarErro("O texto parece curto demais para ser o documento completo.");
      if (!confirm(`Publicar a versão ${versao} de ${doc.titulo}? Todos os usuários precisarão aceitá-la.`)) return;

      const botao = form.querySelector("button");
      botao.disabled = true;
      const { error: erroPublicar } = await sb().from(doc.tabela).insert({ versao, texto });
      if (erroPublicar) {
        botao.disabled = false;
        return mostrarErro("Não foi possível publicar: " + erroPublicar.message);
      }
      await telaPublicarDocumento(tipo, destino);
      const aviso = destino.querySelector(".sucesso");
      aviso.textContent = `Versão ${versao} publicada. Ela será exigida de todos os usuários no próximo acesso.`;
      aviso.hidden = false;
    });
  }

  window.Interno = { abrirPainel, DOCS, carregarVigente };
})();
