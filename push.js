// Notificações push: pede permissão, inscreve o aparelho e guarda a inscrição no banco.
// O envio é feito pelo servidor (função enviar-push). Aqui só registramos quem recebe.
(() => {
  const CHAVE_PUBLICA = window.APP_CONFIG.VAPID_PUBLIC_KEY || "";

  const suportado = () =>
    "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
  const ehIOS = () => /iphone|ipad|ipod/i.test(navigator.userAgent);
  const instalado = () =>
    window.matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;

  // Converte a chave pública (base64url) para o formato que o navegador espera.
  function paraBytes(base64url) {
    const padding = "=".repeat((4 - (base64url.length % 4)) % 4);
    const base64 = (base64url + padding).replace(/-/g, "+").replace(/_/g, "/");
    return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
  }

  // Situação deste aparelho: indisponivel, bloqueado, inativo ou ativo.
  async function estado() {
    if (!CHAVE_PUBLICA) {
      return { situacao: "indisponivel", mensagem: "As notificações ainda não estão configuradas." };
    }
    if (!suportado()) {
      return {
        situacao: "indisponivel",
        mensagem: ehIOS() && !instalado()
          ? "No iPhone, adicione o sistema à tela de início para receber notificações."
          : "Este navegador não oferece notificações.",
      };
    }
    if (Notification.permission === "denied") {
      return { situacao: "bloqueado", mensagem: "As notificações estão bloqueadas no navegador. Libere-as nas configurações do site para ativar." };
    }
    const registro = await navigator.serviceWorker.ready;
    const inscricao = await registro.pushManager.getSubscription();
    return inscricao
      ? { situacao: "ativo", mensagem: "Notificações ativadas neste aparelho." }
      : { situacao: "inativo", mensagem: "Ative para receber aviso de novas respostas e atualizações dos seus atendimentos." };
  }

  async function ativar() {
    const permissao = await Notification.requestPermission();
    if (permissao !== "granted") throw new Error("A permissão para notificações não foi concedida.");

    const registro = await navigator.serviceWorker.ready;
    const inscricao = await registro.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: paraBytes(CHAVE_PUBLICA),
    });
    const dados = inscricao.toJSON();
    const { error } = await window.sb.rpc("registrar_push", {
      p_endpoint: dados.endpoint,
      p_p256dh: dados.keys.p256dh,
      p_auth: dados.keys.auth,
    });
    if (error) {
      await inscricao.unsubscribe();
      throw error;
    }
  }

  async function desativar() {
    const registro = await navigator.serviceWorker.ready;
    const inscricao = await registro.pushManager.getSubscription();
    if (!inscricao) return;
    const { error } = await window.sb.rpc("remover_push", { p_endpoint: inscricao.endpoint });
    if (error) throw error;
    await inscricao.unsubscribe();
  }

  // Verdadeiro quando o aparelho ainda não respondeu sobre notificações (permissão não decidida e sem inscrição).
  async function precisaPerguntar() {
    if (!CHAVE_PUBLICA || !suportado()) return false;
    if (Notification.permission !== "default") return false;
    const registro = await navigator.serviceWorker.ready;
    return !(await registro.pushManager.getSubscription());
  }

  window.Push = { estado, ativar, desativar, precisaPerguntar };
})();
