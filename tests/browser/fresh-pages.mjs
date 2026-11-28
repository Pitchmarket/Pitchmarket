// The service worker must never leave a player on an old version of the
// page: after an update, the next load shows it. The saved copy is only used
// offline. Also checks the upgrade from the old worker (v1), which served
// the saved page first: it must offer a refresh once the new worker is in.
import { readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { openPage } from './harness.mjs';

const BASE = 'http://127.0.0.1:8765/index.html';
const real = readFileSync(new URL('../../index.html', import.meta.url), 'utf8');
const newSw = readFileSync(new URL('../../sw.js', import.meta.url), 'utf8');
const oldSw = execSync('git show origin/main:sw.js', { cwd: new URL('../..', import.meta.url) }).toString();
const fail = (msg) => { console.error('FAIL:', msg); process.exit(1); };

async function run({ startSw }) {
  // Start blank, so no worker registers before the routes below are in place.
  const { page, errors, browser } = await openPage('about:blank');
  const ctx = page.context();
  let marker = 'VERSION-A', sw = startSw;
  await ctx.route('**/127.0.0.1:8765/index.html', r => r.fulfill({ status: 200, contentType: 'text/html', body: real.replace('</title>', ' ' + marker + '</title>') }));
  await ctx.route('**/127.0.0.1:8765/sw.js', r => r.fulfill({ status: 200, contentType: 'application/javascript', body: sw, headers: { 'cache-control': 'no-cache' } }));
  const title = () => page.title();
  const controlled = () => page.waitForFunction(() => !!navigator.serviceWorker.controller, null, { timeout: 15000 });
  await page.goto(BASE, { waitUntil: 'load' });
  await controlled();
  await page.reload({ waitUntil: 'load' });
  if(!(await title()).includes('VERSION-A')) fail('first version not shown');
  return { page, ctx, errors, browser, title, controlled, set: (m) => { marker = m; }, setSw: (s) => { sw = s; } };
}

// 1. New worker: an update shows on the very next load; offline uses the saved copy.
{
  const t = await run({ startSw: newSw });
  t.set('VERSION-B');
  await t.page.reload({ waitUntil: 'load' });
  if(!(await t.title()).includes('VERSION-B')) fail('update not shown on the next load');
  if(t.errors.length) fail('page errors: ' + t.errors.join(' | '));
  // Offline, the database and libraries can't load, so only the page itself is checked.
  await t.ctx.setOffline(true);
  await t.page.reload({ waitUntil: 'load' });
  if(!(await t.title()).includes('VERSION-B')) fail('saved copy not used offline');
  await t.ctx.setOffline(false);
  await t.browser.close();
}

// 2. Upgrade from the old worker: once the new worker activates, the open
//    page is offered a refresh, and from then on updates show on the next load.
{
  const t = await run({ startSw: oldSw });
  t.setSw(newSw);
  t.set('VERSION-B');
  await t.page.reload({ waitUntil: 'load' });           // old worker may still serve its saved copy here
  await t.page.evaluate(() => navigator.serviceWorker.getRegistration().then(r => r && r.update()));
  await t.page.waitForSelector('#pmUpdated', { timeout: 15000 }).catch(() => fail('no "updated" note after the new worker activated'));
  await t.page.reload({ waitUntil: 'load' });
  if(!(await t.title()).includes('VERSION-B')) fail('new version not shown after the refresh');
  t.set('VERSION-C');
  await t.page.reload({ waitUntil: 'load' });
  if(!(await t.title()).includes('VERSION-C')) fail('later update not shown on the next load');
  if(t.errors.length) fail('page errors: ' + t.errors.join(' | '));
  await t.browser.close();
}
console.log('ok');
