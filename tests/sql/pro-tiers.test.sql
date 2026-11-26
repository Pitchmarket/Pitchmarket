-- Plans (supabase-pro-1.sql): user_tier, watchlist caps, leaderboard tier,
-- admin grants, snapshots and access rules. Runs in one transaction and
-- rolls back, so it leaves nothing behind.
begin;

-- Supabase's default grants to anon and authenticated are set up in
-- supabase-stubs.sql before the schema loads.

-- Players (profiles come from the on_auth_user_created trigger).
insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-000000000001', 'free@example.com'),
  ('a2000000-0000-0000-0000-000000000002', 'pro@example.com'),
  ('a3000000-0000-0000-0000-000000000003', 'ult@example.com'),
  ('a4000000-0000-0000-0000-000000000004', 'over@example.com'),
  ('ad000000-0000-0000-0000-0000000000ad', 'pitchmarketadmin@gmail.com');

insert into public.teams (name, league, league_label, tier, price)
select 'Club ' || i, 'eng', 'England', 'A', 10 from generate_series(1, 16) i;

create temp table ids as select
  'a1000000-0000-0000-0000-000000000001'::uuid as free_u,
  'a2000000-0000-0000-0000-000000000002'::uuid as pro_u,
  'a3000000-0000-0000-0000-000000000003'::uuid as ult_u,
  'a4000000-0000-0000-0000-000000000004'::uuid as over_u;
grant select on ids to anon, authenticated;

-- ---------- user_tier ----------

do $$ declare u uuid := (select free_u from ids); begin
  assert public.user_tier(u) = 'free', 'free player should be free';
  assert public.payments_settings() ->> 'mode' = 'test', 'payments mode should start at test';
end $$;

do $$ declare u uuid := (select pro_u from ids); begin
  insert into public.subscriptions (id, user_id, stripe_customer_id, tier, status, current_period_end, livemode)
  values ('sub_pro', u, 'cus_1', 'pro', 'active', now() + interval '1 day', false);
  assert public.user_tier(u) = 'pro', 'test-mode sub counts in test mode';

  update public.site_settings set value = jsonb_set(value, '{mode}', '"live"') where key = 'payments';
  assert public.user_tier(u) = 'free', 'test-mode sub must not count in live mode';
  update public.site_settings set value = jsonb_set(value, '{mode}', '"test"') where key = 'payments';

  update public.subscriptions set current_period_end = now() - interval '2 days' where id = 'sub_pro';
  assert public.user_tier(u) = 'pro', 'sub 2 days past period end still counts';
  update public.subscriptions set current_period_end = now() - interval '4 days' where id = 'sub_pro';
  assert public.user_tier(u) = 'free', 'sub 4 days past period end no longer counts';
  update public.subscriptions set current_period_end = now() + interval '10 days', status = 'canceled' where id = 'sub_pro';
  assert public.user_tier(u) = 'free', 'canceled sub does not count';
  update public.subscriptions set status = 'active' where id = 'sub_pro';

  insert into public.grants (user_id, tier, until, note) values (u, 'ultimate', null, 'friend');
  assert public.user_tier(u) = 'ultimate', 'pro sub + ultimate grant should be ultimate';
  update public.grants set until = now() - interval '1 day' where user_id = u;
  assert public.user_tier(u) = 'pro', 'expired grant falls back to the sub tier';
  delete from public.grants where user_id = u;
end $$;

-- my_plan for the pro player, and signed out.
do $$ declare p jsonb; begin
  perform set_config('request.jwt.claims', json_build_object('sub', (select pro_u from ids), 'email', 'pro@example.com')::text, false);
  p := public.my_plan();
  assert p ->> 'tier' = 'pro', 'my_plan tier: ' || p::text;
  assert p ->> 'source' = 'stripe', 'my_plan source: ' || p::text;
  assert (p ->> 'test')::boolean, 'my_plan test flag: ' || p::text;
  assert (p ->> 'has_subscription')::boolean, 'my_plan has_subscription: ' || p::text;
  perform set_config('request.jwt.claims', '', false);
  p := public.my_plan();
  assert p ->> 'tier' = 'free' and p ->> 'source' = 'free', 'signed-out my_plan: ' || p::text;
end $$;

-- ---------- watchlist caps ----------

do $$ declare u uuid := (select free_u from ids); v_err text; begin
  insert into public.watchlist (user_id, team_id) select u, id from public.teams order by name limit 2;
  begin
    insert into public.watchlist (user_id, team_id)
      select u, id from public.teams where id not in (select team_id from public.watchlist where user_id = u) limit 1;
  exception when others then v_err := sqlerrm;
  end;
  assert v_err = 'Watchlist full: your plan allows 2 clubs.', 'free cap message: ' || coalesce(v_err, '(none)');
end $$;

alter table public.watchlist disable trigger watchlist_limit_check;
insert into public.watchlist (user_id, team_id)
  select (select over_u from ids), id from public.teams order by name limit 4;
alter table public.watchlist enable trigger watchlist_limit_check;

do $$ declare u uuid := (select over_u from ids); v_err text; begin
  begin
    insert into public.watchlist (user_id, team_id)
      select u, id from public.teams where id not in (select team_id from public.watchlist where user_id = u) limit 1;
  exception when others then v_err := sqlerrm;
  end;
  assert v_err = 'Watchlist full: your plan allows 2 clubs.', 'over-cap message: ' || coalesce(v_err, '(none)');
  assert (select count(*) from public.watchlist where user_id = u) = 4, 'over-cap player keeps 4 rows';
end $$;

do $$ declare u uuid := (select ult_u from ids); v_err text; begin
  insert into public.grants (user_id, tier) values (u, 'ultimate');
  insert into public.watchlist (user_id, team_id) select u, id from public.teams order by name limit 15;
  begin
    insert into public.watchlist (user_id, team_id)
      select u, id from public.teams where id not in (select team_id from public.watchlist where user_id = u) limit 1;
  exception when others then v_err := sqlerrm;
  end;
  assert v_err = 'Watchlist full: your plan allows 15 clubs.', 'ultimate cap message: ' || coalesce(v_err, '(none)');
end $$;

-- ---------- leaderboard ----------

do $$ begin
  assert (select l.tier from public.get_leaderboard(50) l
          join public.profiles p on p.display_name = l.display_name
          where p.id = (select pro_u from ids)) = 'pro', 'leaderboard tier for the pro player';
end $$;

-- ---------- admin grants ----------

do $$ declare v_err text; u uuid := (select free_u from ids); begin
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'email', 'free@example.com')::text, false);
  begin
    perform public.admin_grant_plan('free@example.com', 'pro', null, 'sneaky');
  exception when others then v_err := sqlerrm;
  end;
  assert v_err = 'Admins only.', 'non-admin grant: ' || coalesce(v_err, '(none)');
  v_err := null;
  begin
    perform * from public.admin_list_plans();
  exception when others then v_err := sqlerrm;
  end;
  assert v_err = 'Admins only.', 'non-admin list: ' || coalesce(v_err, '(none)');

  perform set_config('request.jwt.claims', json_build_object('sub', 'ad000000-0000-0000-0000-0000000000ad', 'email', 'pitchmarketadmin@gmail.com')::text, false);
  v_err := null;
  begin
    perform public.admin_grant_plan('nobody@example.com', 'pro', null, null);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err = 'No player with that email.', 'unknown email: ' || coalesce(v_err, '(none)');

  perform public.admin_grant_plan('Free@Example.com', 'pro', now() + interval '30 days', 'tester');
  assert public.user_tier(u) = 'pro', 'admin grant gives pro';
  assert (select source from public.admin_list_plans() where user_id = u) = 'grant', 'grant listed for admin';
  assert (select count(*) from public.admin_list_plans() where user_id = (select pro_u from ids)) = 1, 'stripe player listed';
  perform public.admin_grant_plan('free@example.com', 'ultimate', null, 'upgraded');
  assert public.user_tier(u) = 'ultimate', 'second grant replaces the first';
  perform public.admin_revoke_grant(u);
  assert public.user_tier(u) = 'free', 'revoke removes the grant';
  assert not exists (select 1 from public.grants where user_id = u), 'grant row gone';
  perform set_config('request.jwt.claims', '', false);
end $$;

-- ---------- snapshots ----------

do $$ declare n integer; begin
  delete from public.site_settings where key = 'season';
  assert public.season_start() is null, 'no season yet';
  n := public.take_portfolio_snapshots();
  assert n = 0, 'no snapshots before the season starts, got ' || n;
  assert (select count(*) from public.portfolio_snapshots) = 0, 'nothing written before the season starts';

  insert into public.site_settings (key, value) values ('season', '{"start":"not a date"}');
  assert public.season_start() is null, 'malformed season start reads as no season';
  n := public.take_portfolio_snapshots();
  assert n = 0, 'no snapshots with a malformed season start, got ' || n;
  delete from public.site_settings where key = 'season';

  insert into public.site_settings (key, value) values ('season', jsonb_build_object('start', now()));
  assert public.season_start() is not null, 'season start recorded';
  insert into public.holdings (user_id, team_id, shares)
    select (select pro_u from ids), id, 3 from public.teams order by name limit 1;
  n := public.take_portfolio_snapshots();
  assert n = (select count(*) from public.profiles), 'one snapshot per profile, got ' || n;
  n := public.take_portfolio_snapshots();
  assert (select count(*) from public.portfolio_snapshots) = (select count(*) from public.profiles), 'second run same day does not duplicate';
  assert (select value from public.portfolio_snapshots
          where user_id = (select pro_u from ids) and day = (now() at time zone 'Europe/London')::date) = 2030,
         'snapshot value is coins + holdings';
end $$;

-- ---------- access rules ----------

set role anon;
do $$ declare v_ok boolean := false; n bigint; begin
  assert (select count(*) from public.subscriptions) = 0, 'anon sees no subscriptions';
  begin
    select count(*) into n from public.grants;
    v_ok := n = 0;
  exception when insufficient_privilege then v_ok := true;
  end;
  assert v_ok, 'anon sees no grants';
  assert (select count(*) from public.portfolio_snapshots) = 0, 'anon sees no snapshots';
  begin
    perform public.take_portfolio_snapshots();
    v_ok := false;
  exception when insufficient_privilege then v_ok := true;
  end;
  assert v_ok, 'anon cannot take snapshots';
  assert public.my_plan() ->> 'tier' = 'free', 'anon can call my_plan';
end $$;
reset role;

select set_config('request.jwt.claims', json_build_object('sub', 'a2000000-0000-0000-0000-000000000002', 'email', 'pro@example.com')::text, false);
set role authenticated;
do $$ declare v_ok boolean; begin
  assert (select count(*) from public.subscriptions) = 1, 'player sees own subscription';
  assert (select count(*) from public.portfolio_snapshots) = 1, 'player sees own snapshot';
  assert (select count(*) from public.grants) = 0, 'player sees no grants';
  begin
    perform public.take_portfolio_snapshots();
    v_ok := false;
  exception when insufficient_privilege then v_ok := true;
  end;
  assert v_ok, 'players cannot take snapshots';
  assert (select l.tier from public.get_leaderboard() l limit 1) is not null, 'authenticated can read the leaderboard';
end $$;
reset role;

-- A player can't give themselves a plan or change payments settings.
-- Rows exist for each update, so "0 rows updated" means blocked.
create temp table before_state as
  select public.user_tier((select pro_u from ids)) as tier;
do $$ declare u uuid := (select pro_u from ids); begin
  insert into public.grants (user_id, tier, note) values (u, 'pro', 'update target');
  assert exists (select 1 from public.grants where user_id = u and tier = 'pro'), 'grant row to update exists';
  assert exists (select 1 from public.subscriptions where user_id = u and tier = 'pro' and not livemode), 'subscription row to update exists';
  assert exists (select 1 from public.site_settings where key = 'payments'), 'payments row to update exists';
end $$;

set role authenticated;
do $$ declare
  u uuid := (select pro_u from ids);
  v_blocked boolean;
  n bigint;
begin
  v_blocked := false;
  begin
    insert into public.subscriptions (id, user_id, tier, status, current_period_end, livemode)
    values ('sub_fake', u, 'ultimate', 'active', now() + interval '1 year', true);
  exception when insufficient_privilege then v_blocked := true;
  end;
  assert v_blocked, 'player cannot insert a subscription';

  update public.subscriptions set tier = 'ultimate', livemode = true where user_id = u;
  get diagnostics n = row_count;
  assert n = 0, 'player cannot update own subscription, updated ' || n;

  v_blocked := false;
  begin
    insert into public.grants (user_id, tier) values (u, 'ultimate');
  exception when insufficient_privilege then v_blocked := true;
  end;
  assert v_blocked, 'player cannot insert a grant';

  update public.grants set tier = 'ultimate' where user_id = u;
  get diagnostics n = row_count;
  assert n = 0, 'player cannot update a grant, updated ' || n;

  update public.site_settings set value = '{"mode":"off","portal_url":"","links":{}}' where key = 'payments';
  get diagnostics n = row_count;
  assert n = 0, 'player cannot change payments settings, updated ' || n;
end $$;
reset role;

do $$ declare u uuid := (select pro_u from ids); v_before text := (select tier from before_state); begin
  assert public.user_tier(u) = v_before, 'tier unchanged: was ' || v_before || ', now ' || public.user_tier(u);
  assert (select tier from public.grants where user_id = u) = 'pro', 'grant tier unchanged';
  assert (select tier from public.subscriptions where id = 'sub_pro') = 'pro'
     and not (select livemode from public.subscriptions where id = 'sub_pro'), 'subscription unchanged';
  assert not exists (select 1 from public.subscriptions where id = 'sub_fake'), 'no fake subscription';
  assert public.payments_settings() ->> 'mode' = 'test', 'payments mode unchanged';
  delete from public.grants where user_id = u;
end $$;

-- Function privileges, with Supabase's default EXECUTE grants in place.
do $$ declare r text; f text; begin
  foreach f in array array['public.take_portfolio_snapshots()', 'public.user_tier(uuid)', 'public.plan_of(uuid)',
                           'public.tier_rank(text)', 'public.subscription_counts(text, timestamptz, boolean)'] loop
    foreach r in array array['anon', 'authenticated'] loop
      assert not has_function_privilege(r, f, 'execute'), r || ' must not execute ' || f;
    end loop;
  end loop;
  assert not has_function_privilege('anon', 'public.admin_grant_plan(text, text, timestamptz, text)', 'execute'), 'anon must not execute admin_grant_plan';
  assert not has_function_privilege('anon', 'public.admin_list_plans()', 'execute'), 'anon must not execute admin_list_plans';
  assert not has_function_privilege('anon', 'public.admin_revoke_grant(uuid)', 'execute'), 'anon must not execute admin_revoke_grant';
  assert has_function_privilege('service_role', 'public.take_portfolio_snapshots()', 'execute'), 'service_role takes snapshots';
  foreach f in array array['public.my_plan()', 'public.get_leaderboard(integer)', 'public.payments_settings()', 'public.season_start()'] loop
    foreach r in array array['anon', 'authenticated'] loop
      assert has_function_privilege(r, f, 'execute'), r || ' should execute ' || f;
    end loop;
  end loop;
end $$;

set role service_role;
do $$ begin
  perform public.take_portfolio_snapshots();
end $$;
reset role;

rollback;
