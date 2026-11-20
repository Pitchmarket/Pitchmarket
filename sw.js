// PitchMarket service worker: makes repeat visits load from the browser
// instead of the network.
//
// - Pages (index.html, admin.html): shown from the saved copy straight away,
//   then refreshed in the background (stale-while-revalidate). If the
//   refreshed copy differs, open pages are told so they can offer a reload.
// - Code libraries and fonts from the CDNs: their addresses include a fixed
//   version, so they never change and are kept after the first visit.
// - Everything else, including every Supabase request, goes to the network
//   as normal: prices, coins and games are never served from here.
//
// Bump VERSION to throw away everything saved by an older version.

const VERSION = 'v1';
const PAGES = `pm-pages-${VERSION}`;
const LIBS = `pm-libs-${VERSION}`;
const LIB_HOSTS = ['cdn.jsdelivr.net', 'cdnjs.cloudflare.com', 'fonts.googleapis.com', 'fonts.gstatic.com'];

self.addEventListener('install', () => self.skipWaiting());

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keep = new Set([PAGES, LIBS]);
    for (const name of await caches.keys()) if (!keep.has(name)) await caches.delete(name);
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  if (req.mode === 'navigate' && url.origin === self.location.origin) {
    event.respondWith(pageFromCacheThenRefresh(event));
  } else if (LIB_HOSTS.includes(url.hostname)) {
    event.respondWith(libFromCache(req));
  }
});

async function pageFromCacheThenRefresh(event) {
  const cache = await caches.open(PAGES);
  // The query string and #hash don't change the page.
  const key = new URL(event.request.url);
  key.search = '';
  const cached = await cache.match(key.href);
  const refresh = fetch(event.request).then(async (res) => {
    if (res.ok) {
      const old = cached ? await cached.clone().text() : null;
      const fresh = await res.clone().text();
      await cache.put(key.href, res.clone());
      if (old !== null && old !== fresh) {
        const client = await self.clients.get(event.resultingClientId || event.clientId);
        if (client) client.postMessage({ type: 'pm-updated' });
      }
    }
    return res;
  });
  if (cached) {
    event.waitUntil(refresh.catch(() => {}));
    return cached;
  }
  return refresh;
}

async function libFromCache(req) {
  const cache = await caches.open(LIBS);
  const cached = await cache.match(req);
  if (cached) return cached;
  const res = await fetch(req);
  // Only keep complete, readable answers (not opaque ones, which the browser
  // counts as several megabytes each).
  if (res.ok && res.type !== 'opaque') await cache.put(req, res.clone());
  return res;
}
