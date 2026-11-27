// backup-data.js
//
// Run nightly by GitHub Actions (.github/workflows/backup-data.yml).
// Copies the market data PitchMarket can't rebuild on its own (clubs and
// their prices, price history, site content) out of Supabase and writes:
//
//   teams.json, price_history.json, site_settings.json   the raw rows
//   restore.sql   paste into the Supabase SQL Editor to put them back
//   README.md     what's in this backup and how to restore it
//
// The workflow commits these to the `data-backups` branch, so every night
// is kept in that branch's history.
//
// No player data is copied: no emails, balances, holdings or trades. The
// repo is public, and these three tables are already readable by anyone
// through the site.
//
// Usage: node backup-data.js <output folder>
// Needs SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY (the same secrets the
// price updater uses).

import { createClient } from '@supabase/supabase-js';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

// Restore order matters: price_history points at teams.
// site_settings rows restore.sql never overwrites: payments (switching to
// live mode, or back, is done on purpose in admin) and season (it decides
// which portfolio snapshots count). A database without them still gets them.
const KEEP_SETTINGS = ['payments', 'season'];
const TABLES = [
  { name: 'teams',         key: 'id',  order: ['id'] },
  { name: 'site_settings', key: 'key', order: ['key'] },
  { name: 'price_history', key: 'id',  order: ['changed_at', 'id'] },
];

async function fetchAll(supabase, table, order){
  const rows = [];
  const PAGE = 1000;   // Supabase returns at most 1,000 rows per request
  for(let from = 0; ; from += PAGE){
    let q = supabase.from(table).select('*');
    for(const col of order) q = q.order(col, { ascending: true });   // a stable order keeps pages from overlapping
    const { data, error } = await q.range(from, from + PAGE - 1);
    if(error) throw new Error(`Could not read ${table}: ${error.message}`);
    rows.push(...data);
    if(data.length < PAGE) return rows;
  }
}

// SQL string literal: wrap in single quotes, double any inside.
const lit = (s) => `'${String(s).replace(/'/g, "''")}'`;

// One upsert per table, reading the rows from a JSON literal with
// jsonb_populate_recordset, so every column type round-trips exactly.
export function buildRestoreSql(data, takenAt){
  const out = [];
  out.push(`-- PitchMarket data restore, from the backup taken ${takenAt}.`);
  out.push('-- Paste all of this into the Supabase SQL Editor and click Run.');
  out.push('-- It adds missing rows and overwrites changed ones; it never deletes.');
  out.push('-- The payments and season settings already in the database are kept.');
  out.push('-- The database tables must exist first (supabase-schema.sql).');
  out.push('');
  out.push('begin;');
  out.push('');
  out.push('-- Restoring prices must not log "Manual adjustment" history rows or');
  out.push('-- send price alerts, so the teams triggers are off until the end.');
  out.push('alter table public.teams disable trigger user;');
  for(const t of TABLES){
    const rows = data[t.name];
    out.push('');
    out.push(`-- ${t.name}: ${rows.length} row(s)`);
    if(!rows.length) continue;
    const cols = Object.keys(rows[0]);
    const json = lit(JSON.stringify(rows));
    if(t.name === 'price_history'){
      // match_events isn't backed up, so keep the link to a match only if
      // that match is still in the database.
      const select = cols.map(c => c === 'match_event_id'
        ? `case when exists (select 1 from public.match_events m where m.id = r.match_event_id) then r.match_event_id end`
        : `r.${c}`).join(', ');
      out.push(`insert into public.${t.name} (${cols.join(', ')})`);
      out.push(`select ${select}`);
      out.push(`from jsonb_populate_recordset(null::public.${t.name}, ${json}::jsonb) r`);
    } else {
      out.push(`insert into public.${t.name} (${cols.join(', ')})`);
      out.push(`select ${cols.join(', ')}`);
      out.push(`from jsonb_populate_recordset(null::public.${t.name}, ${json}::jsonb)`);
    }
    const updates = cols.filter(c => c !== t.key).map(c => `${c} = excluded.${c}`).join(', ');
    if(t.name === 'site_settings'){
      out.push(`on conflict (${t.key}) do update set ${updates}`);
      out.push(`  where public.site_settings.key not in (${KEEP_SETTINGS.map(lit).join(', ')});`);
    } else {
      out.push(`on conflict (${t.key}) do update set ${updates};`);
    }
  }
  out.push('');
  out.push('alter table public.teams enable trigger user;');
  out.push('');
  out.push('commit;');
  out.push('');
  return out.join('\n');
}

export function buildReadme(data, takenAt){
  const counts = TABLES.map(t => `| \`${t.name}\` | ${data[t.name].length} |`).join('\n');
  return `# PitchMarket data backup

Taken ${takenAt} by the nightly backup job (\`.github/workflows/backup-data.yml\` on \`main\`).
Every earlier night is in this branch's history.

| Table | Rows |
|---|---|
${counts}

No player data is included: no emails, balances, holdings or trades.

## Restoring

1. If the database is empty (a new Supabase project), first run \`supabase-schema.sql\` from the \`main\` branch in the Supabase SQL Editor.
2. Open \`restore.sql\` in this branch, copy all of it, paste it into a new query in the SQL Editor and click **Run**.

\`restore.sql\` adds missing rows and overwrites changed ones. It never deletes anything.
It never changes the \`payments\` or \`season\` rows of \`site_settings\` already in the database (it only adds them if missing): payments mode is switched to live, or back, on purpose in admin, and the season start decides which portfolio snapshots count.

To restore an older night, open this branch's commit history, pick the date, and use that commit's \`restore.sql\`.
`;
}

// Record tonight's portfolio value for every player (Pro portfolio history).
// The database function saves nothing until the Christmas reset records a
// season start. A failure here is logged and the backup carries on.
// Returns whether the snapshots were saved (true also before the season).
async function takePortfolioSnapshots(supabase){
  try{
    const { data, error } = await supabase.rpc('take_portfolio_snapshots');
    if(error) throw new Error(error.message);
    const saved = Number(data) || 0;
    console.log(`Portfolio snapshots: ${saved} saved${saved === 0 ? ' (0 until the season starts)' : ''}.`);
    return true;
  }catch(err){
    console.error('Portfolio snapshots failed (backup continues):', err && err.message ? err.message : err);
    return false;
  }
}

// Close finished league matchweeks. Monday's run closes the week that
// ended on Sunday, right after saving Sunday's snapshot. Weeks missed on
// earlier nights are closed too, as void if a Sunday's snapshots are
// missing. Only called when tonight's snapshots were saved, so a failed
// save never voids a week. A failure here is logged and the backup carries
// on.
async function closeMatchweeks(supabase){
  try{
    const { data, error } = await supabase.rpc('close_matchweeks');
    if(error) throw new Error(error.message);
    console.log(`Matchweeks closed: ${Number(data) || 0}.`);
  }catch(err){
    console.error('Closing matchweeks failed (backup continues):', err && err.message ? err.message : err);
  }
}

async function main(){
  const outDir = process.argv[2];
  const { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY } = process.env;
  if(!outDir){ console.error('Usage: node backup-data.js <output folder>'); process.exit(1); }
  if(!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY){
    console.error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set (GitHub Secrets).');
    process.exit(1);
  }
  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  if(await takePortfolioSnapshots(supabase)){
    await closeMatchweeks(supabase);
  }else{
    console.log('Matchweeks not closed tonight (snapshots failed).');
  }

  const data = {};
  for(const t of TABLES){
    data[t.name] = await fetchAll(supabase, t.name, t.order);
    console.log(`${t.name}: ${data[t.name].length} row(s)`);
  }
  // Refuse to overwrite a good backup with an empty one: an empty teams
  // table means something is wrong, not that the market has no clubs.
  if(data.teams.length === 0){
    console.error('teams came back empty — not saving this backup.');
    process.exit(1);
  }

  const takenAt = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
  mkdirSync(outDir, { recursive: true });
  for(const t of TABLES){
    writeFileSync(join(outDir, `${t.name}.json`), JSON.stringify(data[t.name], null, 1) + '\n');
  }
  writeFileSync(join(outDir, 'restore.sql'), buildRestoreSql(data, takenAt));
  writeFileSync(join(outDir, 'README.md'), buildReadme(data, takenAt));
  console.log(`Backup written to ${outDir}.`);
}

// Only run when called directly, so tests can import buildRestoreSql and buildReadme.
if(import.meta.url === `file://${process.argv[1]}`){
  main().catch(err => { console.error('Backup failed:', err.message); process.exit(1); });
}
