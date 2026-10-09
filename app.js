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

  function renderizar(id) {
    const tpl = document.getElementById(id);
    app.replaceChildren(tpl.content.cloneNode(true));
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

  // Termo de uso vigente (versão publicada mais recente).
  async function carregarTermoAtual() {
    const { data, error } = await sb
      .from("termos_uso")
      .select("versao, texto")
      .order("publicado_em", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (error || !data) return null;
    return data;
  }

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

  function telaMeusDados(perfil) {
    mostrarBotaoSair(true);
    renderizar("tpl-meus-dados");
    const form = document.getElementById("form-meus-dados");
    const sucesso = form.querySelector(".sucesso");
    form.nome.value = perfil.nome_completo;
    form.cpf.value = formatarCpf(perfil.cpf);
    form.email.value = perfil.email;
    form.telefone.value = formatarTelefone(perfil.telefone);

    form.telefone.addEventListener("input", () => {
      form.telefone.value = formatarTelefone(form.telefone.value);
    });

    document.getElementById("voltar-painel").addEventListener("click", (e) => {
      e.preventDefault();
      location.hash = "";
      rotear();
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
      const telefone = telefoneParaBanco(form.telefone.value);

      if (nome.split(" ").length < 2) return mostrarErro(form, "Informe o nome completo.");
      if (!telefoneValido(telefone)) return mostrarErro(form, "Celular inválido. Use o formato +55(33)999058391.");

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

  // Aceite obrigatório da versão vigente dos termos (cadastro antigo ou nova versão publicada).
  function telaAceiteTermos(perfil, termo) {
    mostrarBotaoSair(true);
    app.innerHTML = `
      <section class="cartao largo texto-legal">
        ${textoDosTermos(termo.texto, "h2")}
        <form id="form-aceite-termo" novalidate>
          <label class="opcao">
            <input type="checkbox" name="aceite" />
            <span>Li e aceito os Termos e Condições de Uso</span>
          </label>
          <p class="erro" role="alert" hidden></p>
          <button type="submit" class="btn-primario">Continuar</button>
        </form>
      </section>`;

    const form = document.getElementById("form-aceite-termo");
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      mostrarErro(form, "");
      if (!form.aceite.checked) return mostrarErro(form, "Marque a opção para aceitar os termos.");

      const btn = form.querySelector("button");
      btn.disabled = true;
      const { error } = await sb
        .from("usuarios")
        .update({ termo_versao: termo.versao, termo_aceito_em: new Date().toISOString() })
        .eq("id", perfil.id);
      if (error) {
        btn.disabled = false;
        return mostrarErro(form, "Não foi possível registrar o aceite: " + error.message);
      }
      rotear();
    });
  }

  // Página pública dos termos (acessível sem login, pelo link do cadastro).
  async function telaTermos() {
    app.innerHTML = '<section class="cartao largo"><p class="ajuda">Carregando...</p></section>';
    const termo = await carregarTermoAtual();
    if (!termo) {
      app.innerHTML = '<section class="cartao"><p class="erro">Não foi possível carregar os termos agora. Tente novamente em instantes.</p></section>';
      return;
    }
    app.innerHTML = `
      <section class="cartao largo texto-legal">
        ${textoDosTermos(termo.texto)}
        <p class="rodape-form"><a href="#" id="voltar-termos">Voltar</a></p>
      </section>`;
    document.getElementById("voltar-termos").addEventListener("click", (e) => {
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

    const tipos = await carregarTipos();
    lista.innerHTML = tipos.map((t, i) => `
      <label class="opcao">
        <input type="radio" name="tipo" value="${t.codigo}" ${i === 0 ? "checked" : ""} required />
        <span>${t.descricao}</span>
      </label>`).join("");

    form.telefone.addEventListener("input", () => {
      form.telefone.value = formatarTelefone(form.telefone.value);
    });
    form.cpf.addEventListener("input", () => {
      form.cpf.value = formatarCpf(form.cpf.value);
    });

    const termo = await carregarTermoAtual();
    if (!termo) {
      mostrarErro(form, "Não foi possível carregar os termos de uso. Tente novamente em instantes.");
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

      if (dados.nome.split(" ").length < 2) return mostrarErro(form, "Informe o nome completo.");
      if (!cpfValido(dados.cpf)) return mostrarErro(form, "CPF inválido. Confira os números.");
      if (dados.senha.length < 8) return mostrarErro(form, "A senha precisa ter pelo menos 8 caracteres.");
      if (!telefoneValido(dados.telefone)) return mostrarErro(form, "Celular inválido. Use o formato +55(33)999058391.");
      if (!form.aceite.checked) return mostrarErro(form, "Leia e aceite os Termos e Condições de Uso para continuar.");

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
    document.getElementById("motivo-recusa").textContent =
      perfil.motivo_recusa || "Entre em contato com a cooperativa para mais informações.";
  }

  async function telaPainel(perfil) {
    mostrarBotaoSair(true);
    renderizar("tpl-painel");
    document.getElementById("nome-usuario").textContent = perfil.nome_completo.split(" ")[0];
    document.getElementById("tipo-usuario").textContent = perfil.tipo_acesso.replace("_", " ");
    document.getElementById("btn-meus-dados").addEventListener("click", () => {
      location.hash = "meus-dados";
    });
    window.Interno.montar(perfil, document.getElementById("area-interna"));

    if (perfil.tipo_acesso === "administrador") {
      document.getElementById("area-admin").hidden = false;
      carregarCadastros("pendente");
      document.querySelectorAll(".chip").forEach((chip) => {
        chip.addEventListener("click", () => {
          document.querySelectorAll(".chip").forEach((c) => c.classList.remove("ativo"));
          chip.classList.add("ativo");
          carregarCadastros(chip.dataset.filtro);
        });
      });
    }
  }

  async function carregarCadastros(status) {
    const lista = document.getElementById("lista-cadastros");
    lista.innerHTML = '<p class="ajuda">Carregando...</p>';
    const { data, error } = await sb
      .from("usuarios")
      .select("id, nome_completo, cpf, email, telefone, tipo_acesso, status, criado_em")
      .eq("status", status)
      .order("criado_em", { ascending: true });

    if (error) {
      lista.innerHTML = `<p class="erro">Não foi possível carregar: ${error.message}</p>`;
      return;
    }
    if (!data.length) {
      lista.innerHTML = '<p class="ajuda">Nenhum cadastro nesta situação.</p>';
      return;
    }

    lista.innerHTML = data.map((u) => `
      <article class="item" data-id="${u.id}">
        <div>
          <strong>${escapar(u.nome_completo)}</strong>
          <span class="etiqueta">${escapar(u.tipo_acesso.replace("_", " "))}</span>
        </div>
        <p class="ajuda">CPF ${formatarCpf(u.cpf)} · ${escapar(u.email)} · ${formatarTelefone(u.telefone)}</p>
        ${status === "pendente" ? `
          <div class="acoes">
            <button class="btn-primario" data-acao="aprovado">Aprovar</button>
            <button class="btn-perigo" data-acao="recusado">Recusar</button>
          </div>` : ""}
      </article>`).join("");

    lista.querySelectorAll("[data-acao]").forEach((btn) => {
      btn.addEventListener("click", async () => {
        const card = btn.closest(".item");
        const novoStatus = btn.dataset.acao;
        let motivo = null;
        if (novoStatus === "recusado") {
          motivo = prompt("Motivo da recusa (opcional):") || null;
        }
        const { data: { user } } = await sb.auth.getUser();
        const { error: erroUpd } = await sb
          .from("usuarios")
          .update({
            status: novoStatus,
            motivo_recusa: motivo,
            aprovado_por: user.id,
            aprovado_em: new Date().toISOString(),
          })
          .eq("id", card.dataset.id);
        if (erroUpd) return alert("Não foi possível atualizar: " + erroUpd.message);
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
    try {
      if (modoRecuperacao) return telaRedefinir();
      const hash = location.hash.replace("#", "");
      if (hash === "termos") return telaTermos();
      const { data: { session } } = await sb.auth.getSession();

      if (!session) {
        if (hash === "cadastro") return telaCadastro();
        if (hash === "esqueci") return telaEsqueci();
        return telaLogin();
      }

      const perfil = await buscarPerfil();
      if (!perfil) return telaCadastro();
      if (perfil.status === "recusado" || perfil.status === "bloqueado") return telaRecusado(perfil);

      // Termos valem para todo o sistema: quem não aceitou a versão vigente aceita antes de seguir.
      const termo = await carregarTermoAtual();
      if (!termo) throw new Error("Não foi possível carregar os termos de uso. Atualize a página.");
      if (perfil.termo_versao !== termo.versao) return telaAceiteTermos(perfil, termo);

      if (perfil.status === "pendente") return telaPendente();
      if (hash === "meus-dados") return telaMeusDados(perfil);
      return telaPainel(perfil);
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
