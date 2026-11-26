# Pro and Ultimate, part 1 (payments and tiers) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pro and Ultimate can be bought (Stripe test mode), renewed, cancelled and given by hand, and every paid limit and perk on the site follows one database answer for "what plan is this player on".

**Architecture:** Plan state lives in two private tables (`subscriptions` written only by a Stripe webhook Edge Function, `grants` written only by admin functions). One SQL function `user_tier(uuid)` combines them; triggers and RPCs use it, and the page asks `my_plan()`. Plan-card features are fixed in code so they always match what exists; admin edits prices, links, portal URL and payments mode.

**Tech Stack:** Static `index.html` / `admin.html` (vanilla JS, supabase-js 2.118.0), Supabase Postgres (plpgsql, RLS), Supabase Edge Function (Deno, Stripe SDK `https://esm.sh/stripe@17.7.0?target=deno`), GitHub Actions, Node 22 for tests, Playwright (preinstalled) for browser tests.

**Spec:** `docs/superpowers/specs/2026-11-26-pro-ultimate-design.md`

## Global Constraints

- Tiers: `free`, `pro`, `ultimate` (ultimate > pro > free). Prices on cards: Pro $1.99/mo, $20/yr; Ultimate $4.99/mo, $50/yr.
- Watchlist caps: Free 2, Pro 5, Ultimate 15 (hard cap). Players already over keep their clubs but can't add.
- No paid edge in trading, coins or the leaderboard. Every limit checked in the database.
- Paid subscription counts when status is `active`, `trialing` or `past_due` and `current_period_end > now() - 3 days`, and (when payments mode is `live`) only if `livemode` is true.
- Payments mode (`off` | `test` | `live`) starts at `test`. Test note text: "Test mode: pay with card 4242 4242 4242 4242, any future date, any CVC".
- Admin is the account whose JWT email is `pitchmarketadmin@gmail.com` (existing convention).
- Nothing secret in the repo or the page. Edge Function secrets: `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_PRICE_PRO_MONTHLY`, `STRIPE_PRICE_PRO_YEARLY`, `STRIPE_PRICE_ULTIMATE_MONTHLY`, `STRIPE_PRICE_ULTIMATE_YEARLY`.
- Every SQL change: one new file `supabase-pro-1.sql`, safe to run twice, also folded into `supabase-schema.sql`.
- Snapshots and season stats start only once the Christmas reset records a season start.
- Phone layout: no sideways scrolling at 320–412 px (existing audit).
- Plan-card features, exactly (Free / Pro / Ultimate), from the spec's tier table.

## Review Focus

1. A subscription that was cancelled or stopped renewing: tier drops to free 3 days after `current_period_end`, never earlier, never later.
2. A test-mode subscription after payments mode is switched to `live`: no longer counts; a manual grant still does.
3. A player already watching more clubs than their new cap: existing rows stay, the next add is refused with the cap in the message.
4. A signed-out visitor pressing a buy button: asked to sign in; no Stripe link opens without `client_reference_id`.
5. A webhook event with an unknown price, a missing `client_reference_id`, or a bad signature: no plan granted, no crash (bad signature → 400, otherwise 200 and logged).

---

### Task 1: Test harness for SQL and browser tests

**Files:**
- Create: `tests/sql/supabase-stubs.sql` (auth schema, `auth.users`, `auth.uid()`, `auth.jwt()` reading `request.jwt.claims`, `auth.role()`, roles `anon`, `authenticated`, `service_role`)
- Create: `tests/run-sql-tests.sh` (creates a throwaway database named `pm_test` on `$PGHOST`/`$PGPORT`, loads stubs, then `supabase-schema.sql`, then each `tests/sql/*.test.sql` with `ON_ERROR_STOP=1`; prints `PASS <file>` / `FAIL <file>`; exit code non-zero on any fail)
- Create: `tests/browser/harness.mjs`
- Modify: `README.md` (a short "Tests" section: how to run both)

**Interfaces:**
- Produces: `openPage(url, { routes, session, viewport }) -> { page, errors, calls }` in `tests/browser/harness.mjs`. It routes `cdn.jsdelivr.net` to `node_modules/@supabase/supabase-js/dist/umd/supabase.js`, `cdnjs.cloudflare.com` to a minimal Chart stub (constructor storing config, `update()`, `destroy()`), fonts to empty CSS; `*.supabase.co` requests go to `routes[path](request) -> body` (path like `rpc/my_plan`, `teams`), default `[]`; `session` puts a signed-in session in localStorage; `pm-help` set to `off`. `calls` records each Supabase path hit.
- Produces: SQL tests set the caller with `select set_config('request.jwt.claims', json_build_object('sub', <uuid>, 'email', <email>)::text, false)`; stub `auth.uid()` reads `sub` from it.

- [ ] **Step 1:** Write `tests/sql/smoke.test.sql` asserting the schema loaded: `do $$ begin assert (select count(*) from pg_proc where proname = 'get_leaderboard') = 1; end $$;`
- [ ] **Step 2:** Run `PGHOST=/var/tmp/pmpg PGPORT=5433 tests/run-sql-tests.sh`. Expected: `PASS tests/sql/smoke.test.sql`.
- [ ] **Step 3:** Write `tests/browser/smoke.mjs`: open `http://127.0.0.1:8765/index.html` via `openPage` with `routes.teams` returning two teams; assert `errors` is empty and `#tableBody tr` count is 2.
- [ ] **Step 4:** Run `node tests/browser/smoke.mjs` (with `python3 -m http.server 8765` serving the repo). Expected: prints `ok`.
- [ ] **Step 5:** Commit: `git add tests README.md && git commit -m "Tests: local SQL and browser test harness"`

### Task 2: Plan tables, `user_tier`, caps, alerts, leaderboard tier, admin grants, season and snapshots (SQL)

**Files:**
- Create: `supabase-pro-1.sql`
- Modify: `supabase-schema.sql` (fold in), `supabase-season-reset.sql`
- Test: `tests/sql/pro-tiers.test.sql`

**Interfaces:**
- Produces (tables): `subscriptions(id text pk /* Stripe subscription id */, user_id uuid not null references auth.users on delete cascade, stripe_customer_id text, tier text check (tier in ('pro','ultimate')), status text not null, current_period_end timestamptz, cancel_at_period_end boolean not null default false, livemode boolean not null, updated_at timestamptz not null default now())`, RLS: player selects own rows, no other policies. `grants(user_id uuid pk references auth.users on delete cascade, tier text check (tier in ('pro','ultimate')), until timestamptz, note text, granted_at timestamptz not null default now())`, RLS on, no policies. `portfolio_snapshots(user_id uuid references auth.users on delete cascade, day date, value numeric not null, primary key (user_id, day))`, RLS: player selects own.
- Produces (functions):
  - `is_admin() returns boolean` (JWT email check).
  - `payments_settings() returns jsonb`: `site_settings.value` for key `payments`, default `{"mode":"test","portal_url":"","links":{}}`. Seed row inserted `on conflict do nothing`.
  - `user_tier(p_user uuid) returns text`: highest of counting subscriptions (Global Constraints rule) and an unexpired grant (`until is null or until > now()`); `'free'` otherwise. `stable security definer`.
  - `my_plan() returns jsonb`: `{tier, source: 'stripe'|'grant'|'free', period_end, cancel_at_period_end, test: <true if the counting subscription has livemode false>, has_subscription: <any counting subscription>}` for `auth.uid()`; `{tier:'free', source:'free'}` when signed out. Granted to `anon, authenticated`.
  - `watchlist_limit_check` trigger function: caps from `user_tier`: 2 / 5 / 15; message `Watchlist full: your plan allows N clubs.`
  - `fire_price_alerts`: alert inserts filter `user_tier(w.user_id) <> 'free'` instead of `is_pro/is_ultimate`.
  - `get_leaderboard(p_limit integer default 20) returns table(display_name text, portfolio_value numeric, tier text)` (drop and recreate; keeps hidden-account filter).
  - `admin_list_plans() returns table(user_id uuid, email text, display_name text, tier text, source text, until timestamptz, note text)`: only players whose tier isn't free, plus every grant; raises `Admins only.` for non-admins.
  - `admin_grant_plan(p_email text, p_tier text, p_until timestamptz, p_note text) returns void` (upsert into `grants`; raises `No player with that email.`), `admin_revoke_grant(p_user uuid) returns void`. Admin-only, granted to `authenticated`.
  - `season_start() returns timestamptz` from `site_settings` key `season` (`{"start": "<iso>"}`), null if missing.
  - `take_portfolio_snapshots() returns integer`: 0 and no writes when `season_start()` is null; else upserts today's (Europe/London date) value = `coin_balance + sum(shares * price)` for every profile; returns rows written. Executable by `service_role` only.
- `supabase-season-reset.sql` additionally: `delete from public.portfolio_snapshots;` and upserts `site_settings` key `season` with `{"start": now()}`.

- [ ] **Step 1: Write `tests/sql/pro-tiers.test.sql`** with these assertions (each in a `do` block, users created in `auth.users` + `profiles` first):
  - free player: `user_tier(u) = 'free'`.
  - active pro sub, `livemode` false, mode `test`, period end tomorrow → `'pro'`; same with mode `live` → `'free'`.
  - pro sub with `current_period_end = now() - interval '2 days'` → `'pro'`; `- interval '4 days'` → `'free'`; status `canceled` with future end → `'free'`.
  - pro sub + ultimate grant → `'ultimate'`; grant with `until` yesterday → back to sub tier.
  - watchlist: free player inserts 2 rows OK, 3rd raises `Watchlist full: your plan allows 2 clubs.`; a free player with 4 existing rows (inserted with the trigger disabled) keeps 4 rows and can't add a 5th; ultimate player's 16th insert raises with 15.
  - `get_leaderboard()` returns the `tier` column with `'pro'` for the pro player.
  - as a non-admin JWT, `admin_grant_plan(...)` raises `Admins only.`; as the admin email it creates a grant and `user_tier` returns it; `admin_revoke_grant` removes it.
  - `take_portfolio_snapshots()` returns 0 with no season row; after setting `season` it returns the profile count and a second call the same day doesn't duplicate rows.
  - as `anon`: `select count(*) from subscriptions` = 0 and `select count(*) from grants` raises or returns 0.
- [ ] **Step 2:** Run `tests/run-sql-tests.sh`. Expected: `FAIL tests/sql/pro-tiers.test.sql` (functions missing).
- [ ] **Step 3:** Write `supabase-pro-1.sql` (header comment in the style of the other `supabase-*.sql` files saying what it does and to run it once, safe twice), fold it into `supabase-schema.sql`, update `supabase-season-reset.sql`.
- [ ] **Step 4:** Run `tests/run-sql-tests.sh`, and also load `supabase-pro-1.sql` twice onto a database built from `origin/main`'s schema. Expected: all `PASS`, both loads exit 0.
- [ ] **Step 5:** Commit: `git add supabase-pro-1.sql supabase-schema.sql supabase-season-reset.sql tests/sql && git commit -m "Plans: subscriptions, grants, user_tier, new caps, season snapshots"`

### Task 3: Stripe webhook Edge Function

**Files:**
- Create: `supabase/functions/stripe-webhook/plan.js` (pure logic, no imports)
- Create: `supabase/functions/stripe-webhook/index.ts`
- Test: `tests/stripe-plan.test.mjs` (`node --test`)

**Interfaces:**
- Produces in `plan.js`:
  - `tierForPrice(priceId: string, env: Record<string,string>) -> 'pro'|'ultimate'|null` using the four `STRIPE_PRICE_*` env names.
  - `rowFromSubscription(sub: object, env) -> { id, stripe_customer_id, tier, status, current_period_end /* ISO */, cancel_at_period_end, livemode } | null`; `current_period_end` from `sub.current_period_end ?? sub.items.data[0].current_period_end` (newer Stripe API versions moved it onto items); `null` when the price maps to no tier.
- `index.ts`: `Deno.serve`; verifies `stripe-signature` with `stripe.webhooks.constructEventAsync(body, sig, STRIPE_WEBHOOK_SECRET, undefined, Stripe.createSubtleCryptoProvider())`; bad signature → 400. Handles:
  - `checkout.session.completed`: if `client_reference_id` and `subscription` present, retrieve the subscription, upsert `rowFromSubscription` plus `user_id = client_reference_id` into `subscriptions` (service-role client from `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY`).
  - `customer.subscription.created|updated|deleted`: update the row with that `id` from `rowFromSubscription` (deleted → status `canceled`); if no row exists yet, look up `user_id` from another row with the same `stripe_customer_id`; if none, log and return 200.
  - Anything else → 200.

- [ ] **Step 1: Write `tests/stripe-plan.test.mjs`:** `tierForPrice('price_pm', env) === 'pro'`, `('price_uy', env) === 'ultimate'`, `('price_x', env) === null`; `rowFromSubscription` on a subscription with top-level `current_period_end: 1767225600` returns `current_period_end === '2026-01-01T00:00:00.000Z'`; the same with the field only on `items.data[0]` returns the same; an unknown price returns `null`; `livemode: false` carries through.
- [ ] **Step 2:** Run `node --test tests/stripe-plan.test.mjs`. Expected: FAIL (module missing).
- [ ] **Step 3:** Implement `plan.js` and `index.ts` per the Interfaces block.
- [ ] **Step 4:** Run `node --test tests/stripe-plan.test.mjs`. Expected: all pass. If `deno` is available, `deno check supabase/functions/stripe-webhook/index.ts`; otherwise note it in the commit body.
- [ ] **Step 5:** Commit: `git add supabase/functions tests/stripe-plan.test.mjs && git commit -m "Stripe webhook Edge Function"`

### Task 4: Site: plan state, honest plan cards, buy and change-plan buttons, caps, badges

**Files:**
- Modify: `index.html` (profile loading near `currentIsPro`, `applyProStatus`, `wlSlotLimit`, `renderSiteContent` pro block, `renderLeaderboard`, nav account area)
- Test: `tests/browser/plans.mjs`

**Interfaces:**
- Consumes: `my_plan()`, `get_leaderboard` `tier` column, `site_settings` key `payments` (`{mode, portal_url, links:{pro_monthly, pro_yearly, ultimate_monthly, ultimate_yearly}}`).
- Produces: `let currentPlan = { tier:'free', source:'free' }`, `planTier() -> 'free'|'pro'|'ultimate'`, `hasPaidPerks() -> boolean` (tier isn't free). Existing `currentIsPro` / `currentIsUltimate` are derived from `currentPlan` so older code paths keep working.
- `PLAN_CARDS` constant in `index.html`: Free, Pro monthly, Pro yearly, Ultimate monthly, Ultimate yearly, with the spec's exact features (Free: "Trading, leaderboard, Daily Kickabout and every chart", "Season Wrapped", "2 watchlist slots", "Ads"; Pro: "No ads", "5 watchlist slots", "Price alerts", "Private leagues: create one and invite your mates", "Portfolio history", "Pro skins", "Pro badge"; Ultimate: "Everything in Pro", "15 watchlist slots", "Kickabout archive", "Weekly AI recap", "Compare charts", "League branding", "Ultimate badge"). Features not yet built are shown with a small "Coming soon" tag until their part ships (private leagues, portfolio history, Season Wrapped, Kickabout archive, weekly AI recap, compare charts, league branding). Admin's `pro` content still sets eyebrow, title, description and the displayed prices.
- Card button rules: mode `off` → "Coming soon" (disabled); the player's current tier → "Your plan"; player has a counting subscription → "Change plan" opening `portal_url`; signed out → "Sign in to upgrade" opening the sign-in box; otherwise a link to the matching `links.*` URL with `client_reference_id=<user id>&prefilled_email=<email>` appended; a missing link → "Coming soon". Mode `test` shows the test-card note under the plans.
- Account area: a "Manage subscription" link to `portal_url` when the player has a subscription; a PRO / ULTIMATE pill when paid.
- Leaderboard rows show a small `PRO` / `ULTIMATE` badge next to the name from the `tier` column.

- [ ] **Step 1: Write `tests/browser/plans.mjs`** covering: signed out → buy buttons read "Sign in to upgrade" and clicking opens `#authOverlay`; signed-in free player, mode `test`, links set → Pro monthly href contains `client_reference_id=u1` and `prefilled_email=`; test note visible; `my_plan` returning `{tier:'pro', source:'stripe', has_subscription:true}` → Pro cards read "Your plan" / "Change plan", ads hidden, watchlist tag reads PRO, slot text says 5; mode `off` → every button "Coming soon"; leaderboard row with `tier:'ultimate'` shows an ULTIMATE badge; feature list on the Ultimate card contains "15 watchlist slots" and none of the old features ("Custom dashboards", "Market simulations"); no page errors; phone audit at 390 px: page not wider than the screen.
- [ ] **Step 2:** Run `node tests/browser/plans.mjs`. Expected: FAIL.
- [ ] **Step 3:** Implement per Interfaces.
- [ ] **Step 4:** Run `node tests/browser/plans.mjs` and `node tests/browser/smoke.mjs`. Expected: both `ok`.
- [ ] **Step 5:** Commit: `git add index.html tests/browser/plans.mjs && git commit -m "Plans on the site: honest cards, buy and change-plan buttons, caps, badges"`

### Task 5: Pro skins

**Files:**
- Modify: `index.html` (`window.THEMES`, theme CSS blocks, `buildThemeMenu`, theme choice handler)
- Test: `tests/browser/skins.mjs`

**Interfaces:**
- Consumes: `planTier()` from Task 4.
- Produces: three entries in `THEMES` with `pro: true`: `floodlights` ("Floodlights": night stadium, deep navy with floodlight white and pitch green), `trophy` ("Trophy Cabinet": polished silver with claret), `terrace` ("Terrace": stand concrete with scarf colours). Each a full `[data-theme="…"]` token block like the existing themes, including `--ka-match`, `--ka-close`, `--ka-on` and Google Fonts in `fonts`.
- Picker: Pro themes listed under a "Pro skins" heading with a lock for free players; choosing one as a free player doesn't apply it and scrolls to `#pro` with a short message "Pro skins come with Pro and Ultimate." When the plan loads and the saved theme is a Pro skin the player isn't entitled to, it falls back to `normal`.

- [ ] **Step 1: Write `tests/browser/skins.mjs`:** free player: picker shows 3 locked items; clicking `floodlights` leaves `data-theme` unchanged and the `#pro` section in view; with localStorage `pm-theme=trophy` and a free plan, `data-theme` ends as `normal`; pro player: clicking `terrace` sets `data-theme="terrace"`; each Pro skin renders the table with no page errors.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run it and take a 390 px and a 1280 px screenshot of each Pro skin for the PR description. Expected: `ok`.
- [ ] **Step 5:** Commit: `git add index.html tests/browser/skins.mjs && git commit -m "Pro skins: Floodlights, Trophy Cabinet, Terrace"`

### Task 6: Admin: payments settings and manual grants

**Files:**
- Modify: `admin.html` (new "Plans & Payments" tab; the Pro plan editor limited to eyebrow, title, description and prices)
- Test: `tests/browser/admin-plans.mjs`

**Interfaces:**
- Consumes: `payments_settings` row (`site_settings` key `payments`, written with the existing admin upsert pattern), `admin_list_plans()`, `admin_grant_plan()`, `admin_revoke_grant()`.
- Produces: a form with payments mode (radio: Off / Test / Live), four link fields, portal URL field and Save; a table of players on Pro/Ultimate (name, email, tier, source, until, note) with Revoke on grants; a grant form (email, tier, optional end date, note). Switching to Live asks for confirmation: "Live mode takes real payments. Only switch once the Stripe account is activated and the live links are pasted."

- [ ] **Step 1: Write `tests/browser/admin-plans.mjs`** (admin session): saving the form sends an upsert with `key:'payments'` and the entered links; the grant form calls `rpc/admin_grant_plan` with the email, tier and note; Revoke calls `rpc/admin_revoke_grant` with the row's user id; choosing Live without confirming leaves the mode unchanged; no page errors.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run it. Expected: `ok`.
- [ ] **Step 5:** Commit: `git add admin.html tests/browser/admin-plans.mjs && git commit -m "Admin: payments settings and manual Pro/Ultimate grants"`

### Task 7: Nightly snapshots, setup guide and status

**Files:**
- Modify: `backup-data.js` (call `take_portfolio_snapshots` with the service key before the backup; log the count; a failure is logged, not fatal)
- Create: `docs/stripe-setup.md`
- Modify: `README.md`, `STATUS.md`

**Interfaces:**
- Consumes: `take_portfolio_snapshots()`.
- `docs/stripe-setup.md`, written for someone who hasn't done this before, numbered steps with where to click: create the Stripe account (test mode); create products Pro and Ultimate with monthly and yearly prices ($1.99, $20, $4.99, $50); create four Payment Links with "after payment, redirect to" the site URL; set up the customer portal allowing plan switching between all four prices and cancellation, and copy its login link; deploy the `stripe-webhook` function from the Supabase dashboard (paste `index.ts` and `plan.js`), turning off "Verify JWT"; add the webhook endpoint in Stripe for `checkout.session.completed`, `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`; set the six secrets; paste links and portal URL in admin; test with card 4242 4242 4242 4242; the "going live" checklist from the spec.
- `STATUS.md`: running list gains "Run `supabase-pro-1.sql`" and "Set up Stripe test mode (docs/stripe-setup.md)"; the Pro decision and Pro-lifecycle items are replaced by "Going live with payments: terms, privacy, refund pages, then the go-live checklist".

- [ ] **Step 1:** Add the call to `backup-data.js`; run it against the local database with a fake service key path is not possible, so verify with `node --check backup-data.js` and a dry review that a thrown error is caught. Expected: syntax OK.
- [ ] **Step 2:** Write `docs/stripe-setup.md`, update `README.md` (Plans and payments section linking it) and `STATUS.md`.
- [ ] **Step 3:** Run every test: `tests/run-sql-tests.sh`, `node --test tests/stripe-plan.test.mjs`, each `tests/browser/*.mjs`, and the existing phone audit. Expected: all pass, no sideways scrolling at 320–412 px.
- [ ] **Step 4:** Commit: `git add backup-data.js docs/stripe-setup.md README.md STATUS.md && git commit -m "Nightly portfolio snapshots and Stripe setup guide"`
