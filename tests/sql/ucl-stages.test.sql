-- Champions League stages (supabase-ucl-stages.sql): boosted, out and
-- winners results through approve_match_event, rejecting a stage event,
-- auto-apply, the 12-hour fallback, closed clubs in trade() and who can
-- run the internal functions. Runs in one transaction and rolls back, so
-- it leaves nothing behind.
begin;

-- A holder of every club, and the admin (profiles come from the
-- on_auth_user_created trigger).
insert into auth.users (id, email) values
  ('c1000000-0000-0000-0000-000000000001', 'holder@example.com'),
  ('ad000000-0000-0000-0000-0000000000ad', 'pitchmarketadmin@gmail.com');

insert into public.teams (name, league, league_label, tier, price)
select 'UCL ' || i, 'championsleague', 'Champions League', 'A', 50 from generate_series(1, 4) i;

insert into public.holdings (user_id, team_id, shares)
select 'c1000000-0000-0000-0000-000000000001', id, 4 from public.teams where league = 'championsleague';

create function pg_temp.club(n int) returns uuid language sql stable as
$$ select id from public.teams where name = 'UCL ' || n $$;
create function pg_temp.holder() returns uuid language sql immutable as
$$ select 'c1000000-0000-0000-0000-000000000001'::uuid $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return '(none)'; exception when others then return sqlerrm; end $$;
-- A pending one-sided event for a club (the away side is not on the site).
create function pg_temp.event(p_key text, p_team uuid, p_stage text, p_ai numeric,
                              p_mult numeric, p_delta numeric) returns uuid language sql as
$$ insert into public.match_events (source_match_id, competition, home_team_name, away_team_name,
     home_score, away_score, home_team_id, home_delta_pct, home_ai_pct, home_multiplier, home_stage, ai_provider)
   values (p_key, 'CL', (select name from public.teams where id = p_team), 'Visitors', 2, 1,
     p_team, p_delta, p_ai, p_mult, p_stage, 'test')
   returning id $$;

set local request.jwt.claims = '{"email":"pitchmarketadmin@gmail.com"}';

-- ---------- Only the admin can review ----------

do $$ declare v_ev uuid; e text; begin
  v_ev := pg_temp.event('auth', pg_temp.club(1), null, null, null, 5);
  perform set_config('request.jwt.claims', '{}', true);
  e := pg_temp.err(format('select public.approve_match_event(%L, true)', v_ev));
  assert e = 'Not authorized', 'no email claim: ' || e;
  perform set_config('request.jwt.claims', '{"sub":"c1000000-0000-0000-0000-000000000001","email":"holder@example.com"}', true);
  e := pg_temp.err(format('select public.approve_match_event(%L, false)', v_ev));
  assert e = 'Not authorized', 'player claims: ' || e;
  assert (select status from public.match_events where id = v_ev) = 'pending', 'still pending';
  delete from public.match_events where id = v_ev;
  perform set_config('request.jwt.claims', '{"email":"pitchmarketadmin@gmail.com"}', true);
end $$;

set local role anon;
set local request.jwt.claims = '{}';
do $$ declare e text; begin
  e := pg_temp.err(format('select public.approve_match_event(%L, true)', gen_random_uuid()));
  assert e = 'Not authorized', 'anon: ' || e;
end $$;
reset role;
set local request.jwt.claims = '{"email":"pitchmarketadmin@gmail.com"}';

-- ---------- Boosted stage result ----------

do $$ declare v_ev uuid; r record; begin
  v_ev := pg_temp.event('q1', pg_temp.club(1), 'quarters', 10, 1.5, 15);
  -- Kickoff hours ago, as the price job writes it: the history row is
  -- dated then, so only the pm.history_written flag stops a second row.
  update public.match_events set match_date = now() - interval '3 hours' where id = v_ev;
  perform public.approve_match_event(v_ev, true);
  select * into r from public.teams where id = pg_temp.club(1);
  assert r.price = 57.50, 'boosted price: ' || r.price;
  assert r.ucl_stage = 'quarters', 'stage set: ' || coalesce(r.ucl_stage, 'null');
  assert not r.closed, 'a club through to the quarters stays open';
  assert (select count(*) from public.price_history where team_id = pg_temp.club(1)) = 1,
    'exactly one history row for the boosted club';
  assert (select status = 'approved' and reviewed_by = 'pitchmarketadmin@gmail.com' and not stage_rejected
          from public.match_events where id = v_ev), 'event approved by the admin';
end $$;

-- ---------- Out ----------

do $$ declare v_ev uuid; r record; begin
  v_ev := pg_temp.event('o2', pg_temp.club(2), 'out', -5, 1, -100);
  update public.match_events set match_date = now() - interval '3 hours' where id = v_ev;
  perform public.approve_match_event(v_ev, true);
  select * into r from public.teams where id = pg_temp.club(2);
  assert r.price = 0 and r.chg = -100, 'out club goes to 0: ' || r.price;
  assert r.closed and r.ucl_stage = 'out', 'out club is closed';
  assert (select count(*) = 1 and min(delta_pct) = -100 and min(price) = 0
          from public.price_history where team_id = pg_temp.club(2)), 'one history row at -100';
  assert (select shares from public.holdings where user_id = pg_temp.holder() and team_id = pg_temp.club(2)) = 4,
    'shares in an out club remain';
end $$;

-- ---------- A closed club is never re-priced ----------

-- An older pending normal event for a club that has since gone out:
-- approving it moves nothing and leaves no history row.
do $$ declare v_ev uuid; r record; begin
  v_ev := pg_temp.event('late2', pg_temp.club(2), null, null, null, 8);
  perform public.approve_match_event(v_ev, true);
  select * into r from public.teams where id = pg_temp.club(2);
  assert r.price = 0 and r.chg = -100, 'closed club keeps price 0: ' || r.price;
  assert r.closed and r.ucl_stage = 'out', 'closed club stays out';
  assert (select count(*) from public.price_history where match_event_id = v_ev) = 0, 'no history row for a closed club';
  assert (select status from public.match_events where id = v_ev) = 'approved', 'event still marked approved';

  -- A stage event for it is skipped the same way.
  v_ev := pg_temp.event('late2s', pg_temp.club(2), 'semis', 10, 2, 20);
  perform public.approve_match_event(v_ev, true);
  select * into r from public.teams where id = pg_temp.club(2);
  assert r.price = 0 and r.ucl_stage = 'out' and r.closed, 'stage event does not reopen or re-price: ' || r.ucl_stage;
end $$;

-- ---------- Rejecting a stage event applies it as a normal match ----------

do $$ declare v_ev uuid; r record; begin
  v_ev := pg_temp.event('r3', pg_temp.club(3), 'quarters', 10, 1.5, 15);
  perform public.approve_match_event(v_ev, false);
  select * into r from public.teams where id = pg_temp.club(3);
  assert r.price = 55.00, 'rejected stage event moves by the AI pct: ' || r.price;
  assert r.chg = 10, 'chg is the AI pct: ' || r.chg;
  assert r.ucl_stage is null and not r.closed, 'stage unchanged';
  assert (select status = 'approved' and stage_rejected from public.match_events where id = v_ev),
    'rejected stage event is approved with stage_rejected';
end $$;

-- ---------- Rejecting a normal event ----------

do $$ declare v_ev uuid; begin
  v_ev := pg_temp.event('n3', pg_temp.club(3), null, null, null, 5);
  perform public.approve_match_event(v_ev, false);
  assert (select status = 'rejected' and not stage_rejected from public.match_events where id = v_ev), 'normal reject';
  assert (select price from public.teams where id = pg_temp.club(3)) = 55.00, 'price unchanged on normal reject';
end $$;

-- ---------- Rejecting a play-off-only event is a normal reject ----------

do $$ declare v_ev uuid; begin
  v_ev := pg_temp.event('pr3', pg_temp.club(3), 'playoff', 9, 1, 9);
  perform public.approve_match_event(v_ev, false);
  assert (select status = 'rejected' and not stage_rejected from public.match_events where id = v_ev),
    'play-off-only reject is a normal reject';
  assert (select price from public.teams where id = pg_temp.club(3)) = 55.00, 'price unchanged on play-off reject';
  assert (select ucl_stage from public.teams where id = pg_temp.club(3)) is null, 'stage unchanged on play-off reject';
end $$;

-- ---------- Auto-apply ----------

do $$ declare v_ev uuid; e text; begin
  v_ev := pg_temp.event('s3', pg_temp.club(3), 'semis', 10, 2, 20);
  e := pg_temp.err(format('select public.auto_apply_match_event(%L)', v_ev));
  assert e = 'Stage results need approval', 'auto-apply semis: ' || e;
  assert (select status from public.match_events where id = v_ev) = 'pending', 'semis event still pending';
  delete from public.match_events where id = v_ev;

  v_ev := pg_temp.event('p3', pg_temp.club(3), 'playoff', 2, 1, 2);
  perform public.auto_apply_match_event(v_ev);
  assert (select ucl_stage from public.teams where id = pg_temp.club(3)) = 'playoff', 'playoff stage set';
  assert (select price from public.teams where id = pg_temp.club(3)) = 56.10, 'playoff move applied';
  assert (select reviewed_by from public.match_events where id = v_ev) = 'auto (test)', 'stamped auto';
end $$;

-- ---------- 12-hour fallback ----------

do $$ declare v_old uuid; v_new uuid; e text; begin
  v_old := pg_temp.event('f-old', pg_temp.club(1), 'semis', 10, 2, 20);
  v_new := pg_temp.event('f-new', pg_temp.club(1), 'semis', 10, 2, 20);
  update public.match_events set created_at = now() - interval '13 hours' where id = v_old;
  update public.match_events set created_at = now() - interval '11 hours' where id = v_new;
  assert public.apply_overdue_stage_events() = 1, 'one overdue event applied';
  assert (select status = 'approved' and reviewed_by = 'auto (12h)' from public.match_events where id = v_old),
    'old event applied by the fallback';
  assert (select status from public.match_events where id = v_new) = 'pending', 'newer event still pending';
  assert (select ucl_stage from public.teams where id = pg_temp.club(1)) = 'semis', 'fallback sets the stage';
  assert (select price from public.teams where id = pg_temp.club(1)) = 69.00, 'fallback applies the boosted move';
  assert public.apply_overdue_stage_events() = 0, 'second call applies nothing';
  e := pg_temp.err(format('select public.approve_match_event(%L, true)', v_old));
  assert e = 'Event not found or already reviewed', 'approving an applied event: ' || e;
  delete from public.match_events where id = v_new;
end $$;

-- ---------- One bad overdue event does not block the others ----------

do $$ declare v_bad uuid; v_good uuid; v_before numeric; begin
  select price into v_before from public.teams where id = pg_temp.club(1);
  -- A club that can't go above 100 (a constraint, added only for this test),
  -- so a +200% move on it raises when applied.
  alter table public.teams add constraint pm_test_cap check (name <> 'UCL 3' or price < 100);
  v_bad := pg_temp.event('bad', pg_temp.club(3), 'semis', 10, 2, 200);
  v_good := pg_temp.event('good', pg_temp.club(1), 'semis', 10, 2, 10);
  update public.match_events set created_at = now() - interval '14 hours' where id = v_bad;
  update public.match_events set created_at = now() - interval '13 hours' where id = v_good;
  assert public.apply_overdue_stage_events() = 1, 'only the good event counted';
  assert (select status from public.match_events where id = v_bad) = 'pending', 'bad event skipped, still pending';
  assert (select status = 'approved' from public.match_events where id = v_good), 'good event applied after the bad one';
  assert (select price from public.teams where id = pg_temp.club(1)) = round(v_before * 1.10, 2), 'good move applied once';
  assert (select price from public.teams where id = pg_temp.club(3)) = 56.10, 'bad event changed nothing';
  assert (select count(*) from public.price_history where match_event_id = v_bad) = 0, 'bad event left no history row';
  delete from public.match_events where id = v_bad;
  alter table public.teams drop constraint pm_test_cap;
end $$;

-- ---------- Winners ----------

do $$ declare v_ev uuid; v_coins numeric; r record; begin
  select coin_balance into v_coins from public.profiles where id = pg_temp.holder();
  v_ev := pg_temp.event('w4', pg_temp.club(4), 'winners', 10, 3, 30);
  -- The final's loser is on the site too: closing every club for the
  -- winners must not stop the loser going out.
  update public.match_events set away_team_id = pg_temp.club(3), away_team_name = 'UCL 3',
    away_stage = 'out', away_ai_pct = -4, away_multiplier = null, away_delta_pct = -100 where id = v_ev;
  perform public.approve_match_event(v_ev, true);
  select * into r from public.teams where id = pg_temp.club(3);
  assert r.price = 0 and r.closed and r.ucl_stage = 'out', 'final loser goes out: ' || r.price || ' ' || coalesce(r.ucl_stage, 'null');
  select * into r from public.teams where id = pg_temp.club(4);
  assert r.price = 65.00, 'winners price: ' || r.price;
  assert r.ucl_stage = 'winners' and r.closed, 'winners closed';
  assert (select coin_balance from public.profiles where id = pg_temp.holder()) = v_coins + 260.00,
    'holder paid 4 x 65';
  assert (select count(*) = 1 and min(threshold) = 4 and min(price) = 65 and min(team_name) = 'UCL 4'
          from public.notifications where user_id = pg_temp.holder() and kind = 'cashout'), 'cashout notification';
  assert not exists (select 1 from public.holdings where team_id = pg_temp.club(4)), 'winners holdings removed';
  assert (select count(*) from public.teams where name like 'UCL %' and closed) = 4, 'all four clubs closed';
  assert not exists (select 1 from public.teams where league = 'championsleague' and not closed),
    'no Champions League club left open';
  assert (select count(*) from public.price_history where team_id = pg_temp.club(4)) = 1,
    'one history row for the winners';
end $$;

-- ---------- Trading closed clubs ----------

set local role authenticated;
set local request.jwt.claims = '{"sub":"c1000000-0000-0000-0000-000000000001"}';

do $$ declare e text; begin
  e := pg_temp.err(format('select public.trade(%L, %L, 1)', pg_temp.club(2), 'buy'));
  assert e = 'This club is out of the Champions League. Trading has closed.', 'buy out club: ' || e;
  e := pg_temp.err(format('select public.trade(%L, %L, 1)', pg_temp.club(2), 'sell'));
  assert e = 'This club is out of the Champions League. Trading has closed.', 'sell out club: ' || e;
  e := pg_temp.err(format('select public.trade(%L, %L, 1)', pg_temp.club(4), 'buy'));
  assert e = 'The Champions League is over for this season. Trading has closed.', 'buy winners: ' || e;
  e := pg_temp.err(format('select public.trade(%L, %L, 1)', pg_temp.club(4), 'sell'));
  assert e = 'The Champions League is over for this season. Trading has closed.', 'sell winners: ' || e;
  e := pg_temp.err(format('select public.trade(%L, %L, 1000000)', pg_temp.club(1), 'buy'));
  assert e = 'Trading on this club has closed.', 'buy closed semi-finalist (before the cost check): ' || e;
end $$;

reset role;

-- ---------- Who can run the internal functions ----------

do $$ begin
  assert not has_function_privilege('anon', 'public.apply_match_event_core(uuid,boolean,text)', 'execute'), 'core: anon';
  assert not has_function_privilege('authenticated', 'public.apply_match_event_core(uuid,boolean,text)', 'execute'), 'core: authenticated';
  assert not has_function_privilege('anon', 'public.ucl_cash_out(uuid,text)', 'execute'), 'cash-out: anon';
  assert not has_function_privilege('authenticated', 'public.ucl_cash_out(uuid,text)', 'execute'), 'cash-out: authenticated';
  assert not has_function_privilege('anon', 'public.apply_overdue_stage_events()', 'execute'), 'fallback: anon';
  assert not has_function_privilege('authenticated', 'public.apply_overdue_stage_events()', 'execute'), 'fallback: authenticated';
  assert has_function_privilege('service_role', 'public.apply_overdue_stage_events()', 'execute'), 'fallback: service role';
end $$;

rollback;
