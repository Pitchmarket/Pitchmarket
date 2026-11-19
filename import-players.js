// import-players.js
//
// Run weekly by GitHub Actions (.github/workflows/import-players.yml).
// Fills the player tables that the Daily Kickabout games use, from
// Wikidata (free to use for anything, CC0):
//
//   1. Links each club on the site to its Wikidata entry
//      (teams.wikidata_id). A link you set by hand is never overwritten.
//   2. Fetches the current players at those clubs: name, birth date,
//      nationality, position, height and fame (how many Wikipedia
//      languages have a page on them).
//   3. Fetches club-by-club careers (years, appearances, goals, loans)
//      for the better-known players, for Journeyman.
//   4. Writes them to `players` and `player_careers`. Players no longer
//      found are marked inactive rather than deleted, so a puzzle already
//      in progress keeps working.
//
// Needs SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY (the price updater's
// secrets). `node import-players.js --dry-run <folder>` skips Supabase:
// it reads teams from <folder>/teams.json and writes what it would save
// to <folder>/players.json and <folder>/careers.json.

import { createClient } from '@supabase/supabase-js';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

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

// Careers are only fetched for players at least this famous, which keeps
// the run quick. Journeyman picks from the best-known of these anyway.
const CAREER_MIN_FAME = 25;
const OLDEST_BIRTH_YEAR = new Date().getUTCFullYear() - 42;

// Position labels, mapped to the four groups Scouted compares.
const POSITION_GROUPS = [
  [/goal ?keeper|goalie/i, 'Goalkeeper'],
  [/back|defender|sweeper|stopper|libero/i, 'Defender'],
  [/midfield|wing half|playmaker|regista|mezzala|half-back/i, 'Midfielder'],
  [/forward|striker|winger|attacker|centre-forward|inside|second striker|false nine/i, 'Forward'],
];
const positionGroup = (label) => (POSITION_GROUPS.find(([re]) => re.test(label || '')) || [])[1] || null;

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

// The area of the pitch most of a player's listed positions point to
// (Neymar: forward, winger, attacking midfielder -> Forward). On a tie, the
// most specific label decides. Returns the label to store.
export function mainPosition(labels){
  const grouped = labels.filter(positionGroup);
  if(!grouped.length) return null;
  const count = {};
  for(const l of grouped) count[positionGroup(l)] = (count[positionGroup(l)] || 0) + 1;
  const best = Math.max(...Object.values(count));
  return grouped.filter(l => count[positionGroup(l)] === best).sort((a, b) => b.length - a.length || a.localeCompare(b))[0];
}

// ---------- 2. Players ----------

// National and youth sides, recognised by name ("England national under-21
// football team", "Manchester United F.C. Under-23s", "Real Madrid Castilla").
const isNationalTeam = (label) => /national|under-?\s?\d\d|\bu-?\d\ds?\b|olympic|reserves|youth|academy|\bii\b|\bb team|castilla|primavera|jong /i.test(label || '');

async function fetchPlayers(teams){
  const teamByClub = new Map(teams.filter(t => t.wikidata_id).map(t => [t.wikidata_id, t]));
  const players = new Map();
  const clubIds = [...teamByClub.keys()];
  let n = 0;
  for(const group of chunks(clubIds, 25)){
    n++;
    const rows = await sparql(`
      SELECT ?p ?name ?dob ?club ?start ?pos ?posLabel ?h ?unit ?nat ?natLabel ?natContLabel ?cit ?citLabel ?citContLabel ?links WHERE {
        VALUES ?club { ${group.map(q => 'wd:' + q).join(' ')} }
        ?p p:P54 ?st . ?st ps:P54 ?club .
        FILTER NOT EXISTS { ?st pq:P582 ?end }
        OPTIONAL { ?st pq:P580 ?start }
        ?p wdt:P106 wd:Q937857 ; wdt:P21 wd:Q6581097 ; wdt:P569 ?dob ; wikibase:sitelinks ?links .
        FILTER(YEAR(?dob) >= ${OLDEST_BIRTH_YEAR})
        # Skip memberships the player has since moved on from: a later club
        # spell means this one is stale. National teams don't count: Wikidata
        # files senior sides like England under football clubs too, which
        # used to drop Saka, Foden and most other internationals.
        FILTER NOT EXISTS {
          ?p p:P54 ?later . ?later ps:P54 ?other ; pq:P580 ?laterStart .
          FILTER(BOUND(?start) && ?laterStart > ?start && ?other != ?club)
          ?other wdt:P31/wdt:P279* wd:Q476028 .
          FILTER NOT EXISTS { ?other wdt:P31/wdt:P279* wd:Q6979593 }
        }
        OPTIONAL { ?p rdfs:label ?en FILTER(LANG(?en) = "en") }
        OPTIONAL { ?p rdfs:label ?mul FILTER(LANG(?mul) = "mul") }
        BIND(COALESCE(?en, ?mul) AS ?name)
        OPTIONAL { ?p wdt:P413 ?pos }
        OPTIONAL { ?p p:P2048/psv:P2048 [ wikibase:quantityAmount ?h ; wikibase:quantityUnit ?unit ] }
        OPTIONAL { ?p wdt:P1532 ?nat . OPTIONAL { ?nat wdt:P30 ?natCont } }
        OPTIONAL { ?p wdt:P27 ?cit . OPTIONAL { ?cit wdt:P30 ?citCont } }
        SERVICE wikibase:label { bd:serviceParam wikibase:language "en,mul". }
      }`, `players ${n}`);
    for(const r of rows){
      if(!r.name || /^Q\d+$/.test(r.name)) continue;
      let p = players.get(r.p);
      if(!p) players.set(r.p, p = { id: r.p, name: r.name, birth_date: r.dob.slice(0, 10), fame: Number(r.links) || 0,
        clubs: new Map(), positions: new Set(), heights: [], nats: new Map(), cits: new Map() });
      p.clubs.set(r.club, r.start || '');
      if(r.posLabel && !/^Q\d+$/.test(r.posLabel)) p.positions.add(r.posLabel);
      if(r.h){
        const cm = r.unit === 'Q11573' ? Number(r.h) * 100 : Number(r.h);   // metres or centimetres
        if(cm >= 150 && cm <= 215) p.heights.push(Math.round(cm));
      }
      // Country -> continent; the first continent seen wins for countries
      // that span two (Turkey, Russia).
      const cont = (c) => !c || /^Q\d+$/.test(c) ? null : c === 'Insular Oceania' ? 'Oceania' : c;
      if(r.natLabel && !/^Q\d+$/.test(r.natLabel) && !p.nats.get(r.natLabel)) p.nats.set(r.natLabel, cont(r.natContLabel));
      if(r.citLabel && !/^Q\d+$/.test(r.citLabel) && !p.cits.get(r.citLabel)) p.cits.set(r.citLabel, cont(r.citContLabel));
    }
    console.log(`  Clubs ${(n - 1) * 25 + 1}–${Math.min(n * 25, clubIds.length)}: ${players.size} players so far.`);
  }

  const best = new Map();   // "name|birth date" -> best-known entry
  for(const p of players.values()){
    const k = p.name + '|' + p.birth_date;
    if(!best.has(k) || p.fame > best.get(k).fame) best.set(k, p);
  }
  const out = [];
  for(const p of best.values()){
    // The club joined most recently is the current one (a loan, usually).
    const [clubId] = [...p.clubs].sort((a, b) => b[1].localeCompare(a[1]))[0];
    const team = teamByClub.get(clubId);
    const position = mainPosition([...p.positions]);
    const nats = [...(p.nats.size ? p.nats : p.cits)].sort((a, b) => a[0].localeCompare(b[0]));
    const heights = p.heights.sort((a, b) => a - b);
    out.push({
      id: p.id, name: p.name, birth_date: p.birth_date,
      nationality: nats[0] ? nats[0][0] : null,
      continent: nats[0] ? nats[0][1] : null,
      position, position_group: positionGroup(position),
      height_cm: heights.length ? heights[Math.floor(heights.length / 2)] : null,
      team_id: team.id, club_name: team.name, league: team.league, league_label: team.league_label,
      fame: p.fame,
    });
  }
  return out;
}

// ---------- 3. Careers ----------

export async function fetchCareers(players, teams){
  const siteName = new Map(teams.filter(t => t.wikidata_id).map(t => [t.wikidata_id, t.name]));
  const wanted = players.filter(p => p.fame >= CAREER_MIN_FAME).map(p => p.id);
  const careers = new Map();
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
  return out;
}

// Wikidata often never records a player leaving, so some show at an old
// club. Where we have their career, keep them only if their latest spell
// is at that club and hasn't ended.
export function dropMovedPlayers(players, careers){
  const latest = new Map();
  for(const c of careers){
    const cur = latest.get(c.player_id);
    if(!cur || (c.start_year ?? -1) >= (cur.start_year ?? -1)) latest.set(c.player_id, c);
  }
  const thisYear = new Date().getUTCFullYear();
  const moved = new Set(players.filter(p => {
    const l = latest.get(p.id);
    return l && (l.club !== p.club_name || (l.end_year != null && l.end_year < thisYear));
  }).map(p => p.id));
  return { players: players.filter(p => !moved.has(p.id)), careers: careers.filter(c => !moved.has(c.player_id)) };
}

// ---------- 4. Save ----------

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

  console.log('\n2. Fetching current players...');
  let players = await fetchPlayers(teams);
  console.log(`  ${players.length} players.`);
  // A short list means a failed or partial fetch. Saving it would retire
  // most players, so stop instead.
  if(players.length < 1000){ console.error(`Only ${players.length} players came back, expected thousands. Nothing saved.`); process.exit(1); }

  if(dry) writeFileSync(join(dir, 'players.json'), JSON.stringify(players, null, 1));

  console.log('\n3. Fetching careers...');
  let careers = await fetchCareers(players, teams);
  console.log(`  ${careers.length} career rows for ${new Set(careers.map(c => c.player_id)).size} players.`);

  const kept = dropMovedPlayers(players, careers);
  console.log(`  ${players.length - kept.players.length} players left out: their latest spell is at another club or has ended.`);
  ({ players, careers } = kept);
  // Link-Up can only check teammates for players with a career on file.
  const withCareer = new Set(careers.map(c => c.player_id));
  for(const p of players) p.has_career = withCareer.has(p.id);

  if(dry){
    writeFileSync(join(dir, 'players.json'), JSON.stringify(players, null, 1));
    writeFileSync(join(dir, 'careers.json'), JSON.stringify(careers, null, 1));
    console.log(`\nDry run: wrote players.json and careers.json to ${dir}.`);
    return;
  }

  console.log('\n4. Saving...');
  for(const batch of chunks(players.map(p => ({ ...p, active: true, updated_at: runStart })), 500)){
    const { error } = await supabase.from('players').upsert(batch, { onConflict: 'id' });
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
  console.log(`  Saved ${players.length} players and ${careers.length} career rows; ${count || 0} players no longer found were marked inactive.`);
}

if(import.meta.url === `file://${process.argv[1]}`){
  main().catch(err => { console.error('Import failed:', err.message); process.exit(1); });
}
