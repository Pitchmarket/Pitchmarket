# Emails: design

_28 Nov 2026. Agreed with the organiser in conversation; calls the builder made are marked "(builder's call)". Achievements (an achievements tab with coin rewards) were raised in the same conversation and are a separate project, designed next._

## Why

PitchMarket is played by groups of friends who drift away between visits. Today the site sends no emails at all: password resets never arrive, and price alerts only show in the on-site bell. The organiser wants emails that bring players back by talking about **their own** game: their clubs, their leagues, the matches coming up. These should read like a mate who follows football and your portfolio, not a generic newsletter, so an AI writes each one from what is actually happening to that player. Paid plans get extras in the same emails, so Pro and Ultimate feel worth paying for.

## Goals

- Password-reset emails arrive.
- Two personal emails a week for every player who opts in:
  - **Monday recap** (around 07:00 UK time): how they did, written after the league weeks close (~03:30 UK).
  - **Thursday preview** (around 18:00 UK time): "how will you prepare for this weekend?"
- Each email is built from the player's **moments** (see below), with the words written by an AI and every number taken from the database.
- **Plan extras** inside the same emails: win chances for Pro and Ultimate, "the AI's take" for Ultimate.
- **Price alerts by email** (Pro and Ultimate, who already have alerts) and a **Champions League "last chance" email** for anyone holding a club that could go to 0.
- The system **learns** which kinds of moment each player engages with and puts those first.
- Players control which emails they get, and can unsubscribe in one click from any email.
- **Win chances on the site** for Pro and Ultimate, next to fixtures, and listed on the Pro and Ultimate cards in Go Pro.

## Non-goals

- Achievements (separate project; the recap will mention them once they exist).
- A separate newsletter. The Monday recap *is* the weekly newsletter; site news goes in a short section at the bottom.
- Emails at any other time, except price alerts and "last chance".
- Bookmaker odds, betting links, or anything that looks like a betting tip.
- Instant (within a minute) alerts: within the hour is fine.

## Anti-goals

- **An email that arrives after the player can still act.** A player who gets a "last chance" or preview email and finds the club already locked for kickoff has been let down. Trading on a club locks at kickoff (`team_lock_reason`, using `fixtures.kickoff`).
- **A made-up number.** The AI never produces prices, percentages, positions or odds; it only writes words around numbers it is given. If its text contains a figure that wasn't supplied, the email falls back to the plain template.
- **Spammy volume.** Too many emails make players unsubscribe or mark them as spam, which also hurts password resets on the same domain.
- **Emailing anyone who hasn't agreed** to the recap and preview (UK rules for marketing email).
- **Paying for an edge.** Plan extras are information only; nothing changes trading, coins or leaderboards.
- **Leaking one player's data to another**, beyond what leagues already show to their members.

## Constraints

- Static site + Supabase + GitHub Actions, as now. Every SQL change in a new `supabase-emails-*.sql` file, safe to run twice, also folded into `supabase-schema.sql`. Tests in the repo's SQL, Node and browser harnesses.
- Sending through **Resend** from an `@pitchmarketgame.com` address (DNS records added in Namecheap). Free plan: 3,000 a month, **100 a day**. Password resets go through the same account (Supabase's SMTP), so every scheduled run keeps **20 sends a day in reserve** for resets (builder's call). A daily send count is kept in the database. When a run would pass the limit, it sends in priority order (alerts and last-chance first, then recaps by most recent visit) and logs what was skipped; skipped recaps are dropped, not carried over, because they go stale (builder's call). Admin shows a warning when a run skipped anyone, and when opted-in players pass about 80, so the organiser knows it's time to upgrade Resend (added to the "when to upgrade" list). The limits are settings, so upgrading only means changing numbers.
- The AI is the existing Gemini setup used by `update-prices.js` (same key and model settings, Claude as the alternative provider).
- Secrets only in GitHub Actions secrets and Supabase function secrets, never in the repo or HTML.
- Escape all player text (display names, league names) in emails.

## Approaches (decided)

- **A. GitHub Actions scripts, like prices and backups (chosen).** Scheduled Node scripts ask the database for each player's moments, have the AI write the words, and send through Resend. An hourly run sends price alerts and last-chance emails. A small Supabase Edge Function handles one-click unsubscribe and click tracking. Chosen because it matches how the site already works, reuses the AI setup, and is testable like the other scripts; alerts arriving within the hour is acceptable.
- B. Everything inside Supabase (database jobs plus Edge Functions). Faster alerts, but splits the logic across two systems and long AI jobs hit function time limits.
- C. A newsletter service (Mailchimp, Brevo campaigns). Built for one email to everyone; here every email differs, and it would copy all player data to another company. Ruled out.

## Password resets

No code: the organiser sets Resend as Supabase's custom SMTP (Auth → SMTP settings) and adds `https://pitchmarketgame.com` to the allowed redirect URLs, with step-by-step instructions in a new `docs/email-setup.md` (the same doc covers the Resend account, DNS records and secrets). The builder checks the existing reset flow in `index.html` (`resetPasswordForEmail` with `redirectTo` = current page) still works on the custom domain.

## Moments

A **moment** is one real thing happening to a player, worked out from the database. Each has a kind, a priority, and the facts the email shows. Initial kinds:

| Kind | Example | Used in |
|---|---|---|
| Big mover | "Chelsea up 14% since Monday" (a holding moved by a large amount) | recap, preview |
| Best / worst club | best and worst performing holding over the week | recap |
| League finish | "2nd of 6 in Sunday League Legends" | recap |
| Rival line | "0.4% behind Jake" (the member just above, or just below, in a league) | recap, preview |
| Player of the week | they won it, or who did | recap |
| Champions League danger | a held club is one game from the knockouts, or could go out | recap (week ahead), last chance |
| Shaky position | high in a league but holdings falling for several days: "keep or sell?" | preview |
| Weekend fixtures | which held clubs play this weekend, opponent, and when trading locks | preview |
| Away for a while (needs a new "last visit" time on each profile, updated when the site loads, at most once an hour) | how their shares did since their last visit | recap, preview |
| Milestone | first time over a round number of value (e.g. 3,000, 5,000, 10,000 coins) | recap |
| Kickabout reminder | "100 coins up for grabs" if they haven't played today | preview |

Thresholds (what counts as "big", "several days", milestone levels) are the builder's call, set as constants that are easy to change.

**Picking and ordering:** each email shows the player's top moments (builder's call: the headline moment plus up to 3–4 more), ordered by priority × how much that player engages with that kind (see Learning). A player with no moments worth sending (no holdings, nothing happening) gets no email that week rather than an empty one.

## What every email contains

- A headline and short intro written by the AI in a light football-banter voice, built around the headline moment.
- The moments, each with its real figures.
- A **preview of their shares**: each holding with value and change.
- **Lock times** for any held club playing before the next email: "Trading on Chelsea locks at kickoff, 8pm Tue."
- A button back to the site.
- Plan extras or a locked teaser line for free players, e.g. "🔒 Pro members see the win chances for all 4 of your games."
- Site news (Monday only, when the organiser has written some; edited in admin).
- Footer: why they're getting it, a one-click unsubscribe link, and a link to email settings. Also the standard `List-Unsubscribe` and one-click headers that Gmail and Yahoo require.

## Plans

| | Free | Pro | Ultimate |
|---|---|---|---|
| Monday recap and Thursday preview | ✓ | ✓ | ✓ |
| Win chances for each held club's fixtures (in emails and on the site) | | ✓ | ✓ |
| Price-alert emails | | ✓ | ✓ |
| The AI's take: most-bought club this week, best win chance of the weekend, one "keep or sell?" call on their own portfolio | | | ✓ |
| Champions League last-chance email | ✓ | ✓ | ✓ |

- **Win chances** are shown as percentages ("Chelsea 58%, draw 24%, Brighton 18%"), never as bookmaker odds, with no betting links or bookmaker names. Many players may be under 18 and UK gambling-ad rules are strict.
- **Source of win chances:** the builder compares free options and picks one that covers the clubs on the site (nine leagues plus the Champions League), recording the choice and why. Candidates: an odds service with a free tier (e.g. The Odds API, converting odds to percentages), or ClubElo ratings converted to win chances. If a fixture has no data, that line is left out, not guessed.
- **"Most-bought club this week"** comes from `trades` across all players (aggregated, no names).
- The AI's "keep or sell?" call is framed as the AI's opinion in a game, never as advice, and uses only the facts supplied.
- Plan is checked with `user_tier` when the email is built.
- **Go Pro cards:** add "Win chances for your clubs' games, on the site and in your emails" to Pro and Ultimate, and "The AI's take in your emails" to Ultimate.

## Timing

- **Monday recap:** around 07:00 UK time (after `close_matchweeks()` in the nightly backup run). If the week didn't close (void week), the recap still goes but without league results (builder's call).
- **Thursday preview:** around 18:00 UK time, after the Champions League midweek games and before Friday night games.
- **Hourly run:** price alerts and last-chance emails.
- **Last chance depends on the Champions League knockout rule**, agreed with the organiser but not built yet: a club knocked out (finishing 25th–36th in the league phase, or losing a knockout tie) goes to 0 and stops trading; surviving later stages multiplies the price (×1.2 last 16, ×1.5 quarters, ×2 semis, ×2.5 final, ×3 winners). That rule is its own design and pull request, built before the email part that adds last-chance emails (builder's call on order). "Danger" means a match that rule says can knock the club out; the email reads that from whatever the rule stores (stage, standings), not from its own guess. Until the rule exists, there are no last-chance emails or Champions League danger moments.
- **Last chance:** sent once per held club per match, aiming for midday UK time the day before kickoff, and **only if kickoff is at least 12 hours away**; if that window has passed, it isn't sent. Uses `fixtures` (synced every 6 hours, 7 days ahead).
- **Price alerts:** sent from the hourly run for new rows in `notifications`, at most once per alert. If the club plays again soon, the email shows when trading locks.
- Times are in UK time, so the cron schedules must cope with the clocks changing (builder's call how).
- **Volume:** at most the two weekly emails, plus alerts and last-chance emails for players who have them on (builder's call: a daily cap on alert + last-chance emails per player, e.g. 3, combining several into one email when they fall in the same run).
- An admin **kill switch** (`site_settings`) stops all non-password emails at once.

## AI writing

- The script sends the AI the player's chosen moments as structured facts (no email address; display name only) and asks for a headline and a few sentences. Players are batched into a few calls per run (builder's call), with the same retry and rate-limit care as `update-prices.js`.
- **Number check:** any figure in the AI's text that isn't in the supplied facts means the AI text is dropped for that player and a plain template is used instead. If the AI is down, every email uses the template; emails still go out.
- Tone: friendly, football banter, no swearing, no pressure tactics, nothing implying real money.

## Learning

- Every link in an email goes through the Edge Function, which records the click (player, email, moment kind) and redirects. Opens are not tracked (unreliable, and a privacy cost).
- Each player has an engagement weight per moment kind, starting equal, nudged up by clicks on that kind and gently down when emails with that kind get no click (builder's call on the formula, kept simple and explainable).
- Weights only change the order of moments, never whether a safety email (last chance, alerts) is sent.

## Consent and settings

- **Existing players:** a one-time banner on the site: "Get your Monday recap and Thursday preview by email?" Yes / No thanks. No answer means no emails.
- **New sign-ups:** an unticked checkbox on the sign-up form for the same thing.
- **Email settings** (in the account area): toggles for Monday recap, Thursday preview, Champions League last chance, price alerts (Pro and Ultimate only). Last chance and price alerts default to on once a player has said yes (they protect the player's own holdings); recap and preview follow their answer.
- **One-click unsubscribe** from any email turns off that type; the settings page can turn everything off.
- Addresses that bounce or are reported as spam (Resend webhook to the Edge Function) stop receiving emails, and admin shows them.
- The organiser's accounts get emails like anyone else (useful for checking), and admin can **send a test email** of each type to themselves.

## Admin

A new **Emails** tab: kill switch, site news text for the next Monday recap, send-test buttons, last run of each type (sent, skipped and why, AI fallbacks, failures), bounced or complained addresses, and click counts per moment kind.

## Privacy

- Email addresses never go to the AI.
- Moments that mention other players (rival line, player of the week) only use what that league's members can already see: display names and league results.
- Unsubscribe and click links carry a signed token, not the player's id in plain form, so links can't be forged to change someone else's settings.
- No player data is written to the repo or the backups branch.

## Left to the builder

Table, function and script names; exact thresholds and priorities; the formula for engagement weights; email HTML design (works on phones, dark mode friendly, matches the site's look); how cron copes with UK clock changes; the win-chances source (within the rules above); how many moments per email; batching for the AI; and whether this ships as one pull request or several (suggested: 1. setup doc, consent, settings, sending, unsubscribe and the two weekly emails with templates; 2. AI writing and learning; 3. win chances, alerts, last chance and plan extras).
