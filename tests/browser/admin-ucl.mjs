// Admin, Champions League stages: stage results in Price Approvals (banner,
// Approve / Reject stage, the 12-hour note), the Knock out / Crown winners /
// Reopen buttons on Champions League clubs, the non-entrants box, and the
// page still loading before supabase-ucl-stages.sql has run.
import assert from 'node:assert/strict';
import { openPage } from './harness.mjs';

const URL_ = 'http://127.0.0.1:8765/admin.html';
const ADMIN = { id: 'a1', email: 'pitchmarketadmin@gmail.com' };
const FOUND = '2026-11-28T09:00:00Z';
const cl = (id, name, price, over = {}) => ({ id, name, league: 'championsleague', league_label: 'Champions League', tier: 'UCL',
  price, chg: 0, league_order: 6, closed: false, ucl_stage: 'quarters', ...over });
const TEAMS = [
  cl('t-ars', 'Arsenal (UCL)', 88.2),
  cl('t-bvb', 'Dortmund (UCL)', 0, { closed: true, ucl_stage: 'out', chg: -100 }),
  cl('t-int', 'Inter <b>(UCL)</b>', 70),
  { id: 't-che', name: 'Chelsea', league: 'premierleague', league_label: 'Premier League', tier: 'ENG', price: 50, chg: 1, league_order: 1, closed: false, ucl_stage: null },
];
const ev = (id, over) => ({ id, status: 'pending', competition: 'CL', match_date: FOUND, created_at: FOUND,
  home_score: 2, away_score: 1, home_team_id: null, away_team_id: null, ai_reason: 'Solid win', ai_provider: 'ai',
  home_stage: null, away_stage: null, home_ai_pct: null, away_ai_pct: null, home_multiplier: null, away_multiplier: null,
  stage_rejected: false, ...over });
const PENDING = [
  ev('e-semis', { home_team_name: 'Arsenal FC', away_team_name: 'Real Madrid CF',
    home_stage: 'semis', away_stage: 'out', home_ai_pct: 10, away_ai_pct: -6, home_multiplier: 2, away_multiplier: null,
    home_delta_pct: 20, away_delta_pct: -100 }),
  ev('e-final', { home_team_name: 'FC Internazionale Milano', away_team_name: 'PSG',
    home_stage: 'winners', away_stage: 'out', home_ai_pct: 8, away_ai_pct: -5, home_multiplier: 3,
    home_delta_pct: 24, away_delta_pct: -100 }),
  ev('e-play', { home_team_name: 'Celtic FC', away_team_name: 'Club Brugge',
    home_stage: 'playoff', away_stage: 'playoff', home_ai_pct: 9, away_ai_pct: -9, home_delta_pct: 9, away_delta_pct: -9 }),
  ev('e-norm', { competition: 'PL', home_team_name: 'Chelsea FC', away_team_name: 'Fulham FC', home_delta_pct: 9, away_delta_pct: -9 }),
];
const HISTORY = [
  ev('h-rej', { status: 'approved', home_team_name: 'Arsenal FC', away_team_name: 'Bayern', home_stage: 'quarters', away_stage: 'out',
    home_ai_pct: 4, away_ai_pct: -3, home_multiplier: 1.5, home_delta_pct: 6, away_delta_pct: -100, stage_rejected: true }),
];

function setup(state, { migrated = true } = {}) {
  const rpc = (name, result) => (req) => { state.rpcs.push({ name, body: req.postDataJSON() }); return result; };
  const strip = (rows) => rows.map(({ closed, ucl_stage, home_stage, away_stage, home_ai_pct, away_ai_pct,
    home_multiplier, away_multiplier, stage_rejected, ...r }) => r);
  return {
    teams: () => migrated ? TEAMS : strip(TEAMS),
    match_events: (req) => {
      const status = new URL(req.url()).searchParams.get('status');
      const rows = status === 'eq.pending' ? PENDING : HISTORY;
      return migrated ? rows : strip(rows);
    },
    'rpc/approve_match_event': rpc('approve_match_event', null),
    'rpc/admin_ucl_knock_out': rpc('admin_ucl_knock_out', null),
    'rpc/admin_ucl_crown': rpc('admin_ucl_crown', 3),
    'rpc/admin_ucl_close_refund': rpc('admin_ucl_close_refund', 2),
    'rpc/admin_ucl_reopen': rpc('admin_ucl_reopen', null),
    ...(migrated ? { 'rpc/admin_ucl_non_entrants': () => [{ team_id: 't-ars', name: 'Arsenal (UCL)' }] } : {
      'rpc/admin_ucl_non_entrants': () => { throw new Error('Could not find the function public.admin_ucl_non_entrants'); },
    }),
  };
}

const text = (loc) => loc.evaluate((el) => el.textContent.replace(/\s+/g, ' ').trim());

async function run(name, fn, opts = {}) {
  const state = { rpcs: [], dialogs: [] };
  const { page, errors, browser } = await openPage(URL_, { session: ADMIN, routes: setup(state, opts) });
  page.on('dialog', (d) => {
    state.dialogs.push(d.message());
    if (d.type() === 'prompt') return d.accept('25');
    return d.accept();
  });
  try {
    await page.waitForFunction(() => document.querySelectorAll('#teamRows tr').length === 4, null, { timeout: 8000 });
    await page.waitForFunction(() => document.querySelectorAll('#pendingEventsList .event-card').length === 4, null, { timeout: 8000 });
    await fn(page, state);
    const failed = errors.filter((e) => e.includes('Failed to load resource'));
    assert.equal(failed.length, opts.failedLoads || 0, 'failed loads');
    assert.deepEqual(errors.filter((e) => !failed.includes(e)), [], 'page errors');
  } catch (e) { e.message = name + ': ' + e.message; throw e; }
  finally { await browser.close(); }
}

const card = (page, id) => page.locator('#pendingEventsList .event-card[data-id="' + id + '"]');

// 1. Stage cards in Price Approvals.
await run('stage cards', async (page, state) => {
  await page.click('.section-tab[data-pane="approvalsPane"]');
  const semis = card(page, 'e-semis');
  const banners = await semis.locator('.stage-banner').evaluateAll((els) => els.map((e) => e.textContent.trim()));
  assert.deepEqual(banners, ['Arsenal FC through to the semis: AI +10% ×2 = +20%', 'Real Madrid CF out: price to 0']);
  assert.equal(await text(semis.locator('.approve-btn')), 'Approve');
  assert.equal(await text(semis.locator('.reject-btn')), 'Reject stage (apply as a normal match)');
  const due = new Date(Date.parse(FOUND) + 12 * 3600 * 1000);
  const dueText = await page.evaluate((iso) => fmtWhen(iso), due.toISOString());
  assert.equal(await text(semis.locator('.stage-auto')), 'Applies automatically 12 hours after it was found (at ' + dueText + ')');

  const fin = await card(page, 'e-final').locator('.stage-banner').first().textContent();
  assert.equal(fin.trim(), 'FC Internazionale Milano win the Champions League: AI +8% ×3 = +24%, holders cashed out, Champions League closes');

  // Play-off: banner, but an ordinary card.
  const play = card(page, 'e-play');
  assert.equal((await play.locator('.stage-banner').first().textContent()).trim(), 'Celtic FC to the play-off (no boost)');
  assert.equal(await text(play.locator('.reject-btn')), 'Reject');
  assert.equal(await play.locator('.stage-auto').count(), 0);

  // A normal card is unchanged.
  const norm = card(page, 'e-norm');
  assert.equal(await norm.locator('.stage-banner').count(), 0);
  assert.equal(await text(norm.locator('.reject-btn')), 'Reject');

  // History: a rejected stage says so.
  const hist = page.locator('#historyEventsList .event-card');
  await hist.first().waitFor({ timeout: 8000 });
  assert.match(await text(hist.first()), /stage rejected/i);
  assert.match(await text(hist.first()), /Arsenal FC: \+4%/, 'history shows the move applied');

  // Reject stage calls approve_match_event with p_approve false.
  await semis.locator('.reject-btn').click();
  await page.waitForTimeout(200);
  assert.deepEqual(state.rpcs.find((r) => r.name === 'approve_match_event').body, { p_event_id: 'e-semis', p_approve: false });
});

// 2. Teams tab: Champions League buttons and the non-entrants box.
await run('teams tab', async (page, state) => {
  const ids = { 'Arsenal (UCL)': 't-ars', 'Dortmund (UCL)': 't-bvb', 'Inter <b>(UCL)</b>': 't-int', Chelsea: 't-che' };
  const row = (name) => page.locator('#teamRows tr[data-id="' + ids[name] + '"]');
  // Premier League clubs get no Champions League buttons.
  assert.equal(await row('Chelsea').locator('.ucl-btn').count(), 0);
  const ars = row('Arsenal (UCL)');
  assert.equal(await ars.locator('.ucl-knock').count(), 1, 'Knock out');
  assert.equal(await ars.locator('.ucl-crown').count(), 1, 'Crown winners');
  assert.equal(await ars.locator('.ucl-reopen').count(), 0);
  assert.equal(await row('Inter <b>(UCL)</b>').locator('.ucl-knock').count(), 1);
  assert.equal(await page.locator('#teamRows b').count(), 0, 'club names escaped');

  const n = state.rpcs.length;
  await ars.locator('.ucl-knock').click();
  await page.waitForTimeout(200);
  assert.equal(state.dialogs[0], 'Set Arsenal (UCL) to 0 and close trading? Holders lose these shares.');
  assert.deepEqual(state.rpcs[n], { name: 'admin_ucl_knock_out', body: { p_team_id: 't-ars' } });

  // Crown: confirm, then the count of holders paid.
  await row('Inter <b>(UCL)</b>').locator('.ucl-crown').click();
  await page.waitForTimeout(200);
  assert.match(state.dialogs[1], /^Crown Inter <b>\(UCL\)<\/b> Champions League winners\?/);
  assert.deepEqual(state.rpcs.at(-1), { name: 'admin_ucl_crown', body: { p_team_id: 't-int' } });
  assert.equal(state.dialogs[2], 'Done: 3 holders paid.');

  // Closed club: state and Reopen with a price.
  const bvb = row('Dortmund (UCL)');
  assert.equal(await bvb.locator('.ucl-knock').count(), 0);
  assert.match(await text(bvb.locator('.ucl-state')), /^Out/);
  await bvb.locator('.ucl-price').fill('25');
  await bvb.locator('.ucl-reopen').click();
  await page.waitForTimeout(200);
  assert.match(state.dialogs[3], /^Reopen Dortmund \(UCL\) at 25\.00/);
  assert.deepEqual(state.rpcs.at(-1), { name: 'admin_ucl_reopen', body: { p_team_id: 't-bvb', p_price: 25 } });

  // Non-entrants box: only with the Champions League filter.
  assert.ok(!(await page.locator('#uclNonEntrants').isVisible()), 'box hidden on All');
  await page.click('.filter-btn[data-l="championsleague"]');
  await page.waitForSelector('#uclNonEntrants .ucl-refund', { timeout: 8000 });
  assert.match(await text(page.locator('#uclNonEntrants')), /Arsenal \(UCL\)/);
  await page.click('#uclNonEntrants .ucl-refund');
  await page.waitForTimeout(200);
  assert.match(state.dialogs[4], /^Close Arsenal \(UCL\) and refund/);
  assert.deepEqual(state.rpcs.at(-1), { name: 'admin_ucl_close_refund', body: { p_team_id: 't-ars' } });
  assert.equal(state.dialogs[5], 'Done: 2 holders refunded.');
});

// 3. Before the migration: no stage columns, no Champions League functions.
await run('before migration', async (page) => {
  assert.equal(await page.locator('.stage-banner').count(), 0);
  assert.equal(await page.locator('.ucl-btn').count(), 0, 'no Champions League buttons');
  assert.equal(await page.locator('.stage-banner').count(), 0);
  await page.click('.filter-btn[data-l="championsleague"]');
  await page.waitForTimeout(300);
  assert.ok(!(await page.locator('#uclNonEntrants').isVisible()), 'box stays hidden');
  assert.equal(await text(card(page, 'e-semis').locator('.reject-btn')), 'Reject');
}, { migrated: false, failedLoads: 1 });

console.log('ok');
