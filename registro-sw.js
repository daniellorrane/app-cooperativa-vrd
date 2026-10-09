// Registra o service worker (cache da casca e notificações push).
// Fica em arquivo próprio para permitir uma política de scripts sem código inline.
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("sw.js").catch(() => {});
}
