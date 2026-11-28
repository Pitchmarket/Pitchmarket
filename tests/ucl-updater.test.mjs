import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sideIsOpen, clStageContext, isMissingColumnError, holdForStageNote } from '../update-prices.js';

test('sideIsOpen: missing or closed rows are not open', () => {
  assert.equal(sideIsOpen(null), false);
  assert.equal(sideIsOpen(undefined), false);
  assert.equal(sideIsOpen({ closed: true }), false);
  assert.equal(sideIsOpen({ closed: false }), true);
  assert.equal(sideIsOpen({ name: 'Arsenal (UCL)' }), true);
});

function fakeFeed(responses){
  const calls = [];
  const fetchJson = async (path) => {
    calls.push(path);
    return Object.prototype.hasOwnProperty.call(responses, path) ? responses[path] : null;
  };
  return { fetchJson, calls };
}

test('clStageContext: a knockout stage list is fetched once and cached', async () => {
  const qf = [{ id: 1, stage: 'QUARTER_FINALS' }, { id: 2, stage: 'QUARTER_FINALS' }];
  const { fetchJson, calls } = fakeFeed({ 'competitions/CL/matches?stage=QUARTER_FINALS': { matches: qf } });
  const a = await clStageContext(fetchJson, 'QUARTER_FINALS');
  const b = await clStageContext(fetchJson, 'QUARTER_FINALS');
  assert.deepEqual(calls, ['competitions/CL/matches?stage=QUARTER_FINALS']);
  assert.deepEqual(a.stageMatches, qf);
  assert.deepEqual(b.stageMatches, qf);
});

test('clStageContext: the stage list is requested with no status filter', async () => {
  const { fetchJson, calls } = fakeFeed({ 'competitions/CL/matches?stage=SEMI_FINALS': { matches: [] } });
  await clStageContext(fetchJson, 'SEMI_FINALS');
  assert.equal(calls.length, 1);
  assert.ok(!calls[0].includes('status'));
});

test('clStageContext: a failed feed request gives null and is not retried in the run', async () => {
  const { fetchJson, calls } = fakeFeed({});
  const a = await clStageContext(fetchJson, 'LAST_16');
  const b = await clStageContext(fetchJson, 'LAST_16');
  assert.equal(a.stageMatches, null);
  assert.equal(b.stageMatches, null);
  assert.equal(calls.length, 1);
});

test('clStageContext: league stage gets the league list and a folded-name table', async () => {
  const league = [{ id: 9, stage: 'LEAGUE_STAGE', matchday: 8 }];
  const standings = { standings: [{ type: 'TOTAL', table: [
    { position: 3, team: { name: 'Arsenal FC' }, playedGames: 8, points: 19, goalDifference: 12, form: 'W,W,D' },
  ] }] };
  const { fetchJson, calls } = fakeFeed({
    'competitions/CL/matches?stage=LEAGUE_STAGE': { matches: league },
    'competitions/CL/standings': standings,
  });
  const ctx = await clStageContext(fetchJson, 'LEAGUE_STAGE');
  await clStageContext(fetchJson, 'LEAGUE_STAGE');
  assert.deepEqual(ctx.leagueMatches, league);
  assert.equal(ctx.table.get('Arsenal FC').position, 3);
  assert.equal(ctx.table.get('arsenal').position, 3);
  assert.equal(ctx.table.get('Nobody'), undefined);
  assert.deepEqual(calls.sort(), ['competitions/CL/matches?stage=LEAGUE_STAGE', 'competitions/CL/standings']);
});

test('clStageContext: no standings gives a null table', async () => {
  const { fetchJson } = fakeFeed({ 'competitions/CL/matches?stage=LEAGUE_STAGE': { matches: [] } });
  const ctx = await clStageContext(fetchJson, 'LEAGUE_STAGE');
  assert.equal(ctx.table, null);
});

test('clStageContext: a fetcher that throws gives null lists and never re-throws', async () => {
  let calls = 0;
  const fetchJson = async () => { calls++; throw new Error('getaddrinfo ENOTFOUND'); };
  const errors = [];
  const orig = console.error;
  console.error = (...a) => errors.push(a.join(' '));
  try {
    const a = await clStageContext(fetchJson, 'LAST_16');
    const b = await clStageContext(fetchJson, 'LAST_16');
    assert.equal(a.stageMatches, null);
    assert.equal(b.stageMatches, null);
    const c = await clStageContext(fetchJson, 'LEAGUE_STAGE');
    assert.equal(c.leagueMatches, null);
    assert.equal(c.table, null);
  } finally { console.error = orig; }
  assert.equal(calls, 3); // LAST_16 once, LEAGUE_STAGE once, standings once
  assert.ok(errors.some(e => e.includes('ENOTFOUND')));
});

test('clStageContext: a fetcher that throws synchronously is handled too', async () => {
  const fetchJson = () => { throw new Error('boom'); };
  const orig = console.error;
  console.error = () => {};
  try {
    const a = await clStageContext(fetchJson, 'SEMI_FINALS');
    assert.equal(a.stageMatches, null);
  } finally { console.error = orig; }
});

test('isMissingColumnError: spots a missing stage or leg column only', () => {
  const names = ['stage', 'leg'];
  assert.equal(isMissingColumnError({ code: 'PGRST204', message: "Could not find the 'stage' column of 'fixtures' in the schema cache" }, names), true);
  assert.equal(isMissingColumnError({ code: 'PGRST204', message: "Could not find the 'leg' column of 'fixtures' in the schema cache" }, names), true);
  assert.equal(isMissingColumnError({ code: '42703', message: 'column "stage" of relation "fixtures" does not exist' }, names), true);
  assert.equal(isMissingColumnError({ code: 'PGRST204', message: "Could not find the 'kickoff' column of 'fixtures' in the schema cache" }, names), false);
  assert.equal(isMissingColumnError({ code: '42P01', message: 'relation "public.fixtures" does not exist' }, names), false);
  assert.equal(isMissingColumnError({ code: '23505', message: 'duplicate key value violates unique constraint "stage_key"' }, names), false);
  assert.equal(isMissingColumnError(null, names), false);
});

test('holdForStageNote: a Champions League stage match with a note is held', () => {
  const ko = { stage: 'QUARTER_FINALS' };
  const fin = { stage: 'FINAL' };
  const league = { stage: 'LEAGUE_STAGE', matchday: 8 };
  assert.equal(holdForStageNote('CL', ko, 'cannot find both legs of this tie in the feed'), true);
  assert.equal(holdForStageNote('CL', fin, 'final has no score'), true);
  assert.equal(holdForStageNote('CL', league, 'Alpha FC not placed in the league-phase table'), true);
  // No note: a normal match (leg 1, an earlier matchday) is not held.
  assert.equal(holdForStageNote('CL', ko, null), false);
  assert.equal(holdForStageNote('CL', league, ''), false);
  // Not a stage match, or not the Champions League.
  assert.equal(holdForStageNote('CL', { stage: 'GROUP_STAGE' }, 'x'), false);
  assert.equal(holdForStageNote('PL', { stage: 'REGULAR_SEASON' }, 'x'), false);
  assert.equal(holdForStageNote('PL', ko, 'x'), false);
  assert.equal(holdForStageNote('CL', null, 'x'), false);
});
