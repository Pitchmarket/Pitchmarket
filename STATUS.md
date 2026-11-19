# PitchMarket status

_Last updated: 19 Nov 2026_

Where the project stands before public launch. Update this file in the same pull request as the work it describes. Keep it under 10 KB: when something is done, delete it here instead of marking it done.

## Next up

Launch blockers, roughly in the order to tackle them.

### Running the competition

- **Reset the world before Christmas** (hard deadline). Run `supabase-season-reset.sql`: it clears `holdings` and `trades` and sets every balance to 2,000. Prices and price history stay, so the charts keep their data.
- **Run `supabase-price-lag-lock.sql`** in the Supabase SQL Editor. Until it runs, players can still trade on a club after kickoff, before its result is priced. The site and price updater already handle the lock and keep working either way.
- **Publish the rules before entry opens:** exact start and end timestamps with timezone, eligibility, and how the winner is decided.
- **Write the tie-break rule** for equal final balances. There's a cash pot, so this must be settled up front.
- **State the multi-account rule.** Nothing stops one person running several accounts and keeping the best. CAPTCHA doesn't solve this.
- **Decide whether the organiser plays** (see open decisions).

### Platform

1. **Fix team-name matching.** Run the workflow by hand with `lookback_days: 14` and clear every name in the run summary's "unmatched" list.
2. **Add password reset.** `index.html` has no "forgot password" flow.
3. **Decide on Pro for launch** (see open decisions). If it ships, build the Stripe webhook that sets Pro status.
4. **Legal pages.** Terms of service and a privacy policy, and a check of gambling and contest rules.
5. **At public launch, set the Site URL** (and redirect URLs) in Supabase Auth to the live address, so sign-up and password emails link to the site. The site is already hosted with HTTPS on GitHub Pages; a custom domain is optional.

## Planned work

Not blocking launch, but wanted soon after.

- **Trade rate limit.** A few seconds' cooldown between trades, enforced in the `trade` function, so a script can't fire hundreds of trades around a price update.
- **Data-outage policy.** What happens to the standings if the price pipeline is down for a week. The trading lock lifts after 72 hours even if a result was never priced, so a long outage reopens the price-lag exploit.
- **Staging backend.** A second Supabase project for testing, with a simple way to switch both HTML files to it. Today every local test changes production data.
- **Spotlight chart.** The table, index cards and hero chart now draw real price history. The cup spotlight chart still uses prices typed into admin; link it to a real club or remove it.
- **Pro lifecycle.** Handle cancellations, failed payments and expiry through Stripe webhooks.
- **Auth hardening.** Custom SMTP sender in Supabase, email confirmation, and CAPTCHA on sign-up.
- **Updater alerting.** Make sure failed scheduled runs notify someone who will act on them.
- **Pin `supabase-js`.** Both pages load `@supabase/supabase-js@2` unpinned from jsDelivr (`index.html:402`, `admin.html:249`).
- **Analytics and error tracking.**
- **Branch protection on `main`**, requiring pull requests as the README asks.

## Known issues

| Issue | Where | Impact |
|---|---|---|
| Admin page has no role check; any signed-in user sees an empty dashboard | `admin.html` | Cosmetic: the database refuses every admin read and write from other accounts (checked against `supabase-schema.sql`) |
| Admin-edited site content and checkout links are inserted as raw HTML | `index.html:963`, `index.html:1012` | A compromised admin account could run script on every visitor's page |
| Both HTML files point at production Supabase | `index.html:398`, `admin.html:244` | Local testing changes live data |
| No password reset | `index.html` | Players who forget a password are locked out |
| Stripe checkout links are placeholders, so Pro plans show no buy button | `index.html:917` | Pro can't be bought |
| Nothing sets `is_pro` / `pro_expires_at` after payment | (missing) | Paying users wouldn't get Pro |
| Volume column in the club table is made up | `index.html` (`renderTable`) | Looks like real trading volume but isn't |
| Admin "Market indices" editor no longer changes the index cards once team data loads; they're built from each league's real prices | `admin.html` | Editing it has no visible effect |
| Default Claude model in the updater is out of date | `update-prices.js:870` | Only matters if `AI_PROVIDER=claude` |
| football-data.org free tier: 10 requests/min; Gemini free tier: daily cap | `update-prices.js` | A busy matchday can defer matches to the next run |

## Open decisions

- **Launch with Pro, or hide it?** Shipping Pro needs Stripe links, a webhook, cancellation handling and server-side limits. Hiding it means removing or toggling the Pro band in admin.
- **Is the organiser playing or running it?** Admin can change prices by hand, so competing as well is a conflict of interest. Pick one.
- **Tie-break and multi-account rules** (see Next up). Both need a written answer before entry opens.
- **Cash pot legality.** The competition has a cash prize, so contest and sweepstakes law applies and needs checking per country. Fan Coins must stay unbuyable and uncashable.
- **Auto-apply limit.** Currently moves up to 8% apply without review (`AUTO_APPLY_MAX_PCT`). Keep it, lower it for launch, or turn auto-apply off for the first weeks?
- **AI provider.** Stay on Gemini's free tier, or move to Claude (paid) for better pricing judgment and fewer quota failures?
- **Paid data and AI tiers.** Whether to pay for football-data.org and the AI provider to avoid rate limits on busy matchdays. Also confirm football-data.org's terms allow use on a site that takes payments.
- **Season reset.** When and how the leaderboard and coin balances reset between seasons.
- **Hosting.** Where to host the static pages (any static host works; there's no build step).
- **Branding.** Use club names only, or seek permission for crests? The default should be names only.
