# PitchMarket status

_Last updated: 20 Nov 2026_

Where the project stands before public launch. Update this file in the same pull request as the work it describes. Keep it under 10 KB: when something is done, delete it here instead of marking it done.

## Next up

Launch blockers, roughly in the order to tackle them.

### Running the competition

- **Switch on all four Daily Kickabout games.** Run `supabase-daily-kickabout.sql` (if not already) and then `supabase-kickabout-2.sql` in the Supabase SQL Editor, then run the **Import players for Daily Kickabout** workflow from the Actions tab (15–30 minutes). Re-run the import even if it ran before: this version adds the players it used to miss (Saka, Foden, Rice and most other internationals), each player's continent for Scouted, and the club links Link-Up needs. The import then runs every Monday.
- **Reset the world before Christmas** (hard deadline). Run `supabase-season-reset.sql`: it clears `holdings` and `trades` and sets every balance to 2,000. Prices and price history stay, so the charts keep their data.
- **Run `supabase-names-and-leaderboard.sql`** in the Supabase SQL Editor. It makes display names unique and hides the organiser's accounts (admin and 27hufferdinea) from the leaderboard. Its last line lists the hidden accounts; check they're the right ones.
- **The organiser runs the competition and doesn't play.** The admin and 27hufferdinea accounts are hidden from the leaderboard. To hide another account, set `hidden_from_leaderboard` to true on its row in `profiles`.

### Platform

1. **Fix team-name matching.** Run the workflow by hand with `lookback_days: 14` and clear every name in the run summary's "unmatched" list.
2. **Decide on Pro for launch** (see open decisions). If it ships, build the Stripe webhook that sets Pro status.
3. **Legal pages.** Terms of service and a privacy policy, and a check of gambling and contest rules.
4. **At public launch, set the Site URL** (and redirect URLs) in Supabase Auth to the live address, so sign-up and password emails link to the site. The site is already hosted with HTTPS on GitHub Pages; a custom domain is optional.

## Planned work

Not blocking launch, but wanted soon after.

- **Data-outage policy.** What happens to the standings if the price pipeline is down for a week. The trading lock lifts after 72 hours even if a result was never priced, so a long outage reopens the price-lag exploit.
- **Staging backend.** A second Supabase project for testing, with a simple way to switch both HTML files to it. Today every local test changes production data.
- **Pro lifecycle.** Handle cancellations, failed payments and expiry through Stripe webhooks.
- **Auth hardening.** Custom SMTP sender in Supabase, email confirmation, and CAPTCHA on sign-up.
- **Analytics and error tracking.**
- **Branch protection on `main`**, requiring pull requests as the README asks.

## Known issues

| Issue | Where | Impact |
|---|---|---|
| Admin-edited site content and checkout links are inserted as raw HTML | `index.html:963`, `index.html:1012` | A compromised admin account could run script on every visitor's page |
| Both HTML files point at production Supabase | `index.html:398`, `admin.html:244` | Local testing changes live data |
| Stripe checkout links are placeholders, so Pro plans show no buy button | `index.html:917` | Pro can't be bought |
| Nothing sets `is_pro` / `pro_expires_at` after payment | (missing) | Paying users wouldn't get Pro |
| Default Claude model in the updater is out of date | `update-prices.js:870` | Only matters if `AI_PROVIDER=claude` |
| football-data.org free tier: 10 requests/min; Gemini free tier: daily cap | `update-prices.js` | A busy matchday can defer matches to the next run |

## Open decisions

- **Launch with Pro, or hide it?** Shipping Pro needs Stripe links, a webhook, cancellation handling and server-side limits. Hiding it means removing or toggling the Pro band in admin.
- **Cash pot legality.** The competition has a cash prize, so contest and sweepstakes law applies and needs checking per country. Fan Coins must stay unbuyable and uncashable.
- **Auto-apply limit.** Currently moves up to 8% apply without review (`AUTO_APPLY_MAX_PCT`). Keep it, lower it for launch, or turn auto-apply off for the first weeks?
- **AI provider.** Stay on Gemini's free tier, or move to Claude (paid) for better pricing judgment and fewer quota failures?
- **Paid data and AI tiers.** Whether to pay for football-data.org and the AI provider to avoid rate limits on busy matchdays. Also confirm football-data.org's terms allow use on a site that takes payments.
- **Season reset.** When and how the leaderboard and coin balances reset between seasons.
- **Hosting.** Where to host the static pages (any static host works; there's no build step).
- **Branding.** Use club names only, or seek permission for crests? The default should be names only.
