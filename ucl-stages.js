// Champions League stages: works out, from football-data.org v4 match objects,
// which clubs go out (price to 0) and which go through (the AI's move boosted).
// Pure functions only; update-prices.js supplies the feed data.

export const STAGE_BOOST = { last16: 1.2, quarters: 1.5, semis: 2, final: 2.5, winners: 3 };
export const NEXT_STAGE = { PLAYOFFS: 'last16', LAST_16: 'quarters', QUARTER_FINALS: 'semis', SEMI_FINALS: 'final', FINAL: 'winners' };

const DONE = new Set(['FINISHED', 'AWARDED']);
const isDone = m => DONE.has(m && m.status);
const num = v => typeof v === 'number' && Number.isFinite(v);
const pairOk = p => p && num(p.home) && num(p.away);

// Two decimals without floating noise (10 * 1.2 -> 12, not 12.000000000000002).
function round2(x){
  return Math.round(Number((x * 100).toFixed(6))) / 100;
}

// Goals scored in play (regular time plus extra time), never penalty kicks.
export function matchGoals(match){
  const s = match && match.score;
  if (!s) return null;
  // Incomplete feed data must give "no score", never a confident wrong one.
  const wentLong = s.duration === 'EXTRA_TIME' || s.duration === 'PENALTY_SHOOTOUT';
  if (s.duration === 'PENALTY_SHOOTOUT' && !pairOk(s.penalties)) return null;
  if (s.regularTime && (s.regularTime.home != null || s.regularTime.away != null)) {
    if (!pairOk(s.regularTime)) return null;
    if (wentLong && !pairOk(s.extraTime)) return null;
    const et = s.extraTime || {};
    return {
      home: s.regularTime.home + (num(et.home) ? et.home : 0),
      away: s.regularTime.away + (num(et.away) ? et.away : 0),
    };
  }
  if (!pairOk(s.fullTime)) return null;
  const pen = s.penalties || {};
  return {
    home: s.fullTime.home - (num(pen.home) ? pen.home : 0),
    away: s.fullTime.away - (num(pen.away) ? pen.away : 0),
  };
}

function penaltyWinner(match){
  const p = match && match.score && match.score.penalties;
  if (!pairOk(p) || p.home === p.away) return null;
  return p.home > p.away ? 'home' : 'away';
}

const sameTie = (a, b) => {
  const x = [a.homeTeam && a.homeTeam.id, a.awayTeam && a.awayTeam.id];
  const y = [b.homeTeam && b.homeTeam.id, b.awayTeam && b.awayTeam.id];
  return num(x[0]) && num(x[1]) && x[0] !== x[1]
    && ((x[0] === y[0] && x[1] === y[1]) || (x[0] === y[1] && x[1] === y[0]));
};

// Both legs of this match's tie, ordered by kick-off, or null if there aren't exactly two.
function tieLegs(match, stageMatches){
  const legs = (stageMatches || []).filter(m => m && m.id !== match.id && sameTie(match, m));
  if (!sameTie(match, match)) return null;
  legs.push(match);
  if (legs.length !== 2) return null;
  const t = m => Date.parse(m.utcDate);
  if (!legs.every(m => Number.isFinite(t(m))) || t(legs[0]) === t(legs[1])) return null;
  return legs.sort((a, b) => t(a) - t(b));
}

export function legOf(match, stageMatches){
  if (!match) return null;
  if (match.stage === 'FINAL') return 1;
  const legs = tieLegs(match, stageMatches);
  if (!legs) return null;
  return legs[0] === match ? 1 : 2;
}

function decided(match, homeWins){
  return homeWins
    ? { winnerId: match.homeTeam.id, loserId: match.awayTeam.id }
    : { winnerId: match.awayTeam.id, loserId: match.homeTeam.id };
}

export function tieOutcome(match, stageMatches){
  if (!match || !match.homeTeam || !match.awayTeam) return { unclear: 'match has no teams' };
  const goals = matchGoals(match);
  if (match.stage === 'FINAL') {
    if (!goals) return { unclear: 'final has no score' };
    if (goals.home !== goals.away) return decided(match, goals.home > goals.away);
    const pens = penaltyWinner(match);
    if (!pens) return { unclear: 'final level with no penalty winner' };
    return decided(match, pens === 'home');
  }
  const legs = tieLegs(match, stageMatches);
  if (!legs) return { unclear: 'cannot find both legs of this tie in the feed' };
  if (legs[0] === match) return { pending: true };
  const leg1 = legs[0];
  if (!isDone(leg1)) return { unclear: `first leg is ${leg1.status || 'not finished'}` };
  const g1 = matchGoals(leg1);
  if (!goals || !g1) return { unclear: 'a leg of this tie has no score' };
  const homeId = match.homeTeam.id;
  const homeAgg = goals.home + (leg1.homeTeam.id === homeId ? g1.home : g1.away);
  const awayAgg = goals.away + (leg1.homeTeam.id === homeId ? g1.away : g1.home);
  if (homeAgg !== awayAgg) return decided(match, homeAgg > awayAgg);
  const pens = penaltyWinner(match);
  if (!pens) return { unclear: `aggregate level ${homeAgg}-${awayAgg} with no penalty winner` };
  return decided(match, pens === 'home');
}

function stageForPosition(position){
  if (!num(position)) return null;
  if (position >= 1 && position <= 8) return 'last16';
  if (position >= 9 && position <= 24) return 'playoff';
  if (position >= 25 && position <= 36) return 'out';
  return null;
}

// How many league-phase matches each club has in the list, keyed by its
// feed name.
function leagueCounts(leagueMatches){
  const counts = new Map();
  for (const m of leagueMatches) {
    for (const t of [m.homeTeam, m.awayTeam]) {
      if (t && t.name) counts.set(t.name, (counts.get(t.name) || 0) + 1);
    }
  }
  return counts;
}

// `table.get(feedTeamName)` returns `{ position, played }` or undefined.
// The table can lag the match list, so positions are trusted only once
// every club in it has every one of its league matches counted.
export function leagueOutcome(match, leagueMatches, table){
  const days = (leagueMatches || []).map(m => m && m.matchday).filter(num);
  if (!match || !num(match.matchday) || !days.length) return { unclear: 'cannot tell the league-phase matchday' };
  const lastDay = Math.max(...days);
  if (match.matchday < lastDay) return { home: null, away: null };
  if (!leagueMatches.every(isDone)) return { pending: true };
  if (!table || typeof table.get !== 'function') return { unclear: 'no league-phase table' };
  for (const [name, count] of leagueCounts(leagueMatches)) {
    const row = table.get(name);
    if (row && row.played !== count) return { pending: true };
  }
  const out = {};
  for (const side of ['home', 'away']) {
    const name = match[`${side}Team`] && match[`${side}Team`].name;
    const row = name ? table.get(name) : undefined;
    const stage = row ? stageForPosition(row.position) : null;
    if (!stage) return { unclear: `${name || side + ' team'} not placed in the league-phase table` };
    out[side] = stage;
  }
  return out;
}

export function boostMove(aiPct, stage){
  if (stage === 'out') return { pct: -100, multiplier: null };
  const boost = STAGE_BOOST[stage];
  if (boost && aiPct > 0) return { pct: round2(aiPct * boost), multiplier: boost };
  return { pct: aiPct, multiplier: 1 };
}

export function stageFields(match, ctx, homeAiPct, awayAiPct){
  const none = (note = null, defer = false) => ({ fields: {}, defer, note });
  if (!match) return none();
  const { stageMatches = [], leagueMatches = [], table } = ctx || {};
  let stages;
  if (match.stage === 'LEAGUE_STAGE') {
    const r = leagueOutcome(match, leagueMatches, table);
    if (r.pending) return none(null, true);
    if (r.unclear) return none(r.unclear);
    stages = r;
  } else if (NEXT_STAGE[match.stage]) {
    const r = tieOutcome(match, stageMatches);
    if (r.pending) return none();
    if (r.unclear) return none(r.unclear);
    const winnerIsHome = r.winnerId === match.homeTeam.id;
    const next = NEXT_STAGE[match.stage];
    stages = { home: winnerIsHome ? next : 'out', away: winnerIsHome ? 'out' : next };
  } else {
    return none();
  }
  if (!stages.home && !stages.away) return none();
  const fields = {};
  for (const [side, ai] of [['home', homeAiPct], ['away', awayAiPct]]) {
    const stage = stages[side] || null;
    const move = stage ? boostMove(ai, stage) : { pct: ai, multiplier: null };
    fields[`${side}_stage`] = stage;
    fields[`${side}_ai_pct`] = ai;
    fields[`${side}_multiplier`] = move.multiplier;
    fields[`${side}_delta_pct`] = move.pct;
  }
  return { fields, defer: false, note: null };
}

export function needsReview(fields){
  return [fields && fields.home_stage, fields && fields.away_stage]
    .some(s => s != null && s !== 'playoff');
}
