# Champions League stages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Knocked-out Champions League clubs go to 0 and close; clubs that go through get the AI's move for the deciding match boosted (×1.2 / ×1.5 / ×2 / ×2.5 / ×3); winners' holders are cashed out; every stage result waits for admin approval and applies itself after 12 hours.

**Architecture:** A pure module `ucl-stages.js` works out each Champions League match's stage outcome from the football-data feed. `update-prices.js` stores that outcome on the same `match_events` row as the AI's move, so one approval applies both. In the database, one internal function applies an event (normal, boosted, out, or winners with cash-out); approve, reject, auto-apply and the 12-hour fallback all go through it. `trade()` refuses closed clubs. Admin gets stage cards and manual buttons; the site shows closed clubs.

**Tech Stack:** Supabase Postgres (plpgsql, RLS), Node 22 (`update-prices.js`, `node:test`), vanilla JS in `index.html` / `admin.html`, Playwright browser tests.

**Spec:** `docs/superpowers/specs/2026-11-28-champions-league-stages-design.md`

## Global Constraints

- Boosts, keyed by stage reached: `last16` ×1.2, `quarters` ×1.5, `semis` ×2, `final` ×2.5, `winners` ×3. The boost multiplies **the AI's suggested move for the deciding match**, never the whole price, and **only rises** (a fall on the deciding match stays as suggested, multiplier 1).
- Out = finishing 25th–36th in the league phase, or losing a play-off, knockout tie or the final → price **0**, `closed = true`. Finishing 9th–24th → stage `playoff`, no boost, and that alone does **not** force review.
- Every event with a stage other than `playoff` is never auto-applied by the 8% rule; it waits for admin, and applies itself once **12 hours** old, whether or not `AUTO_APPLY` is on.
- **Reject** on a stage event = apply the AI's unboosted moves with no stage effects (no 0, no close, no cash-out).
- If the feed can't settle an outcome for certain, no stage is proposed; the match is priced as a normal match and the run log says why.
- The Champions League league key on the site is `championsleague`; the feed code is `CL`.
- New SQL goes in `supabase-ucl-stages.sql` (safe to run twice, one transaction) **and** identically into `supabase-schema.sql`. Every new function: `security definer`, `set search_path = public`, explicit `revoke execute … from public, anon, authenticated`, then grants only where stated.
- Escape all player and club text in the page (`escapeHtml` in index.html, `escHtml`/`escAttr` in admin.html).
- Commit messages end with:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01RhqBjAm8kHCUW56x4XzDiw`
- Tests: `PGHOST=/var/tmp/pmpg PGPORT=5433 tests/run-sql-tests.sh`; `node --test tests/*.test.mjs`; browser tests need `python3 -m http.server 8765 --bind 127.0.0.1` from the repo root, then `node tests/browser/<name>.mjs` (prints `ok`).

## Review Focus

1. **Applied twice:** admin presses Approve while the 12-hour fallback runs, or a run is repeated → the event applies exactly once (the second call finds it no longer pending). Pinned in Task 1.
2. **Penalties and extra time:** a second leg won on penalties after a level aggregate → the penalty winner goes through; a feed match with penalties folded into `fullTime` must not count penalty kicks as goals. Pinned in Task 3.
3. **Missing first leg:** the deciding leg's first leg isn't in the feed's stage list → no stage (normal pricing), never a guessed 0. Pinned in Task 3.
4. **Final matchday not complete:** some league-phase matches on the last matchday are still unfinished → those events are not written yet (the clubs stay locked), and are written on a later run. Pinned in Tasks 3 and 4.
5. **Closed club through every door:** buying or selling a closed club fails in `trade()` with the stage message, and the market row, explorer and portfolio show no Trade button for it. Pinned in Tasks 1 and 5.

---

### Task 1: Database: stage columns, applying events, closing, cash-out

**Files:**
- Create: `supabase-ucl-stages.sql`
- Modify: `supabase-schema.sql` (teams, match_events, fixtures, notifications definitions; `approve_match_event`, `auto_apply_match_event`, `trade`; new functions after `auto_apply_match_event`)
- Test: `tests/sql/ucl-stages.test.sql`, `tests/sql/ucl-stages-upgrade.test.sql`

**Interfaces:**
- Produces (columns):
  - `teams.closed boolean not null default false`; `teams.ucl_stage text` check in `('league','playoff','last16','quarters','semis','final','out','winners','refunded')`, null allowed.
  - `match_events.home_stage`, `away_stage text` check in `('playoff','last16','quarters','semis','final','winners','out')`; `home_ai_pct`, `away_ai_pct numeric` (the AI's own move); `home_multiplier`, `away_multiplier numeric`; `stage_rejected boolean not null default false`. For stage events `home_delta_pct`/`away_delta_pct` hold the move to apply (boosted; `-100` for out).
  - `fixtures.stage text`, `fixtures.leg smallint`.
  - `notifications.kind` check widened to `('below','above','cashout','refund')`; for cash-outs `threshold` = shares paid out, `price` = price per share.
- Produces (functions):
  - `apply_match_event_core(p_event_id uuid, p_use_stage boolean, p_reviewer text) returns void`, internal (no grants). Raises `'Event not found or already reviewed'` unless the event is pending (select … `for update`).
  - `ucl_cash_out(p_team_id uuid, p_kind text) returns integer`, internal: pays each holder `round(shares * price, 2)` into `coin_balance`, adds a notification of `p_kind`, deletes the holdings, returns the number of holders.
  - `approve_match_event(p_event_id uuid, p_approve boolean)`: same signature and admin check as today. Approve → core(id, true, email). Reject on a stage event (any side stage not null) → core(id, false, email) and `stage_rejected = true`. Reject on a normal event → marked rejected, nothing applied (unchanged).
  - `auto_apply_match_event(p_event_id uuid)`: raises `'Stage results need approval'` if either side's stage is set and not `'playoff'`; otherwise core(id, true, 'auto (' || ai_provider || ')').
  - `apply_overdue_stage_events() returns integer`: applies, with core(id, true, 'auto (12h)'), every pending event with a non-`playoff` stage created at least 12 hours ago; returns how many. Granted to `service_role` only.
  - `trade(...)`: refuses a closed club before any cost check: `ucl_stage = 'out'` → `'This club is out of the Champions League. Trading has closed.'`; `'winners'` → `'The Champions League is over for this season. Trading has closed.'`; otherwise `'Trading on this club has closed.'`.

Core behaviour, per side with a team id:
- `p_use_stage` and stage `out`: price `0`, `chg -100`, `closed true`, `ucl_stage 'out'`; history row with `delta_pct -100`.
- Otherwise the move is `delta_pct` (or, when not `p_use_stage`, `coalesce(ai_pct, delta_pct)`) applied exactly as today (`greatest(0.01, round(price * (1 + pct/100), 2))`), same history label and W/D/L.
- `p_use_stage` and any other stage: set `ucl_stage` to it. For `winners`, after the price update: `ucl_cash_out(team, 'cashout')`, then every `championsleague` club gets `closed = true`.
- Insert each `price_history` row **before** updating `teams`, so the `log_manual_price_change` trigger sees it and doesn't add a second "Manual adjustment" row.
- Finally `status 'approved'`, `reviewed_by p_reviewer`, `reviewed_at now()`.

- [ ] **Step 1: Write the failing test `tests/sql/ucl-stages.test.sql`** (one transaction, `begin; … rollback;`, players inserted into `auth.users` like `pro-tiers.test.sql`, admin claims set with `set local request.jwt.claims = '{"email":"pitchmarketadmin@gmail.com"}'`). Seed four `championsleague` clubs at price 50 and a holder of each. Assertions, one `do $$` block each:
  - Approving a `quarters` event with `home_ai_pct 10, home_multiplier 1.5, home_delta_pct 15` → home price `57.50`, `ucl_stage 'quarters'`, exactly one `price_history` row for that club.
  - Approving an `out` event → price `0`, `closed`, `ucl_stage 'out'`, history `delta_pct -100`; the holder's shares remain.
  - Approving a `winners` event (`home_delta_pct 30` from 10 ×3) → price `65.00`; the holder of 4 shares gets `+260.00` coins, a `cashout` notification with `threshold 4, price 65`, no holdings left in that club; all four clubs `closed`.
  - Rejecting a stage event with `home_ai_pct 10, home_delta_pct 15, home_stage 'quarters'` → price `55.00`, `ucl_stage` unchanged, status `approved`, `stage_rejected true`.
  - Rejecting a normal event → status `rejected`, price unchanged.
  - `auto_apply_match_event` on a `semis` event raises `'Stage results need approval'`; on a `playoff`-only event it applies and sets `ucl_stage 'playoff'`.
  - `apply_overdue_stage_events()` with one stage event created 13 hours ago and one 11 hours ago → returns `1`, only the older is applied, `reviewed_by 'auto (12h)'`; a second call returns `0`. Calling `approve_match_event` on the applied one raises `'Event not found or already reviewed'` (Review Focus 1).
  - As a signed-in player (`{"sub": …}` claims), `trade` buy and sell on a closed `out` club each raise the out message; on a closed `winners` club, the winners message (Review Focus 5).
  - `anon` and `authenticated` cannot execute `apply_match_event_core`, `ucl_cash_out` or `apply_overdue_stage_events` (`has_function_privilege` is false).

- [ ] **Step 2: Write `tests/sql/ucl-stages-upgrade.test.sql`**: insert a club and a pending normal event on the installed schema, run `\ir ../../supabase-ucl-stages.sql` twice, assert the club has `closed = false`, the event still approves through `approve_match_event`, and a `cashout` notification can be inserted; clean up its rows at the end (it commits, like `pro-1-upgrade.test.sql`).

- [ ] **Step 3: Run the SQL tests and confirm both new files fail**

Run: `PGHOST=/var/tmp/pmpg PGPORT=5433 tests/run-sql-tests.sh`
Expected: `FAIL tests/sql/ucl-stages.test.sql` and `FAIL tests/sql/ucl-stages-upgrade.test.sql`; every other file PASS.

- [ ] **Step 4: Write `supabase-ucl-stages.sql`** with a header comment in the style of `supabase-leagues-1.sql` (what changes, run after `supabase-leagues-1.sql`, safe to run twice). Columns with `add column if not exists`; the notifications check dropped and re-added by name; functions with `create or replace`. Fold the same definitions into `supabase-schema.sql` at the matching places (column definitions in the `create table` statements, functions replacing the old ones).

- [ ] **Step 5: Run the SQL tests**

Run: `PGHOST=/var/tmp/pmpg PGPORT=5433 tests/run-sql-tests.sh`
Expected: every file PASS.

- [ ] **Step 6: Commit**

```bash
git add supabase-ucl-stages.sql supabase-schema.sql tests/sql/ucl-stages.test.sql tests/sql/ucl-stages-upgrade.test.sql
git commit -m "Champions League stages: apply boosted, out and winners results in the database"
```

### Task 2: Database: admin actions for Champions League clubs

**Files:**
- Modify: `supabase-ucl-stages.sql`, `supabase-schema.sql`
- Test: `tests/sql/ucl-admin.test.sql`

**Interfaces:**
- Consumes: `ucl_cash_out(uuid, text)` from Task 1; `is_admin()`.
- Produces (each raises `'Not authorized'` unless `is_admin()`, and `'Not an open Champions League club'` unless the club is in `championsleague` and open, except Reopen; granted to `authenticated`):
  - `admin_ucl_knock_out(p_team_id uuid) returns void`: price 0, `chg -100`, closed, `ucl_stage 'out'`, history row (`source 'admin'`, `label 'Knocked out of the Champions League'`, `delta_pct -100`).
  - `admin_ucl_crown(p_team_id uuid) returns integer`: `ucl_cash_out(team, 'cashout')` at the current price, `ucl_stage 'winners'`, every `championsleague` club closed; returns holders paid.
  - `admin_ucl_close_refund(p_team_id uuid) returns integer`: `ucl_cash_out(team, 'refund')`, closed, `ucl_stage 'refunded'`; returns holders paid.
  - `admin_ucl_reopen(p_team_id uuid, p_price numeric) returns void`: needs a closed `championsleague` club (else `'Not a closed Champions League club'`) and `p_price > 0 and p_price <= 100000` (else `'Price must be between 0.01 and 100000'`); deletes remaining holdings in that club, then `closed false`, `ucl_stage 'league'`, `price p_price`, `chg 0`, history row (`label 'Reopened for the new Champions League'`).
  - `admin_ucl_non_entrants() returns table(team_id uuid, name text)`: open `championsleague` clubs with no `fixtures` row and no `match_events` row with `competition = 'CL'` and `match_date` on or after 1 July of the current competition year (July–December: this year; January–June: last year).

- [ ] **Step 1: Write the failing test `tests/sql/ucl-admin.test.sql`** (one transaction, rolled back). Assertions:
  - A non-admin calling each of the five raises `'Not authorized'`.
  - Knock out → price 0, closed, `ucl_stage 'out'`, one history row with the label; knocking out again raises `'Not an open Champions League club'`; knocking out a club in another league raises the same.
  - Crown a club at price 40 with a holder of 3 → returns 1, holder `+120.00`, `cashout` notification, no holdings, all CL clubs closed.
  - Close and refund a club at price 12.5 with a holder of 2 → returns 1, holder `+25.00`, `refund` notification, `ucl_stage 'refunded'`.
  - Reopen an `out` club where a player still holds 5 shares at price 0, with price 30 → holdings gone, price 30, open, `ucl_stage 'league'`; reopen with `0` raises the price message; reopening an open club raises `'Not a closed Champions League club'`.
  - Non-entrants: of three open CL clubs (one with a fixture, one with a CL match event dated this competition year, one with neither), only the third is returned.

- [ ] **Step 2: Run the SQL tests; expect `FAIL tests/sql/ucl-admin.test.sql`**

- [ ] **Step 3: Add the five functions to `supabase-ucl-stages.sql` and `supabase-schema.sql`** (history row inserted before the `teams` update, as in Task 1).

- [ ] **Step 4: Run the SQL tests; expect every file PASS**

- [ ] **Step 5: Commit** (`git add` the two SQL files and the test; message "Champions League stages: admin knock out, crown, refund and reopen").

### Task 3: Pure stage logic in `ucl-stages.js`

**Files:**
- Create: `ucl-stages.js`
- Test: `tests/ucl-stages.test.mjs`

**Interfaces:**
- Produces (ES module exports; feed match objects are football-data v4 matches: `id`, `utcDate`, `status`, `stage`, `matchday`, `homeTeam.id/name`, `awayTeam.id/name`, `score.{winner,duration,fullTime,regularTime,extraTime,penalties}`):
  - `STAGE_BOOST = { last16: 1.2, quarters: 1.5, semis: 2, final: 2.5, winners: 3 }`
  - `NEXT_STAGE = { PLAYOFFS: 'last16', LAST_16: 'quarters', QUARTER_FINALS: 'semis', SEMI_FINALS: 'final', FINAL: 'winners' }`
  - `matchGoals(match) -> { home: number, away: number } | null`: goals excluding penalty kicks. If `regularTime` exists: regular + `extraTime` (0 when absent). Otherwise `fullTime` minus `penalties` (0 when absent). Null if no usable numbers.
  - `legOf(match, stageMatches) -> 1 | 2 | null`: for two-legged stages, the order of this match among `stageMatches` between the same two teams (by `utcDate`); null if it can't tell. `FINAL` → 1.
  - `tieOutcome(match, stageMatches) -> { winnerId, loserId } | { pending: true } | { unclear: string }`: `FINAL`: one match decides (goals, then penalties). Two-legged: only when `match` is leg 2 and leg 1 is in `stageMatches` with status `FINISHED` or `AWARDED`; aggregate goals, then leg 2's penalties. Leg 1 → `{ pending: true }`. Missing leg 1, a level tie with no penalty winner, or no goals → `{ unclear: <why> }`.
  - `leagueOutcome(match, leagueMatches, table) -> { home: stage|null, away: stage|null } | { pending: true } | { unclear: string }`: only for the last league-phase matchday (`matchday` = max `matchday` in `leagueMatches`); earlier matchdays → `{ home: null, away: null }`. If any league match isn't `FINISHED`/`AWARDED` → `{ pending: true }`. `table` is the `fetchStandings('CL')` Map (folded name → `{ position }`); position 1–8 → `'last16'`, 9–24 → `'playoff'`, 25–36 → `'out'`; a team missing from the table → `{ unclear }`.
  - `boostMove(aiPct, stage) -> { pct, multiplier }`: `'out'` → `{ pct: -100, multiplier: null }`; a boosted stage with `aiPct > 0` → `{ pct: round2(aiPct * boost), multiplier: boost }`; otherwise `{ pct: aiPct, multiplier: 1 }`.
  - `stageFields(match, ctx, homeAiPct, awayAiPct) -> { fields, defer: boolean, note: string|null }`, where `ctx = { stageMatches, leagueMatches, table }`. For `stage === 'LEAGUE_STAGE'` it uses `leagueOutcome`; for the knockout stages, `tieOutcome` (winner gets `NEXT_STAGE[stage]`, loser `'out'`). `fields` are the `match_events` columns to add (`home_stage`, `away_stage`, `home_ai_pct`, `away_ai_pct`, `home_multiplier`, `away_multiplier`, `home_delta_pct`, `away_delta_pct`), or `{}` when there's no stage. `defer` is true for `{ pending: true }` from `leagueOutcome` only (a tie's leg 1 isn't deferred, it just has no stage). `note` carries the `unclear` reason.
  - `needsReview(fields) -> boolean`: true if either stage is set and not `'playoff'`.

- [ ] **Step 1: Write the failing tests `tests/ucl-stages.test.mjs`** with small feed-match builders:
  - `boostMove(10, 'semis')` → `{ pct: 20, multiplier: 2 }`; `boostMove(10, 'last16')` → `{ pct: 12, multiplier: 1.2 }`; `boostMove(-4, 'quarters')` → `{ pct: -4, multiplier: 1 }`; `boostMove(7, 'out')` → `{ pct: -100, multiplier: null }`; `boostMove(5, 'playoff')` → `{ pct: 5, multiplier: 1 }`.
  - `matchGoals` with `regularTime 1-1, extraTime 0-0, penalties 4-3, fullTime 5-4` → `{ home: 1, away: 1 }`; with only `fullTime 2-1` → `{ home: 2, away: 1 }`; with only `fullTime 5-4, penalties 4-3` → `{ home: 1, away: 1 }` (Review Focus 2).
  - `tieOutcome`: leg 1 → `{ pending: true }`; aggregate 3-2 over two legs (teams swap home and away between legs) → the right winner; aggregate level with leg 2's penalties 5-4 for the away side → away wins; leg 1 missing from `stageMatches` → `{ unclear }` (Review Focus 3); final 1-1 with penalties 3-4 → away wins.
  - `leagueOutcome`: matchday 7 → both null; matchday 8 with one league match `IN_PLAY` → `{ pending: true }` (Review Focus 4); matchday 8 complete, positions 3 and 30 → `{ home: 'last16', away: 'out' }`; positions 12 and 24 → both `'playoff'`.
  - `stageFields` for a quarter-final leg 2 won by home with AI moves `+10 / -6` → `home_stage 'semis', home_multiplier 2, home_delta_pct 20, home_ai_pct 10, away_stage 'out', away_delta_pct -100, away_ai_pct -6`; `needsReview` of that → true; of a `playoff`-only result → false; unclear → `fields {}` and a note.

- [ ] **Step 2: Run `node --test tests/ucl-stages.test.mjs`; expect failures (module not found)**

- [ ] **Step 3: Implement `ucl-stages.js`** (no imports from `update-prices.js`; the folded-name function is passed in or the table lookup is done by the caller through a `lookup(name)` on `ctx`, your choice, as long as the tests above hold).

- [ ] **Step 4: Run `node --test tests/*.test.mjs`; expect all pass**

- [ ] **Step 5: Commit** ("Champions League stages: work out who is out and who goes through").

### Task 4: Wire stages into `update-prices.js`

**Files:**
- Modify: `update-prices.js` (imports; `syncFixtures`; Phase 1 of the competition loop; the event insert and auto-apply block; `main` start and run summary)
- Test: `tests/ucl-updater.test.mjs`

**Interfaces:**
- Consumes: `stageFields`, `needsReview`, `legOf` from Task 3; `apply_overdue_stage_events()` from Task 1; `teams.closed`.
- Produces: `export async function clStageContext(fetchJson, stage) -> { stageMatches, leagueMatches, table }` — fetches `competitions/CL/matches?stage=<stage>` (and `stage=LEAGUE_STAGE` plus standings for league matches) through the given fetcher, cached per run; `export function sideIsOpen(row) -> boolean` (`row && !row.closed`).

Changes:
- **Start of `main`, after `syncFixtures`:** call `supabase.rpc('apply_overdue_stage_events')` every run, regardless of `AUTO_APPLY`; log the count, or the error and carry on.
- **Closed clubs:** in Phase 1, a side whose team row is closed is treated as unmatched for pricing (no move applied to it, no "no team matched" noise: log "closed, not priced"). If both sides are closed or missing, skip the match without a row.
- **CL matches:** for each CL match to price, build `ctx` with `clStageContext`. If `stageFields(...).defer` would be true (decide this before pricing by calling `leagueOutcome` with dummy moves, or by splitting the check, your choice), leave the match unwritten this run (log "waiting for the rest of the final league matchday") so the clubs stay locked and the next run retries it. After the AI's moves arrive, merge `stageFields(match, ctx, move.home, move.away).fields` into the insert (the stored `home_delta_pct`/`away_delta_pct` become the boosted ones); log the note when present.
- **Review:** if `needsReview(fields)`, log `Stage result held for your approval: <club> <stage> (AI x% ×m = y%)` and count it under `held`, skipping auto-apply.
- **Fixtures:** `syncFixtures` also stores `stage: m.stage || null` and, for CL knockout stages, `leg` from `legOf(m, stageMatches)` using the same per-run cache.
- **Run log:** after CL standings are fetched in a run, list open `championsleague` clubs on the site that aren't in the CL table: "On your Champions League tab but not in this season's competition: …  Use Close and refund in admin."
- Keep `fetchFinishedMatches` and the existing flow for every other competition untouched.

- [ ] **Step 1: Write the failing tests `tests/ucl-updater.test.mjs`** (import from `../update-prices.js`; it only runs `main` when called directly):
  - `sideIsOpen(null)` false, `sideIsOpen({ closed: true })` false, `sideIsOpen({ closed: false })` true.
  - `clStageContext` with a fake fetcher counting calls: two calls for `QUARTER_FINALS` make one feed request; it returns the matches the fake gave.

- [ ] **Step 2: Run `node --test tests/ucl-updater.test.mjs`; expect failure (exports missing)**

- [ ] **Step 3: Make the changes above.**

- [ ] **Step 4: Run `node --test tests/*.test.mjs` and `node --check update-prices.js`; expect all pass**

- [ ] **Step 5: Commit** ("Champions League stages: price job proposes stage results").

### Task 5: Site: closed clubs and cash-out notifications

**Files:**
- Modify: `index.html` (teams select near line 3411; `renderTable` near line 2620; every other Trade entry point: explorer panel, portfolio rows, watchlist; `loadNotifications` near line 3045)
- Test: `tests/browser/ucl-closed.mjs`

**Interfaces:**
- Consumes: `teams.closed`, `teams.ucl_stage`; notification kinds `cashout` and `refund`.
- Produces: `closedLabel(t) -> string|null` in index.html: `'Out'` for `out`, `'Winners 🏆'` for `winners`, `'Closed'` for any other closed club, null when open.

Behaviour:
- The teams select adds `closed,ucl_stage`.
- A closed club's row shows its price (0.00 when out), a small label from `closedLabel`, and in place of Trade a disabled button reading the label with a title "Trading has closed: <reason>". Same in the explorer panel and the watchlist. Portfolio rows of closed clubs stay visible with their value (0 when out) and have no Sell button.
- Notifications: `cashout` → "Champions League winners! <shares> shares paid out at <price> each (+<total> coins)"; `refund` → "Not in this season's Champions League: <shares> shares refunded at <price> each (+<total> coins)".

- [ ] **Step 1: Write the failing browser test `tests/browser/ucl-closed.mjs`** using `openPage` from `harness.mjs` with Supabase routes returning: an open CL club, an `out` club at 0, a `winners` club, a signed-in session holding the `out` club, and one `cashout` notification. Assert: the out club's market row has no enabled `.buy-btn` and shows `Out`; the winners row shows `Winners 🏆`; the open club still has Trade; the portfolio row for the out club shows `0.00` and no sell control; the bell lists the cash-out text with the total; no page errors.

- [ ] **Step 2: Run `node tests/browser/ucl-closed.mjs`; expect FAIL**

- [ ] **Step 3: Implement the page changes.**

- [ ] **Step 4: Run every browser test (`for t in tests/browser/*.mjs; do …; done`, skipping `harness.mjs`); expect each prints `ok`**

- [ ] **Step 5: Commit** ("Champions League stages: show closed clubs and cash-outs on the site").

### Task 6: Admin: stage cards, Champions League buttons, docs

**Files:**
- Modify: `admin.html` (`eventCardHTML` and `reviewEvent`; the Teams tab rows from `renderRows` near line 705; a small "Not in this season's competition" box on the Teams tab when the Champions League filter is shown)
- Modify: `README.md` (a "Champions League stages" section under Common tasks or after Plans; add `supabase-ucl-stages.sql` to setup notes)
- Test: `tests/browser/admin-ucl.mjs`

**Interfaces:**
- Consumes: `approve_match_event`, the five `admin_ucl_*` functions, the `match_events` stage columns.

Behaviour:
- **Stage event cards** (pending events with a stage): a clear banner per side, e.g. "Arsenal (UCL) through to the semis: AI +10% ×2 = +20%", "Dortmund (UCL) out: price to 0", "Inter (UCL) win the Champions League: AI +8% ×3 = +24%, holders cashed out, Champions League closes", "… to the play-off (no boost)". Buttons: **Approve** and **Reject stage (apply as a normal match)**. Under them: "Applies automatically 12 hours after it was found (at <time>)". Normal cards unchanged.
- **Teams tab, `championsleague` clubs:** open clubs get **Knock out** and **Crown winners**; closed clubs show their state and a price box with **Reopen**. Each asks `confirm()` with a plain sentence of what happens (e.g. "Set Dortmund (UCL) to 0 and close trading? Holders lose these shares.").
- **Non-entrants box:** lists `admin_ucl_non_entrants()` with a **Close and refund** button each.
- After any action: reload teams and events; show errors with `alert`.
- **README:** what the rule is, that stage results wait in Price Approvals and apply after 12 hours, the manual buttons, and "run `supabase-ucl-stages.sql` after `supabase-leagues-1.sql`".

- [ ] **Step 1: Write the failing browser test `tests/browser/admin-ucl.mjs`** (admin session; routes for teams, pending events and the RPCs, recording RPC calls). Assert: a pending `semis` event card shows `×2` and `+20%`; clicking Reject stage calls `approve_match_event` with `p_approve: false`; an open CL club row has Knock out and Crown winners, and accepting the confirm calls `admin_ucl_knock_out` with its id; a closed club row has Reopen, and entering 25 calls `admin_ucl_reopen` with `p_price: 25`; the non-entrants box lists the returned club and its button calls `admin_ucl_close_refund`; no page errors.

- [ ] **Step 2: Run `node tests/browser/admin-ucl.mjs`; expect FAIL**

- [ ] **Step 3: Implement the admin changes and the README section.**

- [ ] **Step 4: Run every browser test, `node --test tests/*.test.mjs`, and the SQL tests; expect all pass**

- [ ] **Step 5: Commit** ("Champions League stages: admin approvals, manual buttons and docs").
