# Private leagues (Classic and H2H): design

_27 Nov 2026. Agreed with the organiser in conversation; calls the builder made are marked "(builder's call)". Part 2 of Pro and Ultimate (see `2026-11-26-pro-ultimate-design.md`). League chat is part 2c and is designed separately._

## Decided after review

- **Missing weekly save:** if a week's Sunday snapshot (or the previous Sunday's) doesn't exist because the nightly job didn't run, that week is **void** in every league: no week scores, no H2H points, no Player of the week; the page says "No result this week (the weekly save didn't run)." The job never guesses values. A void week still counts as played in the fixture order (its pairings are used up).
- **Membership is stored per stint** (joined_at, left_at). **Rejoining in the same season restores the old record**: H2H points and results, and the Classic join value, so leaving and rejoining can't wipe a bad run. Former members don't appear in the table; their past results stay in their opponents' records.
- **Season reset:** leagues and members carry over. Everything scored is tied to a season; a new season starts every table fresh (0 points, Classic join value = season-start value). The reset script cancels any week in progress (its pairings are deleted, it's never scored). Old seasons stay stored; the page shows the current season (builder's call).
- **Fixtures when the rules can't all be met:** each week's pairings minimise, in order: (1) pairs who have already played this cycle; (2) giving a past-self match to someone who had it last week, or more often than others this cycle. Pairs never played this cycle — including with newcomers — are preferred. When every current pair has played, a new cycle starts. Choices among equally good options are random.
- **Who counts in a week:** members at the start of the matchweek (when the Monday job runs). They're the ones paired and eligible for Player of the week. Someone who joins midweek starts the next Monday; someone who leaves or is kicked midweek doesn't count for that week (their opponent plays their own past week).

## Why

PitchMarket is played by groups of friends. Private leagues give each group its own competition, which is the main reason a group's organiser would pay for Pro. Head-to-head adds a weekly rivalry so there's something to play for every week, not only the season table.

## Goals

- Pro and Ultimate players can create a league; anyone, free players included, can join with an invite code.
- Two league types, chosen when the league is created: **Classic** and **H2H**.
- A **Player of the week** in every league.
- Owners can kick anyone at any time. Ultimate owners can brand their league.
- Weekly results are worked out once, stored, and never change afterwards.

## Non-goals

- League chat (part 2c).
- Any effect on the main leaderboard, coins or trading. Leagues only rank what players already do.
- Prizes inside leagues.

## Anti-goals

- **Anyone seeing their next opponent before the matchweek starts**, by any route (page, network requests, predictable pattern).
- A player losing points they already earned because someone joined, left or was kicked.
- A late joiner being punished for weeks they weren't in the league.
- Paid tiers giving an edge in a league (creating and branding are the only paid parts).

## Definitions

- **Value:** a player's coins plus their holdings at current prices (the same as the main leaderboard).
- **Matchweek:** Monday 00:00 to Sunday 23:59, UK time.
- **Week score:** how much a player's value grew over the matchweek, as a percentage: `(value at the end of Sunday / value at the end of the previous Sunday − 1) × 100`, rounded to 2 decimals. Values come from the nightly portfolio snapshots (part 1), each stamped with the London date of the day that just ended. A player with no snapshot for the previous Sunday (new to the site that week) has no week score and isn't paired that week. A start value of 0 counts as a week score of 0.
- **Season:** from the season start recorded by the Christmas reset (`season_start()`, part 1). Before a season start exists, no weeks are scored: league pages show "Scoring starts when the new season starts." The first matchweek is the first full Monday–Sunday week after the season start.

## League types

**Classic:** a table ranked by percentage gained since the player joined the league: `(current value / value when they joined − 1) × 100`. The join value is the player's live value at the moment they join, or the season-start value (2,000) for anyone who joined before the season started (builder's call: the reset sets everyone to 2,000, so this is exact). A new season resets every member's join value to the season-start value. Ties share a rank.

**H2H:** each matchweek every member is paired with one other member. The higher week score wins: **3 points**; tie: **1 point each**; loss: **0**. The table shows played, won, drawn, lost, points, and total week-score percentage as the tie-break (builder's call), then name.
- **Fixtures:** everyone plays everyone once before anyone plays anyone twice; then the cycle repeats through the season. The season's points reset at a new season.
- **Odd number of members:** one member plays **their own previous week**: they win if this week's score is higher than their own score last week, draw if equal, lose if lower. With no previous week score, they play 0%. Who gets this "past self" match is spread fairly: the member who has had it fewest times this cycle, and never the same member two weeks running if avoidable (builder's call).
- **Hidden opponents:** pairings for a week are created only when that week starts (by the Monday job), chosen with randomness among the valid options, and stored where players can read only the current and past weeks. Nothing before then can reveal them.
- **Joining mid-season:** a new member joins the next matchweek on 0 points. The fixtures adapt so everyone still plays everyone before repeats (pairings are chosen each week from the pairs not yet played this cycle).
- **Leaving or kicked:** they're not paired in future weeks. If they were already paired in the current week, their opponent plays their own past week instead (same rules as the odd-number match). All results already recorded stay, for everyone.

## Player of the week

Every league, both types: the member with the highest week score that week. Ties share it. Shown on the league page for the latest finished week, with a short history (builder's call: last 5 weeks).

## Ownership, membership and limits

- Creating a league needs Pro or Ultimate (`user_tier`). Limits: a player can own **3** leagues and be in **10** (builder's call); a league holds up to **20** members (builder's call: keeps H2H fixtures fast and pages readable).
- Joining: by a **6-character invite code** (letters and digits without look-alikes such as 0/O, 1/I) that the owner can copy or regenerate (builder's call).
- **The owner can kick any member at any time.** A kicked player can rejoin only if the owner shares a new code (builder's call: kicking regenerates the code).
- Members can leave. If the owner leaves, ownership passes to the longest-standing member; the owner can also delete the league (builder's call).
- If the owner's plan lapses, the league keeps working; only branding stops showing.
- **Branding (Ultimate owners):** one of 8 colours and one of 12 football emblems (icons such as a ball, boot, whistle, trophy, net, cones; no club crests). Shown on the league page and in the league list while the owner is on Ultimate.

## How results are worked out (approach A, chosen)

Approaches considered:
- **A. Weekly job stores results (chosen).** Each Monday the existing nightly job saves the Sunday snapshot, scores the finished week (week scores, H2H points, Player of the week) and creates the new week's pairings. Opponents stay truly hidden; history never changes; pages load fast.
- B. Pages work it out live. Rejected: next week's pairings would follow a predictable pattern that a determined player could work out, and every page load recomputes.

Details:
- The nightly backup workflow (03:23 UTC) already calls `take_portfolio_snapshots()`. After it, the same run calls the league week function. It does nothing unless a matchweek has ended and isn't closed yet, so it's safe to run every night and to re-run (idempotent). If a night is missed, the next run catches up, closing each missing week in order.
- Pairings for the new week appear when that job runs (around 03:30 UK time on Monday). Before then, the page shows "This week's matchups appear on Monday morning."
- All league logic that decides points, pairings and Player of the week lives in the database (or one tested script), never in the page.

## Privacy and security

- Only members can see a league, its members, standings and matchups. League functions check membership; tables have RLS with no direct writes from players.
- The page never receives future pairings, other leagues' data, or other players' email addresses.
- Owner actions (kick, regenerate code, rename, branding, delete) check ownership in the database.

## The page

- A **Leagues** tab next to the main leaderboard: my leagues (with branding), **Create league** (name, Classic or H2H; locked with "Create leagues with Pro or Ultimate" for free players), **Join with a code**.
- A league view: standings (Classic or H2H table), this week's matchups (H2H), Player of the week, members (with Kick for the owner), invite code with Copy, owner settings (rename, regenerate code, branding for Ultimate, delete). Badges (PRO/ULTIMATE) next to names, as on the main leaderboard.
- Works on phones in the one-column layout.

## Build order (one pull request each)

- **2a. Leagues:** tables, create/join/leave/kick/delete, invite codes, limits, Classic table, Player of the week, branding, the weekly job (week scores and Player of the week), the Leagues tab. Plan cards: "Private leagues" and "League branding" lose their "Coming soon" tags.
- **2b. H2H:** pairing, past-self matches, points table, joins/kicks mid-season, the H2H views.
- **2c. Chat:** designed separately.

## Constraints

- Static site + Supabase + GitHub Actions; every SQL change in a new `supabase-leagues-*.sql` file, safe to run twice, also folded into `supabase-schema.sql`.
- Tests in the repo's test harness (SQL, Node, browser), like part 1.
- Escape all player text (league names, display names).

## Left to the builder

Table and function names; exact pairing algorithm (as long as it meets the fixture rules and is randomised); the look of the Leagues tab, tables and emblems; wording of empty states.
