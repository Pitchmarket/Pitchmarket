// Plan cards, buy / change-plan buttons, plan state, caps and badges.
import assert from 'node:assert/strict';
import { openPage } from './harness.mjs';

const URL_ = 'http://127.0.0.1:8765/index.html';
const LINKS = {
  pro_monthly: 'https://buy.stripe.com/test_pro_m?ref=site',
  pro_yearly: 'https://buy.stripe.com/test_pro_y',
  ultimate_monthly: 'https://buy.stripe.com/test_ult_m',
  ultimate_yearly: 'https://buy.stripe.com/test_ult_y',
};
const settings = (payments) => () => [{ key: 'payments', value: payments }];
const USER = { id: 'u1', email: 'fan@example.com' };
const profile = () => ({ coin_balance: 2000, display_name: 'Fan', is_pro: true, is_ultimate: true, pro_expires_at: null });
const PAID = '.pro-card[data-plan]:not([data-plan="free"]) .pro-btn';

async function run(name, opts, fn, { allowErrors = false } = {}) {
  const { page, errors, browser } = await openPage(URL_, opts);
  try {
    await page.waitForFunction(() => document.querySelectorAll('#proGrid .pro-card[data-plan]').length === 5, null, { timeout: 8000 });
    await fn(page);
    if (!allowErrors) assert.deepEqual(errors, [], name + ': page errors');
    else assert.deepEqual(errors.filter((e) => e.startsWith('pageerror')), [], name + ': page errors');
  } catch (e) { e.message = name + ': ' + e.message; throw e; }
  finally { await browser.close(); }
}
const texts = (page, sel) => page.$$eval(sel, (els) => els.map((e) => e.textContent.trim()));

// 1. Signed out: buy buttons ask to sign in and open the sign-in box.
await run('signed out', { routes: { site_settings: settings({ mode: 'test', portal_url: '', links: LINKS }) } }, async (page) => {
  await page.waitForFunction(() => document.querySelector('.pro-card[data-plan="pro_monthly"] .pro-btn').textContent.includes('Sign in to upgrade'), null, { timeout: 8000 });
  assert.deepEqual(await texts(page, PAID), Array(4).fill('Sign in to upgrade'));
  await page.click('.pro-card[data-plan="pro_monthly"] .pro-btn');
  assert.ok(await page.locator('#authOverlay.open').count(), 'auth box opens');
  // Honest features on the Ultimate card
  const ult = await texts(page, '.pro-card[data-plan="ultimate_monthly"] .pro-feats li');
  assert.ok(ult.some((t) => t.includes('15 watchlist slots')), 'ultimate has 15 slots');
  for (const old of ['Custom dashboards', 'Market simulations']) assert.ok(!(await page.textContent('#proGrid')).includes(old), 'no old feature ' + old);
  assert.ok(ult.some((t) => t.includes('Weekly AI recap') && t.includes('Coming soon')), 'coming soon tag');
  const free = await texts(page, '.pro-card[data-plan="free"] .pro-feats li');
  assert.ok(free.some((t) => t.includes('2 watchlist slots')));
});

// 2. Signed-in free player, test mode, links set.
await run('free player', {
  session: USER,
  routes: {
    site_settings: settings({ mode: 'test', portal_url: 'https://billing.stripe.com/p/login/test', links: LINKS }),
    profiles: profile,
    'rpc/my_plan': () => ({ tier: 'free', source: 'free', has_subscription: false }),
    watchlist: () => [],
  },
}, async (page) => {
  await page.waitForFunction(() => /client_reference_id=u1/.test(document.querySelector('.pro-card[data-plan="pro_monthly"] a.pro-btn')?.href || ''), null, { timeout: 8000 });
  const href = await page.getAttribute('.pro-card[data-plan="pro_monthly"] a.pro-btn', 'href');
  const u = new URL(href);
  assert.equal(u.searchParams.get('client_reference_id'), 'u1');
  assert.equal(u.searchParams.get('prefilled_email'), 'fan@example.com');
  assert.equal(u.searchParams.get('ref'), 'site', 'keeps existing query');
  assert.ok(href.startsWith('https://buy.stripe.com/test_pro_m'));
  assert.ok(await page.isVisible('#planTestNote'), 'test note visible');
  assert.match(await page.textContent('#planTestNote'), /4242 4242 4242 4242/);
  assert.equal((await page.textContent('.pro-card[data-plan="free"] .pro-btn')).trim(), 'Your plan');
  // Profiles flags are ignored: the plan comes from my_plan.
  await page.waitForFunction(() => document.getElementById('wlPlanTag').textContent === 'FREE', null, { timeout: 8000 });
  assert.match(await page.textContent('#wlSlotText'), /\/ 2 slots/);
  assert.ok(!(await page.isVisible('#proBadge')));
  assert.ok(!(await page.isVisible('#manageSubLink')));
  assert.ok(!(await page.isVisible('#proManageLink')));
});

// 3. Pro subscriber.
await run('pro subscriber', {
  session: USER,
  routes: {
    site_settings: settings({ mode: 'test', portal_url: 'https://billing.stripe.com/p/login/test', links: LINKS }),
    profiles: profile,
    'rpc/my_plan': () => ({ tier: 'pro', source: 'stripe', has_subscription: true, test: true }),
    watchlist: () => [],
  },
}, async (page) => {
  await page.waitForFunction(() => document.querySelector('.pro-card[data-plan="pro_monthly"] .pro-btn').textContent.trim() === 'Your plan', null, { timeout: 8000 });
  assert.deepEqual(await texts(page, PAID), ['Your plan', 'Your plan', 'Change plan', 'Change plan']);
  assert.equal(await page.getAttribute('.pro-card[data-plan="ultimate_monthly"] a.pro-btn', 'href'), 'https://billing.stripe.com/p/login/test');
  await page.waitForFunction(() => document.getElementById('wlPlanTag').textContent === 'PRO', null, { timeout: 8000 });
  assert.match(await page.textContent('#wlSlotText'), /\/ 5 slots/);
  for (const id of ['adTopBanner', 'adNativeBanner']) assert.ok(!(await page.isVisible('#' + id)), id + ' hidden');
  assert.ok(await page.isVisible('#proBadge'));
  assert.equal((await page.textContent('#proBadge')).trim(), 'PRO');
  assert.ok(await page.isVisible('#manageSubLink'));
  assert.equal(await page.getAttribute('#manageSubLink', 'href'), 'https://billing.stripe.com/p/login/test');
  assert.ok(await page.isVisible('#proManageLink'), 'manage link under the plans');
  assert.equal(await page.getAttribute('#proManageLink', 'href'), 'https://billing.stripe.com/p/login/test');
});

// 4. Payments off: every buy button says Coming soon; ULTIMATE badge on leaderboard.
await run('mode off', {
  routes: {
    site_settings: settings({ mode: 'off', portal_url: '', links: LINKS }),
    'rpc/get_leaderboard': () => [
      { display_name: 'Ulti', portfolio_value: 3000, tier: 'ultimate' },
      { display_name: 'Pro <b>x</b>', portfolio_value: 2500, tier: 'pro' },
      { display_name: 'Freebie', portfolio_value: 2000, tier: 'free' },
    ],
  },
}, async (page) => {
  await page.waitForFunction(() => document.querySelector('.pro-card[data-plan="pro_monthly"] .pro-btn').textContent.trim() === 'Coming soon', null, { timeout: 8000 });
  assert.deepEqual(await texts(page, PAID), Array(4).fill('Coming soon'));
  assert.equal(await page.locator('#proGrid a.pro-btn').count(), 0, 'no links when off');
  assert.ok(!(await page.isVisible('#planTestNote')), 'no test note when off');
  await page.waitForFunction(() => document.querySelectorAll('#leaderboardBody tr').length === 3, null, { timeout: 8000 });
  const rows = await texts(page, '#leaderboardBody tr');
  assert.match(rows[0], /Ulti\s*ULTIMATE/);
  assert.match(rows[1], /PRO/);
  assert.ok(!/PRO|ULTIMATE/.test(rows[2]));
  assert.equal(await page.locator('#leaderboardBody b').count(), 0, 'names escaped');
});

// 5. Phones: missing / non-http links -> Coming soon, manage link visible, no sideways scroll.
for (const width of [390, 320]) {
  await run('phone ' + width, {
    viewport: { width, height: 844 },
    session: USER,
    routes: {
      site_settings: settings({ mode: 'test', portal_url: 'https://billing.stripe.com/p/login/test', links: { pro_monthly: LINKS.pro_monthly, ultimate_yearly: 'javascript:alert(1)' } }),
      profiles: profile,
      'rpc/my_plan': () => ({ tier: 'free', source: 'grant', has_subscription: true }),
      watchlist: () => [],
    },
  }, async (page) => {
    await page.waitForFunction(() => document.getElementById('proManageLink').style.display !== 'none', null, { timeout: 8000 });
    await page.locator('#proManageLink').scrollIntoViewIfNeeded();
    assert.ok(await page.isVisible('#proManageLink'), 'manage link visible on phone');
    assert.ok(!(await page.isVisible('#manageSubLink')), 'nav one hidden on phone (account area hidden)');
    assert.deepEqual(await texts(page, PAID), Array(4).fill('Change plan'));
    await page.waitForTimeout(300);
    // Nothing sticks out past the screen edge (outside a scrolling or
    // clipping box). Chart canvases are skipped: the harness stubs Chart.js,
    // so they keep the browser's default 300px width instead of fitting.
    const wide = await page.evaluate(() => [...document.querySelectorAll('body *')].filter((el) => {
      if (el.tagName === 'CANVAS') return false;
      const r = el.getBoundingClientRect();
      if (!r.width || r.right <= innerWidth + 0.5 || getComputedStyle(el).position === 'fixed') return false;
      for (let a = el.parentElement; a && a !== document.body; a = a.parentElement) {
        const cs = getComputedStyle(a);
        if (cs.overflowX !== 'visible' || cs.position === 'fixed') return false;
      }
      return true;
    }).map((el) => el.tagName + '#' + el.id + '.' + el.className));
    assert.deepEqual(wide, [], 'page not wider than the screen');
    const pro = await page.evaluate(() => document.getElementById('pro').scrollWidth <= innerWidth);
    assert.ok(pro, 'plans section fits');
    if (process.env.SHOT) await page.locator('#pro').screenshot({ path: process.env.SHOT.replace(/\.png$/, '-' + width + '.png') });
  });
}
await run('missing links', {
  session: USER,
  routes: {
    site_settings: settings({ mode: 'test', portal_url: '', links: { pro_monthly: LINKS.pro_monthly, ultimate_yearly: 'javascript:alert(1)' } }),
    profiles: profile,
    'rpc/my_plan': () => ({ tier: 'free', source: 'free', has_subscription: false }),
    watchlist: () => [],
  },
}, async (page) => {
  await page.waitForFunction(() => !!document.querySelector('.pro-card[data-plan="pro_monthly"] a.pro-btn'), null, { timeout: 8000 });
  assert.equal((await page.textContent('.pro-card[data-plan="pro_yearly"] .pro-btn')).trim(), 'Coming soon');
  assert.equal((await page.textContent('.pro-card[data-plan="ultimate_yearly"] .pro-btn')).trim(), 'Coming soon', 'non-http link refused');
});

// 6. my_plan slow: buttons idle until it replies, then correct.
let release;
const gate = new Promise((r) => { release = r; });
await run('my_plan delayed', {
  session: USER,
  routes: {
    site_settings: settings({ mode: 'test', portal_url: '', links: LINKS }),
    profiles: profile,
    'rpc/my_plan': async () => { await gate; return { tier: 'free', source: 'free', has_subscription: false }; },
    watchlist: () => [],
  },
}, async (page) => {
  await page.waitForFunction(() => document.querySelector('#authBtn').textContent === 'Sign out', null, { timeout: 8000 });
  await page.waitForTimeout(500);
  assert.deepEqual(await texts(page, PAID), Array(4).fill('Checking your plan…'));
  assert.equal(await page.locator('a[href*="buy.stripe.com"]').count(), 0, 'no checkout link while checking');
  assert.equal((await page.textContent('.pro-card[data-plan="free"] .pro-btn')).trim(), 'Free to play');
  release();
  await page.waitForFunction(() => !!document.querySelector('.pro-card[data-plan="pro_monthly"] a.pro-btn'), null, { timeout: 8000 });
  assert.equal((await page.textContent('.pro-card[data-plan="free"] .pro-btn')).trim(), 'Your plan');
});

// 7. my_plan fails: idle error label, no checkout link anywhere; profiles failing too doesn't stop the plan check.
await run('my_plan fails', {
  session: USER,
  routes: {
    site_settings: settings({ mode: 'test', portal_url: 'https://billing.stripe.com/p/login/test', links: LINKS }),
    profiles: () => { throw new Error('profiles down'); },
    'rpc/my_plan': () => { throw new Error('boom'); },
    watchlist: () => [],
  },
}, async (page) => {
  await page.waitForFunction(() => document.querySelector('.pro-card[data-plan="pro_monthly"] .pro-btn').textContent.startsWith("Couldn't"), null, { timeout: 8000 });
  assert.deepEqual(await texts(page, PAID), Array(4).fill("Couldn't check your plan, refresh to try again"));
  assert.equal(await page.locator('a[href*="buy.stripe.com"], a[href*="client_reference_id"]').count(), 0, 'no checkout href');
  assert.ok(!(await page.isVisible('#proManageLink')));
}, { allowErrors: true });

// 8. Switching player A -> B: back to unconfirmed until B's plan arrives.
let releaseB;
const gateB = new Promise((r) => { releaseB = r; });
let planCalls = 0;
await run('user switch', {
  session: USER,
  routes: {
    site_settings: settings({ mode: 'test', portal_url: 'https://billing.stripe.com/p/login/test', links: LINKS }),
    profiles: profile,
    'rpc/my_plan': async () => { planCalls++; if (planCalls === 1) return { tier: 'pro', source: 'stripe', has_subscription: true }; await gateB; return { tier: 'free', source: 'free', has_subscription: false }; },
    watchlist: () => [],
  },
}, async (page) => {
  await page.waitForFunction(() => document.querySelector('.pro-card[data-plan="pro_monthly"] .pro-btn').textContent.trim() === 'Your plan', null, { timeout: 8000 });
  // Player B signs in (as the Supabase client would report it).
  await page.evaluate(() => { const s = JSON.parse(JSON.stringify(currentSession)); s.user.id = 'u2'; s.user.email = 'b@example.com'; sb.auth._notifyAllSubscribers('SIGNED_IN', s); });
  await page.waitForFunction(() => document.querySelector('.pro-card[data-plan="pro_monthly"] .pro-btn').textContent.trim() === 'Checking your plan…', null, { timeout: 8000 });
  assert.equal(await page.locator('#proGrid a').count(), 0, 'nothing clickable while B is unconfirmed');
  assert.ok(!(await page.isVisible('#proBadge')), "A's badge gone");
  releaseB();
  await page.waitForFunction(() => /client_reference_id=u2/.test(document.querySelector('.pro-card[data-plan="pro_monthly"] a.pro-btn')?.href || ''), null, { timeout: 8000 });
});

// 9. A higher plan includes the lower one: Ultimate (grant or subscription)
// sees "Included in your plan" on the Pro cards, never a buy link.
for (const [label, plan] of [
  ['ultimate grant', { tier: 'ultimate', source: 'grant', has_subscription: false }],
  ['ultimate subscriber', { tier: 'ultimate', source: 'stripe', has_subscription: true }],
]) {
  await run(label, {
    session: USER,
    routes: {
      site_settings: settings({ mode: 'test', portal_url: 'https://billing.stripe.com/p/login/test', links: LINKS }),
      profiles: profile,
      'rpc/my_plan': () => plan,
      watchlist: () => [],
    },
  }, async (page) => {
    await page.waitForFunction(() => document.querySelector('.pro-card[data-plan="ultimate_monthly"] .pro-btn').textContent.trim() === 'Your plan', null, { timeout: 8000 });
    assert.deepEqual(await texts(page, PAID), ['Included in your plan', 'Included in your plan', 'Your plan', 'Your plan']);
    for (const key of ['pro_monthly', 'pro_yearly']) {
      assert.equal(await page.locator('.pro-card[data-plan="' + key + '"] a').count(), 0, key + ' has no link');
      assert.equal(await page.getAttribute('.pro-card[data-plan="' + key + '"] .pro-btn', 'aria-disabled'), 'true', key + ' idle');
    }
    assert.equal(await page.locator('a[href*="buy.stripe.com"]').count(), 0, 'no buy link');
  });
}

// 10. A missing or unknown payments mode reads as test, as in admin and SQL.
await run('unknown mode', { routes: { site_settings: settings({ mode: 'bogus', portal_url: '', links: LINKS }) } }, async (page) => {
  await page.waitForFunction(() => document.querySelector('.pro-card[data-plan="pro_monthly"] .pro-btn').textContent.includes('Sign in to upgrade'), null, { timeout: 8000 });
  assert.deepEqual(await texts(page, PAID), Array(4).fill('Sign in to upgrade'));
  assert.ok(await page.isVisible('#planTestNote'), 'test note shown');
});
await run('no mode', { routes: { site_settings: settings({ portal_url: '', links: LINKS }) } }, async (page) => {
  await page.waitForFunction(() => document.querySelector('.pro-card[data-plan="pro_monthly"] .pro-btn').textContent.includes('Sign in to upgrade'), null, { timeout: 8000 });
  assert.ok(await page.isVisible('#planTestNote'), 'test note shown');
});

console.log('ok');
