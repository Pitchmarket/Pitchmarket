# PitchMarket status

_Last updated: 27 Nov 2026_

Where the project stands before public launch. Update this file in the same pull request as the work it describes. Keep it under 10 KB: when something is done, delete it here instead of marking it done.

## Next up

Launch blockers, roughly in the order to tackle them.

### Running the competition

- **Switch on the error log.** Run `supabase-error-log.sql` in the Supabase SQL Editor. Errors players hit then show in admin under **Errors**.
- **Run `supabase-names-and-leaderboard.sql`** in the Supabase SQL Editor. It makes display names unique and hides the organiser's accounts (admin and 27hufferdinea) from the leaderboard. Its last line lists the hidden accounts; check they're the right ones.
- **Then run `supabase-pro-1.sql`** in the Supabase SQL Editor. It adds Pro and Ultimate plans, the new watchlist caps and nightly portfolio snapshots, and turns any old hand-given Pro or Ultimate into a grant. Safe to run twice.
- **Then run `supabase-leagues-1.sql`** in the Supabase SQL Editor. It adds private leagues: the Classic table and Player of the week, scored by the nightly backup job. Needs `supabase-pro-1.sql` first. Safe to run twice.
- **Reset the world before Christmas** (hard deadline). Run `supabase-season-reset.sql` after `supabase-pro-1.sql` and `supabase-leagues-1.sql` (it stops with "Run supabase-pro-1.sql first." otherwise): it clears `holdings`, `trades` and portfolio snapshots, sets every balance to 2,000 and records the season start. Prices and price history stay, so the charts keep their data.
- **Set up Stripe test mode** by following [docs/stripe-setup.md](docs/stripe-setup.md), then make a test purchase with card 4242 4242 4242 4242.
- **The organiser runs the competition and doesn't play.** The admin and 27hufferdinea accounts are hidden from the leaderboard. To hide another account, set `hidden_from_leaderboard` to true on its row in `profiles`.

### Platform

1. **Fix team-name matching.** Run the workflow by hand with `lookback_days: 14` and clear every name in the run summary's "unmatched" list.
2. **Going live with payments:** terms, privacy, refund pages, then the go-live checklist at the end of [docs/stripe-setup.md](docs/stripe-setup.md).
3. **Contest rules.** Check gambling and contest law for the cash prize (see open decisions).

## Planned work

Not blocking launch, but wanted soon after.

- **Data-outage policy.** What happens to the standings if the price pipeline is down for a week. The trading lock lifts after 72 hours even if a result was never priced, so a long outage reopens the price-lag exploit.
- **Staging backend.** A second Supabase project for testing, with a simple way to switch both HTML files to it. Today every local test changes production data.
- **Auth hardening.** Custom SMTP sender in Supabase, email confirmation, and CAPTCHA on sign-up.
- **Analytics.** (Error tracking is built in: admin → Errors.)
- **Branch protection on `main`**, requiring pull requests as the README asks.

## Known issues

| Issue | Where | Impact |
|---|---|---|
| Both HTML files point at production Supabase | `index.html:1374`, `admin.html:280` | Local testing changes live data |
| Default Claude model in the updater is out of date | `update-prices.js:680` | Only matters if `AI_PROVIDER=claude` |
| football-data.org free tier: 10 requests/min; Gemini free tier: daily cap | `update-prices.js` | A busy matchday can defer matches to the next run |

## Open decisions

- **Cash pot legality.** The competition has a cash prize, so contest and sweepstakes law applies and needs checking per country. Fan Coins must stay unbuyable and uncashable.
- **Auto-apply limit.** Currently moves up to 8% apply without review (`AUTO_APPLY_MAX_PCT`). Keep it, lower it for launch, or turn auto-apply off for the first weeks?
- **AI provider.** Stay on Gemini's free tier, or move to Claude (paid) for better pricing judgment and fewer quota failures?
- **Paid data and AI tiers.** Whether to pay for football-data.org and the AI provider to avoid rate limits on busy matchdays. Also confirm football-data.org's terms allow use on a site that takes payments.
- **Season reset.** When and how the leaderboard and coin balances reset between seasons.
- **Branding.** Use club names only, or seek permission for crests? The default should be names only.
