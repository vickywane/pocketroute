// Bump CACHE_VERSION whenever the shell's file list changes. Contents update
// on their own: cached files are served immediately and refreshed in the
// background, so users get new code on the next launch.
const CACHE_VERSION = "v17";
const CACHE = `pocketroute-${CACHE_VERSION}`;
const SHELL = ["/", "/index.html", "/styles.css", "/flow-overrides.css", "/app.js", "/route-engine.js",
  "/manifest.webmanifest", "/icon.svg", "/data/london-underground-network-v1.json"];

self.addEventListener("install", event => {
  // cache: "reload" skips the browser's HTTP cache, so a new version never stores stale files.
  event.waitUntil(caches.open(CACHE)
    .then(cache => cache.addAll(SHELL.map(url => new Request(url, { cache: "reload" }))))
    .then(() => self.skipWaiting()));
});

self.addEventListener("activate", event => {
  event.waitUntil(caches.keys()
    .then(keys => Promise.all(keys.filter(key => key !== CACHE).map(key => caches.delete(key))))
    .then(() => self.clients.claim()));
});

self.addEventListener("fetch", event => {
  const { request } = event;
  if (request.method !== "GET" || new URL(request.url).origin !== self.location.origin) return;

  // Pages: network first so a new deploy shows up, cached shell when offline.
  if (request.mode === "navigate") {
    event.respondWith(fetch(request)
      .then(response => { cachePut("/index.html", response.clone()); return response; })
      .catch(() => caches.match("/index.html")));
    return;
  }

  // Everything else: serve the cached copy now, refresh it in the background.
  event.respondWith(caches.match(request).then(cached => {
    const network = fetch(request).then(response => { cachePut(request, response.clone()); return response; });
    if (cached) { event.waitUntil(network.catch(() => {})); return cached; }
    return network;
  }));
});

function cachePut(key, response) {
  if (!response.ok) return;
  caches.open(CACHE).then(cache => cache.put(key, response));
}
