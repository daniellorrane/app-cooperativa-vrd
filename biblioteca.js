// Biblioteca de documentos: arquivos por área ou gerais, com histórico de versões.
// As regras de acesso ficam no banco (RLS e funções). Esta tela só organiza a apresentação.
window.Biblioteca = (() => {
  const sb = () => window.sb;
  const BUCKET = "biblioteca";
  const LIMITE_BYTES = 10 * 1024 * 1024;

  const FORMATOS = {
    "application/pdf": { ext: "pdf", rotulo: "PDF" },
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document": { ext: "docx", rotulo: "Word" },
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": { ext: "xlsx", rotulo: "Planilha" },
    "image/png": { ext: "png", rotulo: "Imagem" },
    "image/jpeg": { ext: "jpg", rotulo: "Imagem" },
    "image/webp": { ext: "webp", rotulo: "Imagem" },
  };
  const ACEITOS = Object.keys(FORMATOS).join(",");

  function esc(texto) {
    const d = document.createElement("div");
    d.textContent = texto ?? "";
    return d.innerHTML;
  }

  function dataCurta(valor) {
    return new Date(valor).toLocaleDateString("pt-BR");
  }

  function tamanhoLegivel(bytes) {
    if (bytes < 1024) return bytes + " B";
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(0) + " KB";
    return (bytes / (1024 * 1024)).toFixed(1).replace(".", ",") + " MB";
  }

  const ehAdmin = (perfil) => perfil.tipo_acesso === "administrador";
  const ehStaff = (perfil) => ehAdmin(perfil) || perfil.tipo_acesso === "funcionario";

  // Áreas em que a pessoa pode publicar: todas para administradores, as vinculadas para funcionários.
  async function areasDePublicacao(perfil) {
    if (ehAdmin(perfil)) {
      const { data } = await sb().from("areas").select("id, nome").order("nome");
      return data || [];
    }
    const { data } = await sb().from("funcionarios_areas").select("areas(id, nome)").eq("usuario_id", perfil.id);
    return (data || []).map((v) => v.areas).filter(Boolean).sort((a, b) => a.nome.localeCompare(b.nome));
  }

  // Envia o arquivo ao bucket e registra a versão. Retorna a versão criada ou lança erro.
  async function enviarVersao(documentoId, arquivo, observacao) {
    const formato = FORMATOS[arquivo.type];
    if (!formato) throw new Error("Formato não aceito. Use PDF, Word, planilha ou imagem.");
    if (arquivo.size <= 0 || arquivo.size > LIMITE_BYTES) throw new Error("O arquivo deve ter até 10 MB.");

    const caminho = `${documentoId}/${crypto.randomUUID()}.${formato.ext}`;
    const { error: erroEnvio } = await sb().storage.from(BUCKET).upload(caminho, arquivo, {
      contentType: arquivo.type,
      upsert: false,
    });
    if (erroEnvio) throw new Error("Não foi possível enviar o arquivo: " + erroEnvio.message);

    const { data: versao, error } = await sb().rpc("publicar_versao", {
      p_documento: documentoId,
      p_caminho: caminho,
      p_nome: arquivo.name.slice(0, 200),
      p_mime: arquivo.type,
      p_tamanho: arquivo.size,
      p_observacao: observacao || null,
    });
    if (error) throw new Error("O arquivo foi enviado, mas não foi registrado: " + error.message);
    return versao;
  }

  // ---------- Lista ----------

  async function lista(alvo, perfil) {
    alvo.innerHTML = '<p class="ajuda">Carregando...</p>';
    const { data: documentos, error } = await sb()
      .from("documentos")
      .select("id, titulo, descricao, arquivado, atualizado_em, areas(nome)")
      .order("atualizado_em", { ascending: false })
      .limit(200);

    if (error) {
      alvo.innerHTML = `<p class="erro">Não foi possível carregar a biblioteca: ${esc(error.message)}</p>`;
      return;
    }

    alvo.innerHTML = `
      <div class="cabecalho-pagina">
        <h1>Biblioteca</h1>
        ${ehStaff(perfil) ? '<button type="button" id="novo-documento" class="btn-primario">Novo documento</button>' : ""}
      </div>
      <p class="ajuda">Formulários, normas e comunicados da cooperativa. Cada atualização fica guardada no histórico.</p>
      ${(documentos || []).length ? `
        <div class="lista">
          ${documentos.map((d) => `
            <a class="item evento" href="#biblioteca/${esc(d.id)}">
              <span class="evento-texto">
                <strong>${esc(d.titulo)}</strong>
                <span class="ajuda">${esc(d.areas?.nome || "Geral")} · atualizado em ${esc(dataCurta(d.atualizado_em))}</span>
                ${d.arquivado ? '<span class="marcas"><span class="marca">Arquivado</span></span>' : ""}
              </span>
            </a>`).join("")}
        </div>`
        : '<p class="ajuda">Ainda não há documentos na biblioteca.</p>'}`;

    alvo.querySelector("#novo-documento")?.addEventListener("click", () => {
      location.hash = "#biblioteca/novo";
    });
  }

  // ---------- Novo documento ----------

  async function formulario(alvo, perfil) {
    const areas = await areasDePublicacao(perfil);
    const admin = ehAdmin(perfil);

    if (!admin && !areas.length) {
      alvo.innerHTML = `
        <p class="rodape-form"><a href="#biblioteca">← Voltar para a biblioteca</a></p>
        <h1>Novo documento</h1>
        <p class="ajuda">Você ainda não está vinculado a nenhuma área. Peça à administração para vincular você.</p>`;
      return;
    }

    alvo.innerHTML = `
      <p class="rodape-form"><a href="#biblioteca">← Voltar para a biblioteca</a></p>
      <h1>Novo documento</h1>
      <form id="form-documento" class="formulario" novalidate>
        <label>Título
          <input type="text" name="titulo" required minlength="3" maxlength="120" />
        </label>
        <label>Para quem
          <select name="area">
            ${admin ? '<option value="">Geral (todos os cooperados)</option>' : ""}
            ${areas.map((a) => `<option value="${esc(a.id)}">${esc(a.nome)}</option>`).join("")}
          </select>
        </label>
        <label>Descrição <small>(opcional)</small>
          <textarea name="descricao" rows="3" maxlength="1000"></textarea>
        </label>
        <label>Arquivo <small>(até 10 MB: PDF, Word, planilha ou imagem)</small>
          <input type="file" name="arquivo" required accept="${ACEITOS}" />
        </label>
        <label>Observação da versão <small>(opcional)</small>
          <input type="text" name="observacao" maxlength="300" />
        </label>
        <p class="erro" role="alert" hidden></p>
        <button type="submit" class="btn-primario">Publicar documento</button>
      </form>`;

    const form = document.getElementById("form-documento");
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
      const arquivo = f.get("arquivo");

      if (titulo.length < 3) return mostraErro("O título precisa ter pelo menos 3 caracteres.");
      if (!(arquivo instanceof File) || !arquivo.size) return mostraErro("Escolha um arquivo.");
      if (!FORMATOS[arquivo.type]) return mostraErro("Formato não aceito. Use PDF, Word, planilha ou imagem.");
      if (arquivo.size > LIMITE_BYTES) return mostraErro("O arquivo deve ter até 10 MB.");

      const botao = form.querySelector("button[type=submit]");
      botao.disabled = true;
      botao.textContent = "Enviando...";

      const { data: documentoId, error } = await sb().rpc("criar_documento", {
        p_titulo: titulo,
        p_descricao: String(f.get("descricao") || "").trim() || null,
        p_area: f.get("area") || null,
      });
      if (error) {
        botao.disabled = false;
        botao.textContent = "Publicar documento";
        return mostraErro(error.message);
      }

      try {
        await enviarVersao(documentoId, arquivo, String(f.get("observacao") || "").trim());
        location.hash = "#biblioteca/" + documentoId;
      } catch (falha) {
        // O documento já foi criado. Abre a página dele para reenviar o arquivo.
        alert(falha.message + "\n\nO documento foi criado. Envie o arquivo pela própria página dele.");
        location.hash = "#biblioteca/" + documentoId;
      }
    });
  }

  // ---------- Detalhe e histórico de versões ----------

  async function detalhe(alvo, perfil, id) {
    alvo.innerHTML = '<p class="ajuda">Carregando...</p>';
    const [{ data: doc, error }, { data: versoes }, { data: meusVinculos }] = await Promise.all([
      sb().from("documentos").select("*, areas(nome)").eq("id", id).maybeSingle(),
      sb().from("documento_versoes").select("id, versao, nome_arquivo, tipo_mime, tamanho, observacao, caminho, publicado_em").eq("documento_id", id).order("versao", { ascending: false }),
      sb().from("funcionarios_areas").select("area_id").eq("usuario_id", perfil.id),
    ]);

    if (error || !doc) {
      alvo.innerHTML = `
        <p class="rodape-form"><a href="#biblioteca">← Voltar para a biblioteca</a></p>
        <p class="ajuda">Documento não encontrado.</p>`;
      return;
    }

    const podePublicar = ehAdmin(perfil) || (doc.area_id && (meusVinculos || []).some((v) => v.area_id === doc.area_id));
    const atual = (versoes || [])[0];

    alvo.innerHTML = `
      <p class="rodape-form"><a href="#biblioteca">← Voltar para a biblioteca</a></p>
      <h1>${esc(doc.titulo)}</h1>
      <section class="cartao">
        <p><strong>Para:</strong> ${esc(doc.areas?.nome || "Todos os cooperados")}</p>
        <p><strong>Versão atual:</strong> ${atual ? `${atual.versao} · publicada em ${esc(dataCurta(atual.publicado_em))}` : "sem arquivo ainda"}</p>
        ${doc.arquivado ? '<p class="marcas"><span class="marca">Arquivado</span></p>' : ""}
        ${doc.descricao ? `<p class="texto-puro">${esc(doc.descricao)}</p>` : ""}
      </section>

      <section class="cartao">
        <h2>Arquivos</h2>
        ${(versoes || []).length ? `<ul class="lista-respostas">
          ${versoes.map((v) => `
            <li>
              <span>
                <strong>Versão ${v.versao}</strong> · ${esc(FORMATOS[v.tipo_mime]?.rotulo || "Arquivo")} · ${esc(tamanhoLegivel(v.tamanho))}
                <br><span class="ajuda">${esc(v.nome_arquivo)} · ${esc(dataCurta(v.publicado_em))}${v.observacao ? " · " + esc(v.observacao) : ""}</span>
              </span>
              <button type="button" class="btn-ghost" data-baixar="${esc(v.caminho)}" data-nome="${esc(v.nome_arquivo)}">Baixar</button>
            </li>`).join("")}
        </ul>` : '<p class="ajuda">Nenhum arquivo publicado ainda.</p>'}
        <p class="erro" role="alert" hidden></p>
      </section>

      ${podePublicar ? `
      <section class="cartao">
        <h2>Enviar nova versão</h2>
        <form id="form-versao" class="formulario" novalidate>
          <label>Arquivo <small>(até 10 MB)</small>
            <input type="file" name="arquivo" required accept="${ACEITOS}" />
          </label>
          <label>Observação da versão <small>(opcional)</small>
            <input type="text" name="observacao" maxlength="300" />
          </label>
          <button type="submit" class="btn-primario">Publicar versão</button>
        </form>
        <div class="acoes-evento">
          <button type="button" id="alternar-arquivo" class="btn-ghost">${doc.arquivado ? "Reativar documento" : "Arquivar documento"}</button>
        </div>
      </section>` : ""}`;

    const erro = alvo.querySelector(".erro");
    const mostraErro = (mensagem) => {
      erro.textContent = mensagem;
      erro.hidden = false;
    };

    alvo.querySelectorAll("[data-baixar]").forEach((botao) => {
      botao.addEventListener("click", async () => {
        const { data: link, error: falha } = await sb().storage.from(BUCKET).createSignedUrl(botao.dataset.baixar, 300, {
          download: botao.dataset.nome,
        });
        if (falha || !link) return mostraErro("Não foi possível abrir o arquivo: " + (falha?.message || "tente novamente."));
        window.open(link.signedUrl, "_blank", "noopener");
      });
    });

    if (podePublicar) {
      alvo.querySelector("#form-versao").addEventListener("submit", async (ev) => {
        ev.preventDefault();
        erro.hidden = true;
        const form = ev.currentTarget;
        const f = new FormData(form);
        const arquivo = f.get("arquivo");
        if (!(arquivo instanceof File) || !arquivo.size) return mostraErro("Escolha um arquivo.");
        if (!FORMATOS[arquivo.type]) return mostraErro("Formato não aceito. Use PDF, Word, planilha ou imagem.");
        if (arquivo.size > LIMITE_BYTES) return mostraErro("O arquivo deve ter até 10 MB.");

        const botao = form.querySelector("button[type=submit]");
        botao.disabled = true;
        botao.textContent = "Enviando...";
        try {
          await enviarVersao(id, arquivo, String(f.get("observacao") || "").trim());
          detalhe(alvo, perfil, id);
        } catch (falha) {
          botao.disabled = false;
          botao.textContent = "Publicar versão";
          mostraErro(falha.message);
        }
      });

      alvo.querySelector("#alternar-arquivo").addEventListener("click", async () => {
        const arquivar = !doc.arquivado;
        const pergunta = arquivar
          ? "Arquivar este documento? Ele deixa de aparecer para os cooperados, mas o histórico é mantido."
          : "Reativar este documento para os cooperados?";
        if (!confirm(pergunta)) return;
        const { error: falha } = await sb().rpc("arquivar_documento", { p_documento: id, p_arquivar: arquivar });
        if (falha) return mostraErro(falha.message);
        detalhe(alvo, perfil, id);
      });
    }
  }

  // id: undefined = lista; "novo" = formulário; outro = detalhe do documento.
  function tela(alvo, perfil, id) {
    if (id === "novo") return ehStaff(perfil) ? formulario(alvo, perfil) : lista(alvo, perfil);
    if (id) return detalhe(alvo, perfil, id);
    return lista(alvo, perfil);
  }

  return { tela };
})();
