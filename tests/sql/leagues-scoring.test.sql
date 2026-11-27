-- Private leagues scoring (supabase-leagues-1.sql): closing matchweeks from
-- the nightly snapshots, void weeks, the Classic table and Player of the
-- week, including who counts in a week. Runs in one transaction and rolls
-- back, so it leaves nothing behind.
begin;

-- Players 1..13: 1 Alice, 2 Bob, 3 Cat, 4 Dan, 5 Eve, 6 Fay, 7 Gus (not in
-- any league), 8 Hal (never scores), and 9..13 Ivy, Jo, Kit, Lou, Mo for
-- the clock-change weeks.
insert into auth.users (id, email)
select (lpad(n::text, 6, '0') || 'dd-0000-0000-0000-00000000000d')::uuid, 's' || n || '@example.com'
from generate_series(1, 13) n;
create function pg_temp.u(n int) returns uuid language sql immutable as
$$ select (lpad(n::text, 6, '0') || 'dd-0000-0000-0000-00000000000d')::uuid $$;
update public.profiles p set display_name = v.name
from (values (1, 'Alice'), (2, 'Bob'), (3, 'Cat'), (4, 'Dan'), (5, 'Eve'), (6, 'Fay'), (7, 'Gus'),
            (8, 'Hal'), (9, 'Ivy'), (10, 'Jo'), (11, 'Kit'), (12, 'Lou'), (13, 'Mo')) v(n, name)
where p.id = pg_temp.u(v.n);
insert into public.grants (user_id, tier) values (pg_temp.u(1), 'pro');
create function pg_temp.as_player(n int) returns void language sql as
$$ select set_config('request.jwt.claims',
     json_build_object('sub', pg_temp.u(n), 'email', 's' || n || '@example.com')::text, false) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return '(none)'; exception when others then return sqlerrm; end $$;
-- A London wall-clock time as a timestamptz.
create function pg_temp.uk(p text) returns timestamptz language sql immutable as
$$ select p::timestamp at time zone 'Europe/London' $$;

-- ---------- No season: nothing closes ----------

delete from public.site_settings where key = 'season';
do $$ begin
  assert public.close_matchweeks('2027-01-11') = 0, 'no season row closes nothing';
  assert (select count(*) from public.matchweeks) = 0, 'no matchweeks without a season';
end $$;

-- ---------- Snapshots ----------
-- Season starts Saturday 2 Jan 2027, so the first matchweek is Mon 4 Jan to
-- Sun 10 Jan. No snapshots for Sunday 24 Jan (the job didn't run).
insert into public.site_settings (key, value)
values ('season', '{"start":"2027-01-02T12:00:00Z"}'::jsonb)
on conflict (key) do update set value = excluded.value;

insert into public.portfolio_snapshots (user_id, day, value) values
  (pg_temp.u(1), '2026-12-27',  500),
  (pg_temp.u(1), '2027-01-03', 1000), (pg_temp.u(2), '2027-01-03', 2000), (pg_temp.u(4), '2027-01-03', 1000),
  (pg_temp.u(1), '2027-01-10', 1100), (pg_temp.u(2), '2027-01-10', 1900), (pg_temp.u(4), '2027-01-10', 1500),
  (pg_temp.u(3), '2027-01-10', 1000),
  (pg_temp.u(1), '2027-01-17', 1210), (pg_temp.u(2), '2027-01-17', 2090), (pg_temp.u(4), '2027-01-17', 3000),
  (pg_temp.u(3), '2027-01-17', 2000),
  (pg_temp.u(1), '2027-01-31', 1210), (pg_temp.u(2), '2027-01-31', 2090), (pg_temp.u(3), '2027-01-31', 1000),
  (pg_temp.u(1), '2027-02-07', 1210), (pg_temp.u(2), '2027-02-07', 2090), (pg_temp.u(3), '2027-02-07', 1200),
  -- A zero start value scores 0.
  (pg_temp.u(6), '2027-01-03',    0), (pg_temp.u(6), '2027-01-10',  100);

-- ---------- close_matchweeks ----------

do $$ begin
  assert public.close_matchweeks('2027-01-11') = 1, 'Monday 11 Jan closes one week';
  assert (select status from public.matchweeks where week_end = '2027-01-10') = 'scored', 'week to 10 Jan scored';
  assert (select season_start from public.matchweeks where week_end = '2027-01-10') = '2027-01-02T12:00:00Z'::timestamptz,
    'matchweek records its season';
  assert not exists (select 1 from public.matchweeks where week_end = '2027-01-03'),
    'week ending before a full week of the season is not created';
  assert (select pct from public.player_week_scores where week_end = '2027-01-10' and user_id = pg_temp.u(1)) = 10.00, 'A +10';
  assert (select pct from public.player_week_scores where week_end = '2027-01-10' and user_id = pg_temp.u(2)) = -5.00, 'B -5';
  assert (select pct from public.player_week_scores where week_end = '2027-01-10' and user_id = pg_temp.u(4)) = 50.00, 'D +50';
  assert (select pct from public.player_week_scores where week_end = '2027-01-10' and user_id = pg_temp.u(6)) = 0, 'start value 0 scores 0';
  assert not exists (select 1 from public.player_week_scores where week_end = '2027-01-10' and user_id = pg_temp.u(3)),
    'no score without the previous Sunday';
  assert public.close_matchweeks('2027-01-11') = 0, 'second call closes nothing';
  assert (select count(*) from public.player_week_scores) = 4, 'nothing scored twice';
end $$;

-- Missed Mondays: Monday 8 Feb catches up four weeks. 24 Jan has no
-- snapshots, so the weeks to 24 Jan and to 31 Jan are void; 7 Feb scores.
do $$ begin
  assert public.close_matchweeks('2027-02-08') = 4, 'catch-up closes four weeks';
  assert (select status from public.matchweeks where week_end = '2027-01-17') = 'scored', '17 Jan scored';
  assert (select status from public.matchweeks where week_end = '2027-01-24') = 'void', '24 Jan void (no Sunday snapshots)';
  assert (select status from public.matchweeks where week_end = '2027-01-31') = 'void', '31 Jan void (no previous Sunday)';
  assert (select status from public.matchweeks where week_end = '2027-02-07') = 'scored', '7 Feb still scores';
  assert not exists (select 1 from public.player_week_scores where week_end in ('2027-01-24', '2027-01-31')),
    'void weeks have no scores';
  assert (select pct from public.player_week_scores where week_end = '2027-02-07' and user_id = pg_temp.u(3)) = 20.00, 'C +20';
  assert public.close_matchweeks('2027-02-08') = 0, 'catch-up is idempotent';
  -- p_today is a trading day: on trading day Saturday 13 Feb the week to
  -- 14 Feb isn't over, so it isn't closed.
  assert public.close_matchweeks('2027-02-13') = 0, 'a week doesn''t close before its Sunday''s trading day';
  assert (select count(*) from public.matchweeks) = 5, 'five weeks in all';
end $$;

-- ---------- Leagues ----------
-- League 1: Alice (owner), Bob, Eve, Fay. League 2: Alice (owner), Bob,
-- Cat (joined Wednesday 13 Jan), Dan (kicked Thursday 14 Jan).
create temp table l (k text primary key, id bigint);
grant all on l to authenticated;
insert into public.leagues (name, type, owner_id, invite_code) values ('One', 'classic', pg_temp.u(1), 'AAAAAA');
insert into public.leagues (name, type, owner_id, invite_code) values ('Two', 'classic', pg_temp.u(1), 'BBBBBB');
insert into l select 'one', id from public.leagues where invite_code = 'AAAAAA';
insert into l select 'two', id from public.leagues where invite_code = 'BBBBBB';

insert into public.league_members (league_id, user_id, joined_at, left_at, join_value, kicked) values
  -- Before the season: the Classic table counts 2000, not 1500.
  ((select id from l where k = 'one'), pg_temp.u(1), pg_temp.uk('2026-12-20 10:00'), null, 1500, false),
  -- Bob was in before the season, left and rejoined during it: still 2000.
  ((select id from l where k = 'one'), pg_temp.u(2), pg_temp.uk('2026-12-20 10:00'), pg_temp.uk('2027-01-20 10:00'), 1800, false),
  ((select id from l where k = 'one'), pg_temp.u(2), pg_temp.uk('2027-01-21 10:00'), null, 2500, false),
  ((select id from l where k = 'one'), pg_temp.u(5), pg_temp.uk('2027-01-05 10:00'), null, 1000, false),
  -- Fay's stint from last season doesn't count; her current one does.
  ((select id from l where k = 'one'), pg_temp.u(6), pg_temp.uk('2026-10-01 10:00'), pg_temp.uk('2026-11-01 10:00'), 100, false),
  ((select id from l where k = 'one'), pg_temp.u(6), pg_temp.uk('2027-01-05 10:00'), null, 4000, false),
  ((select id from l where k = 'two'), pg_temp.u(1), pg_temp.uk('2026-12-20 10:00'), null, 2000, false),
  ((select id from l where k = 'two'), pg_temp.u(2), pg_temp.uk('2026-12-20 10:00'), null, 2000, false),
  ((select id from l where k = 'two'), pg_temp.u(3), pg_temp.uk('2027-01-13 10:00'), null, 2000, false),
  ((select id from l where k = 'two'), pg_temp.u(4), pg_temp.uk('2026-12-20 10:00'), pg_temp.uk('2027-01-14 10:00'), 2000, true);

update public.profiles p set coin_balance = v.coins
from (values (1, 2200), (2, 2200), (5, 1500), (6, 2000)) v(n, coins)
where p.id = pg_temp.u(v.n);

set role authenticated;

-- ---------- Player of the week ----------

do $$ declare r record; n int := 0; begin
  perform pg_temp.as_player(2);
  for r in select * from public.league_player_of_week((select id from l where k = 'one')) loop
    n := n + 1;
    case n
      when 1 then assert r.week_end = '2027-02-07' and r.status = 'scored'
                     and r.winners = array['Alice', 'Bob'] and r.pct = 0, '7 Feb: tie at 0 ' || r::text;
      when 2 then assert r.week_end = '2027-01-31' and r.status = 'void' and r.pct is null
                     and coalesce(cardinality(r.winners), 0) = 0, '31 Jan void ' || r::text;
      when 3 then assert r.week_end = '2027-01-24' and r.status = 'void', '24 Jan void ' || r::text;
      when 4 then assert r.week_end = '2027-01-17' and r.winners = array['Alice', 'Bob'] and r.pct = 10.00,
                     '17 Jan tie ' || r::text;
      when 5 then assert r.week_end = '2027-01-10' and r.winners = array['Alice'] and r.pct = 10.00,
                     '10 Jan Alice ' || r::text;
    end case;
  end loop;
  assert n = 5, 'five weeks shown: ' || n;
  assert (select count(*) from public.league_player_of_week((select id from l where k = 'one'), 2)) = 2, 'limit';
end $$;

do $$ declare r record; begin
  perform pg_temp.as_player(3);
  -- Dan counts the week before he was kicked.
  select * into r from public.league_player_of_week((select id from l where k = 'two')) where week_end = '2027-01-10';
  assert r.winners = array['Dan'] and r.pct = 50.00, '10 Jan Dan ' || r::text;
  -- Cat joined on Wednesday and Dan was kicked on Thursday: neither counts.
  select * into r from public.league_player_of_week((select id from l where k = 'two')) where week_end = '2027-01-17';
  assert r.winners = array['Alice', 'Bob'] and r.pct = 10.00, '17 Jan without Cat and Dan ' || r::text;
  -- Cat counts from the next full week.
  select * into r from public.league_player_of_week((select id from l where k = 'two')) where week_end = '2027-02-07';
  assert r.winners = array['Cat'] and r.pct = 20.00, '7 Feb Cat ' || r::text;
end $$;

-- A scored week where nobody in the league counted: no winners, not void.
reset role;
insert into public.leagues (name, type, owner_id, invite_code) values ('Hal', 'classic', pg_temp.u(8), 'CCCCCC');
insert into l select 'hal', id from public.leagues where invite_code = 'CCCCCC';
insert into public.league_members (league_id, user_id, joined_at, join_value)
values ((select id from l where k = 'hal'), pg_temp.u(8), pg_temp.uk('2026-12-20 10:00'), 2000);
set role authenticated;
do $$ declare r record; begin
  perform pg_temp.as_player(8);
  select * into r from public.league_player_of_week((select id from l where k = 'hal')) where week_end = '2027-01-10';
  assert r.status = 'scored' and r.winners = '{}'::text[] and r.pct is null, 'scored, nobody counted ' || r::text;
end $$;

-- ---------- Clock changes ----------
-- BST starts at 01:00 on Sunday 28 March 2027, so that week ends at 23:59:59
-- BST (22:59:59 UTC). BST ends on Sunday 31 October, so the week to 31 Oct
-- starts at 00:00 BST on Monday 25 Oct (23:00 UTC on Sunday 24 Oct).
reset role;
insert into public.portfolio_snapshots (user_id, day, value) values
  (pg_temp.u(9),  '2027-03-21', 1000), (pg_temp.u(9),  '2027-03-28', 1100),
  (pg_temp.u(10), '2027-03-21', 1000), (pg_temp.u(10), '2027-03-28', 1300),
  (pg_temp.u(11), '2027-03-21', 1000), (pg_temp.u(11), '2027-03-28', 1400),
  (pg_temp.u(9),  '2027-10-24', 1000), (pg_temp.u(9),  '2027-10-31', 1100),
  (pg_temp.u(12), '2027-10-24', 1000), (pg_temp.u(12), '2027-10-31', 1500),
  (pg_temp.u(13), '2027-10-24', 1000), (pg_temp.u(13), '2027-10-31', 1200);
do $$ begin
  -- Trading day Sunday 14 Feb (Monday's run, after saving Sunday's
  -- snapshot): the week to 14 Feb closes (void here: no snapshots).
  assert public.close_matchweeks('2027-02-14') = 1, 'week to 14 Feb closes on its Sunday''s trading day';
  assert (select status from public.matchweeks where week_end = '2027-02-14') = 'void', '14 Feb void';
  perform public.close_matchweeks('2027-11-01');
  assert (select status from public.matchweeks where week_end = '2027-03-28') = 'scored', '28 Mar scored';
  assert (select status from public.matchweeks where week_end = '2027-10-31') = 'scored', '31 Oct scored';
end $$;
insert into public.leagues (name, type, owner_id, invite_code) values ('Clocks', 'classic', pg_temp.u(9), 'DDDDDD');
insert into l select 'clocks', id from public.leagues where invite_code = 'DDDDDD';
insert into public.league_members (league_id, user_id, joined_at, left_at, join_value) values
  ((select id from l where k = 'clocks'), pg_temp.u(9),  pg_temp.uk('2026-12-20 10:00'), null, 2000),
  -- Left at 00:30 BST on Monday 29 Mar (23:30 UTC Sunday): after the week, counts.
  ((select id from l where k = 'clocks'), pg_temp.u(10), pg_temp.uk('2026-12-20 10:00'), '2027-03-28 23:30:00+00', 2000),
  -- Left at 23:30 BST on Sunday 28 Mar (22:30 UTC): before the week ended, doesn't.
  ((select id from l where k = 'clocks'), pg_temp.u(11), pg_temp.uk('2026-12-20 10:00'), '2027-03-28 22:30:00+00', 2000),
  -- Joined at 00:30 BST on Monday 25 Oct (23:30 UTC Sunday): after the week began, doesn't count.
  ((select id from l where k = 'clocks'), pg_temp.u(12), '2027-10-24 23:30:00+00', null, 2000),
  -- Joined at 23:30 BST on Sunday 24 Oct (22:30 UTC): before the week began, counts.
  ((select id from l where k = 'clocks'), pg_temp.u(13), '2027-10-24 22:30:00+00', null, 2000);
set role authenticated;
do $$ declare r record; begin
  perform pg_temp.as_player(9);
  assert pg_temp.uk('2027-03-28 23:30') = '2027-03-28 22:30:00+00', 'test clock: BST on 28 Mar';
  assert pg_temp.uk('2027-10-25 00:30') = '2027-10-24 23:30:00+00', 'test clock: BST on 25 Oct';
  select * into r from public.league_player_of_week((select id from l where k = 'clocks'), 100) where week_end = '2027-03-28';
  assert r.winners = array['Jo'] and r.pct = 30.00, '28 Mar: Jo counts, Kit doesn''t ' || r::text;
  select * into r from public.league_player_of_week((select id from l where k = 'clocks'), 100) where week_end = '2027-10-31';
  assert r.winners = array['Mo'] and r.pct = 20.00, '31 Oct: Mo counts, Lou doesn''t ' || r::text;
end $$;

-- ---------- Classic table ----------
-- The table shows only once the season has started, so move the season
-- start (and league One's stints with it) into the past.
reset role;
do $$ declare v_shift interval := (now() - interval '60 days') - '2027-01-02T12:00:00Z'::timestamptz; begin
  update public.site_settings set value = jsonb_build_object('start', '2027-01-02T12:00:00Z'::timestamptz + v_shift)
    where key = 'season';
  update public.league_members set joined_at = joined_at + v_shift, left_at = left_at + v_shift
    where league_id = (select id from l where k = 'one');
end $$;
set role authenticated;

do $$ declare r record; n int := 0; begin
  perform pg_temp.as_player(5);
  for r in select * from public.league_classic_table((select id from l where k = 'one')) loop
    n := n + 1;
    case n
      when 1 then assert r.rank = 1 and r.display_name = 'Eve' and r.pct = 50.00, 'Eve first ' || r::text;
      when 2 then assert r.rank = 2 and r.display_name = 'Alice' and r.pct = 10.00 and r.tier = 'pro',
                     'Alice: pre-season stint counts from 2000 ' || r::text;
      when 3 then assert r.rank = 2 and r.display_name = 'Bob' and r.pct = 10.00 and r.tier = 'free',
                     'Bob: rejoin keeps the season''s first stint ' || r::text;
      when 4 then assert r.rank = 4 and r.display_name = 'Fay' and r.pct = -50.00, 'Fay last (this season''s stint) ' || r::text;
    end case;
    assert r.member_id is not null, 'member id';
  end loop;
  assert n = 4, 'current members only: ' || n;
end $$;

-- A season start recorded for the future: nothing to show yet.
reset role;
update public.site_settings set value = jsonb_build_object('start', now() + interval '1 day') where key = 'season';
set role authenticated;
do $$ begin
  perform pg_temp.as_player(5);
  assert (select count(*) from public.league_classic_table((select id from l where k = 'one'))) = 0,
    'classic table empty before the season starts';
end $$;

-- ---------- Members only ----------

do $$ declare e text; begin
  perform pg_temp.as_player(7);
  e := pg_temp.err(format('select * from public.league_classic_table(%s)', (select id from l where k = 'one')));
  assert e = 'You''re not in this league.', 'classic non-member: ' || e;
  e := pg_temp.err(format('select * from public.league_player_of_week(%s)', (select id from l where k = 'one')));
  assert e = 'You''re not in this league.', 'potw non-member: ' || e;
  -- A kicked player is no longer a member.
  perform pg_temp.as_player(4);
  e := pg_temp.err(format('select * from public.league_player_of_week(%s)', (select id from l where k = 'two')));
  assert e = 'You''re not in this league.', 'potw kicked: ' || e;
  perform set_config('request.jwt.claims', '', false);
  e := pg_temp.err(format('select * from public.league_classic_table(%s)', (select id from l where k = 'one')));
  assert e = 'Sign in to use leagues.', 'classic signed out: ' || e;
end $$;

-- ---------- No season row: nothing to show ----------

reset role;
delete from public.site_settings where key = 'season';
set role authenticated;
do $$ begin
  perform pg_temp.as_player(1);
  assert (select count(*) from public.league_classic_table((select id from l where k = 'one'))) = 0,
    'classic table empty before a season';
  assert (select count(*) from public.league_player_of_week((select id from l where k = 'one'))) = 0,
    'no Player of the week before a season';
end $$;

-- ---------- Who can call what ----------

do $$ declare n bigint; begin
  begin
    select count(*) into n from public.matchweeks;
    assert n = 0, 'players read no matchweeks directly';
  exception when insufficient_privilege then null;
  end;
  begin
    select count(*) into n from public.player_week_scores;
    assert n = 0, 'players read no week scores directly';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

do $$ begin
  assert not has_function_privilege('authenticated', 'public.close_matchweeks(date)', 'execute'), 'players cannot close weeks';
  assert not has_function_privilege('anon', 'public.close_matchweeks(date)', 'execute'), 'anon cannot close weeks';
  assert has_function_privilege('service_role', 'public.close_matchweeks(date)', 'execute'), 'the nightly job can';
  assert has_function_privilege('authenticated', 'public.league_classic_table(bigint)', 'execute'), 'players read tables';
  assert has_function_privilege('authenticated', 'public.league_player_of_week(bigint,integer)', 'execute'), 'players read potw';
  assert not has_function_privilege('anon', 'public.league_classic_table(bigint)', 'execute'), 'anon cannot read tables';
  assert not has_function_privilege('anon', 'public.league_player_of_week(bigint,integer)', 'execute'), 'anon cannot read potw';
end $$;

rollback;
