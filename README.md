# PitchMarket

**Trade the table.** PitchMarket is a free-to-play simulated stock exchange for football clubs. Every player starts with 2,000 Fan Coins, buys and sells shares in clubs and national teams, and competes on a season-long leaderboard. Prices move after real match results.

Live at **https://pitchmarketgame.com** (GitHub Pages with a custom domain; the old `pitchmarket.github.io/Pitchmarket` address redirects there).

> PitchMarket is a simulation for entertainment. Prices are not real quotes and Fan Coins have no cash value.

## How it works

```
football-data.org ──► update-prices.js (GitHub Actions, every 6h)
                            │  asks an AI (Gemini / Claude) how far
                            │  each team's price should move
                            ▼
                     Supabase: match_events (pending)
                            │
          auto-apply (≤ 8%) │  or  admin approves in admin.html
                            ▼
                     Supabase: teams.price ──► index.html
```

| Part | What it is |
|---|---|
| `index.html` | The public site: markets, explorer, trading, portfolio, watchlist, price alerts, leaderboard, Pro tiers. One self-contained page (inline CSS and JS, Chart.js and supabase-js from a CDN). |
| `admin.html` | Admin dashboard: manage teams and leagues, edit site content (stored in `site_settings`), and approve or reject AI-proposed price moves. |
| `sw.js` | Service worker. Pages are always fetched fresh when online, so an update shows on the next load; the last good copy is used only offline. Code libraries from the CDNs are kept after the first visit. Supabase data is never served from it. Bump `VERSION` in it to throw away old saved copies. |
| `update-prices.js` | Node script that fetches finished matches, prices them with an AI and writes proposed moves to `match_events`. |
| `.github/workflows/update-prices.yml` | Runs the updater every 6 hours (UTC) and on demand. |

There is no build step. The HTML files are deployed as-is.

## Backend (Supabase)

The site uses [Supabase](https://supabase.com) for auth and data. The browser uses the **public (anon/publishable) key** that is in both HTML files. That key is meant to be public, so all security comes from Row Level Security (RLS) and the database functions.

**Tables:** `teams`, `profiles`, `holdings`, `trades`, `watchlist`, `price_history`, `notifications`, `site_settings`, `match_events`

**Functions (RPC):** `trade`, `get_leaderboard`, `approve_match_event`, `auto_apply_match_event`, `clear_read_notifications`

**Schema:** [`supabase-schema.sql`](supabase-schema.sql) has every table, RLS policy, function and trigger. Browser errors players hit are reported to `client_errors` (at most 5 per visit, repeats counted) and listed in admin under **Errors**. Text edited in admin may use simple formatting (bold, italics, line breaks, links); anything else, including scripts and `javascript:` links, is stripped before it reaches the page. Run it in the SQL Editor of an empty Supabase project to set up your own copy of the backend. When you change the live database, update this file in the same pull request.

## Running locally

Open `index.html` (or `admin.html`) in a browser, or serve the folder:

```bash
npx serve .
```

⚠️ Both pages are wired to the **production** Supabase project. Anything you do while signed in, such as trades or admin edits, changes live data. Use a separate test account, and never approve price moves or edit content in admin unless you mean to.

To point the site at a different Supabase project, change `SUPABASE_URL` and `SUPABASE_ANON_KEY` near the top of each HTML file.

### Running the price updater

```bash
npm install
export FOOTBALL_DATA_API_KEY=...
export SUPABASE_URL=...
export SUPABASE_SERVICE_ROLE_KEY=...   # bypasses RLS: never commit it or put it in HTML
export GEMINI_API_KEY=...
node update-prices.js
```

Requires Node 22, the same version the workflow uses.

## Configuration

The workflow reads these as **GitHub Actions secrets** (Settings → Secrets and variables → Actions):

| Secret | Required | Notes |
|---|---|---|
| `FOOTBALL_DATA_API_KEY` | yes | From [football-data.org](https://www.football-data.org) |
| `SUPABASE_URL` | yes | Same URL as in the HTML files |
| `SUPABASE_SERVICE_ROLE_KEY` | yes | Supabase → Settings → API. **Not** the anon key. |
| `GEMINI_API_KEY` | if `AI_PROVIDER=gemini` | From [aistudio.google.com](https://aistudio.google.com) (free tier) |
| `ANTHROPIC_API_KEY` | if `AI_PROVIDER=claude` | From [console.anthropic.com](https://console.anthropic.com) |

Optional settings (set in the workflow's `env:` block):

| Variable | Default | Purpose |
|---|---|---|
| `AI_PROVIDER` | `gemini` | `gemini` or `claude` |
| `GEMINI_MODEL` | `gemini-3.6-flash` | Gemini model name |
| `CLAUDE_MODEL` | see `update-prices.js` | Claude model name |
| `LOOKBACK_DAYS` | `3` | How far back to look for finished matches |
| `AI_BATCH_SIZE` | `10` | Matches priced per AI call (1–25) |
| `AI_MIN_GAP_MS` | `4500` | Minimum gap between AI calls. Raise it if you see HTTP 429. |
| `AI_MAX_RETRIES` | `4` | Retries per AI call |
| `AI_FAIL_STREAK_ABORT` | `4` | Stop the run after this many AI failures in a row |
| `AUTO_APPLY` | `false` (workflow sets `true`) | Apply small moves without admin approval |
| `AUTO_APPLY_MAX_PCT` | `8` | Moves bigger than this always wait for approval |

### Manual runs

Go to Actions → **Update PitchMarket prices** → **Run workflow**. You can override `lookback_days`, `ai_min_gap_ms` and `ai_batch_size` for that run. For example, use `lookback_days: 14` to catch up after fixing team names.

## Common tasks

**A club's matches are being skipped ("no team matched").**
The run summary at the end of the workflow log lists every unmatched name, already formatted as alias lines. Either rename the club in admin to match the feed, or add the line to `NAME_ALIASES` (or `UCL_ALIASES` for Champions League) in `update-prices.js`.

**Adding a league.**
Add the team rows in admin (with a new league key). If prices should update automatically, also map the football-data.org competition code to that key in `COMPETITIONS` in `update-prices.js`.

## Daily Kickabout

Four daily football games on the main page: **Scouted** (guess the player from league, team, nationality, age and position), **Journeyman** (guess the player from their career, one club at a time), **Link-Up** (connect two players through teammates using at most 6 players) and **Ball Knowledge** (four questions, win with 3 right). Everyone gets the same puzzles each day, and a new day starts at midnight UK time. Each win pays 25 Fan Coins, once per game per day, so 100 a day at most.

- **Player data**: `import-players.js` runs every Monday from `.github/workflows/import-players.yml`. Current squads come from football-data.org (the same feed and key as the price updater), so every player is listed at their real club. Each squad player is matched to [Wikidata](https://www.wikidata.org) (CC0) by birth date and name, for fame, continent and club-by-club careers. Clubs are linked to Wikidata in `teams.wikidata_id`; if one is linked wrongly, set it by hand and the importer won't overwrite it. Every squad player in the nine leagues is kept, including players at clubs that aren't listed for trading (they show under the club's own name); the run log lists those clubs, and if one should be on the site, add an alias in `update-prices.js` (`NAME_ALIASES`). Senior national-team spells go to `player_intl`, so Link-Up counts international teammates as well as club teammates and current squad-mates. Wikidata lists national teams for only some players, so each player's English Wikipedia infobox (`national_team` / `national_years`) is read too; if Wikipedia can't be reached, the run carries on with Wikidata's.
- **Puzzles and coins** are handled in the database: `daily_puzzle()` makes each game's puzzle for the day (Ball Knowledge questions come from `make_question()`, Link-Up pairs from `teammates_of()`), `kickabout_guess()` checks guesses and pays out, and `kickabout_state()` returns what the page shows. Answers, careers and quiz answers can't be read from the page until a player has finished.

## Plans and payments

Pro ($1.99 a month or $20 a year) and Ultimate ($4.99 a month or $50 a year) are paid through Stripe. Nothing paid changes trading, coins or the leaderboard: the plans add things like more watchlist slots (2 Free, 5 Pro, 15 Ultimate), price alerts, Pro skins and a badge on the leaderboard.

- The site's buttons open Stripe **Payment Links**. After a purchase, Stripe tells the `stripe-webhook` Edge Function (`supabase/functions/stripe-webhook/`), which records the subscription in the database. Every limit is checked in the database, so a plan can't be faked from the browser.
- Admin → **Plans & Payments** sets payments to Off, Test or Live, holds the links and the customer portal link, lists who has a plan, and gives or takes away a free plan.
- The nightly backup also saves each player's portfolio value for Pro's portfolio history, once the Christmas reset has started the season.

**Setting it up:** follow [docs/stripe-setup.md](docs/stripe-setup.md), step by step. It starts in Stripe test mode (no real money) and ends with a checklist for going live. The database part is `supabase-pro-1.sql`.

Tests: the webhook's logic in `tests/stripe-plan.test.mjs`, the database side in the SQL tests, and the plan pages in `tests/browser/plans.mjs`, `admin-plans.mjs` and `skins.mjs`. How to run them is under Tests below.

## Private leagues

Pro and Ultimate members can create private leagues (up to 3 each); anyone can join with the league's code (up to 10 leagues each, 20 players per league). The owner can kick a player, which also gives the league a new code, and Ultimate owners can brand their league. Everything is under the **My leagues** tab in the Leaderboard section.

- **Classic** leagues rank members by the percentage they have gained since joining. **Player of the week** is whoever gained the highest percentage that week. Weeks run Monday to Sunday, UK time.
- Results are stored by the nightly backup job (03:23 UTC), after it has saved a good snapshot, so a week's result appears on Monday morning. A week with no Sunday snapshot (the job failed, or ran after 06:00 UK time on Monday) has no result.
- Scoring starts with the first full week after the Christmas reset records the season start. Don't record the next season's start by hand: doing so early stops the current season's remaining weeks closing. Only run the reset.
- Head-to-head leagues are coming in part 2b.

**Setting it up:** run `supabase-leagues-1.sql` in the SQL Editor after `supabase-pro-1.sql` (and before the reset). Safe to run twice.

## Backups

**Code.** Every version is in the git history. After each major change, a branch named `backup/vX.Y-YYYY-MM-DD` keeps a snapshot of the site at that point; open it on GitHub and use **Code → Download ZIP** to get it.

**Data.** `.github/workflows/backup-data.yml` runs `backup-data.js` every night at 03:23 UTC and saves `teams`, `price_history` and `site_settings` to the `data-backups` branch, with a `restore.sql` that puts them back. Each night with changes is a commit on that branch, so older backups stay in its history. No player data is included (no emails, balances, holdings or trades), because the repo is public. Restore steps are in that branch's README. Run it by hand from the Actions tab (**Back up PitchMarket data → Run workflow**). Before saving, it calls `take_portfolio_snapshots()` to record each player's portfolio value for the night (it saves nothing until a season start is recorded); if that fails, the log says so and the backup still runs. When the snapshots were saved, the same nightly run then closes finished league weeks with `close_matchweeks()`.

## Tests

SQL tests run against a throwaway local Postgres (stubs stand in for Supabase auth):

```
PGHOST=/path/to/socket PGPORT=5433 tests/run-sql-tests.sh
```

It creates database `pm_test`, loads `tests/sql/supabase-stubs.sql` and `supabase-schema.sql`, then runs each `tests/sql/*.test.sql`.

Browser tests use Playwright with Supabase and CDN requests stubbed (`tests/browser/harness.mjs`). Serve the repo, then run a test:

```
python3 -m http.server 8765 --bind 127.0.0.1 &
node tests/browser/smoke.mjs
```

`tests/browser/fresh-pages.mjs` checks that an update shows on the next load (and that the page still opens offline), and that players on the old service worker are offered a refresh.

The Stripe webhook's plan logic and the backup's restore script have Node tests:

```
node --test tests/stripe-plan.test.mjs tests/backup-restore.test.mjs
```

## Contributing

1. Branch off `main` and open a pull request. Don't push directly to `main`.
2. Keep changes small. `index.html` is a single large file, so big diffs to it tend to cause merge conflicts.
3. Never commit secrets. The only key that belongs in the HTML is the public anon/publishable key.
4. Test UI changes with a test account. See the production warning above.
