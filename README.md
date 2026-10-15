# PitchMarket

**Trade the table.** PitchMarket is a free-to-play simulated stock exchange for football clubs. Every player starts with 2,000 Fan Coins, buys and sells shares in clubs and national teams, and competes on a season-long leaderboard. Prices move after real match results.

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
| `update-prices.js` | Node script that fetches finished matches, prices them with an AI and writes proposed moves to `match_events`. |
| `.github/workflows/update-prices.yml` | Runs the updater every 6 hours (UTC) and on demand. |

There is no build step. The HTML files are deployed as-is.

## Backend (Supabase)

The site uses [Supabase](https://supabase.com) for auth and data. The browser uses the **public (anon/publishable) key** that is in both HTML files. That key is meant to be public, so all security comes from Row Level Security (RLS) and the database functions.

**Tables:** `teams`, `profiles`, `holdings`, `trades`, `watchlist`, `price_history`, `notifications`, `site_settings`, `match_events`

**Functions (RPC):** `trade`, `get_leaderboard`, `approve_match_event`, `auto_apply_match_event`, `clear_read_notifications`

> **TODO:** The database schema, RLS policies and functions aren't in this repo yet (the code refers to a `supabase-schema.sql`). Until they are, you can't set up your own copy of the backend. Ask a maintainer for access.

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

## Contributing

1. Branch off `main` and open a pull request. Don't push directly to `main`.
2. Keep changes small. `index.html` is a single large file, so big diffs to it tend to cause merge conflicts.
3. Never commit secrets. The only key that belongs in the HTML is the public anon/publishable key.
4. Test UI changes with a test account. See the production warning above.
