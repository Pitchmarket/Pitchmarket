# Pro and Ultimate: design

_26 Nov 2026. Agreed with the organiser in conversation; calls the builder made are marked "(builder's call)"._

## Why

PitchMarket should feel complete: Pro and Ultimate are advertised as the way to get the most out of the site, and everything on the plan cards actually exists and can be bought. Revenue is secondary for now.

## Goals

- Pro and Ultimate can be bought, renewed and cancelled, with access switching on and off immediately.
- The plan cards list exactly what each tier gets, and every item works.
- Built and tested now in **Stripe test mode**; going live later is a swap of links and keys, with no code changes.

## Non-goals

- Taking real money now (needs terms, privacy and refund pages and Stripe account activation; on the launch list).
- The match **simulator** (deferred: it informs trading, which would be a paid edge while there is a cash prize).
- Taxes/VAT handling beyond what Stripe does by default.

## Anti-goals (a failure even if it works)

- **Any paid edge in trading, coins or the leaderboard.** Every paid feature is cosmetic, analysis of the player's own data, social, or for fun. Kickabout archive plays pay no coins. Private leagues don't affect the main leaderboard.
- Advertising a feature that doesn't exist.
- Paid status that can be faked from the browser: every limit is checked in the database.

## The tiers

| | Free | Pro ($1.99/mo, $20/yr) | Ultimate ($4.99/mo, $50/yr) |
|---|---|---|---|
| Trading, leaderboard, Daily Kickabout, all charts | ✓ | ✓ | ✓ |
| **Season Wrapped** (shareable season card) | ✓ | ✓ | ✓ |
| Ads | shown | none | none |
| Watchlist slots | 2 | 5 | 15 (hard cap) |
| Price alerts | – | ✓ | ✓ |
| **Private leagues**: create one, invite by code, mini-leaderboard | join only | create | create |
| **Portfolio history**: value-over-season chart, best/worst trades | – | ✓ | ✓ |
| **Pro skins**: premium themes | – | ✓ | ✓ |
| Badge next to name (leaderboard, leagues) | – | Pro | Ultimate |
| **Kickabout archive**: replay past days, no coins | – | – | ✓ |
| **Weekly AI recap** of your trades and clubs | – | – | ✓ |
| **Compare charts**: up to 4 clubs on one chart | – | – | ✓ |
| **League branding**: league name colour and emblem | – | – | ✓ |

Prices are the current ones on the cards. Players already over a new watchlist cap keep their clubs but can't add more.

(builder's call) Anyone can **join** a private league with its code, free players included; only Pro and Ultimate can **create** one. This lets a Pro player bring in friends, which is the point. A league keeps working if its creator's plan lapses; branding stops showing.

(builder's call) Pro skins are **new** themes, not existing ones moved behind the paywall: nobody loses a look they use (the organiser's favourite is Chalk). Three new themes, designed in the same token system: **Floodlights** (night stadium), **Trophy Cabinet** (polished silver and claret), **Terrace** (scarves and stand concrete). The picker shows them to everyone with a lock; choosing one as a free player opens the plan cards.

## How payments work (approach A, chosen)

Approaches considered:
- **A. Stripe + instant webhook (chosen).** A Supabase Edge Function receives Stripe events and updates the player's plan at once.
- B. Stripe + a GitHub Action polling every 15 minutes. Rejected: a player who just paid waits up to 15 minutes for Pro, which feels broken.
- C. Lemon Squeezy or Paddle (merchant of record, handles VAT worldwide). Not now; same structure as A, so a later switch is contained.

Flow:
1. The organiser creates two products in Stripe (Pro, Ultimate), each with a monthly and a yearly price, and a **Payment Link** for each of the four prices, in test mode.
2. The four links are pasted into admin (plan cards already have a `checkout_url` per plan). The site appends `?client_reference_id=<player id>&prefilled_email=<email>` so Stripe knows who paid. A signed-out player is asked to sign in first.
3. A Supabase **Edge Function** `stripe-webhook` verifies Stripe's signature and handles:
   - `checkout.session.completed`: links the Stripe customer and subscription to the player (from `client_reference_id`).
   - `customer.subscription.created/updated/deleted`: sets the player's plan from the subscription's price and status, and its period end.
4. Plan state lives in a new private table `subscriptions` (one row per player: `stripe_customer_id`, `stripe_subscription_id`, `tier` free/pro/ultimate, `status`, `current_period_end`). Only the Edge Function (service role) writes it. Players can read their own row.
5. One database function `user_tier(uid)` returns `free`, `pro` or `ultimate`: the tier if `status` is active, trialing or past_due and `current_period_end` is in the future, plus a 3-day grace. Every limit (watchlist cap, alerts, league creation, archive, recap) uses it. The old `profiles.is_pro / is_ultimate / pro_expires_at` columns are kept in sync for anything still reading them, then retired.
6. **Manage subscription**: a link to Stripe's customer portal (no-code login link from the Stripe dashboard, stored in admin) for cancelling or changing card.
7. **Payments mode** setting in admin: `off` (cards say "Coming soon", no buy buttons), `test` (buy buttons plus a note "Test mode: pay with card 4242 4242 4242 4242, any future date, any CVC"), `live`. Starts in `test`. While the site isn't public, test mode only lets people "buy" with fake cards, so nothing can be charged.
8. Price IDs → tiers are configured in the Edge Function's secrets (`STRIPE_PRICE_PRO_MONTHLY` etc.), along with `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET`. Nothing secret is in the repo or the page.

Going live later: in Stripe switch to live, recreate the four links and the webhook, replace the Edge Function secrets and the links in admin, set mode to `live`.

Setup instructions for the organiser (Stripe products and links, webhook, deploying the function from the Supabase dashboard, setting secrets) ship as a step-by-step section in the pull request and README, written for someone who hasn't done it before.

## Features

**Watchlist caps** (2/5/15): the existing database trigger switches to `user_tier`; the page reads the same numbers.

**Badges:** `get_leaderboard` and league leaderboards return each player's tier; a small PRO / ULTIMATE badge shows next to the name. Whether someone pays is visible to others, which is the point of a badge.

**Private leagues:** tables `leagues` (id, name, invite code of 6 letters, owner, colour, emblem) and `league_members`. Functions: `create_league` (Pro+, max 3 owned per player (builder's call)), `join_league(code)`, `leave_league`, `league_leaderboard(id)` (members' portfolio value, the same calculation as the main leaderboard). A player can be in up to 10 leagues (builder's call). UI: a "Leagues" tab next to the main leaderboard.

**Portfolio history:** a nightly snapshot of every player's portfolio value (cash + holdings at that night's prices) into `portfolio_snapshots`, written by a database function called from the existing nightly backup workflow (builder's call: reuse, rather than a new schedule). Snapshots start in part 1 so history builds up before part 3 ships. Best/worst trades are computed from `trades` (realised gain per sell against average buy cost). Players read only their own snapshots.

**Season Wrapped (free):** a card "Your season so far": final or current rank, value change, best and worst trade, most-traded club, Kickabout wins and best streak. "Save image" draws it to a canvas and downloads a PNG to share. Available any time; the organiser's season reset is the natural moment to promote it.

**Kickabout archive (Ultimate):** past days' puzzles are already stored in `daily_puzzles`. Archive plays are stored separately from daily plays (`game_plays` gains an `archive` flag, or a sibling table (builder's call)), pay no coins, and never count toward Wrapped streaks. A date picker lists past days.

**Weekly AI recap (Ultimate):** every Monday a GitHub Action writes a short recap per Ultimate player (their trades, value change, how their clubs did) using the same AI provider and key as the price updater, stored in `weekly_recaps`; shown in the portfolio section. Cost is small at this scale; capped at 500 players per run.

**Compare charts (Ultimate):** pick up to 4 clubs, overlay their price history (indexed to 100 at the start so different prices compare), using price history the page already loads.

**League branding (Ultimate):** league owners on Ultimate pick a colour and one of a set of emblems (football icons, no crests).

## Build order (one pull request each)

1. Payments and tiers: `subscriptions`, `user_tier`, Edge Function, admin settings (links, portal link, payments mode), plan cards rewritten to the table above, new caps, badges, Pro skins, nightly snapshots start, setup guide.
2. Private leagues (with Ultimate branding).
3. Portfolio history and Season Wrapped.
4. Kickabout archive, weekly AI recap, compare charts.

## Constraints

- Static site on GitHub Pages; Supabase backend; GitHub Actions for schedules. The Edge Function is the only new server piece.
- Secrets live only in Supabase function secrets and GitHub secrets.
- Every SQL change ships as a new `supabase-*.sql` file (safe to run twice) and is folded into `supabase-schema.sql`.
- Phones: every new screen follows the one-column phone layout.

## Left to the builder

Exact visual design of the new themes, badges, leagues tab and Wrapped card; table and function names; how the archive date picker looks; recap wording and prompt.
