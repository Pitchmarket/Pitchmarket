// update-prices.js
//
// Run by GitHub Actions on a schedule. For every finished match in
// your covered leagues since the last run, asks an AI provider to
// weigh the result and writes a PROPOSED price move into the
// match_events table as status='pending' — nothing touches a real
// team price until you approve it in admin.html's Price Approvals tab
// (or until auto-apply handles it, if that's switched on).
//
// AI provider is modular: set AI_PROVIDER to 'gemini' (default, free)
// or 'claude' (paid, better judgment) — everything else about the
// pipeline stays exactly the same either way.
//
// Required environment variables (set as GitHub Secrets):
//   FOOTBALL_DATA_API_KEY     — from football-data.org
//   SUPABASE_URL              — same one already in your site's config
//   SUPABASE_SERVICE_ROLE_KEY — Settings -> API in Supabase.
//     NOT the anon key. Bypasses all security rules — must NEVER go
//     in pitchmarket.html, admin.html, or any file a browser can see.
//
// One of these two, depending on AI_PROVIDER:
//   GEMINI_API_KEY    — from aistudio.google.com (free, no card needed)
//   ANTHROPIC_API_KEY — from console.anthropic.com (paid, optional upgrade)
//
// Optional:
//   AI_PROVIDER   — 'gemini' (default) or 'claude'
//   GEMINI_MODEL  — defaults to 'gemini-3.6-flash'. Google renames these
//                   models fairly often — check aistudio.google.com if
//                   this one starts erroring, and update the secret/default
//                   without touching any other code.
//   AI_MIN_GAP_MS — minimum milliseconds between AI calls (default 4500,
//                   about 13 per minute). The free Gemini tier caps
//                   requests per minute; on a full matchday this script
//                   can have 40+ matches to price, and without pacing it
//                   walks straight into that cap and every remaining
//                   match fails. That is what happened on 10 Oct 2026.

import { createClient } from '@supabase/supabase-js';

const FOOTBALL_DATA_API_KEY = process.env.FOOTBALL_DATA_API_KEY;
const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const AI_PROVIDER = (process.env.AI_PROVIDER || 'gemini').toLowerCase();
const GEMINI_API_KEY = process.env.GEMINI_API_KEY;
const GEMINI_MODEL = process.env.GEMINI_MODEL || 'gemini-3.6-flash';
const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY;
// How many days back to check for finished matches. Default 3 is plenty
// for the 6-hourly schedule. Raise it temporarily (e.g. LOOKBACK_DAYS=14)
// for a one-off catch-up run after fixing team name aliases.
const LOOKBACK_DAYS = parseInt(process.env.LOOKBACK_DAYS || '3', 10);

// Pacing and retries for the AI calls. These exist because the failure
// they prevent is silent and total: one rate-limit wall used to mark
// every remaining match of the day as skipped, with no reason recorded.
const AI_MIN_GAP_MS = parseInt(process.env.AI_MIN_GAP_MS || '4500', 10);
const AI_MAX_RETRIES = parseInt(process.env.AI_MAX_RETRIES || '4', 10);
// How many matches to price in a single AI request. One request per
// MATCHDAY instead of one per match: a 10-match Saturday costs one call,
// not ten, which is what keeps a real matchday inside the free tier's
// daily cap. Set to 1 to go back to one call per match.
const AI_BATCH_SIZE = Math.max(1, Math.min(25, parseInt(process.env.AI_BATCH_SIZE || '10', 10)));
// Output token ceiling per AI call. Only worth touching if the log says
// the model ran out of budget mid-answer.
const AI_MAX_OUTPUT = parseInt(process.env.AI_MAX_OUTPUT || '0', 10);
// If this many AI calls fail back to back, the provider is down or the
// daily quota is gone. Stop the run rather than writing dozens of
// skipped rows — unlogged matches get picked up on the next run.
const AI_FAIL_STREAK_ABORT = parseInt(process.env.AI_FAIL_STREAK_ABORT || '4', 10);

// Auto-apply: when on, routine price moves are applied straight away
// with no approval step. Anything larger than AUTO_APPLY_MAX_PCT is
// still held for review — those are the ones most likely to be a bad
// team match or a misread scoreline, and they are also the ones that
// would do the most damage to the leaderboard if wrong.
const AUTO_APPLY = (process.env.AUTO_APPLY || 'false').toLowerCase() === 'true';
const AUTO_APPLY_MAX_PCT = parseFloat(process.env.AUTO_APPLY_MAX_PCT || '8');

let supabase; // created inside main(), after the required-variable check below

// football-data.org competition code -> your `league` key in Supabase.
// Only the leagues this free data source actually covers.
const COMPETITIONS = {
  PL:  'epl',
  PD:  'laliga',
  SA:  'seriea',
  BL1: 'bundesliga',
  FL1: 'ligue1',
  CL:  'championsleague',
  ELC: 'championship',   // English Championship
  PPL: 'portugal',       // Primeira Liga
  DED: 'eredivisie',     // Eredivisie
  BSA: 'brazil',         // Brasileirão Série A
};

// ============================================================
// Team name matching
//
// football-data.org team names -> the exact names stored in your
// teams table. Only names that DIFFER need an entry: fold() already
// strips accents, punctuation and FC/CF/AFC-style noise, so
// "Middlesbrough FC" matches "Middlesbrough" with no alias at all.
//
// Any name that can't be resolved is printed in the run summary at the
// end of the log, grouped by league and already formatted as alias
// lines, so adding a missing club is copy-and-paste rather than
// detective work.
// ============================================================
const NAME_ALIASES = {
  // Premier League
  'Manchester City FC': 'Manchester City', 'Arsenal FC': 'Arsenal', 'Liverpool FC': 'Liverpool',
  'Manchester United FC': 'Manchester United', 'Chelsea FC': 'Chelsea', 'Tottenham Hotspur FC': 'Tottenham Hotspur',
  'Newcastle United FC': 'Newcastle United', 'Aston Villa FC': 'Aston Villa',
  'Brighton & Hove Albion FC': 'Brighton', 'Nottingham Forest FC': 'Nottm Forest',
  'Crystal Palace FC': 'Crystal Palace', 'Wolverhampton Wanderers FC': 'Wolves',
  'Ipswich Town FC': 'Ipswich Town', 'Hull City AFC': 'Hull', 'Coventry City FC': 'Coventry',
  'Leeds United FC': 'Leeds', 'Sunderland AFC': 'Sunderland', 'Everton FC': 'Everton',
  'Brentford FC': 'Brentford', 'Fulham FC': 'Fulham', 'AFC Bournemouth': 'Bournemouth',
  // La Liga
  'Real Madrid CF': 'Real Madrid', 'FC Barcelona': 'Barcelona', 'Club Atlético de Madrid': 'Atlético Madrid',
  'Athletic Club': 'Athletic Bilbao', 'Real Sociedad de Fútbol': 'Real Sociedad', 'Villarreal CF': 'Villarreal',
  'Real Betis Balompié': 'Betis', 'Sevilla FC': 'Sevilla', 'Valencia CF': 'Valencia',
  'RC Celta de Vigo': 'Celta', 'Rayo Vallecano de Madrid': 'Rayo Vallecano', 'Getafe CF': 'Getafe',
  'RCD Espanyol de Barcelona': 'Espanyol', 'Deportivo Alavés': 'Alavés', 'Levante UD': 'Levante',
  'CA Osasuna': 'Osasuna', 'Elche CF': 'Elche', 'RC Deportivo de La Coruña': 'Deportivo',
  'Real Racing Club': 'Racing Santander', 'Málaga CF': 'Málaga',
  // Serie A
  'FC Internazionale Milano': 'Inter Milan', 'AC Milan': 'AC Milan', 'Juventus FC': 'Juventus',
  'SSC Napoli': 'Napoli', 'AS Roma': 'AS Roma', 'Atalanta BC': 'Atalanta',
  'SS Lazio': 'Lazio', 'ACF Fiorentina': 'Fiorentina', 'Bologna FC 1909': 'Bologna',
  'Torino FC': 'Torino', 'Udinese Calcio': 'Udinese', 'Genoa CFC': 'Genoa',
  'US Sassuolo Calcio': 'Sassuolo', 'Cagliari Calcio': 'Cagliari', 'Parma Calcio 1913': 'Parma',
  'US Lecce': 'Lecce', 'AC Monza': 'Monza', 'Como 1907': 'Como',
  'Venezia FC': 'Venezia', 'Frosinone Calcio': 'Frosinone',
  // Bundesliga
  'FC Bayern München': 'Bayern Munich', 'Borussia Dortmund': 'Borussia Dortmund', 'Bayer 04 Leverkusen': 'Bayer Leverkusen',
  'RB Leipzig': 'RB Leipzig', 'Eintracht Frankfurt': 'Eintracht Frankfurt', 'VfB Stuttgart': 'VfB Stuttgart',
  'TSG 1899 Hoffenheim': 'Hoffenheim', 'Sport-Club Freiburg': 'Freiburg',
  'Borussia Mönchengladbach': 'Mönchengladbach', 'SV Werder Bremen': 'Werder',
  '1. FC Union Berlin': 'Union Berlin', '1. FSV Mainz 05': 'Mainz', 'FC Augsburg': 'Augsburg',
  'Hamburger SV': 'Hamburg', '1. FC Köln': 'Köln', 'FC Schalke 04': 'Schalke',
  'SC Paderborn 07': 'Paderborn', 'SV 07 Elversberg': 'SV Elversberg',
  // Ligue 1
  'Paris Saint-Germain FC': 'Paris Saint-Germain', 'Olympique de Marseille': 'Marseille', 'AS Monaco FC': 'Monaco',
  'Olympique Lyonnais': 'Lyon', 'LOSC Lille': 'Lille', 'OGC Nice': 'Nice',
  'Racing Club de Lens': 'Lens', 'Stade Rennais FC 1901': 'Rennes',
  'Racing Club de Strasbourg Alsace': 'Strasbourg', 'Toulouse FC': 'Toulouse',
  'Paris FC': 'Paris FC', 'FC Lorient': 'Lorient', 'Stade Brestois 29': 'Brest',
  'Angers SCO': 'Angers', 'Le Havre AC': 'Le Havre', 'AJ Auxerre': 'Auxerre',
  'ES Troyes AC': 'Troyes', 'Le Mans FC': 'Le Mans',
  // Championship
  'West Ham United FC': 'West Ham', 'Middlesbrough FC': 'Middlesbrough',
  'Southampton FC': 'Southampton', 'Norwich City FC': 'Norwich City',
  'Burnley FC': 'Burnley', 'Millwall FC': 'Millwall', 'Sheffield United FC': 'Sheffield United',
  'Derby County FC': 'Derby County', 'Bristol City FC': 'Bristol City', 'Wrexham AFC': 'Wrexham',
  'Queens Park Rangers FC': 'QPR', 'Swansea City AFC': 'Swansea',
  'Birmingham City FC': 'Birmingham', 'West Bromwich Albion FC': 'West Bromwich Albion',
  'Watford FC': 'Watford', 'Portsmouth FC': 'Portsmouth', 'Cardiff City FC': 'Cardiff City',
  'Blackburn Rovers FC': 'Blackburn Rovers', 'Stoke City FC': 'Stoke City',
  'Preston North End FC': 'Preston', 'Bolton Wanderers FC': 'Bolton',
  'Charlton Athletic FC': 'Charlton', 'Lincoln City FC': 'Lincoln City',

  // ---------- Primeira Liga (full roster) ----------
  'Sport Lisboa e Benfica': 'Benfica', 'SL Benfica': 'Benfica',
  'FC Porto': 'FC Porto', 'Futebol Clube do Porto': 'FC Porto',
  'Sporting Clube de Portugal': 'Sporting CP', 'Sporting CP': 'Sporting CP',
  'Sporting Clube de Braga': 'Sporting Braga', 'SC Braga': 'Sporting Braga',
  'Vitória Sport Clube': 'Vitória SC', 'Vitória SC': 'Vitória SC', 'Vitória Guimarães': 'Vitória SC',
  'FC Famalicão': 'Famalicão', 'Futebol Clube de Famalicão': 'Famalicão',
  'CD Santa Clara': 'Santa Clara', 'Santa Clara': 'Santa Clara',
  'Gil Vicente FC': 'Gil Vicente',
  'FC Arouca': 'Arouca',
  'Académico de Viseu FC': 'Académico de Viseu', 'Académico Viseu': 'Académico de Viseu',
  'GD Estoril Praia': 'Estoril', 'Estoril Praia': 'Estoril',
  'FC Alverca': 'Alverca', 'Alverca': 'Alverca',
  'Moreirense FC': 'Moreirense',
  'CD Nacional': 'Nacional', 'Nacional': 'Nacional',
  'CS Marítimo': 'Marítimo', 'Marítimo': 'Marítimo',
  'Rio Ave FC': 'Rio Ave',
  'CF Estrela da Amadora': 'Estrela Amadora', 'Estrela da Amadora': 'Estrela Amadora',
  'Casa Pia AC': 'Casa Pia',

  // ---------- Eredivisie (full roster) ----------
  'AFC Ajax': 'Ajax', 'Ajax Amsterdam': 'Ajax',
  'PSV': 'PSV Eindhoven', 'PSV Eindhoven': 'PSV Eindhoven',
  'Feyenoord Rotterdam': 'Feyenoord',
  'AZ': 'AZ Alkmaar', 'AZ Alkmaar': 'AZ Alkmaar',
  "FC Twente '65": 'FC Twente', 'FC Twente': 'FC Twente',
  'FC Utrecht': 'FC Utrecht',
  'FC Groningen': 'Groningen',
  'SC Heerenveen': 'Heerenveen',
  'NEC': 'NEC', 'N.E.C.': 'NEC', 'NEC Nijmegen': 'NEC',
  'Go Ahead Eagles': 'Go Ahead Eagles',
  'Fortuna Sittard': 'Fortuna Sittard',
  'SBV Excelsior': 'Excelsior', 'Excelsior Rotterdam': 'Excelsior',
  'Sparta Rotterdam': 'Sparta Rotterdam',
  'SC Telstar': 'Telstar', 'Telstar': 'Telstar',
  'SC Cambuur-Leeuwarden': 'Cambuur', 'SC Cambuur': 'Cambuur',
  'PEC Zwolle': 'PEC Zwolle',
  'ADO Den Haag': 'Den Haag',
  'Willem II Tilburg': 'Willem II', 'Willem II': 'Willem II',

  // ---------- Brazil Série A ----------
  'CR Flamengo': 'Flamengo', 'SE Palmeiras': 'Palmeiras', 'São Paulo FC': 'São Paulo',
  'SC Corinthians Paulista': 'Corinthians', 'Fluminense FC': 'Fluminense',
  'Grêmio FBPA': 'Grêmio', 'CA Mineiro': 'Atlético Mineiro', 'Clube Atlético Mineiro': 'Atlético Mineiro',
  'CA Paranaense': 'Athletico-PR', 'Club Athletico Paranaense': 'Athletico-PR',
  'Cruzeiro EC': 'Cruzeiro', 'EC Bahia': 'Bahia', 'RB Bragantino': 'Bragantino',
  'Coritiba FBC': 'Coritiba', 'Botafogo FR': 'Botafogo', 'EC Vitória': 'Vitória',
  'Santos FC': 'Santos', 'SC Internacional': 'Internacional', 'Mirassol FC': 'Mirassol',
  'Clube do Remo': 'Remo', 'CR Vasco da Gama': 'Vasco', 'Associação Chapecoense de Futebol': 'Chapecoense',
};

// The Champions League needs its OWN table, because your UCL rows use
// short names ("Man City (UCL)", "Dortmund (UCL)", "Atlético (UCL)")
// while the domestic rows use long ones ("Manchester City", "Borussia
// Dortmund", "Atlético Madrid"). One shared table can only point each
// feed name at one of the two, so every UCL club whose short name
// differs from its domestic one would silently fail to match.
//
// Values here are the site name WITHOUT the " (UCL)" suffix, since
// findTeamRow strips that before comparing.
const UCL_ALIASES = {
  'Arsenal FC': 'Arsenal',
  'Manchester City FC': 'Man City',
  'FC Bayern München': 'Bayern',
  'Liverpool FC': 'Liverpool',
  'FC Barcelona': 'Barcelona',
  'Real Madrid CF': 'Real Madrid',
  'Aston Villa FC': 'Aston Villa',
  'Paris Saint-Germain FC': 'PSG',
  'Manchester United FC': 'Man Utd',
  'Borussia Dortmund': 'Dortmund',
  'FC Internazionale Milano': 'Inter',
  'VfB Stuttgart': 'VfB Stuttgart',
  'Sporting Clube de Portugal': 'SCP',
  'Como 1907': 'Como',
  'Real Betis Balompié': 'Betis',
  'AS Roma': 'Roma',
  'Racing Club de Lens': 'Lens',
  'FC Porto': 'Porto',
  'AEK Athens FC': 'AEK', 'AEK Athens': 'AEK',
  'Club Atlético de Madrid': 'Atlético',
  'FK Bodø/Glimt': 'Bodø/Glimt',
  'PSV': 'PSV',
  'Fenerbahçe SK': 'Fenerbahçe',
  'Club Brugge KV': 'Club Brugge',
  'SSC Napoli': 'Napoli',
  'RB Leipzig': 'RB Leipzig',
  'Villarreal CF': 'Villarreal',
  'FC Shakhtar Donetsk': 'Shakhtar Donetsk', 'Shakhtar Donetsk': 'Shakhtar Donetsk',
  'Viking FK': 'Viking',
  'LOSC Lille': 'LOSC',
  'Feyenoord Rotterdam': 'Feyenoord',
  'Galatasaray SK': 'Galatasaray',
  'SK Slavia Praha': 'Slavia Praha',
  'LASK': 'LASK', 'LASK Linz': 'LASK',
  'Sabah FK': 'Sabah',
  'ŠK Slovan Bratislava': 'Slovan Bratislava', 'SK Slovan Bratislava': 'Slovan Bratislava',
};

// Letters that don't decompose under NFD and so need spelling out.
const LETTER_FIXES = { 'ø':'o', 'æ':'ae', 'œ':'oe', 'ß':'ss', 'ð':'d', 'đ':'d', 'ł':'l', 'þ':'th', 'ı':'i' };

// Reduce a club name to a comparable core: accents folded, punctuation
// dropped, generic club-type noise removed. Applied to BOTH sides of
// every comparison, so it can only make matching more forgiving —
// "Famalicão"/"Famalicao", "N.E.C."/"NEC", "Bodø/Glimt"/"Bodo Glimt"
// all collapse to the same string.
function fold(name){
  return String(name)
    .normalize('NFD').replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[øæœßðđłþı]/g, c => LETTER_FIXES[c] || c)
    .replace(/[^a-z0-9 ]+/g, '')
    .replace(/\b(fc|cf|afc|cfc|sad)\b/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function normalize(name, isUCL){
  const aliased = (isUCL && UCL_ALIASES[name]) || NAME_ALIASES[name] || name;
  return fold(aliased);
}

// Returns an array of matches, or null if the feed itself errored —
// which is a different thing from "no matches played", and shouldn't
// be treated as a quiet day.
async function fetchFinishedMatches(code, dateFrom, dateTo){
  const url = `https://api.football-data.org/v4/competitions/${code}/matches?status=FINISHED&dateFrom=${dateFrom}&dateTo=${dateTo}`;
  const res = await fetch(url, { headers: { 'X-Auth-Token': FOOTBALL_DATA_API_KEY } });
  if(!res.ok){ console.error(`football-data.org error for ${code}:`, res.status, (await res.text()).slice(0, 300)); return null; }
  const data = await res.json();
  return data.matches || [];
}

// ============================================================
// Modular AI provider layer.
//
// Prices a BATCH of matches in one request — one call per matchday
// rather than one per match. A 10-match Saturday used to cost 10
// requests; it now costs 1, which is what keeps a real matchday inside
// the free tier's daily cap instead of blowing through it.
//
// Both providers return the same shape:
//   { moves: Map(index -> { home, away, reason }) }  on success
//   { error: '<why>' }                              on failure
// The Map is keyed by each match's position in the batch, so a reply
// that covers only some of them is still usable — the missing ones get
// retried rather than the whole batch being thrown away. Swapping
// AI_PROVIDER never touches anything else.
// ============================================================
function buildBatchPrompt(items){
  const lines = items.map((it, i) =>
    `${i + 1}. [${it.competitionName}] ${it.homeName} ${it.homeScore} - ${it.awayScore} ${it.awayName}`
  ).join('\n');

  return `These ${items.length} football match${items.length === 1 ? '' : 'es'} have just finished. For EACH one, decide how much each team's stock price should move as a percentage, reflecting the result.

Consider margin of victory, and that a home draw is milder than an away draw. Winners go up, losers go down, draws move slightly for both (usually toward the run of play if the score suggests one side dominated). Keep moves realistic: routine results should be small (1-4%), landslide or shock results can be larger (up to 15%), draws are usually under 2%. Judge each match on its own merits — do not make them all the same size.

Matches:
${lines}

Respond with ONLY a JSON array, one object per match, covering all ${items.length}, nothing else, no markdown fences:
[{"match": <the number above>, "home_delta_pct": <number, can be negative>, "away_delta_pct": <number, can be negative>, "reason": "<one short sentence>"}]`;
}

// Pull the JSON array out of a reply and key it by match number. Tolerant
// on purpose: fenced code, a wrapper object, or prose either side of the
// array are all survivable, and an entry missing its "match" number falls
// back to its position. Anything the model omits simply isn't in the Map.
function parseBatchResponse(text, expectedCount){
  const cleaned = text.replace(/```json|```/g, '').trim();
  let parsed;
  try{
    parsed = JSON.parse(cleaned);
  } catch(e){
    const span = cleaned.match(/\[[\s\S]*\]/);
    let ok = false;
    if(span){
      try{ parsed = JSON.parse(span[0]); ok = true; } catch(e2){ /* fall through */ }
    }
    if(!ok){
      // Last resort: a reply cut off mid-array still has whole objects in
      // it. Salvage those rather than discarding a batch of good answers
      // because the final entry was clipped.
      const objects = cleaned.match(/\{[^{}]*\}/g) || [];
      const salvaged = [];
      for(const o of objects){
        try{ salvaged.push(JSON.parse(o)); } catch(e3){ /* skip that one */ }
      }
      if(salvaged.length === 0){
        console.error('  Could not parse AI response:', cleaned.slice(0, 400));
        return { error: 'the AI returned something that was not valid JSON' };
      }
      console.log(`  AI reply was malformed — salvaged ${salvaged.length} complete entr${salvaged.length === 1 ? 'y' : 'ies'} from it.`);
      parsed = salvaged;
    }
  }

  // Accept a bare array, or an object with the array under some key.
  let rows = Array.isArray(parsed) ? parsed : null;
  if(!rows && parsed && typeof parsed === 'object'){
    rows = Object.values(parsed).find(v => Array.isArray(v)) || null;
    // A single-match batch may legitimately come back as one object.
    if(!rows && ('home_delta_pct' in parsed)) rows = [parsed];
  }
  if(!rows) return { error: 'the AI reply contained no list of price moves' };

  const clamp = (n) => Math.max(-20, Math.min(20, Number(n) || 0));
  const moves = new Map();
  rows.forEach((row, position) => {
    if(!row || typeof row !== 'object') return;
    const num = Number(row.match);
    // "match" is 1-based in the prompt; fall back to list position.
    const idx = Number.isFinite(num) ? num - 1 : position;
    if(idx < 0 || idx >= expectedCount) return;
    if(row.home_delta_pct == null && row.away_delta_pct == null) return;
    moves.set(idx, {
      home: clamp(row.home_delta_pct),
      away: clamp(row.away_delta_pct),
      reason: typeof row.reason === 'string' ? row.reason : '',
    });
  });

  if(moves.size === 0) return { error: 'the AI reply had no usable price moves in it' };
  return { moves };
}

const sleep = (ms) => new Promise(r => setTimeout(r, ms));
let lastAICallAt = 0;

// Hold a minimum gap between AI calls. This is what stops a busy
// matchday from walking into the free tier's per-minute cap.
async function paceAICall(){
  const wait = AI_MIN_GAP_MS - (Date.now() - lastAICallAt);
  if(wait > 0) await sleep(wait);
  lastAICallAt = Date.now();
}

// 429 = rate limited, 5xx = provider wobble, 408 = timeout. All worth
// retrying. A 400 or 403 is a configuration problem and retrying it
// just burns the clock.
function isRetryable(status){ return status === 429 || status === 408 || (status >= 500 && status < 600); }

// Errors there is no point carrying on through. A 429 that survived every
// retry means the quota is gone for now; 401/403 means the key is wrong;
// 400/404 means the model name is wrong. None of those will fix
// themselves in the next few seconds, and because one batch now covers
// ten matches, waiting for a streak of four would abandon forty of them.
function isFatal(status){
  return status === 429 || status === 401 || status === 403 || status === 400 || status === 404;
}
function fatalHint(status){
  if(status === 429) return 'rate limit or daily quota exhausted — this resets on its own';
  if(status === 401 || status === 403) return 'the API key was rejected';
  if(status === 400 || status === 404) return 'the request or model name was rejected';
  return '';
}

// Two request shapes. "strict" asks Gemini to emit JSON directly and to
// skip its reasoning pass — the current Flash models are thinking models,
// and thinking both costs output tokens and puts prose in the reply.
// "plain" is the fallback for any model or endpoint that rejects those
// options, so an unsupported setting can never take the whole run down.
function geminiBody(items, strict){
  const generationConfig = {
    // Generous: thinking tokens, when enabled, are drawn from this same
    // budget, so a tight limit gets spent before the answer even starts.
    maxOutputTokens: AI_MAX_OUTPUT || (1500 + items.length * 220),
    temperature: 0.4,
  };
  if(strict){
    generationConfig.responseMimeType = 'application/json';
    generationConfig.thinkingConfig = { thinkingBudget: 0 };
  }
  return JSON.stringify({
    contents: [{ parts: [{ text: buildBatchPrompt(items) }] }],
    generationConfig,
  });
}

// A thinking model returns several parts, and the reasoning trace can come
// FIRST. Reading parts[0] therefore grabs the thinking, not the answer —
// which is exactly how valid replies ended up reported as invalid JSON.
// Take every non-thought part; fall back to all parts if that's empty.
function extractGeminiText(data){
  const candidate = data.candidates?.[0];
  const parts = candidate?.content?.parts || [];
  const textOf = (list) => list.filter(p => typeof p?.text === 'string').map(p => p.text).join('');
  const answer = textOf(parts.filter(p => !p?.thought));
  return {
    text: (answer || textOf(parts)).trim(),
    finishReason: candidate?.finishReason || '',
    partCount: parts.length,
  };
}

async function askGemini(items){
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent`;
  let strict = true;
  let body = geminiBody(items, strict);

  for(let attempt = 0; attempt <= AI_MAX_RETRIES; attempt++){
    await paceAICall();
    let res;
    try{
      res = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-goog-api-key': GEMINI_API_KEY },
        body,
      });
    } catch(e){
      if(attempt < AI_MAX_RETRIES){ await sleep(2000 * Math.pow(2, attempt)); continue; }
      return { error: `network error reaching Gemini: ${e.message}` };
    }

    if(res.ok){
      const data = await res.json();
      const { text, finishReason, partCount } = extractGeminiText(data);

      if(!text){
        if(finishReason === 'MAX_TOKENS'){
          return { error: 'Gemini used its whole token budget before answering (raise AI_MAX_OUTPUT or lower AI_BATCH_SIZE)' };
        }
        return { error: `Gemini returned an empty response${finishReason ? ' (finishReason: ' + finishReason + ')' : ''}` };
      }

      const parsed = parseBatchResponse(text, items.length);
      if(parsed.error){
        // Say what the reply actually looked like, so the next failure is
        // diagnosable from the log alone rather than by guesswork.
        console.error(`  Reply had ${partCount} part(s), finishReason ${finishReason || 'unknown'}, ${text.length} chars.`);
        if(finishReason === 'MAX_TOKENS'){
          return { error: 'Gemini ran out of output tokens mid-answer (lower AI_BATCH_SIZE, or raise AI_MAX_OUTPUT)' };
        }
      }
      return parsed;
    }

    // An option this model doesn't support shouldn't cost us the run —
    // drop back to the plain request and try once more before giving up.
    if(res.status === 400 && strict){
      const why = (await res.text()).slice(0, 300);
      console.log('  Gemini rejected the strict JSON request — retrying in plain mode.');
      console.log(`    (${why})`);
      strict = false;
      body = geminiBody(items, strict);
      continue;
    }

    const errText = (await res.text()).slice(0, 500);
    if(isRetryable(res.status) && attempt < AI_MAX_RETRIES){
      // Google usually says exactly how long to wait — use that if present.
      const hinted = /"retryDelay"\s*:\s*"(\d+)s"/.exec(errText);
      const backoff = hinted ? (parseInt(hinted[1], 10) + 1) * 1000 : 5000 * Math.pow(2, attempt);
      console.log(`  Gemini ${res.status} — waiting ${Math.round(backoff/1000)}s, retry ${attempt + 1}/${AI_MAX_RETRIES}.`);
      await sleep(backoff);
      continue;
    }
    console.error(`  Gemini API error ${res.status}:`, errText);
    const hint = fatalHint(res.status);
    return {
      error: `Gemini HTTP ${res.status}${hint ? ' — ' + hint : ''}`,
      fatal: isFatal(res.status),
    };
  }
  return { error: 'Gemini failed after all retries', fatal: true };
}

async function askClaude(items){
  const body = JSON.stringify({
    model: process.env.CLAUDE_MODEL || 'claude-haiku-4-5-20251001',
    max_tokens: AI_MAX_OUTPUT || (1500 + items.length * 220),
    messages: [{ role: 'user', content: buildBatchPrompt(items) }],
  });

  for(let attempt = 0; attempt <= AI_MAX_RETRIES; attempt++){
    await paceAICall();
    let res;
    try{
      res = await fetch('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-api-key': ANTHROPIC_API_KEY,
          'anthropic-version': '2023-06-01',
        },
        body,
      });
    } catch(e){
      if(attempt < AI_MAX_RETRIES){ await sleep(2000 * Math.pow(2, attempt)); continue; }
      return { error: `network error reaching Claude: ${e.message}` };
    }

    if(res.ok){
      const data = await res.json();
      const text = data.content?.[0]?.text?.trim() || '';
      if(!text) return { error: 'Claude returned an empty response' };
      return parseBatchResponse(text, items.length);
    }

    const errText = (await res.text()).slice(0, 500);
    if(isRetryable(res.status) && attempt < AI_MAX_RETRIES){
      const backoff = 5000 * Math.pow(2, attempt);
      console.log(`  Claude ${res.status} — waiting ${Math.round(backoff/1000)}s, retry ${attempt + 1}/${AI_MAX_RETRIES}.`);
      await sleep(backoff);
      continue;
    }
    console.error(`  Claude API error ${res.status}:`, errText);
    const hint = fatalHint(res.status);
    return {
      error: `Claude HTTP ${res.status}${hint ? ' — ' + hint : ''}`,
      fatal: isFatal(res.status),
    };
  }
  return { error: 'Claude failed after all retries', fatal: true };
}

async function askForPriceMoves(items){
  if(AI_PROVIDER === 'claude') return askClaude(items);
  return askGemini(items);
}

// Price a batch, then make ONE follow-up call for anything the model
// left out. A model that drops the last two matches of a ten-match list
// is a normal failure mode, and re-asking for just those two is far
// cheaper than discarding eight good answers and starting over.
//
// Returns { moves: Map(originalIndex -> move), error?: '<why>' }.
// An error means the whole batch failed; a Map short of some entries
// means those specific matches couldn't be priced.
async function priceBatch(items){
  const first = await askForPriceMoves(items);
  if(first.error) return { moves: new Map(), error: first.error, fatal: !!first.fatal };

  const moves = first.moves;
  const missing = items.map((_, i) => i).filter(i => !moves.has(i));
  if(missing.length === 0) return { moves };

  console.log(`  ${missing.length} of ${items.length} came back unpriced — asking again for just those.`);
  const retry = await askForPriceMoves(missing.map(i => items[i]));
  if(!retry.error){
    // Indexes in the retry are positions within `missing`, so map back.
    for(const [retryIdx, move] of retry.moves) {
      const originalIdx = missing[retryIdx];
      if(originalIdx !== undefined) moves.set(originalIdx, move);
    }
  }
  return { moves };
}
// ============================================================

// One query per league, cached — instead of one query per team per
// match. The old version couldn't tell a failed read apart from "team
// not found", which is exactly the confusion this whole fix is about,
// so a read failure now caches null and is reported as its own thing.
const leagueCache = new Map();
async function getLeagueTeams(league){
  if(leagueCache.has(league)) return leagueCache.get(league);
  const { data, error } = await supabase.from('teams').select('*').eq('league', league);
  if(error){
    console.error(`  Could not read teams for league "${league}":`, error.message);
    leagueCache.set(league, null);   // null = read failed, NOT "no teams"
    return null;
  }
  leagueCache.set(league, data || []);
  return data || [];
}

function findTeamRow(teams, teamName, isUCL){
  if(!teams) return null;
  const norm = normalize(teamName, isUCL);
  return teams.find(t => {
    const tName = isUCL ? t.name.replace(' (UCL)', '') : t.name;
    return fold(tName) === norm;
  }) || null;
}

// A match counts as "already handled" only if it produced a real result.
// Rows marked 'skipped' (no team matched, or the AI call failed) are
// deliberately NOT counted, so that once you add a missing alias the
// next run picks those matches up again instead of ignoring them forever.
async function alreadyLogged(matchId){
  const { data } = await supabase.from('match_events')
    .select('id, status').eq('source_match_id', String(matchId)).maybeSingle();
  return !!data && data.status !== 'skipped';
}

// Clear out a previous 'skipped' row for this match so the retry can
// insert a fresh one (source_match_id is unique, so the old row must go).
async function clearSkipped(matchId){
  await supabase.from('match_events').delete()
    .eq('source_match_id', String(matchId)).eq('status', 'skipped');
}

// Every skipped row now carries WHY. Without this, the admin page had
// to guess, and it guessed "no team matched" for every skip — including
// the ones that were really a failed AI call.
async function logSkip(baseRow, reason){
  const { error } = await supabase.from('match_events')
    .insert({ ...baseRow, status: 'skipped', skip_reason: reason });
  if(error) console.error('  Could not write the skipped row:', error.message);
}

async function main(){
  if(!FOOTBALL_DATA_API_KEY || !SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY){
    console.error('Missing a required environment variable (football-data / Supabase). Check your GitHub Secrets.');
    console.error(`  FOOTBALL_DATA_API_KEY set: ${!!FOOTBALL_DATA_API_KEY}`);
    console.error(`  SUPABASE_URL set: ${!!SUPABASE_URL}`);
    console.error(`  SUPABASE_SERVICE_ROLE_KEY set: ${!!SUPABASE_SERVICE_ROLE_KEY}`);
    process.exit(1);
  }
  if(AI_PROVIDER === 'gemini' && !GEMINI_API_KEY){ console.error('AI_PROVIDER is gemini but GEMINI_API_KEY is not set.'); process.exit(1); }
  if(AI_PROVIDER === 'claude' && !ANTHROPIC_API_KEY){ console.error('AI_PROVIDER is claude but ANTHROPIC_API_KEY is not set.'); process.exit(1); }

  supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  console.log(`Using AI provider: ${AI_PROVIDER}${AI_PROVIDER === 'gemini' ? ` (${GEMINI_MODEL})` : ''}`);
  console.log(`Batching: up to ${AI_BATCH_SIZE} match(es) per AI call.`);
  console.log(`Pacing: one AI call per ${AI_MIN_GAP_MS}ms, up to ${AI_MAX_RETRIES} retries each.`);
  console.log(AUTO_APPLY
    ? `Auto-apply: ON — moves up to ${AUTO_APPLY_MAX_PCT}% applied immediately, anything larger held for review.`
    : 'Auto-apply: OFF — every change waits for approval in admin.');

  const now = new Date();
  const dateTo = now.toISOString().slice(0,10);
  const dateFrom = new Date(now.getTime() - LOOKBACK_DAYS*24*60*60*1000).toISOString().slice(0,10);
  console.log(`Window: ${dateFrom} to ${dateTo}`);

  const summary = { considered: 0, applied: 0, held: 0, pending: 0, noTeam: 0, aiFailed: 0, dbFailed: 0 };
  const unmatched = new Map();   // competition code -> Set of unresolved feed names
  let aiFailStreak = 0;
  let aborted = false;

  for(const [code, leagueKey] of Object.entries(COMPETITIONS)){
    if(aborted) break;
    console.log(`\nChecking ${code} (${leagueKey})...`);
    const matches = await fetchFinishedMatches(code, dateFrom, dateTo);
    if(matches === null){ console.log('  Skipping this competition — the data feed errored.'); continue; }
    console.log(`  ${matches.length} finished match(es) found in range.`);

    // ---- Phase 1: work out which matches actually need pricing ----
    // Everything resolvable without the AI is settled here, so the batch
    // we send contains only matches that genuinely need an answer.
    const toPrice = [];
    for(const match of matches){
      const matchId = String(match.id);
      if(await alreadyLogged(matchId)){ continue; }
      // If this match was skipped on an earlier run, remove that row so the
      // retry below can insert fresh (source_match_id is unique).
      await clearSkipped(matchId);

      const homeScore = match.score?.fullTime?.home;
      const awayScore = match.score?.fullTime?.away;
      if(homeScore == null || awayScore == null) continue;

      summary.considered++;
      const isUCL = code === 'CL';
      const teams = await getLeagueTeams(leagueKey);
      const homeTeam = findTeamRow(teams, match.homeTeam.name, isUCL);
      const awayTeam = findTeamRow(teams, match.awayTeam.name, isUCL);

      const baseRow = {
        source_match_id: matchId,
        competition: code,
        home_team_name: match.homeTeam.name,
        away_team_name: match.awayTeam.name,
        home_score: homeScore,
        away_score: awayScore,
        match_date: match.utcDate,
        home_team_id: homeTeam?.id || null,
        away_team_id: awayTeam?.id || null,
        ai_provider: AI_PROVIDER,
      };

      // A failed teams read is NOT a naming problem, and the two have
      // completely different fixes — so never report it as one.
      if(teams === null){
        console.log(`  ${match.homeTeam.name} v ${match.awayTeam.name} — could not read the ${leagueKey} teams from the database.`);
        await logSkip(baseRow, `Could not read the "${leagueKey}" teams from the database. This is a connection problem, not a team-name problem.`);
        summary.dbFailed++;
        continue;
      }

      if(!homeTeam){
        console.log(`  Could not match home team "${match.homeTeam.name}" (${leagueKey}).`);
        if(!unmatched.has(code)) unmatched.set(code, new Set());
        unmatched.get(code).add(match.homeTeam.name);
      }
      if(!awayTeam){
        console.log(`  Could not match away team "${match.awayTeam.name}" (${leagueKey}).`);
        if(!unmatched.has(code)) unmatched.set(code, new Set());
        unmatched.get(code).add(match.awayTeam.name);
      }

      if(!homeTeam && !awayTeam){
        await logSkip(baseRow,
          `Neither "${match.homeTeam.name}" nor "${match.awayTeam.name}" matched a team in your ${leagueKey} tab — add the clubs, or add an alias for them.`);
        summary.noTeam++;
        continue;
      }

      toPrice.push({
        baseRow,
        homeName: match.homeTeam.name,
        awayName: match.awayTeam.name,
        homeScore, awayScore,
        competitionName: match.competition?.name || code,
      });
    }

    if(toPrice.length === 0){ console.log('  Nothing new to price.'); continue; }

    // ---- Phase 2: price them in batches ----
    const batchCount = Math.ceil(toPrice.length / AI_BATCH_SIZE);
    console.log(`  ${toPrice.length} match(es) to price — ${batchCount} AI call${batchCount === 1 ? '' : 's'}.`);

    for(let start = 0; start < toPrice.length; start += AI_BATCH_SIZE){
      if(aborted) break;
      const batch = toPrice.slice(start, start + AI_BATCH_SIZE);
      for(const it of batch) console.log(`    ${it.homeName} ${it.homeScore}-${it.awayScore} ${it.awayName}`);

      const { moves, error: batchError, fatal } = await priceBatch(batch);

      if(batchError){
        // The whole call failed, so every match in it is unpriced. This
        // counts as ONE failed call against the streak, not one per match.
        console.log(`  Batch failed — ${batchError}`);
        for(const it of batch){
          await logSkip(it.baseRow, `AI pricing failed: ${batchError}. The teams matched fine — this is not a naming problem.`);
          summary.aiFailed++;
        }
        aiFailStreak++;

        // Stop at once on an error that won't resolve itself mid-run.
        // One batch is ten matches, so waiting for a streak would abandon
        // far more work than it saves.
        if(fatal){
          console.error(`\n!! Stopping this run — ${batchError}`);
          console.error('!! Everything already priced above is saved. The rest is left for the');
          console.error('!! next run, which retries skipped matches automatically.');
          aborted = true;
          break;
        }
        if(aiFailStreak >= AI_FAIL_STREAK_ABORT){
          console.error(`\n!! ${aiFailStreak} AI calls failed back to back — stopping this run.`);
          console.error('!! Remaining matches are left for the next run, which retries them.');
          aborted = true;
          break;
        }
        continue;
      }
      aiFailStreak = 0;

      for(let i = 0; i < batch.length; i++){
        const it = batch[i];
        const move = moves.get(i);

        if(!move){
          console.log(`  ${it.homeName} v ${it.awayName} — the AI left this one out of its reply.`);
          await logSkip(it.baseRow, 'AI pricing failed: the provider left this match out of its reply, twice. The teams matched fine — this is not a naming problem.');
          summary.aiFailed++;
          continue;
        }

        console.log(`  ${it.homeName} v ${it.awayName}: home ${move.home >= 0 ? '+' : ''}${move.home}% / away ${move.away >= 0 ? '+' : ''}${move.away}% — ${move.reason}`);

        const { data: inserted, error } = await supabase.from('match_events').insert({
          ...it.baseRow,
          home_delta_pct: move.home,
          away_delta_pct: move.away,
          ai_reason: move.reason,
          status: 'pending',
        }).select('id').single();

        if(error){ console.error('  Failed to log match event:', error.message); summary.dbFailed++; continue; }

        if(!AUTO_APPLY){
          console.log('    Logged for admin approval.');
          summary.pending++;
          continue;
        }

        // Only apply on our own if BOTH sides are within the safe band.
        const biggest = Math.max(Math.abs(move.home), Math.abs(move.away));
        if(biggest > AUTO_APPLY_MAX_PCT){
          console.log(`    Held for review — ${biggest}% exceeds the ${AUTO_APPLY_MAX_PCT}% auto-apply limit.`);
          summary.held++;
          continue;
        }

        const { error: applyErr } = await supabase.rpc('auto_apply_match_event', { p_event_id: inserted.id });
        if(applyErr){ console.error('    Auto-apply failed, left pending:', applyErr.message); summary.pending++; }
        else { console.log('    Applied automatically.'); summary.applied++; }
      }
    }
  }

  // ---------- Run summary ----------
  console.log('\n============ RUN SUMMARY ============');
  console.log(`Matches considered:        ${summary.considered}`);
  console.log(`Applied automatically:     ${summary.applied}`);
  console.log(`Held for your review:      ${summary.held}`);
  console.log(`Waiting for approval:      ${summary.pending}`);
  console.log(`Skipped — no team matched: ${summary.noTeam}`);
  console.log(`Skipped — AI call failed:  ${summary.aiFailed}`);
  console.log(`Skipped — database error:  ${summary.dbFailed}`);

  if(unmatched.size){
    console.log('\n--- Names the feed sent that your site has nothing for ---');
    console.log('(add the club in admin, or paste these lines into NAME_ALIASES and fill in the site name)');
    for(const [code, names] of unmatched){
      console.log(`\n  ${code} (${COMPETITIONS[code]}):`);
      for(const n of [...names].sort()) console.log(`    '${n.replace(/'/g, "\\'")}': '',`);
    }
  }

  if(summary.aiFailed > 0){
    console.log('\nNOTE: the AI-failed skips above are NOT a team-name problem. If they are');
    console.log('all HTTP 429, the free Gemini tier is rate-limiting — raise AI_MIN_GAP_MS');
    console.log('(try 8000) or wait for the daily quota to reset. Skipped matches retry');
    console.log('automatically on the next run, so no result is lost.');
  }
  console.log('=====================================');
  console.log(AUTO_APPLY
    ? '\nDone. Anything held for review is in admin.html -> Price Approvals.'
    : '\nDone. Review pending price changes in admin.html -> Price Approvals.');

  if(aborted) process.exit(1);
}

main().catch(err=>{ console.error('Fatal error:', err); process.exit(1); });
