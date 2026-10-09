// Cache mínimo para abrir a casca do app offline, e recebimento de notificações push.
// Nunca faz cache de chamadas ao Supabase, para não mostrar dados desatualizados.
const CACHE = "coop-vrd-v2";
const ARQUIVOS = ["./", "index.html", "styles.css", "app.js", "interno.js", "push.js", "config.js", "manifest.webmanifest", "icons/icon.svg"];

self.addEventListener("install", (evento) => {
  evento.waitUntil(caches.open(CACHE).then((c) => c.addAll(ARQUIVOS)));
  self.skipWaiting();
});

self.addEventListener("activate", (evento) => {
  evento.waitUntil(
    caches.keys().then((chaves) =>
      Promise.all(chaves.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener("fetch", (evento) => {
  const url = new URL(evento.request.url);
  if (url.origin !== self.location.origin) return;
  evento.respondWith(
    fetch(evento.request).catch(() => caches.match(evento.request))
  );
});

// Aviso recebido do servidor. O texto é genérico, sem assunto nem conteúdo das mensagens.
self.addEventListener("push", (evento) => {
  let dados = { titulo: "Cooperativa Vale do Rio Doce", corpo: "Você tem uma nova notificação.", url: "/#notificacoes" };
  try {
    dados = { ...dados, ...evento.data.json() };
  } catch (_) {
    // Sem corpo legível: mantém o aviso genérico.
  }
  evento.waitUntil(
    self.registration.showNotification(dados.titulo, {
      body: dados.corpo,
      icon: "icons/icon.svg",
      badge: "icons/icon.svg",
      data: { url: dados.url },
    })
  );
});

// Ao tocar no aviso, abre o sistema no lugar indicado.
self.addEventListener("notificationclick", (evento) => {
  evento.notification.close();
  const destino = new URL(evento.notification.data?.url || "/#notificacoes", self.location.origin).href;
  evento.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((janelas) => {
      const aberta = janelas.find((j) => j.url.startsWith(self.location.origin));
      if (aberta) {
        aberta.focus();
        return aberta.navigate(destino);
      }
      return self.clients.openWindow(destino);
    })
  );
});
