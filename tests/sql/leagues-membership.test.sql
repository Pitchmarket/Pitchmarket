-- Private leagues (supabase-leagues-1.sql): create, join, leave, kick,
-- limits, invite codes, rejoining, ownership hand-over, branding, and who
-- can see what. Runs in one transaction and rolls back, so it leaves
-- nothing behind.
begin;

-- Players 1..30 (profiles come from the on_auth_user_created trigger).
-- Player 1 is on Pro, player 2 on Ultimate, players 20..23 on Pro (they
-- own the leagues for the 10-league limit); everyone else is free.
insert into auth.users (id, email)
select (lpad(n::text, 6, '0') || 'cc-0000-0000-0000-00000000000c')::uuid, 'p' || n || '@example.com'
from generate_series(1, 30) n;
create function pg_temp.u(n int) returns uuid language sql immutable as
$$ select (lpad(n::text, 6, '0') || 'cc-0000-0000-0000-00000000000c')::uuid $$;
insert into public.grants (user_id, tier) values
  (pg_temp.u(1), 'pro'), (pg_temp.u(2), 'ultimate'), (pg_temp.u(20), 'pro'),
  (pg_temp.u(21), 'pro'), (pg_temp.u(22), 'pro'), (pg_temp.u(23), 'pro');
create function pg_temp.as_player(n int) returns void language sql as
$$ select set_config('request.jwt.claims',
     json_build_object('sub', pg_temp.u(n), 'email', 'p' || n || '@example.com')::text, false) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return '(none)'; exception when others then return sqlerrm; end $$;

-- League ids, shared between blocks.
create temp table l (k text primary key, id bigint);
grant all on l to authenticated;

set role authenticated;

-- ---------- create_league ----------

do $$ declare e text; begin
  perform pg_temp.as_player(3);
  e := pg_temp.err($q$ select public.create_league('Free league', 'classic') $q$);
  assert e = 'Create leagues with Pro or Ultimate.', 'free create: ' || e;
end $$;

do $$ declare v_id bigint; e text; begin
  perform pg_temp.as_player(1);
  v_id := public.create_league('  Friends  ', 'classic');
  insert into l values ('friends', v_id);
  e := pg_temp.err($q$ select public.create_league('Rivals', 'h2h') $q$);
  assert e = 'Only Classic leagues can be created for now.', 'h2h create: ' || e;
  e := pg_temp.err($q$ select public.create_league('   ', 'classic') $q$);
  assert e = 'League names are 1–40 characters.', 'blank name: ' || e;
  e := pg_temp.err($q$ select public.create_league(repeat('x', 41), 'classic') $q$);
  assert e = 'League names are 1–40 characters.', 'long name: ' || e;
  perform public.create_league('Two', 'classic');
  perform public.create_league(repeat('y', 40), 'classic');
  e := pg_temp.err($q$ select public.create_league('Four', 'classic') $q$);
  assert e = 'You can own up to 3 leagues.', '4th owned league: ' || e;
end $$;

reset role;
do $$ declare r record; begin
  select * into r from public.leagues where id = (select id from l where k = 'friends');
  assert r.name = 'Friends', 'name trimmed: ' || r.name;
  assert r.type = 'classic' and r.owner_id = pg_temp.u(1), 'type and owner';
  assert r.invite_code ~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$', 'code shape: ' || r.invite_code;
  assert (select count(*) from public.league_members where league_id = r.id and user_id = pg_temp.u(1)
          and left_at is null and join_value = 2000) = 1, 'owner is the first member at their value';
  assert (select count(*) from public.leagues where owner_id = pg_temp.u(1)) = 3, 'three owned leagues';
end $$;
set role authenticated;

-- ---------- join_league ----------

do $$ declare v_id bigint := (select id from l where k = 'friends'); v_code text; e text; begin
  -- Members can't read the code from the table: the owner reads it from league_detail.
  perform pg_temp.as_player(1);
  v_code := public.league_detail(v_id) ->> 'invite_code';
  assert v_code is not null, 'owner sees the code';

  perform pg_temp.as_player(3);
  assert public.join_league('  ' || lower(v_code) || ' ') = v_id, 'join with lower case and spaces';
  e := pg_temp.err(format('select public.join_league(%L)', v_code));
  assert e = 'You''re already in this league.', 'second join: ' || e;
  e := pg_temp.err($q$ select public.join_league('ZZZZZZ1') $q$);
  assert e = 'No league with that code.', 'bad code: ' || e;
  e := pg_temp.err($q$ select public.join_league(null) $q$);
  assert e = 'No league with that code.', 'null code: ' || e;

  -- Players 4..21 fill it to 20.
  for i in 4..21 loop
    perform pg_temp.as_player(i);
    perform public.join_league(v_code);
  end loop;
  perform pg_temp.as_player(22);
  e := pg_temp.err(format('select public.join_league(%L)', v_code));
  assert e = 'This league is full (20 players).', '21st member: ' || e;
end $$;

reset role;
do $$ begin
  assert (select count(*) from public.league_members
          where league_id = (select id from l where k = 'friends') and left_at is null) = 20,
    'league holds exactly 20';
  -- The member count is taken under a lock on the league row.
  assert pg_get_functiondef('public.join_league(text)'::regprocedure) ~* 'for\s+update',
    'join_league locks the league row';
end $$;
set role authenticated;

-- 10-league limit: players 20..23 own 3 leagues each; player 24 joins 10.
do $$ declare v_codes text[] := '{}'; v_id bigint; e text; begin
  for i in 20..23 loop
    perform pg_temp.as_player(i);
    for j in 1..3 loop
      v_id := public.create_league('L' || i || '-' || j, 'classic');
      v_codes := v_codes || (public.league_detail(v_id) ->> 'invite_code');
    end loop;
  end loop;
  perform pg_temp.as_player(24);
  for j in 1..10 loop
    perform public.join_league(v_codes[j]);
  end loop;
  e := pg_temp.err(format('select public.join_league(%L)', v_codes[11]));
  assert e = 'You can be in up to 10 leagues.', '11th league: ' || e;
  assert (select count(*) from public.my_leagues()) = 10, 'my_leagues lists 10';
end $$;

-- Creating a league also counts towards the 10.
reset role;
insert into public.grants (user_id, tier) values (pg_temp.u(24), 'pro');
set role authenticated;
do $$ declare e text; begin
  perform pg_temp.as_player(24);
  e := pg_temp.err($q$ select public.create_league('Eleventh', 'classic') $q$);
  assert e = 'You can be in up to 10 leagues.', 'create as 11th league: ' || e;
end $$;

-- ---------- owner actions ----------

do $$ declare v_id bigint := (select id from l where k = 'friends'); v_m bigint; v_old text; v_new text; e text; begin
  perform pg_temp.as_player(3);
  v_m := (select (m ->> 'member_id')::bigint from jsonb_array_elements(public.league_detail(v_id) -> 'members') m
          where (m ->> 'is_owner')::boolean is not true limit 1);
  e := pg_temp.err(format('select public.kick_member(%s, %s)', v_id, v_m));
  assert e = 'Only the owner can do that.', 'member kicks: ' || e;
  e := pg_temp.err(format('select public.rename_league(%s, %L)', v_id, 'Mine'));
  assert e = 'Only the owner can do that.', 'member renames: ' || e;
  e := pg_temp.err(format('select public.regenerate_league_code(%s)', v_id));
  assert e = 'Only the owner can do that.', 'member regenerates: ' || e;
  e := pg_temp.err(format('select public.delete_league(%s)', v_id));
  assert e = 'Only the owner can do that.', 'member deletes: ' || e;
  e := pg_temp.err(format('select public.set_league_branding(%s, %L, %L)', v_id, 'sky', 'ball'));
  assert e = 'Only the owner can do that.', 'member brands: ' || e;

  perform pg_temp.as_player(1);
  v_old := public.league_detail(v_id) ->> 'invite_code';
  -- The owner can't kick themselves.
  v_m := (select (m ->> 'member_id')::bigint from jsonb_array_elements(public.league_detail(v_id) -> 'members') m
          where (m ->> 'is_owner')::boolean);
  e := pg_temp.err(format('select public.kick_member(%s, %s)', v_id, v_m));
  assert e = 'Use Leave or Delete for yourself.', 'owner kicks self: ' || e;

  perform public.rename_league(v_id, ' Friends FC ');
  assert public.league_detail(v_id) ->> 'name' = 'Friends FC', 'renamed';
  e := pg_temp.err(format('select public.rename_league(%s, %L)', v_id, ''));
  assert e = 'League names are 1–40 characters.', 'rename blank: ' || e;
  v_new := public.regenerate_league_code(v_id);
  assert v_new ~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$' and v_new = public.league_detail(v_id) ->> 'invite_code',
    'regenerated code';
  v_old := v_new;
end $$;

-- Kick player 3: left_at set, kicked, code changes; the old code no longer
-- works; rejoining with the new code (no season row yet) keeps the first
-- stint's join value.
reset role;
update public.profiles set coin_balance = 2500 where id = pg_temp.u(3);
set role authenticated;
do $$ declare v_id bigint := (select id from l where k = 'friends'); v_m bigint; v_old text; v_new text; e text; begin
  perform pg_temp.as_player(3);
  v_m := (select (m ->> 'member_id')::bigint from jsonb_array_elements(public.league_detail(v_id) -> 'members') m
          where m ->> 'display_name' = (select display_name from public.profiles where id = pg_temp.u(3)));
  assert v_m is not null, 'player 3 listed as a member';
  perform pg_temp.as_player(1);
  v_old := public.league_detail(v_id) ->> 'invite_code';
  perform public.kick_member(v_id, v_m);
  v_new := public.league_detail(v_id) ->> 'invite_code';
  assert v_new <> v_old, 'kicking changes the code';
  assert jsonb_array_length(public.league_detail(v_id) -> 'members') = 19, '19 after the kick';
  e := pg_temp.err(format('select public.kick_member(%s, %s)', v_id, v_m));
  assert e <> '(none)', 'kicking a former stint again is refused';

  perform pg_temp.as_player(3);
  e := pg_temp.err(format('select public.league_detail(%s)', v_id));
  assert e = 'You''re not in this league.', 'kicked player sees nothing: ' || e;
  e := pg_temp.err(format('select public.join_league(%L)', v_old));
  assert e = 'No league with that code.', 'old code after kick: ' || e;
  assert public.join_league(v_new) = v_id, 'rejoin with the new code';
end $$;

reset role;
do $$ declare v_id bigint := (select id from l where k = 'friends'); begin
  assert (select count(*) from public.league_members where league_id = v_id and user_id = pg_temp.u(3)) = 2, 'two stints';
  assert (select left_at is not null and kicked from public.league_members
          where league_id = v_id and user_id = pg_temp.u(3) order by id limit 1), 'first stint ended by a kick';
  assert (select join_value from public.league_members
          where league_id = v_id and user_id = pg_temp.u(3) and left_at is null) = 2000,
    'rejoin without a season row keeps the first join value';
end $$;

-- ---------- rejoining in the same season ----------

insert into public.site_settings (key, value) values ('season', jsonb_build_object('start', now() - interval '1 day'))
on conflict (key) do update set value = excluded.value;
set role authenticated;

do $$ declare v_id bigint; v_code text; begin
  perform pg_temp.as_player(2);
  v_id := public.create_league('Ultimates', 'classic');
  insert into l values ('ult', v_id);
  v_code := public.league_detail(v_id) ->> 'invite_code';
  perform pg_temp.as_player(6);
  perform public.join_league(v_code);
  perform pg_temp.as_player(5);
  perform public.join_league(v_code);
  perform pg_temp.as_player(7);
  perform public.join_league(v_code);
end $$;

reset role;
update public.profiles set coin_balance = 3000 where id = pg_temp.u(5);
-- Player 7's first stint began before the season started.
update public.league_members set joined_at = now() - interval '10 days', join_value = 1234
  where league_id = (select id from l where k = 'ult') and user_id = pg_temp.u(7);
update public.profiles set coin_balance = 2600 where id = pg_temp.u(7);
set role authenticated;

do $$ declare v_id bigint := (select id from l where k = 'ult'); v_code text; begin
  perform pg_temp.as_player(5);
  perform public.leave_league(v_id);
  perform pg_temp.as_player(7);
  perform public.leave_league(v_id);
  perform pg_temp.as_player(2);
  v_code := public.league_detail(v_id) ->> 'invite_code';
  perform pg_temp.as_player(5);
  perform public.join_league(v_code);
  perform pg_temp.as_player(7);
  perform public.join_league(v_code);
end $$;

reset role;
do $$ declare v_id bigint := (select id from l where k = 'ult'); begin
  assert (select join_value from public.league_members where league_id = v_id and user_id = pg_temp.u(5) and left_at is null) = 2000,
    'same-season rejoin keeps the first stint''s join value';
  assert (select join_value from public.league_members where league_id = v_id and user_id = pg_temp.u(7) and left_at is null) = 2600,
    'rejoin after a stint from before the season uses the live value';
end $$;
set role authenticated;

-- ---------- branding ----------

do $$ declare e text; v_ult bigint := (select id from l where k = 'ult'); begin
  perform pg_temp.as_player(1);
  e := pg_temp.err(format('select public.set_league_branding(%s, %L, %L)', (select id from l where k = 'friends'), 'sky', 'ball'));
  assert e = 'League branding comes with Ultimate.', 'pro owner brands: ' || e;

  perform pg_temp.as_player(2);
  e := pg_temp.err(format('select public.set_league_branding(%s, %L, %L)', v_ult, 'pink', 'ball'));
  assert e = 'Pick a colour and emblem from the list.', 'unknown colour: ' || e;
  e := pg_temp.err(format('select public.set_league_branding(%s, %L, %L)', v_ult, 'sky', 'crest'));
  assert e = 'Pick a colour and emblem from the list.', 'unknown emblem: ' || e;
  perform public.set_league_branding(v_ult, 'sky', 'trophy');
  assert (select colour = 'sky' and emblem = 'trophy' from public.my_leagues() where league_id = v_ult), 'my_leagues shows branding';
  assert public.league_detail(v_ult) ->> 'colour' = 'sky', 'league_detail shows branding';
  perform pg_temp.as_player(6);
  assert (select colour = 'sky' from public.my_leagues() where league_id = v_ult), 'members see branding too';
end $$;

reset role;
delete from public.grants where user_id = pg_temp.u(2);
set role authenticated;

do $$ declare v_ult bigint := (select id from l where k = 'ult'); begin
  perform pg_temp.as_player(2);
  assert (select colour is null and emblem is null from public.my_leagues() where league_id = v_ult),
    'branding hidden once the owner is off Ultimate';
  assert public.league_detail(v_ult) ->> 'colour' is null, 'league_detail hides branding too';
end $$;

reset role;
insert into public.grants (user_id, tier) values (pg_temp.u(2), 'ultimate');
set role authenticated;
do $$ declare v_ult bigint := (select id from l where k = 'ult'); begin
  perform pg_temp.as_player(2);
  perform public.set_league_branding(v_ult, null, null);
  assert (select colour is null and emblem is null from public.my_leagues() where league_id = v_ult), 'nulls clear branding';
end $$;

-- ---------- leaving ----------

-- Owner (2) leaves: ownership passes to the earliest current stint, which
-- is player 6 (player 5's and 7's current stints began later).
do $$ declare v_ult bigint := (select id from l where k = 'ult'); r record; begin
  perform pg_temp.as_player(2);
  perform public.leave_league(v_ult);
  perform pg_temp.as_player(6);
  assert (public.league_detail(v_ult) ->> 'is_owner')::boolean, 'ownership passed to player 6';
  assert public.league_detail(v_ult) ->> 'invite_code' is not null, 'new owner sees the code';
  select * into r from public.my_leagues() where league_id = v_ult;
  assert r.is_owner and r.member_count = 3, 'my_leagues for the new owner';
  perform pg_temp.as_player(2);
  assert not exists (select 1 from public.my_leagues() where league_id = v_ult), 'old owner no longer lists it';

  perform pg_temp.as_player(6);  perform public.leave_league(v_ult);
  perform pg_temp.as_player(5);  perform public.leave_league(v_ult);
  perform pg_temp.as_player(7);  perform public.leave_league(v_ult);
end $$;

reset role;
do $$ begin
  assert not exists (select 1 from public.leagues where id = (select id from l where k = 'ult')), 'last member leaving deletes the league';
  assert not exists (select 1 from public.league_members where league_id = (select id from l where k = 'ult')), 'and its members';
end $$;
set role authenticated;

do $$ declare e text; v_id bigint; begin
  perform pg_temp.as_player(25);
  e := pg_temp.err(format('select public.leave_league(%s)', (select id from l where k = 'friends')));
  assert e = 'You''re not in this league.', 'non-member leaves: ' || e;
  -- The owner can delete their league.
  perform pg_temp.as_player(21);
  v_id := (select league_id from public.my_leagues() where name = 'L21-1');
  perform public.delete_league(v_id);
  assert not exists (select 1 from public.my_leagues() where league_id = v_id), 'deleted league gone';
end $$;

-- ---------- league_detail ----------

do $$ declare v_id bigint := (select id from l where k = 'friends'); d jsonb; e text; begin
  perform pg_temp.as_player(22);
  e := pg_temp.err(format('select public.league_detail(%s)', v_id));
  assert e = 'You''re not in this league.', 'non-member detail: ' || e;
  e := pg_temp.err('select public.league_detail(999999)');
  assert e = 'You''re not in this league.', 'missing league detail: ' || e;

  perform pg_temp.as_player(4);
  d := public.league_detail(v_id);
  assert d ? 'invite_code' and d -> 'invite_code' = 'null'::jsonb, 'member sees no code: ' || d::text;
  assert not (d ->> 'is_owner')::boolean, 'member is not owner';
  assert (d ->> 'season_started')::boolean, 'season started';
  assert d ->> 'type' = 'classic', 'type';
  assert jsonb_array_length(d -> 'members') = 20, '20 members listed';
  assert (select count(*) from jsonb_array_elements(d -> 'members') m where (m ->> 'is_owner')::boolean
          and m ->> 'tier' = 'pro') = 1, 'one owner, on pro';
  assert d::text !~ '@example.com' and d::text !~ '0000-00000000000c', 'no emails or user ids reach the page';
end $$;

-- ---------- access ----------

reset role;
set role anon;
do $$ declare n bigint; begin
  begin
    select count(*) into n from public.leagues;
    assert n = 0, 'anon sees no leagues';
  exception when insufficient_privilege then null;
  end;
  begin
    select count(*) into n from public.league_members;
    assert n = 0, 'anon sees no members';
  exception when insufficient_privilege then null;
  end;
end $$;
set role authenticated;
do $$ declare n bigint; begin
  perform pg_temp.as_player(1);
  begin
    select count(*) into n from public.leagues;
    assert n = 0, 'players read no league rows directly';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

do $$ begin
  assert not has_function_privilege('anon', 'public.create_league(text,text)', 'execute'), 'anon cannot create';
  assert has_function_privilege('authenticated', 'public.create_league(text,text)', 'execute'), 'players can create';
  assert not has_function_privilege('authenticated', 'public.player_value(uuid)', 'execute'), 'player_value is internal';
  assert not has_function_privilege('anon', 'public.player_value(uuid)', 'execute'), 'player_value is internal (anon)';
  assert not has_function_privilege('anon', 'public.join_league(text)', 'execute'), 'anon cannot join';
  assert not has_function_privilege('anon', 'public.league_detail(bigint)', 'execute'), 'anon cannot read a league';
  assert not has_function_privilege('anon', 'public.my_leagues()', 'execute'), 'anon cannot list leagues';
end $$;

rollback;
