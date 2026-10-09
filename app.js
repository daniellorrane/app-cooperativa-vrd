(() => {
  const { createClient } = supabase;
  // Guarda se o endereço veio de um link de recuperação antes do Supabase limpá-lo.
  let modoRecuperacao = location.hash.includes("type=recovery");
  // Link inválido ou expirado: o Supabase devolve o erro no endereço.
  const codigoErroLink = new URLSearchParams(location.hash.slice(1)).get("error_code");
  const sb = createClient(window.APP_CONFIG.SUPABASE_URL, window.APP_CONFIG.SUPABASE_KEY);
  window.sb = sb; // usado pelo módulo de comunicação interna

  const app = document.getElementById("app");
  const btnSair = document.getElementById("btn-sair");
  const carregando = document.getElementById("carregando");

  const TIPOS_FALLBACK = [
    { codigo: "cooperado", descricao: "Cooperado" },
    { codigo: "cliente", descricao: "Cliente" },
    { codigo: "funcionario", descricao: "Funcionário" },
    { codigo: "fornecedor", descricao: "Fornecedor" },
    { codigo: "prestador_servico", descricao: "Prestador de serviço" },
  ];

  // ---------- Utilitários ----------

  function somenteDigitos(valor) {
    return (valor || "").replace(/\D/g, "");
  }

  function cpfValido(cpfBruto) {
    const cpf = somenteDigitos(cpfBruto);
    if (cpf.length !== 11 || /^(\d)\1{10}$/.test(cpf)) return false;
    const calc = (base, pesoInicial) => {
      let soma = 0;
      for (let i = 0; i < base; i++) soma += Number(cpf[i]) * (pesoInicial - i);
      const resto = (soma * 10) % 11;
      return resto === 10 ? 0 : resto;
    };
    return calc(9, 10) === Number(cpf[9]) && calc(10, 11) === Number(cpf[10]);
  }

  // Formato de exibição: +55(33)999058391
  function formatarTelefone(valor) {
    let d = somenteDigitos(valor);
    if (d.startsWith("55")) d = d.slice(2);
    d = d.slice(0, 11);
    if (d.length === 0) return "";
    let out = "+55(" + d.slice(0, 2);
    if (d.length >= 2) out += ")";
    out += d.slice(2);
    return out;
  }

  // Valor armazenado: +5533999058391
  function telefoneParaBanco(valor) {
    const d = somenteDigitos(valor).replace(/^55/, "");
    return "+55" + d;
  }

  function telefoneValido(valor) {
    return /^\+55\d{10,11}$/.test(telefoneParaBanco(valor));
  }

  function formatarCpf(valor) {
    const d = somenteDigitos(valor).slice(0, 11);
    return d
      .replace(/^(\d{3})(\d)/, "$1.$2")
      .replace(/^(\d{3})\.(\d{3})(\d)/, "$1.$2.$3")
      .replace(/\.(\d{3})(\d)/, ".$1-$2");
  }

  function mostrarErro(form, mensagem) {
    const p = form.querySelector(".erro");
    p.textContent = mensagem;
    p.hidden = !mensagem;
  }

  function renderizar(id, destino = app) {
    const tpl = document.getElementById(id);
    destino.replaceChildren(tpl.content.cloneNode(true));
    carregando.remove?.();
  }

  function mostrarBotaoSair(visivel) {
    btnSair.hidden = !visivel;
  }

  // ---------- Dados ----------

  async function buscarPerfil() {
    const { data: { user } } = await sb.auth.getUser();
    if (!user) return null;
    const { data, error } = await sb
      .from("usuarios")
      .select("*")
      .eq("id", user.id)
      .maybeSingle();
    if (error) throw error;
    return data;
  }

  async function carregarTipos() {
    const { data, error } = await sb.from("tipos_acesso").select("codigo, descricao").order("descricao");
    if (error || !data?.length) return TIPOS_FALLBACK;
    return data;
  }

  // Documentos versionados (termos e privacidade) são definidos no módulo interno.
  const { DOCS, carregarVigente } = window.Interno;

  // ---------- Telas ----------

  function telaLogin() {
    mostrarBotaoSair(false);
    renderizar("tpl-login");
    const form = document.getElementById("form-login");
    if (codigoErroLink) {
      const mensagem = codigoErroLink === "otp_expired"
        ? "Este link expirou ou já foi usado. Clique em \"Esqueci minha senha\" para receber um novo link e abra-o logo em seguida."
        : "Não foi possível validar este link. Peça um novo link de recuperação.";
      mostrarErro(form, mensagem);
      history.replaceState(null, "", location.pathname);
    }
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      mostrarErro(form, "");
      const email = form.email.value.trim();
      const senha = form.senha.value;
      if (!email || !senha) return mostrarErro(form, "Preencha e-mail e senha.");

      const btn = form.querySelector("button");
      btn.disabled = true;
      const { error } = await sb.auth.signInWithPassword({ email, password: senha });
      btn.disabled = false;
      if (error) return mostrarErro(form, "E-mail ou senha incorretos.");
      rotear();
    });
    document.getElementById("ir-cadastro").addEventListener("click", (e) => {
      e.preventDefault();
      location.hash = "cadastro";
    });
    document.getElementById("ir-esqueci").addEventListener("click", (e) => {
      e.preventDefault();
      location.hash = "esqueci";
    });
  }

  function telaEsqueci() {
    mostrarBotaoSair(false);
    renderizar("tpl-esqueci");
    const form = document.getElementById("form-esqueci");
    const sucesso = form.querySelector(".sucesso");
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      mostrarErro(form, "");
      sucesso.hidden = true;
      const email = form.email.value.trim().toLowerCase();
      if (!email) return mostrarErro(form, "Informe o e-mail do cadastro.");

      const btn = form.querySelector("button");
      btn.disabled = true;
      const { error } = await sb.auth.resetPasswordForEmail(email, {
        redirectTo: location.origin + location.pathname,
      });
      btn.disabled = false;
      if (error) return mostrarErro(form, traduzirErro(error));
      // Mensagem genérica: não revela se o e-mail existe no sistema.
      sucesso.textContent = "Se este e-mail estiver cadastrado, você receberá o link em instantes.";
      sucesso.hidden = false;
    });
  }

  function telaRedefinir() {
    mostrarBotaoSair(false);
    renderizar("tpl-redefinir");
    const form = document.getElementById("form-redefinir");
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      mostrarErro(form, "");
      const senha = form.senha.value;
      if (senha.length < 8) return mostrarErro(form, "A senha precisa ter pelo menos 8 caracteres.");
      if (senha !== form.confirmacao.value) return mostrarErro(form, "As senhas não conferem.");

      const btn = form.querySelector("button");
      btn.disabled = true;
      const { error } = await sb.auth.updateUser({ password: senha });
      btn.disabled = false;
      if (error) return mostrarErro(form, traduzirErro(error));
      modoRecuperacao = false;
      await sb.auth.signOut();
      location.hash = "";
      alert("Senha alterada com sucesso. Entre com a nova senha.");
      rotear();
    });
  }

  function telaMeusDados(perfil, destino = app) {
    mostrarBotaoSair(true);
    renderizar("tpl-meus-dados", destino);
    const form = destino.querySelector("#form-meus-dados");
    const sucesso = form.querySelector(".sucesso");
    form.nome.value = perfil.nome_completo;
    form.cpf.value = formatarCpf(perfil.cpf);
    form.email.value = perfil.email;
    form.telefone.value = formatarTelefone(perfil.telefone);

    form.telefone.addEventListener("input", () => {
      form.telefone.value = formatarTelefone(form.telefone.value);
    });

    const formSenha = document.getElementById("form-alterar-senha");
    const sucessoSenha = formSenha.querySelector(".sucesso");
    formSenha.addEventListener("submit", async (e) => {
      e.preventDefault();
      mostrarErro(formSenha, "");
      sucessoSenha.hidden = true;
      const atual = formSenha.senha_atual.value;
      const nova = formSenha.nova_senha.value;
      if (!atual) return mostrarErro(formSenha, "Informe a senha atual.");
      if (nova.length < 8) return mostrarErro(formSenha, "A nova senha precisa ter pelo menos 8 caracteres.");
      if (nova !== formSenha.confirmacao.value) return mostrarErro(formSenha, "As senhas não conferem.");

      const btn = formSenha.querySelector("button");
      btn.disabled = true;
      // Confirma a senha atual antes de trocar, para proteger a conta caso alguém use uma sessão aberta.
      const { error: erroAtual } = await sb.auth.signInWithPassword({ email: perfil.email, password: atual });
      if (erroAtual) {
        btn.disabled = false;
        return mostrarErro(formSenha, "A senha atual está incorreta.");
      }
      const { error } = await sb.auth.updateUser({ password: nova });
      btn.disabled = false;
      if (error) return mostrarErro(formSenha, traduzirErro(error));
      formSenha.reset();
      sucessoSenha.textContent = "Senha alterada com sucesso.";
      sucessoSenha.hidden = false;
    });

    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      mostrarErro(form, "");
      sucesso.hidden = true;
      const nome = form.nome.value.trim().replace(/\s+/g, " ");
      // Contas de setor não têm celular cadastrado: o campo pode continuar vazio.
      const semTelefone = !form.telefone.value.trim() && !perfil.telefone;
      const telefone = semTelefone ? null : telefoneParaBanco(form.telefone.value);

      if (nome.split(" ").length < 2) return mostrarErro(form, "Informe o nome completo.");
      if (!semTelefone && !telefoneValido(telefone)) return mostrarErro(form, "Celular inválido. Use o formato +55(33)999058391.");

      const btn = form.querySelector("button");
      btn.disabled = true;
      const { error } = await sb
        .from("usuarios")
        .update({ nome_completo: nome, telefone })
        .eq("id", perfil.id);
      btn.disabled = false;
      if (error) return mostrarErro(form, "Não foi possível salvar: " + error.message);

      sucesso.textContent = "Dados atualizados.";
      sucesso.hidden = false;
    });

    const formExcluir = document.getElementById("form-excluir-conta");
    formExcluir.addEventListener("submit", async (e) => {
      e.preventDefault();
      mostrarErro(formExcluir, "");
      const modo = formExcluir.modo.value;
      const senha = formExcluir.senha.value;
      if (formExcluir.confirmacao.value.trim() !== "EXCLUIR") {
        return mostrarErro(formExcluir, "Digite EXCLUIR no campo de confirmação.");
      }
      if (!senha) return mostrarErro(formExcluir, "Informe a sua senha atual.");

      const aviso = modo === "apagar"
        ? "Apagar sua conta e todo o histórico? Esta ação não pode ser desfeita."
        : "Excluir sua conta e manter o histórico de forma anônima? Esta ação não pode ser desfeita.";
      if (!confirm(aviso)) return;

      const btn = formExcluir.querySelector("button");
      btn.disabled = true;
      // Confirma a senha antes de excluir, para proteger a conta caso alguém use uma sessão aberta.
      const { error: erroSenha } = await sb.auth.signInWithPassword({ email: perfil.email, password: senha });
      if (erroSenha) {
        btn.disabled = false;
        return mostrarErro(formExcluir, "A senha atual está incorreta.");
      }
      const { error } = await sb.rpc("excluir_minha_conta", { p_modo: modo });
      if (error) {
        btn.disabled = false;
        return mostrarErro(formExcluir, "Não foi possível excluir a conta: " + error.message);
      }
      await sb.auth.signOut({ scope: "local" });
      location.hash = "";
      alert("Sua conta foi excluída.");
      rotear();
    });

    // Notificações push deste aparelho.
    const statusPush = destino.querySelector("#push-status");
    const botaoPush = destino.querySelector("#push-botao");
    async function atualizarPush() {
      const estado = await window.Push.estado();
      statusPush.textContent = estado.mensagem;
      botaoPush.hidden = estado.situacao === "indisponivel" || estado.situacao === "bloqueado";
      botaoPush.textContent = estado.situacao === "ativo" ? "Desativar neste aparelho" : "Ativar notificações";
      botaoPush.dataset.acao = estado.situacao === "ativo" ? "desativar" : "ativar";
    }
    botaoPush.addEventListener("click", async () => {
      botaoPush.disabled = true;
      try {
        if (botaoPush.dataset.acao === "ativar") await window.Push.ativar();
        else await window.Push.desativar();
      } catch (erro) {
        alert("Não foi possível alterar as notificações: " + erro.message);
      }
      botaoPush.disabled = false;
      atualizarPush();
    });
    atualizarPush();
  }

  // Termos e Condições: texto em blocos. Títulos numerados viram subtítulos.
  function textoDosTermos(texto, titulo = "h1") {
    return texto.split(/\n\s*\n/).map((bloco, i) => {
      const linhas = bloco.trim().split("\n").map((l) => escapar(l));
      if (i === 0) {
        return `<${titulo}>${linhas[0]}</${titulo}>` +
          (linhas.length > 1 ? `<p class="ajuda">${linhas.slice(1).join("<br>")}</p>` : "");
      }
      if (/^\d+\.\s/.test(bloco.trim())) {
        return `<h2>${linhas[0]}</h2>` + (linhas.length > 1 ? `<p>${linhas.slice(1).join("<br>")}</p>` : "");
      }
      return `<p>${linhas.join("<br>")}</p>`;
    }).join("");
  }

  // Aceite obrigatório das versões vigentes que o usuário ainda não aceitou (cadastro antigo ou nova versão publicada).
  function telaAceiteDocumentos(perfil, pendentes) {
    mostrarBotaoSair(true);
    app.innerHTML = `
      <section class="cartao largo">
        <h1>Antes de continuar</h1>
        <p class="ajuda">Leia os documentos abaixo e confirme o aceite de cada um para usar o sistema.</p>
      </section>
      ${pendentes.map(({ tipo, doc }) => `
        <section class="cartao largo texto-legal">
          ${textoDosTermos(doc.texto, "h2")}
          <label class="opcao">
            <input type="checkbox" name="${tipo}" />
            <span>Li e aceito a versão ${escapar(doc.versao)} dos ${escapar(DOCS[tipo].titulo)}</span>
          </label>
        </section>`).join("")}
      <section class="cartao largo">
        <form id="form-aceite-documentos" novalidate>
          <p class="erro" role="alert" hidden></p>
          <button type="submit" class="btn-primario">Aceitar e continuar</button>
        </form>
      </section>`;

    const form = document.getElementById("form-aceite-documentos");
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      mostrarErro(form, "");
      const faltando = pendentes.filter(({ tipo }) => !app.querySelector(`input[name="${tipo}"]`).checked);
      if (faltando.length) {
        return mostrarErro(form, "Marque o aceite de todos os documentos para continuar.");
      }

      const versaoDe = (tipo) => pendentes.find((p) => p.tipo === tipo)?.doc.versao ?? null;
      const btn = form.querySelector("button");
      btn.disabled = true;
      // O banco confere se a versão é a vigente e grava a data do aceite.
      const { error } = await sb.rpc("aceitar_documentos", {
        p_termo_versao: versaoDe("termos"),
        p_privacidade_versao: versaoDe("privacidade"),
      });
      if (error) {
        btn.disabled = false;
        return mostrarErro(form, "Não foi possível registrar o aceite: " + error.message);
      }
      rotear();
    });
  }

  // Pedido de permissão para notificações. Só sai quando o aparelho responde (permitir ou negar).
  function telaPermissoes(perfil) {
    mostrarBotaoSair(true);
    app.innerHTML = `
      <section class="cartao">
        <h1>Ative as notificações</h1>
        <p>Para acompanhar o seu cadastro e os seus atendimentos, precisamos da sua permissão para enviar notificações neste aparelho.</p>
        <p>Você receberá avisos sobre aprovação do cadastro, atualizações dos atendimentos e comunicados da cooperativa.</p>
        <p class="ajuda">Os avisos não mostram detalhes na tela de bloqueio. O conteúdo fica somente dentro do sistema.</p>
        <form id="form-permissao" novalidate>
          <p class="erro" role="alert" hidden></p>
          <button type="submit" class="btn-primario">Permitir notificações</button>
        </form>
      </section>`;

    const form = document.getElementById("form-permissao");
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      mostrarErro(form, "");
      const btn = form.querySelector("button");
      btn.disabled = true;
      try {
        await window.Push.ativar();
      } catch (erro) {
        // Permissão negada no navegador: segue para o sistema. Pode ser ativada depois em Meus dados.
        if (Notification.permission === "denied") return rotear();
        btn.disabled = false;
        return mostrarErro(form, "Não foi possível ativar as notificações: " + erro.message);
      }
      rotear();
    });
  }

  // Página pública de um documento (acessível sem login, pelos links do cadastro).
  async function telaDocumento(tipo) {
    app.innerHTML = '<section class="cartao largo"><p class="ajuda">Carregando...</p></section>';
    const doc = await carregarVigente(tipo);
    if (!doc) {
      app.innerHTML = '<section class="cartao"><p class="erro">Não foi possível carregar o documento agora. Tente novamente em instantes.</p></section>';
      return;
    }
    app.innerHTML = `
      <section class="cartao largo texto-legal">
        ${textoDosTermos(doc.texto)}
        <p class="rodape-form"><a href="#" id="voltar-documento">Voltar</a></p>
      </section>`;
    document.getElementById("voltar-documento").addEventListener("click", (e) => {
      e.preventDefault();
      location.hash = "";
      rotear();
    });
  }

  async function telaCadastro() {
    mostrarBotaoSair(false);
    renderizar("tpl-cadastro");
    const form = document.getElementById("form-cadastro");
    const lista = document.getElementById("lista-tipos");

    // Administrador é criado pela cooperativa, não escolhido no cadastro público.
    const tipos = (await carregarTipos()).filter((t) => t.codigo !== "administrador");
    lista.innerHTML = tipos.map((t) => `
      <label class="opcao">
        <input type="radio" name="tipo" value="${t.codigo}" />
        <span>${escapar(t.descricao)}</span>
      </label>`).join("");

    form.telefone.addEventListener("input", () => {
      form.telefone.value = formatarTelefone(form.telefone.value);
    });
    form.cpf.addEventListener("input", () => {
      form.cpf.value = formatarCpf(form.cpf.value);
    });

    const [termo, privacidade] = await Promise.all([carregarVigente("termos"), carregarVigente("privacidade")]);
    if (!termo || !privacidade) {
      mostrarErro(form, "Não foi possível carregar os termos e a política de privacidade. Tente novamente em instantes.");
      form.querySelector("button[type=submit]").disabled = true;
      return;
    }

    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      mostrarErro(form, "");

      const dados = {
        tipo: form.tipo.value,
        nome: form.nome.value.trim().replace(/\s+/g, " "),
        cpf: somenteDigitos(form.cpf.value),
        email: form.email.value.trim().toLowerCase(),
        senha: form.senha.value,
        telefone: telefoneParaBanco(form.telefone.value),
      };

      if (!dados.tipo) return mostrarErro(form, "Escolha o seu tipo de acesso.");
      if (dados.nome.split(" ").length < 2) return mostrarErro(form, "Informe o nome completo.");
      if (!cpfValido(dados.cpf)) return mostrarErro(form, "CPF inválido. Confira os números.");
      if (dados.senha.length < 8) return mostrarErro(form, "A senha precisa ter pelo menos 8 caracteres.");
      if (!telefoneValido(dados.telefone)) return mostrarErro(form, "Celular inválido. Use o formato +55(33)999058391.");
      if (!form.aceite_termos.checked || !form.aceite_privacidade.checked) {
        return mostrarErro(form, "Leia e aceite os Termos e Condições de Uso e a Política de Privacidade para continuar.");
      }

      const btn = form.querySelector("button");
      btn.disabled = true;
      btn.textContent = "Enviando...";

      try {
        const { data: auth, error: erroAuth } = await sb.auth.signUp({
          email: dados.email,
          password: dados.senha,
        });
        if (erroAuth) throw erroAuth;

        const userId = auth.user?.id;
        if (!userId) throw new Error("Não foi possível criar a conta.");
        if (!auth.session) {
          throw new Error("Confirme o e-mail recebido e depois entre no sistema para concluir o cadastro.");
        }

        const { error: erroPerfil } = await sb.from("usuarios").insert({
          id: userId,
          nome_completo: dados.nome,
          cpf: dados.cpf,
          email: dados.email,
          telefone: dados.telefone,
          tipo_acesso: dados.tipo,
          termo_versao: termo.versao,
          termo_aceito_em: new Date().toISOString(),
          privacidade_versao: privacidade.versao,
          privacidade_aceita_em: new Date().toISOString(),
        });
        if (erroPerfil) {
          if (erroPerfil.code === "23505") {
            throw new Error("Já existe um cadastro com este CPF ou e-mail.");
          }
          throw erroPerfil;
        }

        rotear();
      } catch (err) {
        mostrarErro(form, traduzirErro(err));
        btn.disabled = false;
        btn.textContent = "Solicitar acesso";
      }
    });
  }

  function telaPendente() {
    renderizar("tpl-pendente");
    document.getElementById("btn-atualizar").addEventListener("click", rotear);
  }

  function telaRecusado(perfil) {
    renderizar("tpl-recusado");
    if (perfil.status === "bloqueado") {
      app.querySelector("h1").textContent = "Acesso suspenso";
      app.querySelector("p").textContent = "Seu acesso está suspenso no momento.";
    }
    document.getElementById("motivo-recusa").textContent =
      perfil.motivo_recusa || "Entre em contato com a cooperativa para mais informações.";
  }

  // Painel com menu lateral. A navegação é pelo endereço (#conversas, #meus-dados etc.).
  function telaPainel(perfil, hash) {
    mostrarBotaoSair(true);
    window.Interno.abrirPainel(perfil, app, hash, {
      "meus-dados": (destino) => telaMeusDados(perfil, destino),
      "admin/cadastros": (destino) => telaCadastros(destino, perfil),
    });
  }

  // Aprovação de cadastros (somente administrador).
  function telaCadastros(destino, admin) {
    destino.innerHTML = `
      <h1>Cadastros</h1>
      <p class="ajuda">Confira os dados antes de aprovar. Inativar suspende o acesso sem apagar nada. Excluir remove o cadastro, os atendimentos e as mensagens da pessoa.</p>
      <div class="filtros">
        <button class="chip ativo" data-filtro="pendente">Pendentes</button>
        <button class="chip" data-filtro="aprovado">Aprovados</button>
        <button class="chip" data-filtro="recusado">Recusados</button>
        <button class="chip" data-filtro="bloqueado">Inativos</button>
      </div>
      <div id="lista-cadastros"></div>`;
    destino.querySelectorAll(".chip").forEach((chip) => {
      chip.addEventListener("click", () => {
        destino.querySelectorAll(".chip").forEach((c) => c.classList.toggle("ativo", c === chip));
        carregarCadastros(chip.dataset.filtro, admin);
      });
    });
    carregarCadastros("pendente", admin);
  }

  // Ações disponíveis em cada situação. Quem é administrador não age sobre a própria conta.
  async function carregarCadastros(status, admin) {
    const lista = document.getElementById("lista-cadastros");
    lista.innerHTML = '<p class="ajuda">Carregando...</p>';
    const { data, error } = await sb
      .from("usuarios")
      .select("id, nome_completo, cpf, email, telefone, tipo_acesso, status, criado_em")
      .eq("status", status)
      .order("criado_em", { ascending: true });

    if (error) {
      lista.innerHTML = `<p class="erro">Não foi possível carregar: ${escapar(error.message)}</p>`;
      return;
    }
    if (!data.length) {
      lista.innerHTML = '<p class="ajuda">Nenhum cadastro nesta situação.</p>';
      return;
    }

    lista.innerHTML = data.map((u) => {
      const acoes = [];
      if (u.status === "pendente") acoes.push(["aprovado", "Aprovar", "btn-primario"], ["recusado", "Recusar", "btn-ghost"]);
      if (u.status === "aprovado") acoes.push(["bloqueado", "Inativar", "btn-ghost"]);
      if (u.status === "recusado") acoes.push(["aprovado", "Aprovar", "btn-primario"]);
      if (u.status === "bloqueado") acoes.push(["aprovado", "Reativar", "btn-primario"]);
      const eu = u.id === admin.id;
      return `
      <article class="item" data-id="${u.id}">
        <div>
          <strong>${escapar(u.nome_completo)}</strong>
          <span class="etiqueta">${escapar(u.tipo_acesso.replace("_", " "))}</span>
        </div>
        <p class="ajuda">CPF ${formatarCpf(u.cpf)} · ${escapar(u.email)} · ${formatarTelefone(u.telefone)}</p>
        ${eu ? '<p class="ajuda">Esta é a sua conta.</p>' : `
          <div class="acoes">
            ${acoes.map(([acao, rotulo, classe]) => `<button class="${classe}" data-acao="${acao}">${rotulo}</button>`).join("")}
            <button class="btn-perigo" data-acao="excluir">Excluir</button>
          </div>`}
      </article>`;
    }).join("");

    lista.querySelectorAll("[data-acao]").forEach((btn) => {
      btn.addEventListener("click", async () => {
        const card = btn.closest(".item");
        const acao = btn.dataset.acao;
        const nome = card.querySelector("strong").textContent;

        if (acao === "excluir") {
          const aviso = `Excluir o cadastro de ${nome}? A pessoa perde o acesso e os atendimentos e mensagens dela são removidos. Não pode ser desfeito.`;
          if (!confirm(aviso)) return;
          const { error: erroExcluir } = await sb.rpc("excluir_usuario", { p_usuario: card.dataset.id });
          if (erroExcluir) return alert("Não foi possível excluir: " + erroExcluir.message);
        } else {
          if (acao === "bloqueado" && !confirm(`Inativar ${nome}? A pessoa não conseguirá entrar até ser reativada.`)) return;
          const campos = { status: acao };
          if (acao === "aprovado" || acao === "recusado") {
            campos.motivo_recusa = acao === "recusado" ? (prompt("Motivo da recusa (opcional):") || null) : null;
            campos.aprovado_por = admin.id;
            campos.aprovado_em = new Date().toISOString();
          }
          const { error: erroUpd } = await sb.from("usuarios").update(campos).eq("id", card.dataset.id);
          if (erroUpd) return alert("Não foi possível atualizar: " + erroUpd.message);
        }

        card.remove();
        if (!lista.querySelector(".item")) {
          lista.innerHTML = '<p class="ajuda">Nenhum cadastro nesta situação.</p>';
        }
      });
    });
  }

  // ---------- Roteamento ----------

  function escapar(texto) {
    const div = document.createElement("div");
    div.textContent = texto ?? "";
    return div.innerHTML;
  }

  function traduzirErro(err) {
    const msg = err?.message || "";
    if (/already registered|already been registered/i.test(msg)) return "Este e-mail já está cadastrado. Tente entrar.";
    if (/at least 8|password/i.test(msg)) return "A senha precisa ter pelo menos 8 caracteres.";
    if (/invalid.*email/i.test(msg)) return "E-mail inválido.";
    return msg || "Ocorreu um erro. Tente novamente.";
  }

  async function rotear() {
    app.className = "conteudo"; // o painel troca para a versão larga
    try {
      if (modoRecuperacao) return telaRedefinir();
      const hash = location.hash.replace("#", "");
      if (hash === "termos") return telaDocumento("termos");
      if (hash === "privacidade") return telaDocumento("privacidade");
      const { data: { session } } = await sb.auth.getSession();

      if (!session) {
        if (hash === "cadastro") return telaCadastro();
        if (hash === "esqueci") return telaEsqueci();
        return telaLogin();
      }

      const perfil = await buscarPerfil();
      if (!perfil) return telaCadastro();
      if (perfil.status === "recusado" || perfil.status === "bloqueado") return telaRecusado(perfil);

      // Termos e política valem para todo o sistema: quem não aceitou a versão vigente aceita antes de seguir.
      const pendentes = [];
      for (const tipo of Object.keys(DOCS)) {
        const doc = await carregarVigente(tipo);
        if (!doc) throw new Error("Não foi possível carregar os termos de uso. Atualize a página.");
        if (perfil[DOCS[tipo].campoVersao] !== doc.versao) pendentes.push({ tipo, doc });
      }
      if (pendentes.length) return telaAceiteDocumentos(perfil, pendentes);

      // Permissão de notificações: pedida logo após o aceite, antes de entrar no sistema.
      if (await window.Push.precisaPerguntar()) return telaPermissoes(perfil);

      if (perfil.status === "pendente") return telaPendente();
      return telaPainel(perfil, hash);
    } catch (err) {
      app.innerHTML = `<section class="cartao"><p class="erro">Erro ao carregar: ${escapar(err.message)}</p></section>`;
    }
  }

  btnSair.addEventListener("click", async () => {
    await sb.auth.signOut();
    location.hash = "";
    rotear();
  });

  window.addEventListener("hashchange", rotear);
  sb.auth.onAuthStateChange((evento) => {
    // Clique no link do e-mail de recuperação: mostra o formulário de nova senha.
    if (evento === "PASSWORD_RECOVERY") {
      modoRecuperacao = true;
      return telaRedefinir();
    }
    if (evento === "SIGNED_OUT") rotear();
  });

  rotear();
})();
