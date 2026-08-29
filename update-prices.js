// update-prices.js
//
// Run by GitHub Actions on a schedule. For every finished match in
// your covered leagues since the last run, asks an AI provider to
// weigh the result and writes a PROPOSED price move into the
// match_events table as status='pending' — nothing touches a real
// team price until you approve it in admin.html's Price Approvals tab.
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
//   AI_PROVIDER  — 'gemini' (default) or 'claude'
//   GEMINI_MODEL — defaults to 'gemini-3.6-flash'. Google renames these
//                  models fairly often — check aistudio.google.com if
//                  this one starts erroring, and update the secret/default
//                  without touching any other code.

import { createClient } from '@supabase/supabase-js';

const FOOTBALL_DATA_API_KEY = process.env.FOOTBALL_DATA_API_KEY;
const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const AI_PROVIDER = (process.env.AI_PROVIDER || 'gemini').toLowerCase();
const GEMINI_API_KEY = process.env.GEMINI_API_KEY;
const GEMINI_MODEL = process.env.GEMINI_MODEL || 'gemini-3.6-flash';
const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY;

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
};

// football-data.org team names -> the exact names stored in your
// teams table. Extend this if a team isn't matching — the script
// logs any name it can't resolve so you know what to add.
const NAME_ALIASES = {
  'Manchester City FC': 'Manchester City', 'Arsenal FC': 'Arsenal', 'Liverpool FC': 'Liverpool',
  'Manchester United FC': 'Manchester United', 'Chelsea FC': 'Chelsea', 'Tottenham Hotspur FC': 'Tottenham Hotspur',
  'Newcastle United FC': 'Newcastle United', 'Aston Villa FC': 'Aston Villa',
  'Real Madrid CF': 'Real Madrid', 'FC Barcelona': 'Barcelona', 'Club Atlético de Madrid': 'Atlético Madrid',
  'Athletic Club': 'Athletic Bilbao', 'Real Sociedad de Fútbol': 'Real Sociedad', 'Villarreal CF': 'Villarreal',
  'FC Internazionale Milano': 'Inter Milan', 'AC Milan': 'AC Milan', 'Juventus FC': 'Juventus',
  'SSC Napoli': 'Napoli', 'AS Roma': 'AS Roma', 'Atalanta BC': 'Atalanta',
  'FC Bayern München': 'Bayern Munich', 'Borussia Dortmund': 'Borussia Dortmund', 'Bayer 04 Leverkusen': 'Bayer Leverkusen',
  'RB Leipzig': 'RB Leipzig', 'Eintracht Frankfurt': 'Eintracht Frankfurt', 'VfB Stuttgart': 'VfB Stuttgart',
  'Paris Saint-Germain FC': 'Paris Saint-Germain', 'Olympique de Marseille': 'Marseille', 'AS Monaco FC': 'Monaco',
  'Olympique Lyonnais': 'Lyon', 'LOSC Lille': 'Lille', 'OGC Nice': 'Nice',
};

function normalize(name){
  return (NAME_ALIASES[name] || name)
    .toLowerCase().replace(/\bfc\b|\bcf\b|\bafc\b/g, '').trim();
}

async function fetchFinishedMatches(code, dateFrom, dateTo){
  const url = `https://api.football-data.org/v4/competitions/${code}/matches?status=FINISHED&dateFrom=${dateFrom}&dateTo=${dateTo}`;
  const res = await fetch(url, { headers: { 'X-Auth-Token': FOOTBALL_DATA_API_KEY } });
  if(!res.ok){ console.error(`football-data.org error for ${code}:`, res.status, await res.text()); return []; }
  const data = await res.json();
  return data.matches || [];
}

// ============================================================
// Modular AI provider layer. Both functions return the same
// shape: { home: number, away: number, reason: string } | null
// so swapping AI_PROVIDER never touches anything else.
// ============================================================
function buildPrompt(homeName, awayName, homeScore, awayScore, competitionName){
  return `A football match just finished.
Competition: ${competitionName}
Home team: ${homeName}
Away team: ${awayName}
Final score: ${homeName} ${homeScore} - ${awayScore} ${awayName}

Decide how much each team's stock price should move as a percentage, reflecting the result. Consider margin of victory, and that a home draw is milder than an away draw. Winners go up, losers go down, draws move slightly for both (usually toward the run of play if the score suggests one side dominated). Keep moves realistic: routine results should be small (1-4%), landslide or shock results can be larger (up to 15%), draws are usually under 2%.

Respond with ONLY this JSON shape, nothing else, no markdown fences:
{"home_delta_pct": <number, can be negative>, "away_delta_pct": <number, can be negative>, "reason": "<one short sentence>"}`;
}

function parseAIResponse(text){
  try{
    const parsed = JSON.parse(text.replace(/```json|```/g, '').trim());
    const clamp = (n) => Math.max(-20, Math.min(20, Number(n) || 0));
    return { home: clamp(parsed.home_delta_pct), away: clamp(parsed.away_delta_pct), reason: parsed.reason || '' };
  } catch(e){
    console.error('Could not parse AI response:', text);
    return null;
  }
}

async function askGemini(homeName, awayName, homeScore, awayScore, competitionName){
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent`;
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-goog-api-key': GEMINI_API_KEY },
    body: JSON.stringify({ contents: [{ parts: [{ text: buildPrompt(homeName, awayName, homeScore, awayScore, competitionName) }] }] }),
  });
  if(!res.ok){ console.error('Gemini API error:', res.status, await res.text()); return null; }
  const data = await res.json();
  const text = data.candidates?.[0]?.content?.parts?.[0]?.text?.trim() || '';
  return parseAIResponse(text);
}

async function askClaude(homeName, awayName, homeScore, awayScore, competitionName){
  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: { 'x-api-key': ANTHROPIC_API_KEY, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
    body: JSON.stringify({
      model: 'claude-haiku-4-5-20251001',
      max_tokens: 200,
      messages: [{ role: 'user', content: buildPrompt(homeName, awayName, homeScore, awayScore, competitionName) }],
    }),
  });
  if(!res.ok){ console.error('Claude API error:', res.status, await res.text()); return null; }
  const data = await res.json();
  const text = data.content?.[0]?.text?.trim() || '';
  return parseAIResponse(text);
}

async function askForPriceMove(homeName, awayName, homeScore, awayScore, competitionName){
  if(AI_PROVIDER === 'claude') return askClaude(homeName, awayName, homeScore, awayScore, competitionName);
  return askGemini(homeName, awayName, homeScore, awayScore, competitionName);
}
// ============================================================

async function findTeamRow(league, teamName, isUCL){
  const norm = normalize(teamName);
  const { data, error } = await supabase.from('teams').select('*').eq('league', league);
  if(error || !data) return null;
  return data.find(t=>{
    const tName = isUCL ? t.name.replace(' (UCL)', '') : t.name;
    return normalize(tName) === norm;
  }) || null;
}

async function alreadyLogged(matchId){
  const { data } = await supabase.from('match_events').select('id').eq('source_match_id', String(matchId)).maybeSingle();
  return !!data;
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

  console.log(`Using AI provider: ${AI_PROVIDER}`);

  const now = new Date();
  const dateTo = now.toISOString().slice(0,10);
  const dateFrom = new Date(now.getTime() - 3*24*60*60*1000).toISOString().slice(0,10); // 3-day lookback, safety margin over the run schedule

  for(const [code, leagueKey] of Object.entries(COMPETITIONS)){
    console.log(`\nChecking ${code} (${leagueKey})...`);
    const matches = await fetchFinishedMatches(code, dateFrom, dateTo);
    console.log(`  ${matches.length} finished match(es) found in range.`);

    for(const match of matches){
      const matchId = String(match.id);
      if(await alreadyLogged(matchId)){ continue; }

      const homeScore = match.score?.fullTime?.home;
      const awayScore = match.score?.fullTime?.away;
      if(homeScore == null || awayScore == null) continue;

      const isUCL = code === 'CL';
      const homeTeam = await findTeamRow(leagueKey, match.homeTeam.name, isUCL);
      const awayTeam = await findTeamRow(leagueKey, match.awayTeam.name, isUCL);

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

      if(!homeTeam) console.log(`  Could not match home team "${match.homeTeam.name}" — add it to NAME_ALIASES if it should be tracked.`);
      if(!awayTeam) console.log(`  Could not match away team "${match.awayTeam.name}" — add it to NAME_ALIASES if it should be tracked.`);

      if(!homeTeam && !awayTeam){
        await supabase.from('match_events').insert({ ...baseRow, status: 'skipped' });
        continue;
      }

      console.log(`  ${match.homeTeam.name} ${homeScore}-${awayScore} ${match.awayTeam.name}`);
      const move = await askForPriceMove(match.homeTeam.name, match.awayTeam.name, homeScore, awayScore, match.competition.name);

      if(!move){
        console.log('  Skipping — could not get a price move from the AI provider.');
        await supabase.from('match_events').insert({ ...baseRow, status: 'skipped' });
        continue;
      }

      console.log(`  Proposed: home ${move.home >= 0 ? '+' : ''}${move.home}% / away ${move.away >= 0 ? '+' : ''}${move.away}% — ${move.reason}`);

      const { error } = await supabase.from('match_events').insert({
        ...baseRow,
        home_delta_pct: move.home,
        away_delta_pct: move.away,
        ai_reason: move.reason,
        status: 'pending',
      });
      if(error) console.error('  Failed to log match event:', error.message);
      else console.log('  Logged for admin approval.');
    }
  }
  console.log('\nDone. Review pending price changes in admin.html -> Price Approvals.');
}

main().catch(err=>{ console.error('Fatal error:', err); process.exit(1); });
