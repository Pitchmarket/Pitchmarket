# PitchMarket status

_Last updated: 18 Nov 2026_

Where the project stands before public launch. Update this file in the same pull request as the work it describes. Keep it under 10 KB: when something is done, delete it here instead of marking it done.

## Next up

Launch blockers, roughly in the order to tackle them.

### Running the competition

- **Reset the world before Christmas** (hard deadline). Clear `holdings`, `trades` and `price_history`; set every balance to 2,000.
- **Close the price-lag exploit.** Lock a team from kickoff until its price update applies, or players can trade on results the price doesn't reflect yet.
- **Publish the rules before entry opens:** exact start and end timestamps with timezone, eligibility, and how the winner is decided.
- **Write the tie-break rule** for equal final balances. There's a cash pot, so this must be settled up front.
- **State the multi-account rule.** Nothing stops one person running several accounts and keeping the best. CAPTCHA doesn't solve this.
- **Verify the leaderboard maths** by hand for two accounts: total = coins + holdings at current price.
- **Decide whether the organiser plays** (see open decisions).

### Platform

1. **Run `supabase-security-fixes.sql`** in the Supabase SQL Editor. Until it runs, the live database lets a player sell the same shares twice by sending two sells at once (tested: 2,000 coins became 3,000), lets anyone apply pending match results early, allows HTML in display names, and shows the start of each player's email address on the leaderboard.
2. **Fix team-name matching.** Run the workflow by hand with `lookback_days: 14` and clear every name in the run summary's "unmatched" list.
3. **Add password reset.** `index.html` has no "forgot password" flow.
4. **Decide on Pro for launch** (see open decisions). If it ships, build the Stripe webhook that sets Pro status.
5. **Legal pages.** Terms of service and a privacy policy, and a check of gambling and contest rules.
6. **Hosting and domain** with HTTPS, then set the Site URL and redirect URLs in Supabase Auth.

## Planned work

Not blocking launch, but wanted soon after.

- **Retro theme.** The theme picker is live with twelve looks; Retro is the one still to build, once there's a reference image.
- **Trade rate limit.** A few seconds' cooldown between trades, enforced in the `trade` function, so a script can't fire hundreds of trades around a price update.
- **Data-outage policy.** What happens to the standings if the price pipeline is down for a week.
- **Staging backend.** A second Supabase project for testing, with a simple way to switch both HTML files to it. Today every local test changes production data.
- **Real price charts.** Replace the generated hero chart and table sparklines (`genSeries`, `index.html:731`) with data from `price_history`. Update or remove the hardcoded cup spotlight chart.
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
| Hero chart and sparklines are generated, not real history | `index.html:731` | Charts don't reflect real price moves |
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
