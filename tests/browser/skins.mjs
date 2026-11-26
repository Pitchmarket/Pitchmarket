// Pro skins: locked for free players, applied for Pro and Ultimate, and a
// saved Pro skin falls back to Normal once the plan is confirmed as free.
// SKIN_SHOTS=<dir> also saves a 390 px and a 1280 px screenshot of each skin.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { openPage, makeSession } from './harness.mjs';

const URL_ = 'http://127.0.0.1:8765/index.html';
const USER = { id: 'u1', email: 'fan@example.com' };
const SKINS = ['floodlights', 'trophy', 'terrace'];
const SHOTS = process.env.SKIN_SHOTS || '';
const mk = (id, name, price, chg) => ({ id, name, league: 'epl', league_label: 'Premier League', tier: 'ENG · TIER 1', price, chg, league_order: 1 });
const TEAMS = () => [mk(1, 'Arsenal', 100, 2.4), mk(2, 'Chelsea', 90, -1.8), mk(3, 'Everton', 41.5, 0)];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const routes = (tier, { delay = 0, fail = false } = {}) => ({
  teams: TEAMS,
  profiles: () => ({ coin_balance: 2000, display_name: 'Fan' }),
  watchlist: () => [],
  'rpc/my_plan': async () => {
    if (delay) await sleep(delay);
    if (fail) throw new Error('boom');
    return { tier, source: tier === 'free' ? 'free' : 'stripe', has_subscription: tier !== 'free' };
  },
});

async function run(name, opts, fn, { savedTheme = null, allowConsole = false } = {}) {
  const { page, errors, browser } = await openPage(URL_, savedTheme ? { ...opts, storage: { 'pm-theme': savedTheme } } : opts);
  try {
    await fn(page);
    const bad = allowConsole ? errors.filter((e) => e.startsWith('pageerror')) : errors;
    assert.deepEqual(bad, [], 'page errors');
  } catch (e) { e.message = name + ': ' + e.message; throw e; }
  finally { await browser.close(); }
}
const theme = (page) => page.getAttribute('html', 'data-theme');
const planOk = (page) => page.waitForFunction(() => planStatus === 'ok', null, { timeout: 8000 });

// 1. Free player: three locked skins under a "Pro skins" heading; choosing
// one doesn't apply it, scrolls to the plans and says why.
await run('free player picker', { session: USER, routes: routes('free') }, async (page) => {
  await planOk(page);
  await page.click('#themeBtn');
  assert.equal((await page.textContent('#themeMenu .theme-group')).trim(), 'Pro skins');
  const locked = await page.$$eval('#themeMenu .theme-opt.is-locked', (els) => els.map((e) => e.dataset.themeKey));
  assert.deepEqual(locked, SKINS);
  for (const k of SKINS) assert.match(await page.getAttribute(`.theme-opt[data-theme-key="${k}"]`, 'aria-label'), /locked/i);
  assert.equal(await page.locator('#themeMenu .theme-opt:not(.is-locked)').count(), 13, 'free themes unlocked');
  await page.click('.theme-opt[data-theme-key="floodlights"]');
  assert.equal(await theme(page), 'normal', 'skin not applied');
  assert.equal(await page.evaluate(() => localStorage.getItem('pm-theme')), null, 'nothing saved');
  await page.waitForFunction(() => { const r = document.getElementById('pro').getBoundingClientRect(); return r.top < innerHeight && r.bottom > 0 && Math.abs(r.top) < 120; }, null, { timeout: 4000 });
  assert.ok(await page.isVisible('#skinNotice'), 'notice shown');
  assert.equal((await page.textContent('#skinNotice')).trim(), 'Pro skins come with Pro and Ultimate.');
  assert.equal(await page.getAttribute('#skinNotice', 'aria-live'), 'polite');
  assert.ok(!(await page.isVisible('#themeMenu')), 'menu closed');
  const focus = await page.evaluate(() => { const a = document.activeElement; return a === document.body ? 'body' : (document.getElementById('pro').contains(a) ? 'pro' : a.id); });
  assert.ok(focus === 'pro' || focus === 'themeBtn', 'focus moves to the plans or the picker, not ' + focus);
  // A free theme still applies.
  await page.click('#themeBtn');
  await page.click('.theme-opt[data-theme-key="chalk"]');
  await page.waitForFunction(() => document.documentElement.dataset.theme === 'chalk', null, { timeout: 4000 });
});

// 2. Saved Pro skin + free plan: kept while the plan loads, Normal once it is confirmed.
await run('free player with saved skin', { session: USER, routes: routes('free', { delay: 900 }) }, async (page) => {
  await page.waitForFunction(() => planStatus === 'pending' && !!currentSession, null, { timeout: 8000 });
  assert.equal(await theme(page), 'trophy', 'no flash while the plan loads');
  await planOk(page);
  await page.waitForFunction(() => document.documentElement.dataset.theme === 'normal', null, { timeout: 4000 });
  assert.equal(await page.evaluate(() => localStorage.getItem('pm-theme')), 'normal');
  assert.equal(await page.textContent('#themeLabel'), 'Normal');
}, { savedTheme: 'trophy' });

// 3. The plan check fails: the skin stays.
await run('plan error keeps skin', { session: USER, routes: routes('free', { fail: true }) }, async (page) => {
  await page.waitForFunction(() => planStatus === 'error', null, { timeout: 8000 });
  await page.waitForTimeout(200);
  assert.equal(await theme(page), 'trophy');
}, { savedTheme: 'trophy', allowConsole: true });

// 4. Signed out: a saved Pro skin falls back to Normal.
await run('signed out', { routes: { teams: TEAMS } }, async (page) => {
  await page.waitForFunction(() => document.documentElement.dataset.theme === 'normal', null, { timeout: 8000 });
}, { savedTheme: 'floodlights' });

// 5. Pro player: skins unlocked and applied; a saved one is kept.
await run('pro player', { session: USER, routes: routes('pro') }, async (page) => {
  await planOk(page);
  await page.click('#themeBtn');
  assert.equal(await page.locator('#themeMenu .theme-opt.is-locked').count(), 0, 'nothing locked');
  await page.click('.theme-opt[data-theme-key="terrace"]');
  await page.waitForFunction(() => document.documentElement.dataset.theme === 'terrace', null, { timeout: 4000 });
  assert.equal(await page.evaluate(() => localStorage.getItem('pm-theme')), 'terrace');
  assert.equal(await page.textContent('#themeLabel'), 'Terrace');
  assert.ok(!(await page.isVisible('#skinNotice')));
});

// 6. While the plan loads, Pro skins are neither locked nor offered.
await run('plan pending picker', { session: USER, routes: routes('pro', { delay: 1500 }) }, async (page) => {
  await page.waitForFunction(() => planStatus === 'pending' && !!currentSession, null, { timeout: 8000 });
  await page.click('#themeBtn');
  assert.equal(await page.locator('#themeMenu .theme-opt.is-locked').count(), 0, 'no locks while checking');
  assert.equal(await page.locator('#themeMenu .theme-opt[aria-disabled="true"]').count(), 3);
  assert.equal((await page.textContent('#themeMenu .theme-group-note')).trim(), 'Checking your plan…');
  await page.click('.theme-opt[data-theme-key="floodlights"]', { force: true });   // Playwright would wait for aria-disabled to clear
  assert.equal(await page.evaluate(() => planStatus), 'pending', 'clicked while still pending');
  await page.waitForTimeout(300);
  assert.equal(await theme(page), 'normal', 'not applied');
  assert.ok(!(await page.isVisible('#skinNotice')), 'no upsell');
  assert.ok(await page.isVisible('#themeMenu'), 'menu stays open');
  await planOk(page);
  assert.equal(await page.locator('#themeMenu .theme-opt[aria-disabled="true"]').count(), 0, 'open once confirmed');
  await page.click('.theme-opt[data-theme-key="floodlights"]');
  await page.waitForFunction(() => document.documentElement.dataset.theme === 'floodlights', null, { timeout: 4000 });
});

// 7. The remembered skin belongs to its player: it comes back for them,
// never for someone else on the same browser, and a hand-picked theme clears it.
const PRO_IDS = { u1: 'pro', u3: 'pro', u4: 'free' };
const authRoutes = {
  ...routes('free'),
  token: async (req) => { const { email } = JSON.parse(req.postData() || '{}'); const id = email.split('@')[0]; return makeSession({ id, email }); },
  logout: () => ({}),
  'rpc/my_plan': (req) => {
    const tok = (req.headers()['authorization'] || '').split(' ')[1] || '';
    let sub = ''; try { sub = JSON.parse(Buffer.from(tok.split('.')[1], 'base64url').toString()).sub; } catch (e) {}
    const tier = PRO_IDS[sub] || 'free';
    return { tier, source: tier === 'free' ? 'free' : 'stripe', has_subscription: tier !== 'free' };
  },
};
const signOut = (page) => page.evaluate(() => sb.auth.signOut());
const signIn = (page, id) => page.evaluate((email) => sb.auth.signInWithPassword({ email, password: 'pw123456' }), id + '@example.com');
const waitFor = (page, fn, arg) => page.waitForFunction(fn, arg, { timeout: 8000 });
const themeIs = (page, t) => waitFor(page, (t) => document.documentElement.dataset.theme === t, t);
await run('remember per player', { session: USER, routes: authRoutes }, async (page) => {
  await planOk(page);
  assert.equal(await theme(page), 'terrace');
  await signOut(page);
  await themeIs(page, 'normal');
  assert.deepEqual(JSON.parse(await page.evaluate(() => localStorage.getItem('pm-theme-pro'))), { uid: 'u1', theme: 'terrace' });
  // Another Pro player on this browser doesn't inherit it.
  await signIn(page, 'u3');
  await waitFor(page, () => currentSession && currentSession.user.id === 'u3' && planStatus === 'ok');
  await page.waitForTimeout(200);
  assert.equal(await theme(page), 'normal', 'u3 does not get u1\'s skin');
  await signOut(page);
  await waitFor(page, () => !currentSession);
  // Its owner gets it back.
  await signIn(page, 'u1');
  await themeIs(page, 'terrace');
  assert.equal(await page.evaluate(() => localStorage.getItem('pm-theme-pro')), null, 'memory used up');
  // Signed out again, then a theme picked by hand: the memory is cleared.
  await signOut(page);
  await themeIs(page, 'normal');
  await page.click('#themeBtn');
  await page.click('.theme-opt[data-theme-key="chalk"]');
  await themeIs(page, 'chalk');
  assert.equal(await page.evaluate(() => localStorage.getItem('pm-theme-pro')), null, 'hand-picked theme clears the memory');
  await signIn(page, 'u1');
  await waitFor(page, () => currentSession && planStatus === 'ok');
  await page.waitForTimeout(200);
  assert.equal(await theme(page), 'chalk');
  // A skin picked by hand is remembered for its player too.
  await page.click('#themeBtn');
  await page.click('.theme-opt[data-theme-key="floodlights"]');
  await themeIs(page, 'floodlights');
  await signOut(page);
  await themeIs(page, 'normal');
  assert.deepEqual(JSON.parse(await page.evaluate(() => localStorage.getItem('pm-theme-pro'))), { uid: 'u1', theme: 'floodlights' });
}, { savedTheme: 'terrace' });

// 7b. A short window: the menu scrolls, with a fade while more is below, and Terrace is reachable.
await run('picker scroll cue', { session: USER, routes: routes('free'), viewport: { width: 1280, height: 600 } }, async (page) => {
  await planOk(page);
  await page.click('#themeBtn');
  await waitFor(page, () => document.getElementById('themeMenu').classList.contains('has-more'));
  await page.locator('.theme-opt[data-theme-key="terrace"]').scrollIntoViewIfNeeded();
  await waitFor(page, () => !document.getElementById('themeMenu').classList.contains('has-more'));
  assert.ok(await page.isVisible('.theme-opt[data-theme-key="terrace"]'));
});

// 8. Each skin draws the table, with readable text and recognisable clue colours.
const lum = (hex) => {
  const n = parseInt(hex.slice(1), 16);
  const c = [n >> 16, (n >> 8) & 255, n & 255].map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; });
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
};
const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
const contrast = {};
for (const skin of SKINS) {
  for (const width of [1280, 390]) {
    await run('render ' + skin + ' ' + width, { session: { id: 'u2', email: 'ult@example.com' }, routes: routes('ultimate'), viewport: { width, height: width < 500 ? 844 : 900 } }, async (page) => {
      await page.waitForFunction(() => document.querySelectorAll('#tableBody tr:not(.sk-row)').length === 3, null, { timeout: 8000 });
      await planOk(page);
      assert.equal(await theme(page), skin);
      if (width === 1280) {
        const t = await page.evaluate(() => Object.fromEntries(['--bg', '--panel', '--panel2', '--chalk', '--steel', '--steel-dim', '--surge', '--drop', '--gilt', '--on-gilt', '--accent', '--on-accent', '--ka-match', '--ka-close', '--ka-on']
          .map((n) => [n, getComputedStyle(document.documentElement).getPropertyValue(n).trim()])));
        for (const [k, v] of Object.entries(t)) assert.match(v, /^#[0-9A-Fa-f]{6}$/, skin + ' ' + k + ' is a solid colour');
        const checks = {
          'chalk/bg': ratio(t['--chalk'], t['--bg']), 'chalk/panel': ratio(t['--chalk'], t['--panel']), 'chalk/panel2': ratio(t['--chalk'], t['--panel2']),
          'steel/bg': ratio(t['--steel'], t['--bg']), 'steel/panel': ratio(t['--steel'], t['--panel']),
          'steel-dim/bg': ratio(t['--steel-dim'], t['--bg']), 'steel-dim/panel': ratio(t['--steel-dim'], t['--panel']), 'steel-dim/panel2': ratio(t['--steel-dim'], t['--panel2']),
          'gilt/bg': ratio(t['--gilt'], t['--bg']), 'surge/panel': ratio(t['--surge'], t['--panel']), 'drop/panel': ratio(t['--drop'], t['--panel']),
          'on-gilt/gilt': ratio(t['--on-gilt'], t['--gilt']), 'on-accent/accent': ratio(t['--on-accent'], t['--accent']),
          'ka-on/match': ratio(t['--ka-on'], t['--ka-match']), 'ka-on/close': ratio(t['--ka-on'], t['--ka-close']),
        };
        // Every solid colour in the page background (its lightest and darkest stops).
        const pageStops = (await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--page-bg'))).match(/#[0-9A-Fa-f]{6}\b/g) || [];
        for (const c of pageStops) for (const k of ['--chalk', '--steel', '--steel-dim']) checks[k.slice(2) + '/page ' + c] = ratio(t[k], c);
        // Where the accent is used as text: sign-in modal links on the panel, the picker's tick on panel2.
        const rgbHex = (c) => '#' + c.match(/\d+/g).slice(0, 3).map((n) => (+n).toString(16).padStart(2, '0')).join('');
        const used = await page.evaluate(() => ({
          link: getComputedStyle(document.querySelector('.m-toggle a')).color,
          tick: (() => { const o = document.createElement('button'); o.className = 'theme-opt'; o.setAttribute('aria-checked', 'true'); document.getElementById('themeMenu').appendChild(o); const c = getComputedStyle(o, '::after').color; o.remove(); return c; })(),
        }));
        checks['accent-text link/panel'] = ratio(rgbHex(used.link), t['--panel']);
        checks['accent-text tick/panel2'] = ratio(rgbHex(used.tick), t['--panel2']);
        for (const [k, r] of Object.entries(checks)) assert.ok(r >= 4.5, `${skin} ${k} contrast ${r.toFixed(2)} < 4.5`);
        contrast[skin] = Object.fromEntries(Object.entries(checks).map(([k, r]) => [k, +r.toFixed(2)]));
        // Clue colours stay green and yellow.
        const hue = (hex) => { const n = parseInt(hex.slice(1), 16); const [r, g, b] = [n >> 16, (n >> 8) & 255, n & 255]; const mx = Math.max(r, g, b), mn = Math.min(r, g, b); if (mx === mn) return 0; let h = mx === r ? (g - b) / (mx - mn) : mx === g ? 2 + (b - r) / (mx - mn) : 4 + (r - g) / (mx - mn); return ((h * 60) + 360) % 360; };
        assert.ok(hue(t['--ka-match']) > 90 && hue(t['--ka-match']) < 160, skin + ' match is green');
        assert.ok(hue(t['--ka-close']) > 35 && hue(t['--ka-close']) < 60, skin + ' close is yellow');
      }
      // Nothing sticks out sideways on a phone.
      assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), 'no sideways scroll');
      if (SHOTS) {
        fs.mkdirSync(SHOTS, { recursive: true });
        // Real web fonts for the screenshots (the harness stubs them out).
        const UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';
        await page.route(/fonts\.(googleapis|gstatic)\.com/, (r) => {
          const u = r.request().url();
          let body = '';
          try { body = execFileSync('curl', ['-s', '--max-time', '20', '-A', UA, u]); } catch (e) {}
          return r.fulfill({ status: 200, headers: { 'access-control-allow-origin': '*' }, contentType: u.includes('gstatic') ? 'font/woff2' : 'text/css', body });
        });
        await page.evaluate(() => { const l = document.getElementById('themeFonts'); l.href += '&v=shot'; });
        await page.waitForTimeout(1500);
        await page.evaluate(() => document.fonts && document.fonts.ready);
        await page.screenshot({ path: path.join(SHOTS, `${skin}-${width}.png`) });
        await page.locator('#explorer').scrollIntoViewIfNeeded();
        await page.waitForTimeout(700);
        await page.screenshot({ path: path.join(SHOTS, `${skin}-${width}-table.png`) });
        await page.locator('#pro').scrollIntoViewIfNeeded();
        await page.waitForTimeout(700);
        await page.screenshot({ path: path.join(SHOTS, `${skin}-${width}-plans.png`) });
      }
    }, { savedTheme: skin });
  }
}
if (process.env.SKIN_CONTRAST) console.log(JSON.stringify(contrast, null, 1));
console.log('ok');
