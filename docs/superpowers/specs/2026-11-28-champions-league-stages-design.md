# Champions League stages: design

_28 Nov 2026. Agreed with the organiser in conversation; calls the builder made are marked "(builder's call)". Needed before the emails' "last chance" part (see `2026-11-28-emails-design.md`), and live before this season's league phase ends (late January 2027)._

## Why

A club's Champions League run already trades as its own instrument ("Arsenal (UCL)"), but today it moves like any league club: the AI prices each match and that's it. The organiser wants it to feel like a high-stakes bet: get knocked out and your shares are worth nothing; keep going and the payouts grow each round. That gives every knockout night real tension for anyone holding a club.

## The rule

**Going out → 0.** A club that finishes **25th–36th** in the league phase, or loses a **play-off**, a **knockout tie** or **the final**, has its price set to **0** and trading on it closes. Holders keep the shares, worth 0.

**Going through → the AI's move is boosted.** The multiplier applies to **the AI's suggested price move for the match that sends the club through**, not to the club's whole price. Example: Arsenal win their quarter-final second leg, the AI suggests +10%, reaching the semis is ×2, so the move is +20%.

| Stage reached | Applied to the AI's move for | Boost |
|---|---|---|
| Last 16, by finishing 1st–8th | their last league-phase match | ×1.2 |
| Last 16, by winning the play-off | the play-off second leg | ×1.2 |
| Quarter-finals | the last-16 second leg | ×1.5 |
| Semi-finals | the quarter-final second leg | ×2 |
| Final | the semi-final second leg | ×2.5 |
| Winners | the final | ×3 |

- Clubs finishing **9th–24th** get no boost when the league phase ends; they go into the play-off.
- **The boost only applies to rises** (builder's call, agreed). If a club goes through but the AI suggests a fall for that match (e.g. lost the second leg, won on aggregate), the fall stays as suggested, unboosted.
- **Winners cash out.** Once the final's result is applied, every holder of the winning club gets its shares turned into coins at the new price, the holdings are removed, and they get a notification. The runner-up goes to 0 (lost the final). The Champions League is then closed until next season.
- The AI's own pricing of the match is unchanged; it doesn't need to know about the boost. The boost is applied to its suggested percentage afterwards.

## Goals

- Stage results (out, through, winners) are worked out automatically from the football-data.org feed, by the same price job that prices the match.
- Every stage result waits for the organiser's approval in admin, and applies itself if not handled within **12 hours**, so nothing sits waiting.
- Closed clubs can't be bought or sold, and the site says why.
- The organiser can reopen closed clubs for next season with a starting price.

## Non-goals

- Changing how the AI prices matches, or the Europa League or other cups.
- Emails about any of this (that's the emails project).
- Refunds or partial payouts for clubs that go out.

## Anti-goals

- **Trading in the gap.** Nobody may trade a club between the moment its stage result is known and the moment it's applied. Trading already locks at kickoff until the match's price move is approved or rejected (`team_lock_reason`); the stage result must be part of that same decision, so the club never unlocks first.
- **A wrong 0.** A feed mistake (aggregate scores, extra time, penalties, a missing leg) must not wipe players' coins with nobody looking. Hence admin approval and Reject; if the job can't tell for sure, it doesn't propose a stage result (the match is priced as a normal match and admin sees why).
- **A stage result applied twice** (on a re-run, or by both admin and the 12-hour fallback).
- **Stage results leaking into the main leaderboard unfairly:** holdings at 0 simply count as 0, like any price.

## Constraints

- Static site + Supabase + GitHub Actions, as now. SQL in a new `supabase-ucl-stages.sql`, safe to run twice, folded into `supabase-schema.sql`. Tests in the repo's SQL, Node and browser harnesses.
- The price job runs every 6 hours (`update-prices.js`), so the 12-hour fallback is checked by those runs (an event approved within 12–18 hours in practice).
- Today's flow: the job writes each priced match to `match_events` (pending); moves up to 8% auto-apply; bigger ones wait for `approve_match_event` in admin. A lock lasts at most 72 hours.

## Approach (decided)

The stage result is worked out by the price job at the moment it prices the match, and stored on the same `match_events` row, so one approval applies both the boosted move (or the 0) and the stage. This is the only sensible way: a separate job would leave a window where the stage is known but not applied, and doing it all by hand would make the organiser check every result. Considered and rejected:
- A separate stage job after pricing: leaves a gap where players could trade on news the price doesn't show.
- Admin sets stages by hand: no automation, easy to forget.

## How it works

- **Stage of each match** comes from the feed (`stage` on each match: league stage, play-offs, last 16, quarters, semis, final). **Who went through** in a two-legged tie is decided from both legs, including extra time and penalties (builder's call on the exact feed fields; if the outcome can't be determined for certain, no stage result is proposed and the run log says why).
- **League phase end:** the 1st–8th boost and the 25th–36th drop to 0 are proposed only once **every** match of the final league-phase matchday is finished and the table is final. Until then, those final-matchday events stay unapplied, so those clubs stay locked (builder's call on how: e.g. hold the event back until the table is complete).
- **A stage event** records the club, the stage reached (or "out", or "winners"), the AI's suggested move, the multiplier and the resulting move, so admin can show: "Arsenal through to the semis: AI +10% ×2 = +20%" or "Dortmund out: price to 0".
- **Approval:** stage events are never auto-applied by the 8% rule. Admin shows them clearly marked with Approve and Reject. **Reject** means the match is applied as a normal match (the AI's move, unboosted, no 0, no closing) (builder's call); the organiser can then fix things by hand. Not handled after 12 hours → applied as proposed by the next price run.
- **Closing:** a club at 0 is marked closed. `trade()` refuses buys and sells on it with a clear message; the site shows it as "Out of the Champions League" instead of Buy/Sell; the AI never prices a closed club again.
- **Winners:** applying the final converts holders' shares into coins at the new price (one transaction), removes those holdings, sends each holder a notification (the bell), and closes every Champions League club.
- **Reopening:** an admin action reopens a Champions League club with a starting price the organiser types (for next season's competition). Reopening first removes any holdings still left in that club (worth 0), so old shares can't jump to the new price (builder's call). The Christmas reset doesn't touch prices or closed state (builder's call: it only resets player data today).
- **Fixing by hand** (builder's call): admin gets two buttons on any open Champions League club, for when the organiser rejects a stage event or the job couldn't tell: **Knock out** (price to 0, close) and **Crown winners** (cash out holders at the current price, close every Champions League club). A boost by hand is just a price edit, which admin already has.
- **Clubs on the site that aren't in this season's competition** (builder's call): the run log and admin list them. Admin's **Close and refund** button closes such a club and cashes out holders at its current price (they never had a chance to go through). Entrants missing from the site are handled for the listed side only, as today.
- **The 12-hour fallback** runs whether or not `AUTO_APPLY` is on (builder's call): the organiser agreed stage results apply themselves after 12 hours.
- **What later projects can read** (builder's call, for the emails' "last chance"): each Champions League club's current stage (league phase, play-off, last 16, quarters, semis, final, out, winners) is stored, and `fixtures` also stores each upcoming match's stage and leg, so a later project can tell which fixture can knock a club out without guessing.

## The page

- Closed clubs: price shows 0.00, a small "Out" or "Winners 🏆" label, and the trade buttons replaced by a note. Their chart stays.
- Holdings at 0 still show in the portfolio, so players see what happened.
- Admin: stage events shown with the calculation and Approve and Reject; a Reopen button on closed Champions League clubs.

## Left to the builder

Table and column names; how stage and aggregate outcomes are read from the feed; how the final matchday waits for a complete table; notification wording; exact labels and styling; whether the "winners" stage and the cash-out are one event or two.
