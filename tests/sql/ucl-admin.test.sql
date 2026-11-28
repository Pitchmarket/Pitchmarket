-- Champions League admin actions (supabase-ucl-stages.sql): knock out,
-- crown, close and refund, reopen and the non-entrants list. Runs in one
-- transaction and rolls back, so it leaves nothing behind.
begin;

insert into auth.users (id, email) values
  ('c1000000-0000-0000-0000-000000000001', 'holder@example.com'),
  ('ad000000-0000-0000-0000-0000000000ad', 'pitchmarketadmin@gmail.com');

insert into public.teams (name, league, league_label, tier, price)
select 'UCL ' || i, 'championsleague', 'Champions League', 'A', 10 from generate_series(1, 6) i;
insert into public.teams (name, league, league_label, tier, price)
values ('Other 1', 'premierleague', 'Premier League', 'A', 10);

create function pg_temp.club(n int) returns uuid language sql stable as
$$ select id from public.teams where name = 'UCL ' || n $$;
create function pg_temp.holder() returns uuid language sql immutable as
$$ select 'c1000000-0000-0000-0000-000000000001'::uuid $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return '(none)'; exception when others then return sqlerrm; end $$;

-- ---------- Only the admin ----------

set local role authenticated;
set local request.jwt.claims = '{"sub":"c1000000-0000-0000-0000-000000000001","email":"holder@example.com"}';
do $$ declare e text; t uuid := gen_random_uuid(); begin
  e := pg_temp.err(format('select public.admin_ucl_knock_out(%L)', t));
  assert e = 'Not authorized', 'knock out: ' || e;
  e := pg_temp.err(format('select public.admin_ucl_crown(%L)', t));
  assert e = 'Not authorized', 'crown: ' || e;
  e := pg_temp.err(format('select public.admin_ucl_close_refund(%L)', t));
  assert e = 'Not authorized', 'refund: ' || e;
  e := pg_temp.err(format('select public.admin_ucl_reopen(%L, 10)', t));
  assert e = 'Not authorized', 'reopen: ' || e;
  e := pg_temp.err('select * from public.admin_ucl_non_entrants()');
  assert e = 'Not authorized', 'non-entrants: ' || e;
  perform set_config('request.jwt.claims', '{}', true);
  e := pg_temp.err(format('select public.admin_ucl_knock_out(%L)', t));
  assert e = 'Not authorized', 'no email claim: ' || e;
end $$;
set local role anon;
do $$ declare e text; begin
  e := pg_temp.err(format('select public.admin_ucl_crown(%L)', gen_random_uuid()));
  assert e like 'permission denied%', 'anon: ' || e;
end $$;
reset role;
set local request.jwt.claims = '{"email":"pitchmarketadmin@gmail.com"}';

-- ---------- Knock out ----------

do $$ declare r record; e text; begin
  perform public.admin_ucl_knock_out(pg_temp.club(1));
  select * into r from public.teams where id = pg_temp.club(1);
  assert r.price = 0 and r.chg = -100 and r.closed and r.ucl_stage = 'out', 'knocked out';
  assert (select count(*) = 1 and min(label) = 'Knocked out of the Champions League'
            and min(delta_pct) = -100 and min(source) = 'admin' and min(price) = 0
          from public.price_history where team_id = pg_temp.club(1)), 'exactly one history row';
  e := pg_temp.err(format('select public.admin_ucl_knock_out(%L)', pg_temp.club(1)));
  assert e = 'Not an open Champions League club', 'again: ' || e;
  e := pg_temp.err(format('select public.admin_ucl_knock_out(%L)', (select id from public.teams where name = 'Other 1')));
  assert e = 'Not an open Champions League club', 'other league: ' || e;
end $$;

-- ---------- Close and refund ----------

do $$ declare v_coins numeric; r record; begin
  update public.teams set price = 12.5 where id = pg_temp.club(2);
  delete from public.price_history where team_id = pg_temp.club(2);
  insert into public.holdings (user_id, team_id, shares) values (pg_temp.holder(), pg_temp.club(2), 2);
  select coin_balance into v_coins from public.profiles where id = pg_temp.holder();
  assert public.admin_ucl_close_refund(pg_temp.club(2)) = 1, 'one holder refunded';
  assert (select coin_balance from public.profiles where id = pg_temp.holder()) = v_coins + 25.00, 'refund 2 x 12.5';
  assert (select count(*) = 1 and min(threshold) = 2 and min(price) = 12.5
          from public.notifications where user_id = pg_temp.holder() and kind = 'refund'), 'refund notification';
  select * into r from public.teams where id = pg_temp.club(2);
  assert r.closed and r.ucl_stage = 'refunded' and r.price = 12.5, 'refunded club closed';
  assert not exists (select 1 from public.holdings where team_id = pg_temp.club(2)), 'holdings gone';
end $$;

-- ---------- Reopen ----------

do $$ declare e text; r record; begin
  insert into public.holdings (user_id, team_id, shares) values (pg_temp.holder(), pg_temp.club(1), 5);
  e := pg_temp.err(format('select public.admin_ucl_reopen(%L, 0)', pg_temp.club(1)));
  assert e = 'Price must be between 0.01 and 100000', 'zero price: ' || e;
  e := pg_temp.err(format('select public.admin_ucl_reopen(%L, 100001)', pg_temp.club(1)));
  assert e = 'Price must be between 0.01 and 100000', 'too high: ' || e;
  assert exists (select 1 from public.holdings where team_id = pg_temp.club(1)), 'bad price changes nothing';
  perform public.admin_ucl_reopen(pg_temp.club(1), 30);
  select * into r from public.teams where id = pg_temp.club(1);
  assert r.price = 30 and r.chg = 0 and not r.closed and r.ucl_stage = 'league', 'reopened';
  assert not exists (select 1 from public.holdings where team_id = pg_temp.club(1)), 'old holdings removed';
  assert (select count(*) from public.price_history
          where team_id = pg_temp.club(1) and label = 'Reopened for the new Champions League') = 1, 'one reopen history row';
  assert (select count(*) from public.price_history where team_id = pg_temp.club(1)) = 2, 'no extra manual row';
  e := pg_temp.err(format('select public.admin_ucl_reopen(%L, 30)', pg_temp.club(1)));
  assert e = 'Not a closed Champions League club', 'open club: ' || e;
  e := pg_temp.err(format('select public.admin_ucl_reopen(%L, 30)', (select id from public.teams where name = 'Other 1')));
  assert e = 'Not a closed Champions League club', 'other league: ' || e;
end $$;

-- ---------- Non-entrants ----------

do $$ declare v_year int; begin
  -- Clubs 3 to 5 are open (1 was reopened, 2 is refunded and closed, 6 gets closed).
  update public.teams set closed = true where id = pg_temp.club(6);
  v_year := extract(year from now())::int - case when extract(month from now()) >= 7 then 0 else 1 end;
  insert into public.fixtures (source_match_id, competition, home_team_id, kickoff)
    values ('fx1', 'CL', pg_temp.club(3), now() + interval '3 days');
  insert into public.match_events (source_match_id, competition, home_team_name, away_team_name,
      home_score, away_score, match_date, home_team_id)
    values ('me1', 'CL', 'UCL 4', 'Visitors', 1, 0, make_date(v_year, 7, 1), pg_temp.club(4));
  -- Club 1 only has a match from before this competition year.
  insert into public.match_events (source_match_id, competition, home_team_name, away_team_name,
      home_score, away_score, match_date, home_team_id)
    values ('me0', 'CL', 'UCL 1', 'Visitors', 1, 0, make_date(v_year, 7, 1) - interval '1 day', pg_temp.club(1));
  -- A match in another competition does not count for club 5.
  insert into public.match_events (source_match_id, competition, home_team_name, away_team_name,
      home_score, away_score, match_date, home_team_id)
    values ('me5', 'PL', 'UCL 5', 'Visitors', 1, 0, now(), pg_temp.club(5));
  -- Club 3 has a fixture, club 4 a match this year; 1 (an old match) and 5 (another competition) have neither.
  assert (select array_agg(name order by name) from public.admin_ucl_non_entrants()) = array['UCL 1', 'UCL 5'],
    'non-entrants: ' || (select string_agg(name, ',') from public.admin_ucl_non_entrants());
  delete from public.match_events where source_match_id in ('me0', 'me5');
end $$;

-- ---------- Crown ----------

do $$ declare v_coins numeric; begin
  update public.teams set price = 40 where id = pg_temp.club(3);
  insert into public.holdings (user_id, team_id, shares) values (pg_temp.holder(), pg_temp.club(3), 3);
  select coin_balance into v_coins from public.profiles where id = pg_temp.holder();
  assert public.admin_ucl_crown(pg_temp.club(3)) = 1, 'one holder paid';
  assert (select coin_balance from public.profiles where id = pg_temp.holder()) = v_coins + 120.00, 'crown 3 x 40';
  assert (select count(*) = 1 and min(threshold) = 3 and min(price) = 40
          from public.notifications where user_id = pg_temp.holder() and kind = 'cashout'), 'cashout notification';
  assert not exists (select 1 from public.holdings where team_id = pg_temp.club(3)), 'holdings gone';
  assert (select ucl_stage from public.teams where id = pg_temp.club(3)) = 'winners', 'winners stage';
  assert not exists (select 1 from public.teams where league = 'championsleague' and not closed), 'all clubs closed';
  assert (select not closed from public.teams where name = 'Other 1'), 'other leagues untouched';
end $$;

rollback;
