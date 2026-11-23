// import-players.js
//
// Run weekly by GitHub Actions (.github/workflows/import-players.yml).
// Fills the player tables that the Daily Kickabout games use:
//
//   1. Links each club on the site to its Wikidata entry
//      (teams.wikidata_id). A link you set by hand is never overwritten.
//   2. Fetches every club's current squad from football-data.org, the same
//      feed the price updater uses: name, birth date, nationality and
//      position. Squads are kept up to date there, so this decides who
//      plays where.
//   3. Matches each squad player to Wikidata (CC0, free to use) by birth
//      date and name, for fame (how many Wikipedia languages have a page
//      on them) and continent.
//   4. Fetches every matched player's club-by-club career from Wikidata
//      (years, appearances, goals, loans) for Journeyman and Link-Up, and
//      their senior national-team spells so Link-Up can link international
//      teammates too.
//   5. Writes them to `players`, `player_careers` and `player_intl`.
//      Players no longer in a squad are marked inactive rather than deleted,
//      so a puzzle already in progress keeps working.
//
// Every squad player in the nine leagues is kept, including players at
// clubs that aren't listed for trading on the site.
//
// Needs FOOTBALL_DATA_API_KEY, SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY
// (the price updater's secrets). `node import-players.js --dry-run <folder>`
// skips Supabase: it reads teams from <folder>/teams.json (and squads from
// <folder>/squads.json if it's there), and writes what it would save to
// <folder>/players.json and <folder>/careers.json.

import { createClient } from '@supabase/supabase-js';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { COMPETITIONS, findTeamRow } from './update-prices.js';

// The site's league keys and the Wikidata league each one matches.
const LEAGUES = {
  epl: 'Q9448', laliga: 'Q324867', seriea: 'Q15804', bundesliga: 'Q82595', ligue1: 'Q13394',
  championship: 'Q19510', portugal: 'Q182994', eredivisie: 'Q167541', brazil: 'Q206813',
};

// Clubs the name matching can't find, or gets wrong, keyed by the club's
// name on the site. "Paris FC" folds to "paris", which is one of PSG's
// alternative names, so it must be pinned.
const CLUB_OVERRIDES = {
  'Paris FC': 'Q1051013',
  'QPR': 'Q18723',
  'Stade Rennes FC 1901': 'Q19509',
  'Toulouse': 'Q19518',
  'Cruzeiro': 'Q188277',
  'Cruziero': 'Q188277',
  'Coritiba': 'Q478317',
  'Mirassol': 'Q2622870',
  'Chapecoense': 'Q2536715',
  'Athletico-PR': 'Q506832',
  'Académico de Viseu': 'Q2410944',
};

// Careers are fetched for every player matched to Wikidata, so anyone can
// be used in Link-Up. Journeyman still picks from the best-known.
const CAREER_MIN_FAME = 0;

const SPARQL_URL = 'https://query.wikidata.org/sparql';
const USER_AGENT = 'PitchMarket/1.0 (https://pitchmarket.github.io/Pitchmarket/; daily football games)';
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

// ---------- Wikidata ----------

// One SPARQL query, as rows of { variable: value }. Uses the compact
// tab-separated format, and retries when Wikidata is busy.
async function sparql(query, label){
  for(let attempt = 0; attempt < 5; attempt++){
    const res = await fetch(SPARQL_URL, {
      method: 'POST',
      headers: { 'Accept': 'text/tab-separated-values', 'Content-Type': 'application/x-www-form-urlencoded', 'User-Agent': USER_AGENT },
      body: new URLSearchParams({ query }),
    });
    if(res.ok){
      const text = await res.text();
      await sleep(2500);
      // A busy Wikidata can stop mid-answer and still say "200 OK", so check
      // the answer is whole before trusting it.
      const rows = parseTsv(text);
      if(rows) return rows;
      if(attempt < 4){ console.log(`  Wikidata cut off the answer to ${label}, trying again in 30s.`); await sleep(30000); continue; }
      throw new Error(`Wikidata kept cutting off the answer to "${label}".`);
    }
    if([429, 500, 502, 503, 504].includes(res.status) && attempt < 4){
      const wait = (Number(res.headers.get('retry-after')) || 20 * (attempt + 1)) * 1000;
      console.log(`  Wikidata busy on ${label} (HTTP ${res.status}), waiting ${wait / 1000}s.`);
      await sleep(wait);
      continue;
    }
    throw new Error(`Wikidata query "${label}" failed: HTTP ${res.status} ${(await res.text()).slice(0, 200)}`);
  }
}

// Rows of { variable: value }, or null if the answer looks cut off: a line
// with the wrong number of columns, or an error message from the server.
export function parseTsv(text){
  if(/java\.|Exception|Query timeout/.test(text.slice(-3000))) return null;
  const lines = text.split('\n').filter(l => l.length);
  if(!lines.length) return null;
  const head = lines.shift().split('\t').map(h => h.replace(/^\?/, ''));
  if(lines.some(line => line.split('\t').length !== head.length)) return null;
  return lines.map(line => {
    const cells = line.split('\t');
    const row = {};
    head.forEach((h, i) => { row[h] = tsvValue(cells[i]); });
    return row;
  });
}
function tsvValue(cell){
  if(cell == null || cell === '') return null;
  let m = /^<http:\/\/www\.wikidata\.org\/entity\/(Q\d+)>$/.exec(cell);
  if(m) return m[1];
  m = /^"([\s\S]*)"(?:@[\w-]+|\^\^<[^>]+>)?$/.exec(cell);
  if(m) return m[1].replace(/\\t/g, '\t').replace(/\\n/g, '\n').replace(/\\"/g, '"').replace(/\\\\/g, '\\');
  return cell;   // plain numbers
}
const chunks = (arr, n) => Array.from({ length: Math.ceil(arr.length / n) }, (_, i) => arr.slice(i * n, i * n + n));

// ---------- 1. Clubs ----------

const NOISE = new Set('fc cf afc sc ac as ss ssc us rc cd ud sd ca se cr ec fk sk bk club de futbol football calcio sv vfb vfl tsg rcd sl sad cp fbpa fr the of 1'.split(' '));
export function foldClub(s){
  return s.normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/&/g, ' and ')
    .replace(/[^a-z0-9 ]/g, ' ').split(/\s+/).filter(w => w && !NOISE.has(w) && !/^(18|19)\d\d$/.test(w)).join(' ');
}

export async function linkClubs(teams){
  const rows = await sparql(`
    SELECT ?club ?league ?name ?links WHERE {
      VALUES ?league { ${Object.values(LEAGUES).map(q => 'wd:' + q).join(' ')} }
      ?club wdt:P118 ?league ; wdt:P31/wdt:P279* wd:Q476028 ; wikibase:sitelinks ?links .
      { ?club rdfs:label ?name FILTER(LANG(?name) IN ("en","mul")) } UNION { ?club skos:altLabel ?name FILTER(LANG(?name) = "en") }
    }`, 'clubs');
  // The full list is well over a thousand names; far fewer means Wikidata
  // answered only in part, and matching against it would link clubs wrongly.
  if(rows.length < 800) throw new Error(`The club list from Wikidata looks incomplete (${rows.length} names). Nothing changed; try again later.`);
  const names = new Map();   // "league|club" -> Set of folded names
  const fame = new Map();
  for(const r of rows){
    if(!r.club || !r.name) continue;
    const k = r.league + '|' + r.club;
    if(!names.has(k)) names.set(k, new Set());
    names.get(k).add(foldClub(r.name));
    fame.set(r.club, Number(r.links) || 0);
  }
  const unmatched = [];
  for(const t of teams){
    if(t.wikidata_id) continue;   // set by hand or by an earlier run
    if(CLUB_OVERRIDES[t.name]){ t.wikidata_id = CLUB_OVERRIDES[t.name]; t.linked = true; continue; }
    const lg = LEAGUES[t.league], f = foldClub(t.name), words = new Set(f.split(' '));
    let found = [...names].filter(([k, ns]) => k.startsWith(lg + '|') && ns.has(f));
    // Short site names ("Mönchengladbach") match a club whose name holds every word.
    if(!found.length) found = [...names].filter(([k, ns]) => k.startsWith(lg + '|') && [...ns].some(n => { const nw = new Set(n.split(' ')); return [...words].every(w => nw.has(w)); }));
    const ids = [...new Set(found.map(([k]) => k.split('|')[1]))].sort((a, b) => (fame.get(b) || 0) - (fame.get(a) || 0));
    if(ids.length){ t.wikidata_id = ids[0]; t.linked = true; }
    else unmatched.push(t);
  }
  // Two site clubs on one Wikidata club means a wrong match somewhere.
  const byId = new Map();
  for(const t of teams) if(t.wikidata_id) byId.set(t.wikidata_id, [...(byId.get(t.wikidata_id) || []), t.name]);
  const clashes = [...byId].filter(([, ns]) => ns.length > 1);
  // Never save a link that clashes: one of the two is wrong.
  const clashing = new Set(clashes.flatMap(([, ns]) => ns));
  for(const t of teams) if(t.linked && clashing.has(t.name)){ t.wikidata_id = null; t.linked = false; }
  return { unmatched, clashes };
}

// National and youth sides, recognised by name ("England national under-21
// football team", "Manchester United F.C. Under-23s", "Real Madrid Castilla").
const isNationalTeam = (label) => /national|under-?\s?\d\d|\bu-?\d\ds?\b|olympic|reserves|youth|academy|\bii\b|\bb team|castilla|primavera|jong /i.test(label || '');

// A senior men's national team ("England national association football
// team", "Brazil national football team"): its country, or null for any
// other side (under-21s, Olympic, B teams, women's, futsal...).
export function seniorNationalTeam(label){
  const m = /^(.+?) (?:men's )?national (?:association )?football team$/i.exec(label || '');
  if(!m || /under|\bu-?\d|olympic|\bb\b|women|youth|amateur|futsal|beach|universiade|military|student|\bA'/i.test(label)) return null;
  return m[1];
}

// ---------- 2. Squads (football-data.org) ----------

const FD_POSITIONS = { Goalkeeper: 'Goalkeeper', Defence: 'Defender', Midfield: 'Midfielder', Offence: 'Forward' };

// { competition code: [team with squad] } for every league the site covers
// (the Champions League is left out: its clubs' squads come from their leagues).
async function fetchSquads(key){
  const out = {};
  for(const code of Object.keys(COMPETITIONS).filter(c => c !== 'CL')){
    for(let attempt = 0; attempt < 4; attempt++){
      const res = await fetch(`https://api.football-data.org/v4/competitions/${code}/teams`, { headers: { 'X-Auth-Token': key } });
      if(res.ok){ out[code] = (await res.json()).teams || []; break; }
      if(res.status === 429 && attempt < 3){ console.log(`  football-data busy on ${code}, waiting 30s.`); await sleep(30000); continue; }
      throw new Error(`football-data.org refused the ${code} squads: HTTP ${res.status}`);
    }
    console.log(`  ${code}: ${out[code].length} clubs, ${out[code].reduce((n, t) => n + (t.squad || []).length, 0)} players.`);
    await sleep(7000);   // the free plan allows 10 requests a minute
  }
  return out;
}

// The site's label for each league, for clubs that aren't on the site.
const LEAGUE_LABELS = {
  epl: 'Premier League', laliga: 'La Liga', seriea: 'Serie A', bundesliga: 'Bundesliga', ligue1: 'Ligue 1',
  championship: 'Championship', portugal: 'Primeira Liga', eredivisie: 'Eredivisie', brazil: 'Brasileirão',
};
// "Norwich City FC" -> "Norwich City"
const cleanClub = (s) => (s || '').replace(/\s+(F\.?C\.?|A\.?F\.?C\.?|C\.?F\.?|S\.?C\.?)$/i, '').replace(/^(F\.?C\.?|A\.?C\.?)\s+/i, '').trim();

// One player per squad member. Players at a club the site lists are tied
// to it; players at any other club in the league are kept too, under the
// club's own name, so every player in the nine leagues can be guessed.
export function squadPlayers(squads, teams){
  const players = [], unmatched = [];
  for(const [code, fdTeams] of Object.entries(squads)){
    const league = COMPETITIONS[code];
    const siteTeams = teams.filter(t => t.league === league);
    const leagueLabel = siteTeams[0]?.league_label || LEAGUE_LABELS[league] || league;
    for(const ft of fdTeams){
      const team = findTeamRow(siteTeams, ft.name, false) || (ft.shortName && findTeamRow(siteTeams, ft.shortName, false));
      if(!team) unmatched.push(`${ft.name} (${code})`);
      for(const p of ft.squad || []){
        if(!p.name || !p.dateOfBirth) continue;
        players.push({
          fd_id: p.id, name: p.name, birth_date: p.dateOfBirth.slice(0, 10),
          nationality: p.nationality || null,
          position_group: FD_POSITIONS[p.position] || null,
          team_id: team ? team.id : null,
          club_name: team ? team.name : cleanClub(ft.shortName || ft.name),
          league: team ? team.league : league,
          league_label: team ? team.league_label : leagueLabel,
          // Who is in the same squad right now: Link-Up counts them as teammates.
          club_key: team?.wikidata_id || 'fd:' + ft.id,
          club_wikidata_id: team?.wikidata_id || null,
        });
      }
    }
  }
  return { players, unmatched };
}

// ---------- 3. Matching squad players to Wikidata ----------

const foldPerson = (s) => s.normalize('NFKD').replace(/[\u0300-\u036f]/g, '').replace(/ø/gi, 'o').replace(/æ/gi, 'ae')
  .replace(/ß/g, 'ss').replace(/ð/gi, 'd').replace(/þ/gi, 'th').toLowerCase().replace(/[^a-z ]/g, ' ').split(/\s+/).filter(Boolean);

// How well a Wikidata name matches the squad name: 3 for the same name,
// 2 when the surname (last word) of one appears in the other, else 0.
export function nameScore(squadName, wdName){
  const a = foldPerson(squadName), b = foldPerson(wdName);
  if(!a.length || !b.length) return 0;
  if(a.join(' ') === b.join(' ')) return 3;
  if(b.includes(a[a.length - 1]) || a.includes(b[b.length - 1])) return 2;
  return 0;
}

// Finds each squad player's Wikidata entry: men's footballers born on the
// same day, picked by name. Adds id (the Wikidata ID), fame, continent and
// the Wikidata name (usually the name fans know, with accents).
async function matchWikidata(players){
  const dobs = [...new Set(players.map(p => p.birth_date))];
  const byDob = new Map();   // birth date -> Map(id -> { names:Set, en, mul, fame })
  let n = 0;
  for(const group of chunks(dobs, 120)){
    n++;
    const rows = await sparql(`
      SELECT ?p ?dob ?en ?mul ?alt ?links WHERE {
        VALUES ?dob { ${group.map(d => `"${d}T00:00:00Z"^^xsd:dateTime`).join(' ')} }
        ?p wdt:P569 ?dob ; wdt:P106 wd:Q937857 ; wdt:P21 wd:Q6581097 ; wikibase:sitelinks ?links .
        OPTIONAL { ?p rdfs:label ?en FILTER(LANG(?en) = "en") }
        OPTIONAL { ?p rdfs:label ?mul FILTER(LANG(?mul) = "mul") }
        OPTIONAL { ?p skos:altLabel ?alt FILTER(LANG(?alt) = "en") }
      }`, `birth dates ${n}`);
    for(const r of rows){
      const d = r.dob.slice(0, 10);
      if(!byDob.has(d)) byDob.set(d, new Map());
      const m = byDob.get(d);
      if(!m.has(r.p)) m.set(r.p, { id: r.p, names: new Set(), en: r.en, mul: r.mul, fame: Number(r.links) || 0 });
      const c = m.get(r.p);
      for(const name of [r.en, r.mul, r.alt]) if(name) c.names.add(name);
    }
    if(n % 5 === 0) console.log(`  Birth dates ${Math.min(n * 120, dobs.length)} of ${dobs.length} checked.`);
  }

  const used = new Set();
  let matched = 0;
  for(const p of players){
    const cands = [...(byDob.get(p.birth_date)?.values() || [])].map(c => ({ c, score: Math.max(0, ...[...c.names].map(nm => nameScore(p.name, nm))) }))
      .filter(x => x.score >= 2 && !used.has(x.c.id))
      .sort((a, b) => b.score - a.score || b.c.fame - a.c.fame);
    const hit = cands[0]?.c;
    if(hit){
      used.add(hit.id);
      p.id = hit.id;
      p.fame = hit.fame;
      // Wikidata's English name is usually the one fans know ("Rodri",
      // "Vinícius Júnior"); keep the squad name if it's missing.
      const wdName = hit.en || hit.mul;
      if(wdName && !/^Q\d+$/.test(wdName)) p.name = wdName;
      matched++;
    } else {
      p.id = 'FD' + p.fd_id;
      p.fame = 0;
    }
  }
  console.log(`  ${matched} of ${players.length} squad players matched to Wikidata.`);

  // Continent of each nationality, from the matched players' countries.
  const qids = players.filter(p => p.id.startsWith('Q')).map(p => p.id);
  const continentOf = new Map();   // player id -> continent
  n = 0;
  for(const group of chunks(qids, 200)){
    n++;
    const rows = await sparql(`
      SELECT ?p ?contLabel WHERE {
        VALUES ?p { ${group.map(q => 'wd:' + q).join(' ')} }
        { ?p wdt:P1532 ?c } UNION { ?p wdt:P27 ?c }
        ?c wdt:P30 ?cont .
        SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
      }`, `continents ${n}`);
    for(const r of rows) if(r.contLabel && !continentOf.has(r.p)) continentOf.set(r.p, r.contLabel === 'Insular Oceania' ? 'Oceania' : r.contLabel);
  }
  // Squad nationalities to continents, learned from the matched players, so
  // unmatched players get one too.
  const votes = new Map();
  for(const p of players){
    const c = continentOf.get(p.id);
    if(!c || !p.nationality) continue;
    if(!votes.has(p.nationality)) votes.set(p.nationality, new Map());
    votes.get(p.nationality).set(c, (votes.get(p.nationality).get(c) || 0) + 1);
  }
  for(const p of players){
    const v = votes.get(p.nationality);
    p.continent = v ? [...v].sort((a, b) => b[1] - a[1])[0][0] : (continentOf.get(p.id) || null);
  }
  return players;
}

// ---------- 4. Careers ----------

export async function fetchCareers(players, teams){
  const siteName = new Map(teams.filter(t => t.wikidata_id).map(t => [t.wikidata_id, t.name]));
  const wanted = players.filter(p => p.id.startsWith('Q') && p.fame >= CAREER_MIN_FAME).map(p => p.id);
  const born = new Map(players.map(p => [p.id, p.birth_date ? Number(p.birth_date.slice(0, 4)) : null]));
  const careers = new Map();
  const intl = new Map();   // "player|team" -> national-team spell
  let n = 0;
  for(const group of chunks(wanted, 40)){
    n++;
    const rows = await sparql(`
      SELECT ?p ?club ?clubLabel ?start ?end ?apps ?goals ?how WHERE {
        VALUES ?p { ${group.map(q => 'wd:' + q).join(' ')} }
        ?p p:P54 ?st . ?st ps:P54 ?club .
        OPTIONAL { ?st pq:P580 ?start } OPTIONAL { ?st pq:P582 ?end }
        OPTIONAL { ?st pq:P1350 ?apps } OPTIONAL { ?st pq:P1351 ?goals }
        OPTIONAL { ?st pq:P1642 ?how }
        SERVICE wikibase:label { bd:serviceParam wikibase:language "en,mul". }
      }`, `careers ${n}`);
    for(const r of rows){
      const country = seniorNationalTeam(r.clubLabel);
      if(country){
        // One spell per player and country, from their first call-up to
        // their last (still going if any spell has no end). With no start
        // year on file, count from when they turned 18.
        const k = r.p + '|' + r.club;
        const start = r.start ? Number(r.start.slice(0, 4)) : (born.get(r.p) ? born.get(r.p) + 18 : null);
        const end = r.end ? Number(r.end.slice(0, 4)) : null;
        const prev = intl.get(k);
        if(!prev) intl.set(k, { player_id: r.p, team_id: r.club, team: country, start_year: start, end_year: end, open: !r.end });
        else {
          if(start != null && (prev.start_year == null || start < prev.start_year)) prev.start_year = start;
          if(!r.end) prev.open = true;
          else if(prev.end_year == null || end > prev.end_year) prev.end_year = end;
        }
        continue;
      }
      if(isNationalTeam(r.clubLabel) || /^Q\d+$/.test(r.clubLabel || '')) continue;
      if(!careers.has(r.p)) careers.set(r.p, new Map());
      const key = r.club + '|' + (r.start || '');
      const spells = careers.get(r.p);
      const prev = spells.get(key);
      const loan = /loan/i.test(r.how || '') || r.how === 'Q2914547';
      const row = {
        club_id: r.club,   // Wikidata ID: Link-Up matches teammates on this
        club: siteName.get(r.club) || r.clubLabel.replace(/\s+(F\.C\.|FC|A\.F\.C\.|AFC|CF|C\.F\.|S\.C\.|SC)$/, ''),
        start_year: r.start ? Number(r.start.slice(0, 4)) : null,
        end_year: r.end ? Number(r.end.slice(0, 4)) : null,
        apps: r.apps != null ? Math.round(Number(r.apps)) : null,
        goals: r.goals != null ? Math.round(Number(r.goals)) : null,
        loan: loan || (prev ? prev.loan : false),
      };
      spells.set(key, prev ? { ...prev, ...Object.fromEntries(Object.entries(row).filter(([, v]) => v != null)) } : row);
    }
    console.log(`  Careers ${(n - 1) * 40 + 1}–${Math.min(n * 40, wanted.length)} fetched.`);
  }
  const out = [];
  for(const [player_id, spells] of careers){
    const rows = [...spells.values()].sort((a, b) =>
      (a.start_year ?? 9999) - (b.start_year ?? 9999) || (a.end_year ?? 9999) - (b.end_year ?? 9999));
    rows.forEach((r, i) => out.push({ player_id, seq: i + 1, ...r }));
  }
  const intlRows = [...intl.values()].filter(s => s.start_year != null)
    .map(({ open, ...s }) => ({ ...s, end_year: open ? null : s.end_year }));
  return { careers: out, intl: intlRows, checked: wanted };
}

// Wikidata careers lag behind for some players. A career counts as up to
// date when its latest spell is at the player's current club and hasn't
// ended; Journeyman only picks players whose career is.
export function markCareers(players, careers){
  const latest = new Map();
  for(const c of careers){
    const cur = latest.get(c.player_id);
    if(!cur || (c.start_year ?? -1) >= (cur.start_year ?? -1)) latest.set(c.player_id, c);
  }
  const thisYear = new Date().getUTCFullYear();
  for(const p of players){
    const l = latest.get(p.id);
    p.has_career = !!l;
    p.career_current = !!l && !!p.club_wikidata_id && l.club_id === p.club_wikidata_id && (l.end_year == null || l.end_year >= thisYear);
  }
}

// ---------- 5. Save ----------

async function main(){
  const dry = process.argv[2] === '--dry-run';
  const dir = process.argv[3];
  const runStart = new Date().toISOString();
  let supabase = null, teams;

  if(dry){
    teams = JSON.parse(readFileSync(join(dir, 'teams.json'), 'utf8')).filter(t => LEAGUES[t.league]);
  } else {
    const { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY } = process.env;
    if(!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY){ console.error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set.'); process.exit(1); }
    supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const { data, error } = await supabase.from('teams').select('id,name,league,league_label,wikidata_id');
    if(error){ console.error('Could not read teams:', error.message); process.exit(1); }
    teams = data.filter(t => LEAGUES[t.league]);
  }
  console.log(`${teams.length} league clubs on the site.`);

  console.log('\n1. Linking clubs to Wikidata...');
  const { unmatched, clashes } = await linkClubs(teams);
  // Links are saved for good, so if many clubs failed to match, something
  // is off with Wikidata's answer: stop rather than save doubtful links.
  if(unmatched.length > 10) throw new Error(`${unmatched.length} clubs couldn't be found on Wikidata, which usually means its answer was incomplete. Nothing saved; try again later.`);
  const newly = teams.filter(t => t.linked);
  console.log(`  ${teams.length - unmatched.length} linked (${newly.length} new this run), ${unmatched.length} not found.`);
  for(const t of unmatched) console.log(`  Not found: ${t.name} (${t.league}). Set teams.wikidata_id for it by hand, or add it to CLUB_OVERRIDES.`);
  for(const [id, ns] of clashes) console.log(`  Check: ${ns.join(' and ')} both linked to ${id}. One is wrong; fix its teams.wikidata_id.`);
  if(supabase){
    for(const t of newly){
      const { error } = await supabase.from('teams').update({ wikidata_id: t.wikidata_id }).eq('id', t.id).is('wikidata_id', null);
      if(error){ console.error('  Could not save the link for', t.name, '-', error.message); }
    }
  }

  console.log('\n2. Fetching squads from football-data.org...');
  let squads;
  if(dry && existsSync(join(dir, 'squads.json'))){
    squads = JSON.parse(readFileSync(join(dir, 'squads.json'), 'utf8'));
    console.log('  Using squads.json from the dry-run folder.');
  } else {
    if(!process.env.FOOTBALL_DATA_API_KEY){ console.error('FOOTBALL_DATA_API_KEY must be set.'); process.exit(1); }
    squads = await fetchSquads(process.env.FOOTBALL_DATA_API_KEY);
  }
  const { players: squad, unmatched: unmatchedTeams } = squadPlayers(squads, teams);
  for(const t of unmatchedTeams) console.log(`  ${t} isn't on the site: its players are kept for the games under the club's own name. If it should be on the site, add an alias in update-prices.js NAME_ALIASES.`);
  console.log(`  ${squad.length} squad players.`);
  // A short list means a failed fetch. Saving it would retire most
  // players, so stop instead.
  if(squad.length < 3000){ console.error(`Only ${squad.length} squad players came back, expected about 5,000. Nothing saved.`); process.exit(1); }

  console.log('\n3. Matching players to Wikidata...');
  let players = await matchWikidata(squad);

  console.log('\n4. Fetching careers...');
  const { careers, intl, checked } = await fetchCareers(players, teams);
  console.log(`  ${careers.length} career rows for ${new Set(careers.map(c => c.player_id)).size} players.`);
  console.log(`  ${intl.length} senior international spells for ${new Set(intl.map(c => c.player_id)).size} players.`);
  markCareers(players, careers);
  console.log(`  ${players.filter(p => p.career_current).length} careers are up to date with the player's current club.`);
  // Only the columns the players table has.
  players = players.map(({ fd_id, club_wikidata_id, ...p }) => ({ ...p, position: p.position_group, height_cm: null }));

  if(dry){
    writeFileSync(join(dir, 'players.json'), JSON.stringify(players, null, 1));
    writeFileSync(join(dir, 'careers.json'), JSON.stringify(careers, null, 1));
    writeFileSync(join(dir, 'intl.json'), JSON.stringify(intl, null, 1));
    console.log(`\nDry run: wrote players.json and careers.json to ${dir}.`);
    return;
  }

  console.log('\n5. Saving...');
  for(const batch of chunks(players.map(p => ({ ...p, active: true, updated_at: runStart })), 500)){
    const { error } = await supabase.from('players').upsert(batch, { onConflict: 'id' });
    if(error && /column/i.test(error.message)) throw new Error('Saving players failed: ' + error.message +
      '. The database is missing a column this import needs: run supabase-linkup-2.sql in the Supabase SQL Editor, then run this workflow again.');
    if(error) throw new Error('Saving players failed: ' + error.message);
  }
  const { error: retireErr, count } = await supabase.from('players')
    .update({ active: false }, { count: 'exact' }).lt('updated_at', runStart).eq('active', true);
  if(retireErr) throw new Error('Retiring old players failed: ' + retireErr.message);
  const withCareers = [...new Set(careers.map(c => c.player_id))];
  for(const ids of chunks(withCareers, 300)){
    const { error } = await supabase.from('player_careers').delete().in('player_id', ids);
    if(error) throw new Error('Clearing careers failed: ' + error.message);
  }
  for(const batch of chunks(careers, 1000)){
    const { error } = await supabase.from('player_careers').insert(batch);
    if(error) throw new Error('Saving careers failed: ' + error.message);
  }
  for(const ids of chunks(checked, 300)){
    const { error } = await supabase.from('player_intl').delete().in('player_id', ids);
    if(error) throw new Error('Clearing international spells failed: ' + error.message);
  }
  for(const batch of chunks(intl, 1000)){
    const { error } = await supabase.from('player_intl').insert(batch);
    if(error) throw new Error('Saving international spells failed: ' + error.message);
  }
  console.log(`  Saved ${players.length} players, ${careers.length} career rows and ${intl.length} international spells; ${count || 0} players no longer found were marked inactive.`);
}

if(import.meta.url === `file://${process.argv[1]}`){
  main().catch(err => { console.error('Import failed:', err.message); process.exit(1); });
}
