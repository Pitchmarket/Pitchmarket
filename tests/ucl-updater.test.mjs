import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sideIsOpen, clStageContext } from '../update-prices.js';

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
