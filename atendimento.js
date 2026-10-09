// Tela de um atendimento: mensagens, anexos (até 2 MB), responsável, prazo, respostas rápidas e avaliação.
// Também a tela de respostas rápidas da equipe. As regras de acesso ficam no banco (RLS e funções).
(() => {
  const sb = () => window.sb;
  let canal = null;

  const STATUS = { aberta: "Aberta", em_andamento: "Em andamento", concluida: "Concluída", cancelada: "Cancelada" };
  const TIPOS = { conversa: "Atendimento", documento: "Solicitação de documento", servico: "Solicitação de serviço" };
  const LIMITE_ANEXO = 2 * 1024 * 1024;
  const EXTENSAO = { "application/pdf": "pdf", "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" };
  const ABERTO = ["aberta", "em_andamento"];

  const esc = (texto) => {
    const d = document.createElement("div");
    d.textContent = texto ?? "";
    return d.innerHTML;
  };
  const dataCurta = (v) => (v ? new Date(v).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" }) : "");
  const tamanhoLegivel = (bytes) => (bytes >= 1024 * 1024 ? (bytes / 1024 / 1024).toFixed(1) + " MB" : Math.ceil(bytes / 1024) + " KB");
  const aviso = (el, texto, tipo = "erro") => {
    el.textContent = texto;
    el.hidden = !texto;
    el.className = "form-mensagem " + tipo;
  };

  function sair() {
    if (canal) {
      sb().removeChannel(canal);
      canal = null;
    }
  }

  async function baixarAnexo(caminho) {
    const { data, error } = await sb().storage.from("anexos").createSignedUrl(caminho, 300);
    if (error || !data) return alert("Não foi possível abrir o arquivo agora.");
    window.open(data.signedUrl, "_blank", "noopener");
  }

  // ---------- Atendimento ----------

  async function abrir(alvo, perfil, id) {
    sair();
    alvo.innerHTML = '<p class="ajuda">Carregando...</p>';

    const { data: c, error } = await sb()
      .from("conversas")
      .select("id, assunto, tipo, status, solicitante_id, area_id, responsavel_id, prazo_em, avaliacao, avaliacao_comentario, areas(nome)")
      .eq("id", id)
      .single();
    if (error) return (alvo.innerHTML = `<p class="erro">${esc(error.message)}</p>`);

    const souSolicitante = c.solicitante_id === perfil.id;
    const equipe = !souSolicitante && (perfil.tipo_acesso === "administrador" || perfil.tipo_acesso === "funcionario");
    const nomeArea = c.areas?.nome || "Atendimento";
    const atrasado = ABERTO.includes(c.status) && c.prazo_em && new Date(c.prazo_em) < new Date();

    const [{ data: equipeArea }, { data: rapidas }] = equipe
      ? await Promise.all([
          sb().rpc("equipe_da_area", { p_area: c.area_id }),
          sb().from("respostas_rapidas").select("id, titulo, texto").eq("area_id", c.area_id).order("titulo"),
        ])
      : [{ data: [] }, { data: [] }];
    const responsavel = (equipeArea || []).find((p) => p.usuario_id === c.responsavel_id);

    alvo.innerHTML = `
      <section class="cartao">
        <a href="#conversas" class="btn-ghost">Voltar aos atendimentos</a>
        <h1 class="titulo-conversa">${esc(c.assunto)}</h1>
        <p class="ajuda">${esc(TIPOS[c.tipo])} · ${esc(nomeArea)} · prazo até ${dataCurta(c.prazo_em)}${atrasado ? ' · <span class="erro">prazo vencido</span>' : ""}</p>
        ${equipe ? `
          <div class="formulario">
            <label>Responsável
              <select id="responsavel">
                <option value="">Sem responsável (pendente)</option>
                ${(equipeArea || []).map((p) => `<option value="${p.usuario_id}" ${p.usuario_id === c.responsavel_id ? "selected" : ""}>${esc(p.nome)}</option>`).join("")}
              </select>
            </label>
            <label>Status
              <select id="status" class="seletor-status">
                ${Object.entries(STATUS).map(([v, r]) => `<option value="${v}" ${v === c.status ? "selected" : ""}>${r}</option>`).join("")}
              </select>
            </label>
            <p class="form-mensagem" id="aviso-equipe" role="status" hidden></p>
          </div>` : `
          <p class="ajuda">${responsavel ? "Responsável: " + esc(responsavel.nome) : "Aguardando um responsável da área."}</p>`}
        <div id="chat" class="chat" aria-live="polite"></div>
        <form id="form-mensagem" class="form-mensagem" novalidate>
          ${equipe && (rapidas || []).length ? `
            <label>Resposta rápida
              <select id="resposta-rapida">
                <option value="">Escolha um modelo</option>
                ${rapidas.map((r) => `<option value="${r.id}">${esc(r.titulo)}</option>`).join("")}
              </select>
            </label>` : ""}
          <textarea name="texto" rows="2" maxlength="4000" required placeholder="Escreva uma mensagem"></textarea>
          <label class="anexo-campo">Anexar arquivo (até 2 MB: PDF, JPG, PNG ou WEBP)
            <input type="file" name="anexo" accept="application/pdf,image/jpeg,image/png,image/webp" />
          </label>
          <button type="submit" class="btn-primario">Enviar</button>
        </form>
        <p class="erro" role="alert" hidden></p>
        ${souSolicitante && c.status === "concluida" ? blocoAvaliacao(c) : ""}
      </section>`;

    const chat = alvo.querySelector("#chat");
    const exibidas = new Set();
    const nomeAutor = (msg) => {
      if (msg.autor_id === null) return "Usuário removido";
      if (msg.autor_id === perfil.id) return "Você";
      if (msg.autor_id === c.solicitante_id) return "Cooperado";
      const pessoa = (equipeArea || []).find((p) => p.usuario_id === msg.autor_id);
      return pessoa ? pessoa.nome : "Equipe " + nomeArea;
    };

    function adicionar(msg) {
      if (exibidas.has(msg.id)) return;
      exibidas.add(msg.id);
      const eu = msg.autor_id === perfil.id;
      const item = document.createElement("div");
      item.className = "msg " + (eu ? "eu" : "outro");
      item.dataset.mensagem = msg.id;
      item.innerHTML = `<small>${esc(nomeAutor(msg))} · ${dataCurta(msg.criado_em)}</small>${esc(msg.texto).replace(/\n/g, "<br>")}<div class="anexos"></div>`;
      chat.appendChild(item);
      chat.scrollTop = chat.scrollHeight;
    }

    function adicionarAnexo(anexo) {
      const bloco = chat.querySelector(`[data-mensagem="${anexo.mensagem_id}"] .anexos`);
      if (!bloco || bloco.querySelector(`[data-caminho="${CSS.escape(anexo.caminho)}"]`)) return;
      const botao = document.createElement("button");
      botao.type = "button";
      botao.className = "btn-ghost anexo";
      botao.dataset.caminho = anexo.caminho;
      botao.textContent = `${anexo.nome_arquivo} (${tamanhoLegivel(anexo.tamanho)})`;
      botao.addEventListener("click", () => baixarAnexo(anexo.caminho));
      bloco.appendChild(botao);
    }

    const [{ data: mensagens }, { data: anexos }] = await Promise.all([
      sb().from("mensagens").select("id, texto, autor_id, criado_em").eq("conversa_id", id).order("criado_em", { ascending: true }),
      sb().from("anexos").select("mensagem_id, nome_arquivo, caminho, tamanho").eq("conversa_id", id),
    ]);
    (mensagens || []).forEach(adicionar);
    (anexos || []).forEach(adicionarAnexo);

    canal = sb()
      .channel("msg-" + id)
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "mensagens", filter: "conversa_id=eq." + id },
        (payload) => adicionar(payload.new))
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "anexos", filter: "conversa_id=eq." + id },
        (payload) => adicionarAnexo(payload.new))
      .subscribe();

    // Equipe: responsável e status
    const selectResponsavel = alvo.querySelector("#responsavel");
    if (selectResponsavel) {
      selectResponsavel.addEventListener("change", async () => {
        const avisoEl = alvo.querySelector("#aviso-equipe");
        const { error: erroAtr } = await sb().rpc("atribuir_atendimento", {
          p_conversa: id,
          p_responsavel: selectResponsavel.value || null,
        });
        aviso(avisoEl, erroAtr ? "Não foi possível atribuir: " + erroAtr.message : "Responsável atualizado.", erroAtr ? "erro" : "sucesso");
      });
    }
    const selectStatus = alvo.querySelector("#status");
    if (selectStatus) {
      selectStatus.addEventListener("change", async () => {
        const avisoEl = alvo.querySelector("#aviso-equipe");
        const { error: erroStatus } = await sb().from("conversas").update({ status: selectStatus.value }).eq("id", id);
        aviso(avisoEl, erroStatus ? "Não foi possível alterar o status: " + erroStatus.message : "Status atualizado.", erroStatus ? "erro" : "sucesso");
      });
    }

    // Respostas rápidas
    const selectRapida = alvo.querySelector("#resposta-rapida");
    if (selectRapida) {
      selectRapida.addEventListener("change", () => {
        const escolhida = (rapidas || []).find((r) => r.id === selectRapida.value);
        if (escolhida) alvo.querySelector('[name="texto"]').value = escolhida.texto;
        selectRapida.value = "";
      });
    }

    // Envio de mensagem, com anexo opcional
    const form = alvo.querySelector("#form-mensagem");
    const erro = alvo.querySelector('p.erro[role="alert"]');
    form.addEventListener("submit", async (evento) => {
      evento.preventDefault();
      erro.hidden = true;
      const arquivo = form.anexo.files[0] || null;
      let texto = form.texto.value.trim();

      if (arquivo) {
        if (arquivo.size > LIMITE_ANEXO) return mostrarErro(erro, "O arquivo passa de 2 MB. Envie um arquivo menor.");
        if (!EXTENSAO[arquivo.type]) return mostrarErro(erro, "Envie um arquivo PDF, JPG, PNG ou WEBP.");
        if (!texto) texto = "Anexo: " + arquivo.name;
      }
      if (!texto) return;

      const botao = form.querySelector("button");
      botao.disabled = true;
      const { data: nova, error: erroEnvio } = await sb()
        .from("mensagens")
        .insert({ conversa_id: id, autor_id: perfil.id, texto })
        .select("id, texto, autor_id, criado_em")
        .single();
      if (erroEnvio) {
        botao.disabled = false;
        return mostrarErro(erro, "Não foi possível enviar: " + erroEnvio.message);
      }

      if (arquivo) {
        // Pasta do arquivo = id do atendimento (regra de acesso do bucket).
        const caminho = `${id}/${crypto.randomUUID()}.${EXTENSAO[arquivo.type]}`;
        const { error: erroUpload } = await sb().storage.from("anexos").upload(caminho, arquivo, {
          contentType: arquivo.type,
          upsert: false,
        });
        if (erroUpload) {
          botao.disabled = false;
          mostrarErro(erro, "A mensagem foi enviada, mas o anexo não: " + erroUpload.message);
        } else {
          const { error: erroRegistro } = await sb().from("anexos").insert({
            mensagem_id: nova.id,
            conversa_id: id,
            nome_arquivo: arquivo.name.slice(0, 200) || "arquivo",
            tipo_mime: arquivo.type,
            tamanho: arquivo.size,
            caminho,
            enviado_por: perfil.id,
          });
          if (erroRegistro) mostrarErro(erro, "A mensagem foi enviada, mas o anexo não foi registrado: " + erroRegistro.message);
        }
      }

      form.texto.value = "";
      form.anexo.value = "";
      botao.disabled = false;
      adicionar(nova);
      const { data: novosAnexos } = await sb()
        .from("anexos").select("mensagem_id, nome_arquivo, caminho, tamanho").eq("mensagem_id", nova.id);
      (novosAnexos || []).forEach(adicionarAnexo);
    });

    // Avaliação
    const formAvaliar = alvo.querySelector("#form-avaliar");
    if (formAvaliar) {
      formAvaliar.addEventListener("submit", async (evento) => {
        evento.preventDefault();
        const msg = formAvaliar.querySelector(".form-mensagem");
        const nota = formAvaliar.querySelector('input[name="nota"]:checked');
        if (!nota) return aviso(msg, "Escolha uma nota de 0 a 5.");
        const { error: erroAval } = await sb().rpc("avaliar_atendimento", {
          p_conversa: id,
          p_nota: Number(nota.value),
          p_comentario: formAvaliar.comentario.value.trim() || null,
        });
        if (erroAval) return aviso(msg, "Não foi possível enviar a avaliação: " + erroAval.message);
        abrir(alvo, perfil, id);
      });
    }
  }

  function mostrarErro(el, texto) {
    el.textContent = texto;
    el.hidden = false;
  }

  function blocoAvaliacao(c) {
    if (c.avaliacao !== null) {
      return `
        <section class="cartao">
          <h2>Sua avaliação</h2>
          <p>Você deu ${c.avaliacao} de 5 estrelas.</p>
          ${c.avaliacao_comentario ? `<p class="ajuda">${esc(c.avaliacao_comentario)}</p>` : ""}
        </section>`;
    }
    return `
      <section class="cartao">
        <h2>Avalie este atendimento</h2>
        <form id="form-avaliar" class="formulario">
          <fieldset class="estrelas">
            <legend>Nota (0 a 5)</legend>
            ${[0, 1, 2, 3, 4, 5].map((n) => `
              <label class="opcao"><input type="radio" name="nota" value="${n}" /><span>${n}</span></label>`).join("")}
          </fieldset>
          <label>Comentário (opcional, até 280 caracteres)
            <textarea name="comentario" rows="2" maxlength="280"></textarea>
          </label>
          <button type="submit" class="btn-primario">Enviar avaliação</button>
          <p class="form-mensagem" role="status" hidden></p>
        </form>
      </section>`;
  }

  // ---------- Respostas rápidas (equipe) ----------

  async function respostasRapidas(alvo, perfil) {
    alvo.innerHTML = '<p class="ajuda">Carregando...</p>';
    const { data: vinculos } = await sb().from("funcionarios_areas").select("area_id, areas(nome)");
    let areas = (vinculos || []).map((v) => ({ id: v.area_id, nome: v.areas?.nome || "Área" }));
    if (perfil.tipo_acesso === "administrador") {
      const { data: todas } = await sb().from("areas").select("id, nome").order("nome");
      areas = todas || [];
    }
    if (!areas.length) {
      alvo.innerHTML = '<h1>Respostas rápidas</h1><p class="ajuda">Você ainda não atua em nenhuma área.</p>';
      return;
    }

    alvo.innerHTML = `
      <h1>Respostas rápidas</h1>
      <p class="ajuda">Modelos de resposta para padronizar o atendimento da área. Quem atua na área pode criar, editar e remover.</p>
      <label>Área
        <select id="area-rapidas">${areas.map((a) => `<option value="${a.id}">${esc(a.nome)}</option>`).join("")}</select>
      </label>
      <div id="lista-rapidas"></div>
      <section class="cartao largo">
        <h2 id="titulo-form-rapida">Nova resposta</h2>
        <form id="form-rapida" class="formulario">
          <input type="hidden" name="id" />
          <label>Título
            <input name="titulo" required minlength="3" maxlength="80" />
          </label>
          <label>Texto
            <textarea name="texto" rows="4" required minlength="3" maxlength="1000"></textarea>
          </label>
          <button type="submit" class="btn-primario">Salvar</button>
          <button type="button" class="btn-ghost" id="cancelar-rapida" hidden>Cancelar edição</button>
          <p class="form-mensagem" role="status" hidden></p>
        </form>
      </section>`;

    const areaSelect = alvo.querySelector("#area-rapidas");
    const lista = alvo.querySelector("#lista-rapidas");
    const form = alvo.querySelector("#form-rapida");
    const msg = form.querySelector(".form-mensagem");

    const carregar = async () => {
      const { data, error } = await sb().from("respostas_rapidas")
        .select("id, titulo, texto").eq("area_id", areaSelect.value).order("titulo");
      if (error) return (lista.innerHTML = `<p class="erro">${esc(error.message)}</p>`);
      lista.innerHTML = (data || []).length ? `<div class="lista">${data.map((r) => `
        <article class="item" data-id="${r.id}">
          <strong>${esc(r.titulo)}</strong>
          <p>${esc(r.texto)}</p>
          <button type="button" class="btn-ghost" data-editar>Editar</button>
          <button type="button" class="btn-perigo" data-remover>Remover</button>
        </article>`).join("")}</div>` : '<p class="ajuda">Nenhuma resposta rápida nesta área.</p>';

      lista.querySelectorAll("[data-editar]").forEach((b) => b.addEventListener("click", () => {
        const item = data.find((r) => r.id === b.closest("[data-id]").dataset.id);
        form.id.value = item.id;
        form.titulo.value = item.titulo;
        form.texto.value = item.texto;
        alvo.querySelector("#titulo-form-rapida").textContent = "Editar resposta";
        alvo.querySelector("#cancelar-rapida").hidden = false;
      }));
      lista.querySelectorAll("[data-remover]").forEach((b) => b.addEventListener("click", async () => {
        if (!confirm("Remover esta resposta rápida?")) return;
        const { error: erroDel } = await sb().from("respostas_rapidas").delete().eq("id", b.closest("[data-id]").dataset.id);
        if (erroDel) return alert("Não foi possível remover: " + erroDel.message);
        carregar();
      }));
    };

    const limpar = () => {
      form.reset();
      form.id.value = "";
      alvo.querySelector("#titulo-form-rapida").textContent = "Nova resposta";
      alvo.querySelector("#cancelar-rapida").hidden = true;
    };
    alvo.querySelector("#cancelar-rapida").addEventListener("click", limpar);
    areaSelect.addEventListener("change", () => { limpar(); carregar(); });

    form.addEventListener("submit", async (evento) => {
      evento.preventDefault();
      const dados = { titulo: form.titulo.value.trim(), texto: form.texto.value.trim() };
      const operacao = form.id.value
        ? sb().from("respostas_rapidas").update(dados).eq("id", form.id.value)
        : sb().from("respostas_rapidas").insert({ ...dados, area_id: areaSelect.value, criado_por: perfil.id });
      const { error } = await operacao;
      if (error) return aviso(msg, "Não foi possível salvar: " + error.message);
      aviso(msg, "Salvo.", "sucesso");
      limpar();
      carregar();
    });

    carregar();
  }

  window.Atendimento = { abrir, sair, respostasRapidas };
})();
