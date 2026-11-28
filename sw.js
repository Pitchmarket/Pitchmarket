// PitchMarket service worker.
//
// - Pages (index.html, admin.html): always fetched fresh from the site when
//   online, so players never get stuck on an old version after an update.
//   The browser revalidates with GitHub (a quick "not modified" reply when
//   nothing changed). The last good copy is saved and only used when the
//   network fails, so the site still opens offline.
// - Code libraries and fonts from the CDNs: their addresses include a fixed
//   version, so they never change and are kept after the first visit.
// - Everything else, including every Supabase request, goes to the network
//   as normal: prices, coins and games are never served from here.
//
// Bump VERSION to throw away everything saved by an older version.

const VERSION = 'v2';
const PAGES = `pm-pages-${VERSION}`;
const LIBS = `pm-libs-${VERSION}`;
const LIB_HOSTS = ['cdn.jsdelivr.net', 'cdnjs.cloudflare.com', 'fonts.googleapis.com', 'fonts.gstatic.com'];
// How long to wait for the site before falling back to the saved page.
const PAGE_TIMEOUT_MS = 8000;

self.addEventListener('install', () => self.skipWaiting());

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keep = new Set([PAGES, LIBS]);
    let upgraded = false;
    for (const name of await caches.keys()) {
      if (!keep.has(name)) { await caches.delete(name); upgraded = true; }
    }
    await self.clients.claim();
    // Pages opened by an older version were served from its saved copy:
    // offer them a refresh (they show the "PitchMarket has been updated" note).
    if (upgraded) {
      for (const client of await self.clients.matchAll({ type: 'window' })) {
        client.postMessage({ type: 'pm-updated' });
      }
    }
  })());
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  if (req.mode === 'navigate' && url.origin === self.location.origin) {
    event.respondWith(pageFromNetworkThenCache(req));
  } else if (LIB_HOSTS.includes(url.hostname)) {
    event.respondWith(libFromCache(req));
  }
});

async function pageFromNetworkThenCache(req) {
  const cache = await caches.open(PAGES);
  // The query string and #hash don't change the page.
  const key = new URL(req.url);
  key.search = '';
  try {
    const res = await Promise.race([
      fetch(req, { cache: 'no-cache' }),
      new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), PAGE_TIMEOUT_MS)),
    ]);
    if (res.ok) await cache.put(key.href, res.clone());
    return res;
  } catch (err) {
    const cached = await cache.match(key.href);
    if (cached) return cached;
    throw err;
  }
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
