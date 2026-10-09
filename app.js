(() => {
  const { createClient } = supabase;
  const sb = createClient(window.APP_CONFIG.SUPABASE_URL, window.APP_CONFIG.SUPABASE_KEY);

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

  // ---------- Telas ----------

  function telaLogin() {
    mostrarBotaoSair(false);
    renderizar("tpl-login");
    const form = document.getElementById("form-login");
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
      location.hash = "";
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
      // Link de recuperação de senha chega com type=recovery no endereço.
      if (location.hash.includes("type=recovery")) return telaRedefinir();
      const hash = location.hash.replace("#", "");
      const { data: { session } } = await sb.auth.getSession();

      if (!session) {
        if (hash === "cadastro") return telaCadastro();
        if (hash === "esqueci") return telaEsqueci();
        return telaLogin();
      }

      const perfil = await buscarPerfil();
      if (!perfil) return telaCadastro();
      if (perfil.status === "pendente") return telaPendente();
      if (perfil.status === "recusado" || perfil.status === "bloqueado") return telaRecusado(perfil);
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
    if (evento === "PASSWORD_RECOVERY") return telaRedefinir();
    if (evento === "SIGNED_OUT") rotear();
  });

  rotear();
})();
