// Privacidade e dados (LGPD), ouvidoria e administração dessas áreas.
// As regras de acesso ficam no banco (RLS e funções). Esta camada organiza as telas.
(() => {
  const sb = () => window.sb;

  const TITULAR = {
    confirmacao: "Confirmar se tratamos meus dados",
    acesso: "Acessar meus dados",
    correcao: "Corrigir meus dados",
    anonimizacao: "Anonimizar minha conta",
    eliminacao: "Excluir meus dados",
    portabilidade: "Receber meus dados em formato portável",
    informacao: "Saber com quem meus dados são compartilhados",
    revogacao: "Revogar meu consentimento",
  };
  const STATUS_TITULAR = { recebida: "Recebido", em_analise: "Em análise", atendida: "Atendido", negada: "Não atendido" };
  const OUV_TIPOS = { reclamacao: "Reclamação", denuncia: "Denúncia", sugestao: "Sugestão", elogio: "Elogio" };
  const OUV_STATUS = { recebida: "Recebida", em_analise: "Em análise", respondida: "Respondida", encerrada: "Encerrada" };

  const esc = (texto) => {
    const d = document.createElement("div");
    d.textContent = texto ?? "";
    return d.innerHTML;
  };
  const dataCurta = (v) => (v ? new Date(v).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" }) : "");
  const dataSimples = (v) => (v ? new Date(v).toLocaleDateString("pt-BR") : "");
  const opcoes = (mapa, atual) =>
    Object.entries(mapa).map(([v, r]) => `<option value="${v}" ${v === atual ? "selected" : ""}>${esc(r)}</option>`).join("");
  const aviso = (el, texto, tipo = "erro") => {
    el.textContent = texto;
    el.className = "form-mensagem " + tipo;
  };
  const ouvidoriaProtocolo = () => {
    const agora = new Date();
    const p2 = (n) => String(n).padStart(2, "0");
    const ymd = String(agora.getFullYear()).slice(2) + p2(agora.getMonth() + 1) + p2(agora.getDate());
    const hex = [...crypto.getRandomValues(new Uint8Array(3))].map((b) => b.toString(16).padStart(2, "0")).join("").toUpperCase();
    return `OUV-${ymd}-${hex}`;
  };
  const baixarJson = (dados, nome) => {
    const url = URL.createObjectURL(new Blob([JSON.stringify(dados, null, 2)], { type: "application/json" }));
    const a = document.createElement("a");
    a.href = url;
    a.download = nome;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  };

  // ---------- Meus direitos (LGPD) ----------

  async function meusDireitos(destino, perfil) {
    destino.innerHTML = '<section class="cartao largo"><p class="ajuda">Carregando...</p></section>';
    const [{ data: config }, { data: pedidos, error }] = await Promise.all([
      sb().from("configuracoes").select("chave, valor").in("chave", ["dpo_nome", "dpo_email"]),
      sb().from("solicitacoes_titular").select("tipo, status, prazo, resposta, criado_em").order("criado_em", { ascending: false }),
    ]);
    if (error) return (destino.innerHTML = `<p class="erro">${esc(error.message)}</p>`);
    const dpo = Object.fromEntries((config || []).map((c) => [c.chave, c.valor]));

    destino.innerHTML = `
      <header class="topo">
        <h1>Privacidade e dados</h1>
        <p class="ajuda">Acompanhe os seus dados pessoais e faça pedidos sobre eles, conforme a Lei Geral de Proteção de Dados (LGPD).</p>
      </header>

      <section class="cartao largo">
        <h2>Encarregado de dados</h2>
        ${dpo.dpo_email
          ? `<p>${esc(dpo.dpo_nome || "Encarregado")}: <a href="mailto:${esc(dpo.dpo_email)}">${esc(dpo.dpo_email)}</a></p>`
          : '<p class="ajuda">O contato do encarregado ainda não foi informado. Use a Ouvidoria para falar com a cooperativa.</p>'}
      </section>

      <section class="cartao largo">
        <h2>Baixar meus dados</h2>
        <p class="ajuda">Um arquivo com o seu cadastro, aceites, atendimentos, notificações e pedidos. Mensagens de funcionários aparecem como "Equipe", sem nome.</p>
        <button type="button" class="btn-primario" id="btn-exportar">Baixar meus dados (JSON)</button>
        <p class="form-mensagem" id="aviso-exportar" role="status"></p>
      </section>

      <section class="cartao largo">
        <h2>Fazer um pedido</h2>
        <form id="form-titular" class="formulario">
          <label>O que você deseja
            <select name="tipo" required>
              <option value="">Escolha</option>
              ${opcoes(TITULAR, "")}
            </select>
          </label>
          <label>Detalhes (opcional)
            <textarea name="descricao" rows="3" maxlength="500" placeholder="Explique o que precisa, se quiser."></textarea>
          </label>
          <p class="ajuda">Para excluir ou anonimizar a conta agora, use "Excluir minha conta" em Meus dados. O pedido fica registrado para a cooperativa acompanhar.</p>
          <button type="submit" class="btn-primario">Enviar pedido</button>
          <p class="form-mensagem" role="status"></p>
        </form>
      </section>

      <section class="cartao largo">
        <h2>Meus pedidos</h2>
        ${(pedidos || []).length
          ? `<div class="lista">${pedidos.map((p) => `
              <article class="item">
                <strong>${esc(TITULAR[p.tipo])}</strong>
                <p class="ajuda">${esc(STATUS_TITULAR[p.status])} · pedido em ${dataSimples(p.criado_em)} · prazo até ${dataSimples(p.prazo)}</p>
                ${p.resposta ? `<p>${esc(p.resposta)}</p>` : ""}
              </article>`).join("")}</div>`
          : '<p class="ajuda">Você ainda não fez nenhum pedido.</p>'}
      </section>`;

    destino.querySelector("#btn-exportar").addEventListener("click", async (evento) => {
      const btn = evento.currentTarget;
      const avisoEl = destino.querySelector("#aviso-exportar");
      btn.disabled = true;
      const { data, error: erroExport } = await sb().rpc("exportar_meus_dados");
      btn.disabled = false;
      if (erroExport) return aviso(avisoEl, "Não foi possível gerar o arquivo agora. Tente novamente.");
      baixarJson(data, "meus-dados-cooperativa.json");
      aviso(avisoEl, "Arquivo gerado. Ele foi baixado para o seu aparelho.", "sucesso");
    });

    const form = destino.querySelector("#form-titular");
    form.addEventListener("submit", async (evento) => {
      evento.preventDefault();
      const tipo = form.tipo.value;
      const descricao = form.descricao.value.trim();
      const msg = form.querySelector(".form-mensagem");
      if (!tipo) return aviso(msg, "Escolha o que você deseja.");
      const { error: erroEnvio } = await sb()
        .from("solicitacoes_titular")
        .insert({ usuario_id: perfil.id, tipo, descricao: descricao || null });
      if (erroEnvio) return aviso(msg, "Não foi possível registrar o pedido: " + erroEnvio.message);
      meusDireitos(destino, perfil);
    });
  }

  // ---------- Ouvidoria ----------

  async function ouvidoria(destino, perfil) {
    destino.innerHTML = `
      <header class="topo">
        <h1>Ouvidoria</h1>
        <p class="ajuda">Envie reclamações, denúncias, sugestões ou elogios. Você pode se identificar ou registrar de forma anônima.</p>
      </header>

      <section class="cartao largo">
        <h2>Nova manifestação</h2>
        <form id="form-ouvidoria" class="formulario">
          <label>Tipo
            <select name="tipo" required>${opcoes(OUV_TIPOS, "")}</select>
          </label>
          <label>Assunto
            <input name="assunto" required minlength="3" maxlength="150" />
          </label>
          <label>Descrição
            <textarea name="descricao" rows="5" required minlength="10" maxlength="3000"></textarea>
          </label>
          <label class="opcao">
            <input type="checkbox" name="anonima" />
            <span>Registrar de forma anônima. A equipe não verá o seu nome, e só você poderá acompanhar pelo protocolo.</span>
          </label>
          <button type="submit" class="btn-primario">Enviar</button>
          <p class="form-mensagem" role="status"></p>
        </form>
        <div id="protocolo-novo" hidden></div>
      </section>

      <section class="cartao largo">
        <h2>Acompanhar pelo protocolo</h2>
        <form id="form-consulta" class="formulario">
          <label>Número do protocolo
            <input name="protocolo" placeholder="OUV-000000-ABC123" required />
          </label>
          <button type="submit" class="btn-primario">Consultar</button>
          <p class="form-mensagem" role="status"></p>
        </form>
        <div id="resultado-consulta"></div>
      </section>

      <section class="cartao largo">
        <h2>Minhas manifestações identificadas</h2>
        <div id="lista-ouvidoria"><p class="ajuda">Carregando...</p></div>
      </section>`;

    const listar = async () => {
      const { data, error } = await sb()
        .from("ouvidoria")
        .select("protocolo, tipo, assunto, status, resposta, prazo, criado_em")
        .order("criado_em", { ascending: false });
      const lista = destino.querySelector("#lista-ouvidoria");
      if (error) return (lista.innerHTML = `<p class="erro">${esc(error.message)}</p>`);
      lista.innerHTML = (data || []).length
        ? `<div class="lista">${data.map((o) => `
            <article class="item">
              <strong>${esc(o.assunto)}</strong>
              <p class="ajuda">${esc(OUV_TIPOS[o.tipo])} · ${esc(o.protocolo)} · ${esc(OUV_STATUS[o.status])} · prazo até ${dataSimples(o.prazo)}</p>
              ${o.resposta ? `<p>${esc(o.resposta)}</p>` : ""}
            </article>`).join("")}</div>`
        : '<p class="ajuda">Você ainda não enviou manifestações identificadas.</p>';
    };
    listar();

    const form = destino.querySelector("#form-ouvidoria");
    form.addEventListener("submit", async (evento) => {
      evento.preventDefault();
      const msg = form.querySelector(".form-mensagem");
      const anonima = form.anonima.checked;
      const protocolo = ouvidoriaProtocolo();
      const { error } = await sb().from("ouvidoria").insert({
        protocolo,
        tipo: form.tipo.value,
        assunto: form.assunto.value.trim(),
        descricao: form.descricao.value.trim(),
        anonima,
        usuario_id: anonima ? null : perfil.id,
      });
      if (error) return aviso(msg, "Não foi possível registrar: " + error.message);
      const bloco = destino.querySelector("#protocolo-novo");
      bloco.hidden = false;
      bloco.innerHTML = `<p class="sucesso">Manifestação registrada. Guarde o protocolo <strong>${esc(protocolo)}</strong> para acompanhar a resposta.</p>`;
      form.reset();
      listar();
    });

    destino.querySelector("#form-consulta").addEventListener("submit", async (evento) => {
      evento.preventDefault();
      const f = evento.currentTarget;
      const saida = destino.querySelector("#resultado-consulta");
      const { data, error } = await sb().rpc("consultar_ouvidoria", { p_protocolo: f.protocolo.value });
      if (error) return (saida.innerHTML = `<p class="erro">${esc(error.message)}</p>`);
      const r = data?.[0];
      saida.innerHTML = r
        ? `<article class="item"><strong>${esc(r.protocolo)}</strong>
             <p class="ajuda">${esc(OUV_STATUS[r.status])} · prazo até ${dataSimples(r.prazo)} · atualizado em ${dataCurta(r.atualizado_em)}</p>
             ${r.resposta ? `<p>${esc(r.resposta)}</p>` : "<p class=\"ajuda\">Ainda sem resposta.</p>"}
           </article>`
        : '<p class="ajuda">Protocolo não encontrado. Confira o número.</p>';
    });
  }

  // ---------- Administração ----------

  const ABAS = {
    pedidos: "Pedidos de titulares",
    ouvidoria: "Ouvidoria",
    incidentes: "Incidentes",
    encarregado: "Encarregado",
    auditoria: "Auditoria",
  };

  async function adminPrivacidade(destino, perfil) {
    destino.innerHTML = `
      <header class="topo"><h1>Privacidade e ouvidoria</h1></header>
      <nav class="filtros" aria-label="Seções">
        ${Object.entries(ABAS).map(([k, r]) => `<button type="button" class="chip" data-aba="${k}">${esc(r)}</button>`).join("")}
      </nav>
      <div id="aba-conteudo"></div>`;

    const abrir = (aba) => {
      destino.querySelectorAll("[data-aba]").forEach((b) => b.classList.toggle("ativo", b.dataset.aba === aba));
      const alvo = destino.querySelector("#aba-conteudo");
      const telas = { pedidos: abaPedidos, ouvidoria: abaOuvidoria, incidentes: abaIncidentes, encarregado: abaEncarregado, auditoria: abaAuditoria };
      telas[aba](alvo, perfil);
    };
    destino.querySelectorAll("[data-aba]").forEach((b) => b.addEventListener("click", () => abrir(b.dataset.aba)));
    abrir("pedidos");
  }

  async function abaPedidos(alvo, perfil) {
    alvo.innerHTML = '<p class="ajuda">Carregando...</p>';
    const { data, error } = await sb()
      .from("solicitacoes_titular")
      .select("id, tipo, descricao, status, prazo, resposta, criado_em, usuarios:usuario_id(nome_completo)")
      .order("criado_em", { ascending: false });
    if (error) return (alvo.innerHTML = `<p class="erro">${esc(error.message)}</p>`);
    const encerrado = (s) => s === "atendida" || s === "negada";
    alvo.innerHTML = (data || []).length ? `<div class="lista">${data.map((p) => {
      const vencido = !encerrado(p.status) && new Date(p.prazo) < new Date();
      return `
        <article class="item" data-id="${p.id}">
          <strong>${esc(TITULAR[p.tipo])}</strong>
          <p class="ajuda">${esc(p.usuarios?.nome_completo ?? "Usuário removido")} · pedido em ${dataCurta(p.criado_em)} · prazo ${dataSimples(p.prazo)}${vencido ? ' · <span class="erro">prazo vencido</span>' : ""}</p>
          ${p.descricao ? `<p>${esc(p.descricao)}</p>` : ""}
          <label>Situação
            <select name="status">${opcoes(STATUS_TITULAR, p.status)}</select>
          </label>
          <label>Resposta ao titular
            <textarea name="resposta" rows="2" maxlength="1000">${esc(p.resposta ?? "")}</textarea>
          </label>
          <button type="button" class="btn-ghost" data-salvar>Salvar</button>
          <p class="form-mensagem" role="status"></p>
        </article>`;
    }).join("")}</div>` : '<p class="ajuda">Nenhum pedido registrado.</p>';

    alvo.querySelectorAll("[data-salvar]").forEach((btn) => btn.addEventListener("click", async () => {
      const card = btn.closest("[data-id]");
      const { error: erroUpd } = await sb().from("solicitacoes_titular").update({
        status: card.querySelector("[name=status]").value,
        resposta: card.querySelector("[name=resposta]").value.trim() || null,
        respondido_por: perfil.id,
      }).eq("id", card.dataset.id);
      aviso(card.querySelector(".form-mensagem"), erroUpd ? "Não foi possível salvar: " + erroUpd.message : "Salvo.", erroUpd ? "erro" : "sucesso");
    }));
  }

  async function abaOuvidoria(alvo) {
    alvo.innerHTML = '<p class="ajuda">Carregando...</p>';
    const { data, error } = await sb()
      .from("ouvidoria")
      .select("id, protocolo, tipo, assunto, descricao, anonima, status, resposta, prazo, criado_em, usuarios:usuario_id(nome_completo)")
      .order("criado_em", { ascending: false });
    if (error) return (alvo.innerHTML = `<p class="erro">${esc(error.message)}</p>`);
    alvo.innerHTML = (data || []).length ? `<div class="lista">${data.map((o) => `
      <article class="item" data-id="${o.id}">
        <strong>${esc(o.assunto)}</strong>
        <p class="ajuda">${esc(OUV_TIPOS[o.tipo])} · ${esc(o.protocolo)} · ${o.anonima ? "Anônima" : esc(o.usuarios?.nome_completo ?? "Usuário removido")} · prazo ${dataSimples(o.prazo)}</p>
        <p>${esc(o.descricao)}</p>
        <label>Situação
          <select name="status">${opcoes(OUV_STATUS, o.status)}</select>
        </label>
        <label>Resposta
          <textarea name="resposta" rows="2" maxlength="3000">${esc(o.resposta ?? "")}</textarea>
        </label>
        <button type="button" class="btn-ghost" data-salvar>Salvar</button>
        <p class="form-mensagem" role="status"></p>
      </article>`).join("")}</div>` : '<p class="ajuda">Nenhuma manifestação recebida.</p>';

    alvo.querySelectorAll("[data-salvar]").forEach((btn) => btn.addEventListener("click", async () => {
      const card = btn.closest("[data-id]");
      const { error: erroUpd } = await sb().from("ouvidoria").update({
        status: card.querySelector("[name=status]").value,
        resposta: card.querySelector("[name=resposta]").value.trim() || null,
      }).eq("id", card.dataset.id);
      aviso(card.querySelector(".form-mensagem"), erroUpd ? "Não foi possível salvar: " + erroUpd.message : "Salvo.", erroUpd ? "erro" : "sucesso");
    }));
  }

  async function abaIncidentes(alvo, perfil) {
    alvo.innerHTML = '<p class="ajuda">Carregando...</p>';
    const { data, error } = await sb().from("incidentes_seguranca").select("*").order("ocorrido_em", { ascending: false });
    if (error) return (alvo.innerHTML = `<p class="erro">${esc(error.message)}</p>`);
    alvo.innerHTML = `
      <section class="cartao largo">
        <h2>Registrar incidente</h2>
        <p class="ajuda">Registre vazamentos ou acessos indevidos. A LGPD exige comunicar a ANPD e os titulares em prazo razoável (art. 48).</p>
        <form id="form-incidente" class="formulario">
          <label>O que aconteceu
            <textarea name="descricao" rows="3" required minlength="10"></textarea>
          </label>
          <label>Quando ocorreu
            <input type="datetime-local" name="ocorrido_em" required />
          </label>
          <label>Dados afetados
            <input name="dados_afetados" maxlength="500" />
          </label>
          <label>Medidas tomadas
            <textarea name="medidas" rows="2" maxlength="1000"></textarea>
          </label>
          <button type="submit" class="btn-primario">Registrar</button>
          <p class="form-mensagem" role="status"></p>
        </form>
      </section>
      <div class="lista">${(data || []).map((i) => `
        <article class="item" data-id="${i.id}">
          <strong>Ocorrido em ${dataCurta(i.ocorrido_em)}</strong>
          <p>${esc(i.descricao)}</p>
          ${i.dados_afetados ? `<p class="ajuda">Dados: ${esc(i.dados_afetados)}</p>` : ""}
          ${i.medidas ? `<p class="ajuda">Medidas: ${esc(i.medidas)}</p>` : ""}
          <p class="ajuda">ANPD: ${i.comunicado_anpd_em ? dataCurta(i.comunicado_anpd_em) : "pendente"} · Titulares: ${i.comunicado_titulares_em ? dataCurta(i.comunicado_titulares_em) : "pendente"}</p>
          ${i.comunicado_anpd_em ? "" : '<button type="button" class="btn-ghost" data-comunicar="comunicado_anpd_em">Marcar comunicado à ANPD</button>'}
          ${i.comunicado_titulares_em ? "" : '<button type="button" class="btn-ghost" data-comunicar="comunicado_titulares_em">Marcar comunicado aos titulares</button>'}
        </article>`).join("")}</div>`;

    alvo.querySelector("#form-incidente").addEventListener("submit", async (evento) => {
      evento.preventDefault();
      const f = evento.currentTarget;
      const { error: erroIns } = await sb().from("incidentes_seguranca").insert({
        descricao: f.descricao.value.trim(),
        ocorrido_em: new Date(f.ocorrido_em.value).toISOString(),
        dados_afetados: f.dados_afetados.value.trim() || null,
        medidas: f.medidas.value.trim() || null,
      });
      if (erroIns) return aviso(f.querySelector(".form-mensagem"), "Não foi possível registrar: " + erroIns.message);
      abaIncidentes(alvo, perfil);
    });

    alvo.querySelectorAll("[data-comunicar]").forEach((btn) => btn.addEventListener("click", async () => {
      const coluna = btn.dataset.comunicar;
      const { error: erroUpd } = await sb().from("incidentes_seguranca")
        .update({ [coluna]: new Date().toISOString() })
        .eq("id", btn.closest("[data-id]").dataset.id);
      if (erroUpd) return alert("Não foi possível registrar: " + erroUpd.message);
      abaIncidentes(alvo, perfil);
    }));
  }

  async function abaEncarregado(alvo) {
    alvo.innerHTML = '<p class="ajuda">Carregando...</p>';
    const { data } = await sb().from("configuracoes").select("chave, valor").in("chave", ["dpo_nome", "dpo_email"]);
    const atual = Object.fromEntries((data || []).map((c) => [c.chave, c.valor || ""]));
    alvo.innerHTML = `
      <section class="cartao largo">
        <h2>Encarregado de dados (DPO)</h2>
        <p class="ajuda">Este contato aparece para todos os usuários em Privacidade e dados, como exige a LGPD (art. 41).</p>
        <form id="form-dpo" class="formulario">
          <label>Nome
            <input name="dpo_nome" maxlength="120" value="${esc(atual.dpo_nome)}" />
          </label>
          <label>E-mail
            <input name="dpo_email" type="email" maxlength="160" value="${esc(atual.dpo_email)}" />
          </label>
          <button type="submit" class="btn-primario">Salvar</button>
          <p class="form-mensagem" role="status"></p>
        </form>
      </section>`;
    alvo.querySelector("#form-dpo").addEventListener("submit", async (evento) => {
      evento.preventDefault();
      const f = evento.currentTarget;
      const msg = f.querySelector(".form-mensagem");
      const email = f.dpo_email.value.trim();
      if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return aviso(msg, "Informe um e-mail válido.");
      const r1 = await sb().from("configuracoes").update({ valor: f.dpo_nome.value.trim() || null }).eq("chave", "dpo_nome");
      const r2 = await sb().from("configuracoes").update({ valor: email || null }).eq("chave", "dpo_email");
      const erroFinal = r1.error || r2.error;
      aviso(msg, erroFinal ? "Não foi possível salvar: " + erroFinal.message : "Salvo.", erroFinal ? "erro" : "sucesso");
    });
  }

  async function abaAuditoria(alvo) {
    alvo.innerHTML = '<p class="ajuda">Carregando...</p>';
    const { data, error } = await sb()
      .from("auditoria")
      .select("id, criado_em, acao, entidade, entidade_id, detalhes, ator_id")
      .order("criado_em", { ascending: false })
      .limit(200);
    if (error) return (alvo.innerHTML = `<p class="erro">${esc(error.message)}</p>`);
    const ids = [...new Set((data || []).map((r) => r.ator_id).filter(Boolean))];
    const nomes = {};
    if (ids.length) {
      const { data: usuarios } = await sb().from("usuarios").select("id, nome_completo").in("id", ids);
      (usuarios || []).forEach((u) => (nomes[u.id] = u.nome_completo));
    }
    alvo.innerHTML = `
      <section class="cartao largo">
        <p class="ajuda">Últimos 200 registros. Mostra quem fez cada ação, sem o conteúdo das mensagens.</p>
        <label>Filtrar pela ação
          <input id="filtro-auditoria" placeholder="Ex.: usuario_alterado" />
        </label>
        <div class="lista" id="lista-auditoria">${(data || []).map((r) => `
          <article class="item" data-acao="${esc(r.acao)}">
            <strong>${esc(r.acao)}</strong>
            <p class="ajuda">${dataCurta(r.criado_em)} · ${r.ator_id ? esc(nomes[r.ator_id] ?? "Usuário removido") : "Sistema"} · ${esc(r.entidade)}${r.entidade_id ? " · " + esc(r.entidade_id) : ""}</p>
            ${Object.keys(r.detalhes || {}).length ? `<p class="ajuda">${esc(JSON.stringify(r.detalhes))}</p>` : ""}
          </article>`).join("") || '<p class="ajuda">Nenhum registro.</p>'}</div>
      </section>`;
    alvo.querySelector("#filtro-auditoria").addEventListener("input", (evento) => {
      const termo = evento.target.value.trim().toLowerCase();
      alvo.querySelectorAll("#lista-auditoria [data-acao]").forEach((el) => {
        el.hidden = termo && !el.dataset.acao.toLowerCase().includes(termo);
      });
    });
  }

  window.Privacidade = { meusDireitos, ouvidoria, adminPrivacidade };
})();
