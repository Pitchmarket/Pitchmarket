import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  STAGE_BOOST, NEXT_STAGE, matchGoals, legOf, tieOutcome, leagueOutcome,
  boostMove, stageFields, needsReview,
} from '../ucl-stages.js';

const A = { id: 1, name: 'Alpha FC' };
const B = { id: 2, name: 'Beta United' };

let nextId = 100;
function match({ home = A, away = B, stage = 'QUARTER_FINALS', status = 'FINISHED', date = '2027-04-08T19:00:00Z', matchday = null, score = {} } = {}) {
  return {
    id: nextId++, utcDate: date, status, stage, matchday,
    homeTeam: { ...home }, awayTeam: { ...away },
    score: { winner: null, duration: 'REGULAR', ...score },
  };
}
const ft = (home, away) => ({ fullTime: { home, away } });

test('constants hold the agreed boosts and next stages', () => {
  assert.deepEqual(STAGE_BOOST, { last16: 1.2, quarters: 1.5, semis: 2, final: 2.5, winners: 3 });
  assert.deepEqual(NEXT_STAGE, { PLAYOFFS: 'last16', LAST_16: 'quarters', QUARTER_FINALS: 'semis', SEMI_FINALS: 'final', FINAL: 'winners' });
});

test('boostMove boosts only rises, outs go to -100', () => {
  assert.deepEqual(boostMove(10, 'semis'), { pct: 20, multiplier: 2 });
  assert.deepEqual(boostMove(10, 'last16'), { pct: 12, multiplier: 1.2 });
  assert.deepEqual(boostMove(-4, 'quarters'), { pct: -4, multiplier: 1 });
  assert.deepEqual(boostMove(7, 'out'), { pct: -100, multiplier: null });
  assert.deepEqual(boostMove(5, 'playoff'), { pct: 5, multiplier: 1 });
});

test('matchGoals never counts penalty kicks as goals', () => {
  assert.deepEqual(matchGoals(match({ score: {
    duration: 'PENALTY_SHOOTOUT',
    regularTime: { home: 1, away: 1 }, extraTime: { home: 0, away: 0 },
    penalties: { home: 4, away: 3 }, fullTime: { home: 5, away: 4 },
  } })), { home: 1, away: 1 });
  assert.deepEqual(matchGoals(match({ score: ft(2, 1) })), { home: 2, away: 1 });
  assert.deepEqual(matchGoals(match({ score: { fullTime: { home: 5, away: 4 }, penalties: { home: 4, away: 3 } } })), { home: 1, away: 1 });
  assert.equal(matchGoals(match({ score: ft(null, null) })), null);
});

test('matchGoals gives null when extra time or a shootout is missing its numbers', () => {
  // Shootout with no penalties pair: fullTime includes shootout goals, can't separate them.
  const noPens = match({ score: { duration: 'PENALTY_SHOOTOUT', fullTime: { home: 5, away: 4 } } });
  assert.equal(matchGoals(noPens), null);
  // Extra time played but no extraTime pair: extra-time goals would be lost.
  const noEt = match({ score: { duration: 'EXTRA_TIME', regularTime: { home: 1, away: 0 }, fullTime: { home: 1, away: 2 } } });
  assert.equal(matchGoals(noEt), null);
  const noEtShootout = match({ score: {
    duration: 'PENALTY_SHOOTOUT', regularTime: { home: 1, away: 1 },
    penalties: { home: 4, away: 3 }, fullTime: { home: 5, away: 4 },
  } });
  assert.equal(matchGoals(noEtShootout), null);
  // Extra time with full numbers still works.
  assert.deepEqual(matchGoals(match({ score: {
    duration: 'EXTRA_TIME', regularTime: { home: 1, away: 0 }, extraTime: { home: 0, away: 2 }, fullTime: { home: 1, away: 2 },
  } })), { home: 1, away: 2 });
});

test('tieOutcome is unclear when extra time or shootout data is missing', () => {
  const fin = match({ stage: 'FINAL', score: { duration: 'PENALTY_SHOOTOUT', fullTime: { home: 5, away: 4 } } });
  assert.equal(typeof tieOutcome(fin, [fin]).unclear, 'string');
  // Home leads 2-0 on aggregate after 90' of leg 2 but extra-time goals are missing.
  const leg1 = match({ home: B, away: A, date: '2027-04-08T19:00:00Z', score: ft(0, 1) });
  const leg2 = match({ home: A, away: B, date: '2027-04-15T19:00:00Z', score: {
    duration: 'EXTRA_TIME', regularTime: { home: 1, away: 0 }, fullTime: { home: 1, away: 3 },
  } });
  assert.equal(typeof tieOutcome(leg2, [leg1, leg2]).unclear, 'string');
  const r = stageFields(leg2, { stageMatches: [leg1, leg2], leagueMatches: [], table: new Map() }, 5, -5);
  assert.deepEqual(r.fields, {});
  assert.equal(typeof r.note, 'string');
});

test('legOf orders the two legs by date and calls a final leg 1', () => {
  const leg1 = match({ home: B, away: A, date: '2027-04-08T19:00:00Z', score: ft(1, 1) });
  const leg2 = match({ home: A, away: B, date: '2027-04-15T19:00:00Z', score: ft(1, 0) });
  const other = match({ home: { id: 3, name: 'C' }, away: { id: 4, name: 'D' }, date: '2027-04-01T19:00:00Z' });
  assert.equal(legOf(leg1, [leg2, other, leg1]), 1);
  assert.equal(legOf(leg2, [leg2, other, leg1]), 2);
  assert.equal(legOf(leg2, [leg2, other]), null);
  assert.equal(legOf(match({ stage: 'FINAL' }), []), 1);
});

test('tieOutcome: leg 1 is pending', () => {
  const leg1 = match({ home: B, away: A, date: '2027-04-08T19:00:00Z', score: ft(2, 0) });
  const leg2 = match({ home: A, away: B, date: '2027-04-15T19:00:00Z', status: 'TIMED', score: ft(null, null) });
  assert.deepEqual(tieOutcome(leg1, [leg1, leg2]), { pending: true });
});

test('tieOutcome: aggregate decides, with teams swapping home and away', () => {
  // Leg 1: B 2-1 A. Leg 2: A 1-1 B. Aggregate B 3-2 A.
  const leg1 = match({ home: B, away: A, date: '2027-04-08T19:00:00Z', score: ft(2, 1) });
  const leg2 = match({ home: A, away: B, date: '2027-04-15T19:00:00Z', score: ft(1, 1) });
  assert.deepEqual(tieOutcome(leg2, [leg1, leg2]), { winnerId: B.id, loserId: A.id });
  // Leg 1: B 0-1 A. Leg 2: A 2-2 B. Aggregate A 3-2 B.
  const l1 = match({ home: B, away: A, date: '2027-04-08T19:00:00Z', score: ft(0, 1) });
  const l2 = match({ home: A, away: B, date: '2027-04-15T19:00:00Z', score: ft(2, 2) });
  assert.deepEqual(tieOutcome(l2, [l2, l1]), { winnerId: A.id, loserId: B.id });
});

test('tieOutcome: level aggregate goes to leg 2 penalties (away side wins 5-4)', () => {
  const leg1 = match({ home: B, away: A, date: '2027-04-08T19:00:00Z', score: ft(1, 0) });
  const leg2 = match({ home: A, away: B, date: '2027-04-15T19:00:00Z', score: {
    duration: 'PENALTY_SHOOTOUT',
    regularTime: { home: 1, away: 0 }, extraTime: { home: 0, away: 0 },
    penalties: { home: 4, away: 5 }, fullTime: { home: 5, away: 5 },
  } });
  assert.deepEqual(tieOutcome(leg2, [leg1, leg2]), { winnerId: B.id, loserId: A.id });
});

test('tieOutcome: missing first leg is unclear, never a guess', () => {
  const leg2 = match({ home: A, away: B, date: '2027-04-15T19:00:00Z', score: ft(3, 0) });
  const out = tieOutcome(leg2, [leg2]);
  assert.equal(typeof out.unclear, 'string');
  const outEmpty = tieOutcome(leg2, []);
  assert.equal(typeof outEmpty.unclear, 'string');
});

test('tieOutcome: unfinished first leg or level tie with no penalties is unclear', () => {
  const leg1 = match({ home: B, away: A, date: '2027-04-08T19:00:00Z', status: 'POSTPONED', score: ft(null, null) });
  const leg2 = match({ home: A, away: B, date: '2027-04-15T19:00:00Z', score: ft(1, 0) });
  assert.equal(typeof tieOutcome(leg2, [leg1, leg2]).unclear, 'string');
  const l1 = match({ home: B, away: A, date: '2027-04-08T19:00:00Z', score: ft(1, 0) });
  const l2 = match({ home: A, away: B, date: '2027-04-15T19:00:00Z', score: ft(1, 0) });
  assert.equal(typeof tieOutcome(l2, [l1, l2]).unclear, 'string');
});

test('tieOutcome: final 1-1 with penalties 3-4 goes to the away side', () => {
  const fin = match({ stage: 'FINAL', score: {
    duration: 'PENALTY_SHOOTOUT',
    regularTime: { home: 1, away: 1 }, extraTime: { home: 0, away: 0 },
    penalties: { home: 3, away: 4 }, fullTime: { home: 4, away: 5 },
  } });
  assert.deepEqual(tieOutcome(fin, [fin]), { winnerId: B.id, loserId: A.id });
});

function leagueSet(lastStatus = 'FINISHED') {
  const all = [];
  for (let md = 1; md <= 8; md++) {
    all.push(match({ stage: 'LEAGUE_STAGE', matchday: md, score: ft(1, 0) }));
    all.push(match({ stage: 'LEAGUE_STAGE', matchday: md, home: { id: 5, name: 'E' }, away: { id: 6, name: 'F' }, score: ft(0, 0) }));
  }
  all[all.length - 1].status = lastStatus;
  return all;
}
const table = (a, b) => new Map([[A.name, { position: a }], [B.name, { position: b }]]);

test('leagueOutcome: earlier matchdays have no stage', () => {
  const m = match({ stage: 'LEAGUE_STAGE', matchday: 7, score: ft(1, 0) });
  assert.deepEqual(leagueOutcome(m, leagueSet(), table(3, 30)), { home: null, away: null });
});

test('leagueOutcome: last matchday waits while any league match is unfinished', () => {
  const m = match({ stage: 'LEAGUE_STAGE', matchday: 8, score: ft(1, 0) });
  assert.deepEqual(leagueOutcome(m, leagueSet('IN_PLAY'), table(3, 30)), { pending: true });
});

test('leagueOutcome: last matchday maps positions to stages', () => {
  const m = match({ stage: 'LEAGUE_STAGE', matchday: 8, score: ft(1, 0) });
  assert.deepEqual(leagueOutcome(m, leagueSet(), table(3, 30)), { home: 'last16', away: 'out' });
  assert.deepEqual(leagueOutcome(m, leagueSet(), table(12, 24)), { home: 'playoff', away: 'playoff' });
  assert.deepEqual(leagueOutcome(m, leagueSet(), table(8, 25)), { home: 'last16', away: 'out' });
  assert.deepEqual(leagueOutcome(m, leagueSet(), table(9, 36)), { home: 'playoff', away: 'out' });
  const missing = leagueOutcome(m, leagueSet(), new Map([[A.name, { position: 3 }]]));
  assert.equal(typeof missing.unclear, 'string');
});

test('stageFields: quarter-final leg 2 won by home', () => {
  const leg1 = match({ home: B, away: A, date: '2027-04-08T19:00:00Z', score: ft(1, 1) });
  const leg2 = match({ home: A, away: B, date: '2027-04-15T19:00:00Z', score: ft(2, 0) });
  const r = stageFields(leg2, { stageMatches: [leg1, leg2], leagueMatches: [], table: new Map() }, 10, -6);
  assert.deepEqual(r, {
    fields: {
      home_stage: 'semis', away_stage: 'out',
      home_ai_pct: 10, away_ai_pct: -6,
      home_multiplier: 2, away_multiplier: null,
      home_delta_pct: 20, away_delta_pct: -100,
    },
    defer: false, note: null,
  });
  assert.equal(needsReview(r.fields), true);
});

test('stageFields: league playoff-only result fills fields and needs no review', () => {
  const m = match({ stage: 'LEAGUE_STAGE', matchday: 8, score: ft(1, 0) });
  const r = stageFields(m, { stageMatches: [], leagueMatches: leagueSet(), table: table(12, 20) }, 4, -3);
  assert.deepEqual(r.fields, {
    home_stage: 'playoff', away_stage: 'playoff',
    home_ai_pct: 4, away_ai_pct: -3,
    home_multiplier: 1, away_multiplier: 1,
    home_delta_pct: 4, away_delta_pct: -3,
  });
  assert.equal(r.defer, false);
  assert.equal(needsReview(r.fields), false);
});

test('stageFields: unclear gives no fields and a note; pending league defers; leg 1 does not', () => {
  const leg2 = match({ home: A, away: B, date: '2027-04-15T19:00:00Z', score: ft(3, 0) });
  const unclear = stageFields(leg2, { stageMatches: [leg2], leagueMatches: [], table: new Map() }, 5, -5);
  assert.deepEqual(unclear.fields, {});
  assert.equal(unclear.defer, false);
  assert.equal(typeof unclear.note, 'string');
  assert.ok(unclear.note.length > 0);

  const m = match({ stage: 'LEAGUE_STAGE', matchday: 8, score: ft(1, 0) });
  assert.deepEqual(stageFields(m, { stageMatches: [], leagueMatches: leagueSet('IN_PLAY'), table: table(3, 30) }, 1, 1),
    { fields: {}, defer: true, note: null });

  const leg1 = match({ home: B, away: A, date: '2027-04-08T19:00:00Z', score: ft(2, 0) });
  const l2 = match({ home: A, away: B, date: '2027-04-15T19:00:00Z', status: 'TIMED', score: ft(null, null) });
  assert.deepEqual(stageFields(leg1, { stageMatches: [leg1, l2], leagueMatches: [], table: new Map() }, 3, -3),
    { fields: {}, defer: false, note: null });

  const early = match({ stage: 'LEAGUE_STAGE', matchday: 7, score: ft(1, 0) });
  assert.deepEqual(stageFields(early, { stageMatches: [], leagueMatches: leagueSet(), table: table(3, 30) }, 1, 1),
    { fields: {}, defer: false, note: null });
});

test('stageFields: final winner gets winners boost ×3', () => {
  const fin = match({ stage: 'FINAL', score: ft(0, 1) });
  const r = stageFields(fin, { stageMatches: [fin], leagueMatches: [], table: new Map() }, -2, 10);
  assert.equal(r.fields.away_stage, 'winners');
  assert.equal(r.fields.away_multiplier, 3);
  assert.equal(r.fields.away_delta_pct, 30);
  assert.equal(r.fields.home_stage, 'out');
  assert.equal(r.fields.home_ai_pct, -2);
});

test('needsReview: no stage means no review', () => {
  assert.equal(needsReview({}), false);
  assert.equal(needsReview({ home_stage: 'playoff', away_stage: 'out' }), true);
});
