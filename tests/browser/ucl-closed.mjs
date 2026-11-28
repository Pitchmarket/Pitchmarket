// Champions League stages on the page: knocked-out and winning clubs are
// closed (no Trade, no Sell, a label instead), cash-outs and refunds show in
// the bell, and the market still loads before the migration has run.
import assert from 'node:assert/strict';
import { openPage, withStatus } from './harness.mjs';

const URL_ = 'http://127.0.0.1:8765/index.html';
const USER = { id: 'u1', email: 'fan@example.com' };
const cl = (id, name, price, over = {}) => ({ id, name, league: 'championsleague', league_label: 'Champions League', tier: 'UCL',
  price, chg: 0, league_order: 6, closed: false, ucl_stage: 'quarters', ...over });
const TEAMS = [
  cl(1, 'Open FC', 120),
  cl(2, 'Out United', 0, { closed: true, ucl_stage: 'out', chg: -100 }),
  cl(3, 'Winners Athletic', 150, { closed: true, ucl_stage: 'winners' }),
];
const teamOf = (t) => ({ name: t.name, tier: t.tier, league_label: t.league_label, price: t.price, chg: t.chg });
const NOTIFS = [
  { id: 1, team_id: 3, kind: 'cashout', threshold: 25, price: 12.5, team_name: 'Winners Athletic', read: false, created_at: new Date().toISOString() },
  { id: 2, team_id: 4, kind: 'refund', threshold: 4, price: 7.25, team_name: 'Not Qualified', read: false, created_at: new Date().toISOString() },
];
const signedIn = (over = {}) => ({
  teams: () => TEAMS,
  profiles: () => ({ coin_balance: 2000, display_name: 'Fan' }),
  'rpc/my_plan': () => ({ tier: 'pro', source: 'stripe', has_subscription: true }),
  holdings: () => [{ shares: 10, team_id: 2, teams: teamOf(TEAMS[1]) }, { shares: 5, team_id: 1, teams: teamOf(TEAMS[0]) }],
  trades: () => [{ team_id: 2, side: 'buy', qty: 10, price: 50 }],
  watchlist: () => [{ id: 9, team_id: 2, alert_below: null, alert_above: null, teams: teamOf(TEAMS[1]) }],
  notifications: () => NOTIFS,
  ...over,
});

const text = (page, sel) => page.$eval(sel, (el) => el.textContent.replace(/\s+/g, ' ').trim());
const rowOf = (page, name) => page.locator('#tableBody tr', { hasText: name });

async function run(name, opts, fn, allow = /^$/) {
  const { page, errors, browser } = await openPage(URL_, opts);
  try {
    await page.waitForFunction(() => document.querySelectorAll('#tableBody tr:not(.sk-row)').length >= 1, null, { timeout: 8000 });
    await fn(page);
    assert.deepEqual(errors.filter((e) => !allow.test(e)), [], 'page errors');
  } catch (e) { e.message = name + ': ' + e.message; throw e; }
  finally { await browser.close(); }
}

// 1. closedLabel itself.
await run('closedLabel', { routes: { teams: () => TEAMS } }, async (page) => {
  const labels = await page.evaluate(() => [
    closedLabel({ closed: true, ucl_stage: 'out' }), closedLabel({ closed: true, ucl_stage: 'winners' }),
    closedLabel({ closed: true, ucl_stage: 'refunded' }), closedLabel({ closed: true, ucl_stage: null }),
    closedLabel({ closed: false, ucl_stage: 'quarters' }), closedLabel({}),
  ]);
  assert.deepEqual(labels, ['Out', 'Winners 🏆', 'Closed', 'Closed', null, null]);
});

// 2. Signed in on a desktop: market, portfolio, watchlist, bell.
await run('desktop', { session: USER, routes: signedIn() }, async (page) => {
  await page.waitForFunction(() => document.querySelectorAll('#tableBody tr').length === 3, null, { timeout: 8000 });
  // Open club: still has Trade.
  const open = rowOf(page, 'Open FC');
  assert.equal(await open.locator('.buy-btn:not([disabled])').count(), 1, 'open club tradable');
  assert.equal((await open.locator('.buy-btn').textContent()).trim(), 'Trade');
  // Out club: price 0.00, label, disabled button with the reason.
  const out = rowOf(page, 'Out United');
  assert.equal(await out.locator('.buy-btn:not([disabled])').count(), 0, 'no enabled trade on out club');
  assert.equal(await out.locator('.buy-btn[data-id]').count(), 0, 'no trade data on out club');
  assert.match(await out.textContent(), /0\.00/);
  assert.equal((await out.locator('.closed-tag').textContent()).trim(), 'Out');
  const outBtn = out.locator('.buy-btn');
  assert.equal((await outBtn.textContent()).trim(), 'Out');
  assert.ok(await outBtn.isDisabled());
  assert.match(await outBtn.getAttribute('title'), /^Trading has closed: /);
  // Winners club.
  const win = rowOf(page, 'Winners Athletic');
  assert.equal(await win.locator('.buy-btn:not([disabled])').count(), 0, 'no enabled trade on winners');
  assert.equal((await win.locator('.buy-btn').textContent()).trim(), 'Winners 🏆');
  assert.match(await win.textContent(), /Winners 🏆/);
  // Clicking the disabled button, or opening the trade box by hand, does nothing.
  await outBtn.click({ force: true });
  await page.evaluate(() => openTrade(2, 'Out United', 0));
  assert.equal(await page.locator('#tradeOverlay.open').count(), 0, 'trade box stays shut for a closed club');

  // Portfolio: the out club stays with 0.00 and no Sell; the open club keeps Sell.
  await page.waitForFunction(() => document.querySelectorAll('#portfolioBody tr').length === 2, null, { timeout: 8000 });
  const pfOut = page.locator('#portfolioBody tr', { hasText: 'Out United' });
  assert.equal(await pfOut.locator('.sell-btn').count(), 0, 'no sell on out club');
  assert.equal((await pfOut.locator('td').nth(4).textContent()).trim(), '0.00', 'value 0.00');
  assert.equal((await pfOut.locator('td').nth(3).textContent()).trim(), '0.00', 'price 0.00');
  assert.match(await pfOut.textContent(), /Out/);
  assert.equal(await page.locator('#portfolioBody tr', { hasText: 'Open FC' }).locator('.sell-btn').count(), 1, 'open club keeps Sell');

  // Watchlist card shows the label.
  await page.waitForSelector('.wl-card[data-team="2"]', { timeout: 8000 });
  assert.equal((await page.locator('.wl-card[data-team="2"] .closed-tag').textContent()).trim(), 'Out');

  // Bell: cash-out and refund messages with totals.
  await page.waitForFunction(() => document.querySelectorAll('#notifList .notif-item').length === 2, null, { timeout: 8000 });
  const items = await page.$$eval('#notifList .notif-detail', (els) => els.map((e) => e.textContent.replace(/\s+/g, ' ').trim()));
  assert.equal(items[0], 'Champions League winners! 25 shares paid out at 12.50 each (+312.50 coins)');
  assert.equal(items[1], "Not in this season's Champions League: 4 shares refunded at 7.25 each (+29.00 coins)");
});

// 3. A trade the database refuses shows its message in the trade box.
await run('trade refused', { session: USER, routes: signedIn({
  'rpc/trade': () => withStatus(400, { code: 'P0001', message: 'Trading on this club has closed.' }),
}) }, async (page) => {
  await page.waitForFunction(() => document.querySelectorAll('#tableBody tr').length === 3, null, { timeout: 8000 });
  await rowOf(page, 'Open FC').locator('.buy-btn').click();
  await page.waitForSelector('#tradeOverlay.open', { timeout: 8000 });
  await page.waitForFunction(() => !document.getElementById('tradeSubmit').disabled, null, { timeout: 8000 });
  await page.click('#tradeSubmit');
  await page.waitForFunction(() => /Trading on this club has closed\./.test(document.getElementById('tradeMsg').textContent), null, { timeout: 8000 });
}, /status of 400/);

// 4. Before the migration: the select with closed fails, the page retries without it.
{
  const selects = [];
  await run('before migration', { routes: { teams: (req) => {
    const sel = new URL(req.url()).searchParams.get('select');
    selects.push(sel);
    if (/closed|ucl_stage/.test(sel)) return withStatus(400, { code: '42703', message: 'column teams.closed does not exist', details: null, hint: null });
    return TEAMS.map(({ closed, ucl_stage, ...t }) => t);
  } } }, async (page) => {
    await page.waitForFunction(() => document.querySelectorAll('#tableBody tr').length === 3, null, { timeout: 8000 });
    assert.equal(await page.locator('#tableBody .buy-btn:not([disabled])').count(), 3, 'every club open');
    assert.equal(await page.locator('#tableBody .closed-tag').count(), 0);
    assert.equal(selects.length, 2, 'one retry');
    assert.match(selects[0], /closed,ucl_stage/);
    assert.ok(!/closed/.test(selects[1]));
  }, /status of 400/);
}

// 5. Phones: the label and disabled button fit, and tapping a closed club opens nothing.
for (const width of [390, 360]) {
  await run('phone ' + width, { session: USER, viewport: { width, height: 844 }, routes: signedIn() }, async (page) => {
    await page.waitForFunction(() => document.querySelectorAll('#tableBody tr').length === 3, null, { timeout: 8000 });
    await page.waitForFunction(() => document.querySelectorAll('#portfolioBody tr').length === 2, null, { timeout: 8000 });
    await page.waitForSelector('.wl-card[data-team="2"]', { timeout: 8000 });
    assert.ok(await rowOf(page, 'Winners Athletic').locator('.buy-btn').isVisible(), 'winners button visible on phone');
    assert.ok(await rowOf(page, 'Out United').locator('.buy-btn').isVisible(), 'out button visible on phone');
    const over = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    assert.equal(over, 0, 'no horizontal scroll');
    const fits = await page.$$eval('#tableBody tr', (rows) => rows.every((r) => r.getBoundingClientRect().right <= innerWidth));
    assert.ok(fits, 'rows fit the screen');
    await rowOf(page, 'Out United').locator('.team-name').click();
    assert.equal(await page.locator('#tradeOverlay.open').count(), 0, 'tapping a closed club opens nothing');
    await rowOf(page, 'Open FC').locator('.team-name').click();
    await page.waitForSelector('#tradeOverlay.open', { timeout: 8000 });
  });
}

console.log('ok');
