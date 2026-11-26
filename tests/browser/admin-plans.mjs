// Admin "Plans & Payments" tab: payments settings, manual grants, revokes.
import assert from 'node:assert/strict';
import { openPage } from './harness.mjs';

const URL_ = 'http://127.0.0.1:8765/admin.html';
const ADMIN = { id: 'a1', email: 'pitchmarketadmin@gmail.com' };
const LIVE_MSG = 'Live mode takes real payments. Only switch once the Stripe account is activated and the live links are pasted.';
const PAYMENTS = { mode: 'test', portal_url: 'https://billing.stripe.com/p/login/test', links: { pro_monthly: 'https://buy.stripe.com/test_old' }, extra: 'kept' };
const PLANS = [
  { user_id: 'u-grant', email: 'friend@example.com', display_name: 'Friend <b>x</b>', tier: 'pro', source: 'grant', until: '2026-12-31T23:59:59Z', note: 'Beta tester', has_grant: true, grant_tier: 'pro', grant_until: '2026-12-31T23:59:59Z' },
  { user_id: 'u-paid', email: 'payer@example.com', display_name: 'Payer', tier: 'ultimate', source: 'stripe', until: '2026-12-20T10:00:00Z', note: null, has_grant: false, grant_tier: null, grant_until: null },
  // A subscriber who also has a grant with no note: Revoke must still show.
  { user_id: 'u-both', email: 'both@example.com', display_name: 'Both', tier: 'ultimate', source: 'stripe', until: '2026-12-22T10:00:00Z', note: null, has_grant: true, grant_tier: 'pro', grant_until: null },
];

function setup(state) {
  return {
    site_settings: (req) => {
      if (req.method() === 'POST') { state.upserts.push(req.postDataJSON()); return []; }
      return [{ key: 'payments', value: PAYMENTS }];
    },
    'rpc/admin_list_plans': () => PLANS,
    'rpc/admin_grant_plan': (req) => {
      const b = req.postDataJSON();
      state.grants.push(b);
      if (b.p_email === 'nobody@example.com') throw new Error('No player with that email.');
      return null;
    },
    'rpc/admin_revoke_grant': (req) => { state.revokes.push(req.postDataJSON()); return null; },
  };
}

async function run(name, fn, viewport, { failedLoads = 0 } = {}) {
  const state = { upserts: [], grants: [], revokes: [], dialogs: [] };
  const { page, errors, browser } = await openPage(URL_, { session: ADMIN, routes: setup(state), viewport });
  try {
    await page.click('.section-tab[data-pane="plansPane"]');
    await page.waitForFunction(() => document.querySelectorAll('#plansTable tbody tr').length === 3, null, { timeout: 8000 });
    await page.waitForFunction(() => document.querySelector('#payLinks [data-link="pro_monthly"]')?.value === 'https://buy.stripe.com/test_old', null, { timeout: 8000 });
    await fn(page, state);
    // A stubbed RPC error shows as one failed resource load in the console.
    const failed = errors.filter((e) => e.includes('Failed to load resource'));
    assert.equal(failed.length, failedLoads, 'failed loads');
    assert.deepEqual(errors.filter((e) => !failed.includes(e)), [], 'page errors');
  } catch (e) { e.message = name + ': ' + e.message; throw e; }
  finally { await browser.close(); }
}

// 1. Payments form: Live without confirming keeps the mode; save sends the links.
await run('payments form', async (page, state) => {
  assert.ok(await page.isChecked('input[name="payMode"][value="test"]'), 'loaded mode');
  page.once('dialog', (d) => { state.dialogs.push(d.message()); d.dismiss(); });
  await page.check('input[name="payMode"][value="live"]').catch(() => {});
  await page.waitForTimeout(100);
  assert.deepEqual(state.dialogs, [LIVE_MSG], 'live asks first');
  assert.ok(await page.isChecked('input[name="payMode"][value="test"]'), 'still test after cancel');
  assert.ok(!(await page.isChecked('input[name="payMode"][value="live"]')));

  // A bad link: inline message, nothing saved.
  await page.fill('#payLinks [data-link="pro_yearly"]', 'http://buy.stripe.com/insecure');
  await page.click('#savePaymentsBtn');
  await page.waitForTimeout(150);
  assert.equal(state.upserts.length, 0, 'not saved with bad link');
  assert.match(await page.textContent('#payLinks'), /https:\/\//);

  const links = {
    pro_monthly: 'https://buy.stripe.com/pm',
    pro_yearly: 'https://buy.stripe.com/py',
    ultimate_monthly: 'https://buy.stripe.com/um',
    ultimate_yearly: '',
  };
  for (const [k, v] of Object.entries(links)) await page.fill('#payLinks [data-link="' + k + '"]', v);
  await page.fill('#payPortal', 'https://billing.stripe.com/p/login/new');
  await page.click('#savePaymentsBtn');
  await page.waitForFunction(() => /Saved/.test(document.getElementById('payStatus').textContent), null, { timeout: 8000 });
  assert.equal(state.upserts.length, 1);
  const up = state.upserts[0];
  assert.equal(up.key, 'payments');
  assert.equal(up.value.mode, 'test', 'mode unchanged');
  assert.deepEqual(up.value.links, links);
  assert.equal(up.value.portal_url, 'https://billing.stripe.com/p/login/new');
  assert.equal(up.value.extra, 'kept', 'other keys kept');

  // Confirming Live switches it.
  page.once('dialog', (d) => d.accept());
  await page.check('input[name="payMode"][value="live"]');
  await page.click('#savePaymentsBtn');
  await page.waitForTimeout(200);
  assert.equal(state.upserts.at(-1).value.mode, 'live');
});

// 2. Grants table, grant form and revoke.
await run('grants', async (page, state) => {
  const rows = await page.$$eval('#plansTable tbody tr', (trs) => trs.map((t) => t.textContent));
  assert.match(rows[0], /Friend <b>x<\/b>/, 'names escaped as text');
  assert.match(rows[0], /friend@example\.com/);
  assert.match(rows[0], /Beta tester/);
  assert.equal(await page.locator('#plansTable b').count(), 0);
  assert.equal(await page.locator('#plansTable tbody tr:nth-child(1) .revoke-btn').count(), 1, 'grant row has Revoke');
  assert.equal(await page.locator('#plansTable tbody tr:nth-child(2) .revoke-btn').count(), 0, 'paid row has no Revoke');
  assert.equal(await page.locator('#plansTable tbody tr:nth-child(3) .revoke-btn').count(), 1, 'subscriber with a grant has Revoke');
  assert.match(rows[2], /Subscription/);
  assert.match(rows[2], /Pro grant, no end/, 'grant shown apart from the plan');
  assert.ok(!/grant/i.test(rows[1]), 'no grant line without a grant');

  // Grant with an end date: end of that day, local time.
  await page.fill('#grantEmail', 'new@example.com');
  await page.selectOption('#grantTier', 'ultimate');
  await page.fill('#grantUntil', '2027-01-15');
  await page.fill('#grantNote', 'Prize winner');
  await page.click('#grantBtn');
  await page.waitForFunction(() => /Granted/.test(document.getElementById('grantStatus').textContent), null, { timeout: 8000 });
  const g = state.grants[0];
  assert.equal(g.p_email, 'new@example.com');
  assert.equal(g.p_tier, 'ultimate');
  assert.equal(g.p_note, 'Prize winner');
  const expected = await page.evaluate(() => new Date(2027, 0, 15, 23, 59, 59, 999).toISOString());
  assert.equal(g.p_until, expected);

  // No end date -> null; an RPC error is shown.
  await page.fill('#grantEmail', 'nobody@example.com');
  await page.fill('#grantUntil', '');
  await page.click('#grantBtn');
  await page.waitForFunction(() => document.getElementById('grantStatus').classList.contains('err'), null, { timeout: 8000 });
  assert.equal(state.grants[1].p_until, null);
  assert.equal(state.grants[1].p_tier, 'ultimate');
  assert.match(await page.textContent('#grantStatus'), /No player with that email\./);

  // Revoke: confirm, then the RPC with the row's user id.
  page.once('dialog', (d) => { state.dialogs.push(d.message()); d.accept(); });
  await page.click('#plansTable tbody tr:nth-child(1) .revoke-btn');
  await page.waitForTimeout(200);
  assert.equal(state.dialogs.length, 1);
  assert.deepEqual(state.revokes, [{ p_user: 'u-grant' }]);
}, undefined, { failedLoads: 1 });

// 3. Pro editor: eyebrow/title/desc and prices only; other keys kept on save.
await run('pro editor', async (page, state) => {
  await page.click('.section-tab[data-pane="contentPane"]');
  const ed = '#proEditor';
  assert.equal(await page.locator(ed + ' .pro-feats, ' + ed + ' .add-feat-btn, ' + ed + ' [data-f="checkout_url"], ' + ed + ' [data-f="cta"], ' + ed + ' #addPlanBtn, ' + ed + ' .remove-x').count(), 0, 'no features, CTA, links, add or remove');
  assert.match(await page.textContent(ed), /Plans & Payments/);
  await page.locator(ed + ' .pro-card-prev').nth(1).locator('[data-f="price"]').fill('$2.49');
  await page.click('.editor-block[data-key="pro"] .editor-save');
  await page.waitForFunction(() => /Saved/.test(document.querySelector('.editor-block[data-key="pro"] .editor-status').textContent), null, { timeout: 8000 });
  const v = state.upserts.at(-1).value;
  assert.equal(state.upserts.at(-1).key, 'pro');
  assert.equal(v.plans.length, 5);
  assert.equal(v.plans[1].price, '$2.49');
  assert.equal(v.plans[1].tier, 'Pro');
  assert.ok(v.plans[1].feats.length > 0, 'features kept');
  assert.ok('checkout_url' in v.plans[1] && 'cta' in v.plans[1], 'cta and link kept');
});

// 4. Phone width: no sideways scroll on the tab.
await run('phone', async (page) => {
  const over = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  assert.ok(over <= 0, 'no sideways scroll (' + over + 'px)');
}, { width: 390, height: 844 });

console.log('ok');
