// Cache mínimo para abrir a casca do app offline.
// Nunca faz cache de chamadas ao Supabase, para não mostrar dados desatualizados.
const CACHE = "coop-vrd-v1";
const ARQUIVOS = ["./", "index.html", "styles.css", "app.js", "config.js", "manifest.webmanifest", "icons/icon.svg"];

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
