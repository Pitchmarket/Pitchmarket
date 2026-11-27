// Private leagues on the page: the My leagues tab, create / join, the league
// view (Classic table, Player of the week, members, code, owner settings).
import assert from 'node:assert/strict';
import { openPage } from './harness.mjs';

const URL_ = 'http://127.0.0.1:8765/index.html';
const USER = { id: 'u1', email: 'fan@example.com' };
const profile = () => ({ coin_balance: 2000, display_name: 'Fan' });
const plan = (tier) => () => ({ tier, source: tier === 'free' ? 'free' : 'stripe', has_subscription: tier !== 'free' });

const LIST = [
  { league_id: 1, name: 'Sunday <i>League</i>', type: 'classic', is_owner: true, member_count: 3, colour: null, emblem: null },
  { league_id: 2, name: 'Office', type: 'classic', is_owner: false, member_count: 12, colour: 'claret', emblem: 'trophy' },
];
const MEMBERS = [
  { member_id: 11, display_name: 'Fan', tier: 'ultimate', is_owner: true, joined_at: '2026-11-01T10:00:00Z' },
  { member_id: 12, display_name: '<b>Bold</b>', tier: 'pro', is_owner: false, joined_at: '2026-11-02T10:00:00Z' },
  { member_id: 13, display_name: 'Sam', tier: 'free', is_owner: false, joined_at: '2026-11-03T10:00:00Z' },
];
const detail = (over = {}) => ({ id: 1, name: 'Sunday <i>League</i>', type: 'classic', is_owner: true, invite_code: 'ABC234',
  colour: null, emblem: null, season_started: true, members: MEMBERS, ...over });
const TABLE = [
  { rank: 1, member_id: 12, display_name: '<b>Bold</b>', tier: 'pro', pct: 5.5 },
  { rank: 2, member_id: 11, display_name: 'Fan', tier: 'ultimate', pct: 1.25 },
  { rank: 2, member_id: 13, display_name: 'Sam', tier: 'free', pct: -0.4 },
];
const POTW = [
  { week_end: '2027-01-10', status: 'scored', winners: ['Fan', 'Sam'], pct: 3.21 },
  { week_end: '2027-01-03', status: 'void', winners: [], pct: null },
  { week_end: '2026-12-27', status: 'scored', winners: [], pct: null },
];

// Routes for a signed-in player; `log` collects every league RPC body.
function routes(tier, log, over = {}) {
  const rec = (name, reply) => async (req) => { log.push({ name, body: req.postDataJSON() }); return typeof reply === 'function' ? reply(req.postDataJSON()) : reply; };
  return {
    profiles: profile, watchlist: () => [], 'rpc/my_plan': plan(tier),
    'rpc/my_leagues': rec('my_leagues', LIST),
    'rpc/league_detail': rec('league_detail', detail()),
    'rpc/league_classic_table': rec('league_classic_table', TABLE),
    'rpc/league_player_of_week': rec('league_player_of_week', POTW),
    'rpc/create_league': rec('create_league', 1),
    'rpc/join_league': rec('join_league', 2),
    'rpc/kick_member': rec('kick_member', null),
    'rpc/set_league_branding': rec('set_league_branding', null),
    ...Object.fromEntries(Object.entries(over).map(([k, v]) => [k, rec(k.replace('rpc/', ''), v)])),
  };
}

// allow500: the test makes RPCs fail on purpose, so the browser logs them.
async function run(name, opts, fn, { allow500 = false } = {}) {
  const { page, errors, browser } = await openPage(URL_, opts);
  try {
    await page.waitForSelector('#lbTabLeagues', { timeout: 8000 });
    await fn(page);
    assert.deepEqual(errors.filter((e) => !(allow500 && /status of 500/.test(e))), [], 'page errors');
  } catch (e) { e.message = name + ': ' + e.message; throw e; }
  finally { await browser.close(); }
}
const texts = (page, sel) => page.$$eval(sel, (els) => els.map((e) => e.textContent.replace(/\s+/g, ' ').trim()));
const count = (log, n) => log.filter((c) => c.name === n).length;
async function openLeagues(page) {
  await page.click('#lbTabLeagues');
  assert.ok(await page.isVisible('#lgPanel'), 'leagues panel shown');
  assert.ok(!(await page.isVisible('#lbOverall')), 'overall hidden');
}
async function openLeague(page, id = 1) {
  await page.waitForSelector('.lg-item[data-league="' + id + '"]', { timeout: 8000 });
  await page.click('.lg-item[data-league="' + id + '"]');
  await page.waitForSelector('#lgTable tbody tr', { timeout: 8000 });
}

// 1. Signed out: no leagues loaded, a sign-in prompt.
await run('signed out', {}, async (page) => {
  assert.ok(await page.isVisible('#lbOverall'), 'overall shown first');
  assert.ok(!(await page.isVisible('#lgPanel')), 'leagues hidden first');
  await openLeagues(page);
  assert.match(await page.textContent('#lgPanel'), /Sign in to create or join a league/);
  await page.click('#lbTabOverall');
  assert.ok(await page.isVisible('#lbOverall'));
  await openLeagues(page);
  await page.click('#lgSignIn');
  assert.ok(await page.locator('#authOverlay.open').count(), 'auth box opens');
});

// 2. Free player: create locked with the Pro message, join works.
{
  const log = [];
  await run('free player', { session: USER, routes: routes('free', log, { 'rpc/league_detail': detail({ id: 2, name: 'Office', is_owner: false, invite_code: null }) }) }, async (page) => {
    await page.waitForTimeout(500);
    assert.equal(count(log, 'my_leagues'), 0, 'nothing loaded before the tab opens');
    await openLeagues(page);
    await page.waitForSelector('.lg-item', { timeout: 8000 });
    assert.equal(count(log, 'my_leagues'), 1);
    await page.waitForFunction(() => document.getElementById('lgCreateBtn').disabled && /Create leagues with Pro or Ultimate/.test(document.getElementById('lgCreate').textContent), null, { timeout: 8000 });
    assert.equal(await page.getAttribute('#lgCreateLock a', 'href'), '#pro');
    await page.fill('#lgJoinCode', 'abc234');
    await page.click('#lgJoinBtn');
    await page.waitForFunction(() => document.querySelector('#lgTable tbody tr'), null, { timeout: 8000 });
    const join = log.find((c) => c.name === 'join_league');
    assert.deepEqual(join.body, { p_code: 'abc234' });
    assert.equal(count(log, 'my_leagues'), 2, 'list refreshed after joining');
    // Non-owner: no Kick, no code, no settings, but can leave.
    assert.equal(await page.locator('.lg-kick').count(), 0, 'no kick for non-owner');
    assert.equal(await page.locator('#lgCode').count(), 0, 'no code for non-owner');
    assert.equal(await page.locator('#lgRenameInput').count(), 0, 'no settings for non-owner');
    assert.ok(await page.isVisible('#lgLeave'));
  });
}

// 3. Pro player creates a Classic league; H2H is "Coming soon".
{
  const log = [];
  await run('pro creates', { session: USER, routes: routes('pro', log) }, async (page) => {
    await openLeagues(page);
    await page.waitForFunction(() => !document.getElementById('lgCreateBtn').disabled, null, { timeout: 8000 });
    assert.ok(await page.isDisabled('input[name="lgType"][value="h2h"]'), 'H2H disabled');
    assert.ok(await page.isChecked('input[name="lgType"][value="classic"]'), 'Classic chosen');
    assert.match(await page.textContent('#lgCreate'), /Coming soon/);
    await page.fill('#lgCreateName', 'Five-a-side');
    await page.click('#lgCreateBtn');
    await page.waitForSelector('#lgTable tbody tr', { timeout: 8000 });
    assert.deepEqual(log.find((c) => c.name === 'create_league').body, { p_name: 'Five-a-side', p_type: 'classic' });
    // Pro owner: branding locked.
    assert.match(await page.textContent('#lgView'), /League branding comes with Ultimate/);
    assert.equal(await page.locator('.lg-colour').count(), 0, 'no picker for a Pro owner');
  });
}

// 4. Ultimate owner: the league view, kick, branding, list branding.
{
  const log = [];
  await run('ultimate owner', { session: USER, routes: routes('ultimate', log) }, async (page) => {
    await openLeagues(page);
    await page.waitForSelector('.lg-item[data-league="2"]', { timeout: 8000 });
    // List: names escaped, Owner tag, member count, branding.
    const items = await texts(page, '.lg-item');
    assert.match(items[0], /Sunday <i>League<\/i>/);
    assert.match(items[0], /Owner/);
    assert.match(items[0], /3 members/);
    assert.ok(!/Owner/.test(items[1]));
    assert.equal(await page.locator('#lgList i').count(), 0, 'league names escaped');
    const bg = await page.$eval('.lg-item[data-league="2"] .lg-badge', (el) => getComputedStyle(el).backgroundColor);
    assert.equal(bg, 'rgb(122, 28, 46)', 'claret swatch');
    assert.equal(await page.locator('.lg-item[data-league="2"] .lg-badge svg[data-emblem="trophy"]').count(), 1, 'trophy emblem');

    await openLeague(page, 1);
    assert.deepEqual(log.find((c) => c.name === 'league_detail').body, { p_league: 1 });
    // Classic table
    const rows = await texts(page, '#lgTable tbody tr');
    assert.equal(rows.length, 3);
    assert.match(rows[0], /^1\s*<b>Bold<\/b>\s*PRO\s*\+5\.50%$/);
    assert.match(rows[1], /^2\s*Fan\s*ULTIMATE\s*\+1\.25%$/);
    assert.match(rows[2], /^2\s*Sam\s*-0\.40%$/);
    assert.equal(await page.locator('#lgView b').count(), 0, 'display names escaped');
    // Player of the week
    const weeks = await texts(page, '#lgPotw li');
    assert.equal(weeks.length, 3);
    assert.match(weeks[0], /Week to Sun 10 Jan/);
    assert.match(weeks[0], /Fan/); assert.match(weeks[0], /Sam/); assert.match(weeks[0], /\+3\.21%/);
    assert.match(weeks[1], /Week to Sun 3 Jan.*No result this week \(the weekly save didn't run\)\./);
    assert.match(weeks[2], /Week to Sun 27 Dec.*No one in this league played this week\./);
    // Owner sees the code and Kick (not on themselves)
    assert.equal((await page.textContent('#lgCode')).trim(), 'ABC234');
    assert.ok(await page.isVisible('#lgCopy'));
    assert.ok(await page.isVisible('#lgNewCode'));
    assert.equal(await page.locator('.lg-kick').count(), 2, 'kick on the two other members');
    assert.equal(await page.locator('.lg-kick[data-member="11"]').count(), 0);
    // Kick asks first; dismissing does nothing
    let asked = '';
    page.once('dialog', (d) => { asked = d.message(); d.dismiss(); });
    await page.click('.lg-kick[data-member="13"]');
    await page.waitForTimeout(200);
    assert.equal(asked, "Remove Sam from Sunday <i>League</i>? They'll need a new code to rejoin.");
    assert.equal(count(log, 'kick_member'), 0, 'dismissed: no kick');
    const before = count(log, 'league_detail');
    page.once('dialog', (d) => d.accept());
    await page.click('.lg-kick[data-member="13"]');
    await page.waitForTimeout(400);
    assert.deepEqual(log.find((c) => c.name === 'kick_member').body, { p_league: 1, p_member: 13 });
    assert.ok(count(log, 'league_detail') > before, 'view re-fetched after kick');
    // Branding picker for an Ultimate owner
    assert.equal(await page.locator('.lg-colour').count(), 8);
    assert.equal(await page.locator('.lg-emblem').count(), 12);
    await page.click('.lg-colour[data-colour="sky"]');
    await page.click('.lg-emblem[data-emblem="bolt"]');
    await page.click('#lgBrandSave');
    await page.waitForTimeout(400);
    assert.deepEqual(log.find((c) => c.name === 'set_league_branding').body, { p_league: 1, p_colour: 'sky', p_emblem: 'bolt' });
    // Back to the list
    await page.click('#lgBack');
    assert.ok(await page.isVisible('#lgList'));
  });
}

// 5. Pre-season and "first results on Monday" texts; RPC errors shown in place.
{
  const log = [];
  await run('pre-season', { session: USER, routes: routes('pro', log, {
    'rpc/league_detail': detail({ season_started: false }), 'rpc/league_classic_table': [], 'rpc/league_player_of_week': [],
    'rpc/join_league': () => { throw 'No league with that code.'; },
    'rpc/regenerate_league_code': () => { throw 'Only the owner can do that.'; },
  }) }, async (page) => {
    await openLeagues(page);
    await page.fill('#lgJoinCode', 'ZZZZZZ');
    await page.click('#lgJoinBtn');
    await page.waitForFunction(() => /No league with that code\./.test(document.getElementById('lgJoinMsg').textContent), null, { timeout: 8000 });
    await page.waitForSelector('.lg-item[data-league="1"]', { timeout: 8000 });
    await page.click('.lg-item[data-league="1"]');
    await page.waitForFunction(() => /Scoring starts when the new season starts\./.test(document.getElementById('lgPotw')?.textContent || ''), null, { timeout: 8000 });
    await page.click('#lgNewCode');
    await page.waitForFunction(() => /Only the owner can do that\./.test(document.getElementById('lgCodeMsg').textContent), null, { timeout: 8000 });
    }, { allow500: true });
  const log2 = [];
  await run('season started, no weeks', { session: USER, routes: routes('pro', log2, { 'rpc/league_player_of_week': [] }) }, async (page) => {
    await openLeagues(page);
    await openLeague(page, 1);
    assert.match(await page.textContent('#lgPotw'), /The first results appear on Monday morning\./);
  });
}

// 6. Plan cards: no "Coming soon" on the two league features.
await run('plan cards', {}, async (page) => {
  await page.waitForFunction(() => document.querySelectorAll('#proGrid .pro-card[data-plan]').length === 5, null, { timeout: 8000 });
  const pro = await texts(page, '.pro-card[data-plan="pro_monthly"] .pro-feats li');
  const ult = await texts(page, '.pro-card[data-plan="ultimate_monthly"] .pro-feats li');
  const leagues = pro.find((t) => t.startsWith('Private leagues'));
  const brand = ult.find((t) => t.startsWith('League branding'));
  assert.ok(leagues && !/Coming soon/.test(leagues), 'private leagues live: ' + leagues);
  assert.ok(brand && !/Coming soon/.test(brand), 'branding live: ' + brand);
});

// 7. Phones: nothing wider than the screen on the list or the league view.
const wide = (page) => page.evaluate(() => [...document.querySelectorAll('body *')].filter((el) => {
  if (el.tagName === 'CANVAS') return false;
  const r = el.getBoundingClientRect();
  if (!r.width || r.right <= innerWidth + 0.5 || getComputedStyle(el).position === 'fixed') return false;
  for (let a = el.parentElement; a && a !== document.body; a = a.parentElement) {
    const cs = getComputedStyle(a);
    if (cs.overflowX !== 'visible' || cs.position === 'fixed') return false;
  }
  return true;
}).map((el) => el.tagName + '#' + el.id + '.' + el.className));
for (const width of [320, 390]) {
  const log = [];
  const long = 'Averyveryverylongleaguenamewithoutspaces';
  await run('phone ' + width, { viewport: { width, height: 844 }, session: USER, routes: routes('ultimate', log, {
    'rpc/my_leagues': [{ ...LIST[0], name: long }, LIST[1]],
    'rpc/league_detail': detail({ name: long, colour: 'navy', emblem: 'ball', members: [...MEMBERS, { member_id: 14, display_name: 'Maximilian_Longname_99', tier: 'ultimate', is_owner: false, joined_at: '2026-11-04T10:00:00Z' }] }),
  }) }, async (page) => {
    await openLeagues(page);
    await page.waitForSelector('.lg-item[data-league="1"]', { timeout: 8000 });
    await page.waitForTimeout(300);
    assert.deepEqual(await wide(page), [], 'list not wider than the screen');
    await openLeague(page, 1);
    await page.waitForTimeout(300);
    assert.deepEqual(await wide(page), [], 'league view not wider than the screen');
  });
}

console.log('ok');
