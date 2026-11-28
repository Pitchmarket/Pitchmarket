// Browser test harness: opens a page in headless Chromium with CDN scripts and
// Supabase calls stubbed. Usage: const { page, errors, calls, browser } = await openPage(url, { routes, session, viewport, storage })
// storage: localStorage items set before the page's own scripts run.
import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const SUPABASE_JS = path.join(ROOT, 'node_modules/@supabase/supabase-js/dist/umd/supabase.js');
const PROJECT_REF = 'ljpwxujlyqhlznasnhfk';
const CORS = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' };

const CHART_STUB = `window.Chart = function Chart(ctx, config) { this.ctx = ctx; this.config = config; this.data = config && config.data; this.options = config && config.options; };
Chart.prototype.update = function () {}; Chart.prototype.destroy = function () {};
Chart.defaults = { font: {}, plugins: { legend: { labels: {} } } }; Chart.register = function () {};`;

async function loadPlaywright() {
  try { return await import('playwright'); } catch (e) {
    const g = path.join(execSync('npm root -g').toString().trim(), 'playwright', 'index.mjs');
    return await import(pathToFileURL(g).href);
  }
}

const b64url = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');

export function makeSession(s) {
  const exp = Math.floor(Date.now() / 1000) + 3600;
  const user = { id: s.id, email: s.email, aud: 'authenticated', role: 'authenticated' };
  return {
    access_token: 'h.' + b64url({ sub: s.id, email: s.email, exp, role: 'authenticated' }) + '.s',
    refresh_token: 'r', token_type: 'bearer', expires_in: 3600, expires_at: exp, user,
  };
}

export async function openPage(url, { routes = {}, session = null, viewport = { width: 1280, height: 900 }, storage = {} } = {}) {
  const { chromium } = await loadPlaywright();
  const browser = await chromium.launch();
  const context = await browser.newContext({ viewport });
  const page = await context.newPage();
  const errors = [];
  const calls = [];
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  page.on('console', (m) => { if (m.type() === 'error') errors.push('console: ' + m.text()); });

  const sess = session ? makeSession(session) : null;
  await page.addInitScript(({ sess, ref, storage }) => {
    try {
      localStorage.setItem('pm-help', 'off');
      for (const [k, v] of Object.entries(storage)) localStorage.setItem(k, v);
      if (sess) localStorage.setItem('sb-' + ref + '-auth-token', JSON.stringify(sess));
    } catch (e) {}
  }, { sess, ref: PROJECT_REF, storage });

  const handlers = { 'rpc/kickabout_state': () => ({ game: 'scouted', day: '2026-11-26', signed_in: false, finished: false, won: false, coins: 0, max_guesses: 10, guesses: [] }), ...routes };
  const json = (route, body, status = 200) => route.fulfill({ status, headers: CORS, contentType: 'application/json', body: JSON.stringify(body) });

  await context.route(/cdn\.jsdelivr\.net/, (r) => r.fulfill({ status: 200, headers: CORS, contentType: 'application/javascript', body: fs.readFileSync(SUPABASE_JS) }));
  await context.route(/cdnjs\.cloudflare\.com/, (r) => r.fulfill({ status: 200, headers: CORS, contentType: 'application/javascript', body: CHART_STUB }));
  await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.fulfill({ status: 200, headers: CORS, contentType: 'text/css', body: '' }));
  await context.route(/\.supabase\.co\//, async (route) => {
    const request = route.request();
    if (request.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: CORS });
    const u = new URL(request.url());
    const m = u.pathname.match(/^\/(rest|auth|functions|storage|realtime)\/v1\/(.*)$/);
    const kind = m ? m[1] : '';
    const p = m ? m[2] : u.pathname.replace(/^\//, '');
    calls.push(p);
    if (kind === 'auth' && p === 'user' && sess) return json(route, sess.user);
    const h = handlers[p];
    if (h) {
      try {
        const body = await h(request);
        return json(route, body === undefined ? [] : body);
      } catch (e) { return json(route, { message: String(e) }, 500); }
    }
    return json(route, []);
  });

  await page.goto(url);
  page.close_ = () => browser.close();
  return { page, errors, calls, browser };
}
