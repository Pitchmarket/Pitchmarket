-- PitchMarket private leagues, part 2a: tables and membership, 27 Nov 2026.
-- Run once in the Supabase SQL Editor (paste all of it, click Run), after
-- supabase-pro-1.sql. Safe to run more than once. supabase-schema.sql
-- already includes it.
--
-- What changes:
--   * New private table leagues: name, type (classic or h2h; only classic
--     can be created for now), owner, 6-character invite code and the
--     Ultimate owner's branding (colour and emblem keys).
--   * New private table league_members: one row per stint (joined_at to
--     left_at), with the player's value when the stint began (join_value)
--     and whether it ended with a kick. Rejoining in the same season reuses
--     the join value of that season's first stint.
--   * Neither table can be read or written directly by players; everything
--     goes through the functions below, which check membership and
--     ownership.
--   * create_league (Pro or Ultimate), join_league (anyone, by code),
--     leave_league, kick_member, delete_league, rename_league,
--     regenerate_league_code, set_league_branding (Ultimate owners),
--     my_leagues and league_detail.
--   * Limits: own up to 3 leagues, be in up to 10, 20 players per league.
--     If the owner leaves, the longest-standing current member takes over;
--     the last member leaving deletes the league.
--   * New private tables matchweeks (one row per closed Monday-Sunday week,
--     scored or void) and player_week_scores (each player's % change over
--     the week, from the nightly portfolio snapshots), filled once by
--     close_matchweeks from the nightly backup and never changed after.
--   * league_classic_table (% gained since joining this season) and
--     league_player_of_week (latest weeks' top scorers among the members
--     who were in the league for the whole week), for members only.

begin;

-- ---------- Tables ----------

create table if not exists public.leagues (
  id           bigserial primary key,
  name         text not null,
  type         text not null check (type in ('classic', 'h2h')),
  owner_id     uuid not null references auth.users(id) on delete cascade,
  invite_code  text not null unique,
  colour       text,                -- a key from set_league_branding's list
  emblem       text,                -- likewise
  created_at   timestamptz default now()
);
create index if not exists leagues_owner on public.leagues (owner_id);
alter table public.leagues enable row level security;

-- One row per stint: leaving and rejoining adds a new row.
create table if not exists public.league_members (
  id          bigserial primary key,
  league_id   bigint references public.leagues(id) on delete cascade,
  user_id     uuid references auth.users(id) on delete cascade,
  joined_at   timestamptz not null default now(),
  left_at     timestamptz,
  join_value  numeric not null,
  kicked      boolean not null default false
);
create unique index if not exists league_members_current
  on public.league_members (league_id, user_id) where left_at is null;
create index if not exists league_members_user on public.league_members (user_id) where left_at is null;
alter table public.league_members enable row level security;

-- One row per closed matchweek (Monday to Sunday, UK time), keyed by its
-- Sunday. void: a Sunday's snapshots were missing, so nobody scored.
create table if not exists public.matchweeks (
  week_end      date primary key,
  season_start  timestamptz not null,
  status        text not null check (status in ('scored', 'void')),
  closed_at     timestamptz not null default now()
);
alter table public.matchweeks enable row level security;

-- Each player's week score (% change in value over the week), stored once
-- when the week closes.
create table if not exists public.player_week_scores (
  week_end  date references public.matchweeks(week_end) on delete cascade,
  user_id   uuid references auth.users(id) on delete cascade,
  pct       numeric(10,2) not null,
  primary key (week_end, user_id)
);
alter table public.player_week_scores enable row level security;

-- No policies: only the functions below read or write these tables.
revoke all on public.leagues, public.league_members, public.matchweeks, public.player_week_scores
  from anon, authenticated;
revoke all on sequence public.leagues_id_seq, public.league_members_id_seq from anon, authenticated;

-- ---------- Helpers (not callable by players) ----------

-- A player's value: coins plus holdings at current prices, as on the
-- leaderboard.
create or replace function public.player_value(p_user uuid)
 returns numeric
 language sql
 stable
 security definer
 set search_path = public
as $function$
  select p.coin_balance + coalesce(sum(h.shares * t.price), 0)
  from profiles p
  left join holdings h on h.user_id = p.id
  left join teams t on t.id = h.team_id
  where p.id = p_user
  group by p.id, p.coin_balance;
$function$;

-- A fresh, unused invite code: 6 characters from an alphabet without
-- look-alikes (no 0/O, 1/I). Random bytes come from gen_random_uuid, whose
-- first 6 bytes are fully random; 256 is a multiple of 32, so every
-- character is equally likely.
create or replace function public.new_league_code()
 returns text
 language plpgsql
 volatile
 security definer
 set search_path = public
as $function$
declare
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_bytes bytea;
  v_code text;
begin
  loop
    v_bytes := uuid_send(gen_random_uuid());
    v_code := '';
    for i in 0..5 loop
      v_code := v_code || substr(v_alphabet, get_byte(v_bytes, i) % 32 + 1, 1);
    end loop;
    exit when not exists (select 1 from leagues where invite_code = v_code);
  end loop;
  return v_code;
end;
$function$;

-- The caller's league, locked, for an owner-only action.
create or replace function public.league_for_owner(p_league bigint)
 returns public.leagues
 language plpgsql
 volatile
 security definer
 set search_path = public
as $function$
declare
  v_uid uuid := auth.uid();
  v_league leagues;
begin
  if v_uid is null then raise exception 'Sign in to use leagues.'; end if;
  select * into v_league from leagues where id = p_league for update;
  if not found or not exists (select 1 from league_members
      where league_id = p_league and user_id = v_uid and left_at is null) then
    raise exception 'You''re not in this league.';
  end if;
  if v_league.owner_id <> v_uid then raise exception 'Only the owner can do that.'; end if;
  return v_league;
end;
$function$;

-- A league name with control characters (newlines, tabs, ...) removed and
-- spaces trimmed, or an error if that isn't 1–40 characters.
create or replace function public.league_name_ok(p_name text)
 returns text
 language plpgsql
 immutable
 set search_path = public
as $function$
declare
  v_name text := btrim(regexp_replace(coalesce(p_name, ''), '[[:cntrl:]]', '', 'g'));
begin
  if char_length(v_name) not between 1 and 40 then
    raise exception 'League names are 1–40 characters.';
  end if;
  return v_name;
end;
$function$;

-- A player's join value in a league this season (used by join_league and
-- the Classic table): the join value of their first stint in the league
-- this season, where a stint that was running when the season started
-- counts as 2000 (the reset puts everyone on 2000). So leaving and
-- rejoining never resets a player's percentage. Null if they have no stint
-- this season.
create or replace function public.league_season_join_value(p_league bigint, p_user uuid, p_start timestamptz)
 returns numeric
 language sql
 stable
 security definer
 set search_path = public
as $function$
  select case when m.joined_at < p_start then 2000 else m.join_value end
  from league_members m
  where m.league_id = p_league and m.user_id = p_user
    and (m.left_at is null or m.left_at > p_start)
  order by m.joined_at, m.id
  limit 1;
$function$;

-- ---------- Membership ----------

create or replace function public.create_league(p_name text, p_type text)
 returns bigint
 language plpgsql
 volatile
 security definer
 set search_path = public
as $function$
declare
  v_uid uuid := auth.uid();
  v_name text;
  v_id bigint;
begin
  if v_uid is null then raise exception 'Sign in to use leagues.'; end if;
  if user_tier(v_uid) not in ('pro', 'ultimate') then
    raise exception 'Create leagues with Pro or Ultimate.';
  end if;
  if p_type is distinct from 'classic' then
    raise exception 'Only Classic leagues can be created for now.';
  end if;
  v_name := league_name_ok(p_name);
  -- One league action at a time per player, so limits can't be raced.
  perform pg_advisory_xact_lock(hashtextextended('league-player:' || v_uid::text, 0));
  if (select count(*) from leagues where owner_id = v_uid) >= 3 then
    raise exception 'You can own up to 3 leagues.';
  end if;
  if (select count(*) from league_members where user_id = v_uid and left_at is null) >= 10 then
    raise exception 'You can be in up to 10 leagues.';
  end if;

  insert into leagues (name, type, owner_id, invite_code)
  values (v_name, 'classic', v_uid, new_league_code())
  returning id into v_id;
  insert into league_members (league_id, user_id, join_value)
  values (v_id, v_uid, coalesce(player_value(v_uid), 0));
  return v_id;
end;
$function$;

create or replace function public.join_league(p_code text)
 returns bigint
 language plpgsql
 volatile
 security definer
 set search_path = public
as $function$
declare
  v_uid uuid := auth.uid();
  v_league leagues;
  v_start timestamptz := season_start();
  v_value numeric;
begin
  if v_uid is null then raise exception 'Sign in to use leagues.'; end if;
  -- Lock the league row first: two players taking the last place at the
  -- same moment are counted one after the other.
  select * into v_league from leagues
    where invite_code = upper(btrim(coalesce(p_code, ''), E' \t\r\n'))
    for update;
  if not found then raise exception 'No league with that code.'; end if;
  if exists (select 1 from league_members
             where league_id = v_league.id and user_id = v_uid and left_at is null) then
    raise exception 'You''re already in this league.';
  end if;
  if (select count(*) from league_members where league_id = v_league.id and left_at is null) >= 20 then
    raise exception 'This league is full (20 players).';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('league-player:' || v_uid::text, 0));
  if (select count(*) from league_members where user_id = v_uid and left_at is null) >= 10 then
    raise exception 'You can be in up to 10 leagues.';
  end if;

  -- Rejoining in the same season keeps that season's first join value,
  -- the same value the Classic table uses (2000 for a stint that was
  -- running when the season started). Before a season start, any earlier
  -- stint counts.
  if v_start is not null and now() >= v_start then
    v_value := league_season_join_value(v_league.id, v_uid, v_start);
  else
    select join_value into v_value
    from league_members
    where league_id = v_league.id and user_id = v_uid
    order by joined_at, id
    limit 1;
  end if;
  if v_value is null then v_value := coalesce(player_value(v_uid), 0); end if;

  insert into league_members (league_id, user_id, join_value)
  values (v_league.id, v_uid, v_value);
  return v_league.id;
end;
$function$;

create or replace function public.leave_league(p_league bigint)
 returns void
 language plpgsql
 volatile
 security definer
 set search_path = public
as $function$
declare
  v_uid uuid := auth.uid();
  v_league leagues;
  v_cand uuid;
  v_first uuid;
  v_next uuid;
begin
  if v_uid is null then raise exception 'Sign in to use leagues.'; end if;
  select * into v_league from leagues where id = p_league for update;
  if not found then raise exception 'You''re not in this league.'; end if;
  update league_members set left_at = now()
    where league_id = p_league and user_id = v_uid and left_at is null;
  if not found then raise exception 'You''re not in this league.'; end if;

  select user_id into v_first from league_members
    where league_id = p_league and left_at is null
    order by joined_at, id
    limit 1;
  if v_first is null then
    -- The last member left.
    delete from leagues where id = p_league;
    return;
  end if;
  if v_league.owner_id <> v_uid then return; end if;

  -- The owner left: the league passes to the earliest current member who
  -- owns fewer than 3 leagues, or failing that to the earliest current
  -- member. Each candidate's player lock is taken after the league row
  -- lock (the order join_league uses) and the count re-checked under it.
  for v_cand in
    select user_id from league_members
    where league_id = p_league and left_at is null
    order by joined_at, id
  loop
    if (select count(*) from leagues where owner_id = v_cand) < 3 then
      perform pg_advisory_xact_lock(hashtextextended('league-player:' || v_cand::text, 0));
      if (select count(*) from leagues where owner_id = v_cand) < 3 then
        v_next := v_cand;
        exit;
      end if;
    end if;
  end loop;
  update leagues set owner_id = coalesce(v_next, v_first) where id = p_league;
end;
$function$;

-- p_member is a league_members id (from league_detail).
create or replace function public.kick_member(p_league bigint, p_member bigint)
 returns void
 language plpgsql
 volatile
 security definer
 set search_path = public
as $function$
declare
  v_league leagues := league_for_owner(p_league);
  v_user uuid;
begin
  select user_id into v_user from league_members
    where id = p_member and league_id = p_league and left_at is null;
  if not found then raise exception 'That player isn''t in this league.'; end if;
  if v_user = v_league.owner_id then raise exception 'Use Leave or Delete for yourself.'; end if;
  update league_members set left_at = now(), kicked = true where id = p_member;
  -- A new code, so the kicked player can't simply rejoin.
  update leagues set invite_code = new_league_code() where id = p_league;
end;
$function$;

create or replace function public.delete_league(p_league bigint)
 returns void
 language plpgsql
 volatile
 security definer
 set search_path = public
as $function$
begin
  perform league_for_owner(p_league);
  delete from leagues where id = p_league;
end;
$function$;

create or replace function public.rename_league(p_league bigint, p_name text)
 returns void
 language plpgsql
 volatile
 security definer
 set search_path = public
as $function$
declare
  v_name text;
begin
  perform league_for_owner(p_league);
  v_name := league_name_ok(p_name);
  update leagues set name = v_name where id = p_league;
end;
$function$;

create or replace function public.regenerate_league_code(p_league bigint)
 returns text
 language plpgsql
 volatile
 security definer
 set search_path = public
as $function$
declare
  v_code text;
begin
  perform league_for_owner(p_league);
  v_code := new_league_code();
  update leagues set invite_code = v_code where id = p_league;
  return v_code;
end;
$function$;

-- Colour and emblem keys; the page maps them to colours and icons. Nulls
-- clear them.
create or replace function public.set_league_branding(p_league bigint, p_colour text, p_emblem text)
 returns void
 language plpgsql
 volatile
 security definer
 set search_path = public
as $function$
declare
  v_league leagues := league_for_owner(p_league);
begin
  if user_tier(v_league.owner_id) <> 'ultimate' then
    raise exception 'League branding comes with Ultimate.';
  end if;
  if (p_colour is not null and p_colour not in
        ('claret', 'sky', 'emerald', 'gold', 'crimson', 'navy', 'orange', 'purple'))
     or (p_emblem is not null and p_emblem not in
        ('ball', 'boot', 'whistle', 'trophy', 'net', 'cones', 'flag', 'gloves', 'shirt', 'star', 'crown', 'bolt')) then
    raise exception 'Pick a colour and emblem from the list.';
  end if;
  update leagues set colour = p_colour, emblem = p_emblem where id = p_league;
end;
$function$;

-- ---------- Reading ----------

-- The caller's current leagues. Branding shows only while the owner is on
-- Ultimate.
create or replace function public.my_leagues()
 returns table(league_id bigint, name text, type text, is_owner boolean, member_count integer,
               colour text, emblem text)
 language sql
 stable
 security definer
 set search_path = public
as $function$
  select l.id, l.name, l.type, l.owner_id = m.user_id,
         (select count(*)::integer from league_members c where c.league_id = l.id and c.left_at is null),
         case when b.branded then l.colour end,
         case when b.branded then l.emblem end
  from league_members m
  join leagues l on l.id = m.league_id
  cross join lateral (select user_tier(l.owner_id) = 'ultimate' as branded) b
  where m.user_id = auth.uid() and m.left_at is null
  order by m.joined_at, m.id;
$function$;

-- One league for a member: its settings (the invite code only for the
-- owner) and current members. No emails or user ids.
create or replace function public.league_detail(p_league bigint)
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path = public
as $function$
declare
  v_uid uuid := auth.uid();
  v_league leagues;
  v_branded boolean;
  v_start timestamptz := season_start();
begin
  select * into v_league from leagues where id = p_league;
  if v_uid is null or not found or not exists (select 1 from league_members
      where league_id = p_league and user_id = v_uid and left_at is null) then
    raise exception 'You''re not in this league.';
  end if;
  v_branded := user_tier(v_league.owner_id) = 'ultimate';
  return jsonb_build_object(
    'id', v_league.id,
    'name', v_league.name,
    'type', v_league.type,
    'is_owner', v_league.owner_id = v_uid,
    'invite_code', case when v_league.owner_id = v_uid then v_league.invite_code end,
    'colour', case when v_branded then v_league.colour end,
    'emblem', case when v_branded then v_league.emblem end,
    'season_started', v_start is not null and v_start <= now(),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
               'member_id', m.id,
               'display_name', coalesce(p.display_name, 'Trader'),
               'tier', user_tier(m.user_id),
               'is_owner', m.user_id = v_league.owner_id,
               'joined_at', m.joined_at)
             order by m.joined_at, m.id)
      from league_members m
      left join profiles p on p.id = m.user_id
      where m.league_id = p_league and m.left_at is null), '[]'::jsonb));
end;
$function$;

-- ---------- Weekly scores ----------

-- Closes every finished matchweek not yet closed, oldest first, and returns
-- how many it closed. Run by the nightly backup (~03:23 UTC) after the
-- snapshot step succeeds. "Today" is the trading day the snapshots use
-- (the UK date 6 hours ago), and weeks up to and including that day's
-- Sunday close, so Monday's run (trading day Sunday) closes the week just
-- after saving Sunday's snapshot. A week counts if its previous Sunday is on or after the season start
-- date; it's scored if both its Sunday and the previous Sunday have
-- snapshots, otherwise void. Does nothing before a season start. p_today
-- (a trading day) is for tests only.
create or replace function public.close_matchweeks(p_today date default null)
 returns integer
 language plpgsql
 volatile
 security definer
 set search_path = public
as $function$
declare
  v_start timestamptz := season_start();
  v_today date := coalesce(p_today, ((now() at time zone 'Europe/London') - interval '6 hours')::date);
  v_first date;
  v_week date;
  v_closed integer := 0;
begin
  if v_start is null then return 0; end if;
  -- One run at a time.
  perform pg_advisory_xact_lock(hashtextextended('close-matchweeks', 0));
  -- The first Sunday at least 7 days after the season start date.
  -- Weeks are closed for the season recorded now, so recording the next
  -- season's start early stops the current season's remaining weeks
  -- closing: record it when you run the reset.
  v_first := (v_start at time zone 'Europe/London')::date + 7;
  v_first := v_first + (7 - extract(isodow from v_first)::integer) % 7;

  for v_week in
    -- <= is safe: the backup calls this only after this run's snapshots
    -- (stamped with this trading day) were saved.
    select d::date from generate_series(v_first, v_today, interval '7 days') d
    where not exists (select 1 from matchweeks w where w.week_end = d::date)
    order by 1
  loop
    if exists (select 1 from portfolio_snapshots where day = v_week)
       and exists (select 1 from portfolio_snapshots where day = v_week - 7) then
      insert into matchweeks (week_end, season_start, status) values (v_week, v_start, 'scored');
      insert into player_week_scores (week_end, user_id, pct)
      select v_week, e.user_id,
             case when b.value = 0 then 0
                  -- Kept within numeric(10,2), so one odd value can't stop
                  -- every later week from closing.
                  else least(greatest(round((e.value / b.value - 1) * 100, 2), -99999999.99), 99999999.99)
             end
      from portfolio_snapshots b
      join portfolio_snapshots e on e.user_id = b.user_id and e.day = v_week
      where b.day = v_week - 7;
    else
      insert into matchweeks (week_end, season_start, status) values (v_week, v_start, 'void');
    end if;
    v_closed := v_closed + 1;
  end loop;
  return v_closed;
end;
$function$;

-- A league's Classic table: current members ranked by % gained since they
-- joined (this season); ties share a rank. Empty until the season has
-- started (as league_detail's season_started).
create or replace function public.league_classic_table(p_league bigint)
 returns table(rank integer, member_id bigint, display_name text, tier text, pct numeric)
 language plpgsql
 stable
 security definer
 set search_path = public
as $function$
#variable_conflict use_column
declare
  v_uid uuid := auth.uid();
  v_start timestamptz := season_start();
begin
  if v_uid is null then raise exception 'Sign in to use leagues.'; end if;
  if not exists (select 1 from league_members
      where league_id = p_league and user_id = v_uid and left_at is null) then
    raise exception 'You''re not in this league.';
  end if;
  if v_start is null or v_start > now() then return; end if;
  return query
  select (rank() over (order by x.pct desc))::integer, x.id, x.display_name, x.tier, x.pct
  from (
    select m.id, coalesce(p.display_name, 'Trader') as display_name, user_tier(m.user_id) as tier,
           case when coalesce(j.v, 0) = 0 then 0::numeric
                else round((coalesce(player_value(m.user_id), 0) / j.v - 1) * 100, 2) end as pct
    from league_members m
    left join profiles p on p.id = m.user_id
    cross join lateral (select league_season_join_value(p_league, m.user_id, v_start) as v) j
    where m.league_id = p_league and m.left_at is null
  ) x
  order by x.pct desc, x.display_name, x.id;
end;
$function$;

-- A league's Player of the week for its latest p_limit closed weeks this
-- season, newest first: the highest week score among members who count
-- that week (in the league from before its Monday 00:00 to after its Sunday
-- 23:59:59, UK time). Ties share it. A void week has no winners.
create or replace function public.league_player_of_week(p_league bigint, p_limit integer default 5)
 returns table(week_end date, status text, winners text[], pct numeric)
 language plpgsql
 stable
 security definer
 set search_path = public
as $function$
#variable_conflict use_column
declare
  v_uid uuid := auth.uid();
  v_start timestamptz := season_start();
begin
  if v_uid is null then raise exception 'Sign in to use leagues.'; end if;
  if not exists (select 1 from league_members
      where league_id = p_league and user_id = v_uid and left_at is null) then
    raise exception 'You''re not in this league.';
  end if;
  if v_start is null then return; end if;
  return query
  with w as (
    select mw.week_end, mw.status
    from matchweeks mw
    where mw.season_start = v_start
    order by mw.week_end desc
    limit greatest(coalesce(p_limit, 5), 0)
  ), s as (
    select w.week_end, coalesce(p.display_name, 'Trader') as name, sc.pct,
           rank() over (partition by w.week_end order by sc.pct desc) as r
    from w
    join player_week_scores sc on sc.week_end = w.week_end
    join league_members m on m.league_id = p_league and m.user_id = sc.user_id
      and m.joined_at < ((w.week_end - 6) + time '00:00') at time zone 'Europe/London'
      and (m.left_at is null
           or m.left_at > (w.week_end + time '23:59:59.999') at time zone 'Europe/London')
    left join profiles p on p.id = m.user_id
  )
  select w.week_end, w.status,
         coalesce(array_agg(s.name order by s.name) filter (where s.r = 1), '{}'::text[]),
         max(s.pct) filter (where s.r = 1)
  from w
  left join s on s.week_end = w.week_end
  group by w.week_end, w.status
  order by w.week_end desc;
end;
$function$;

-- ---------- Who can call what ----------

revoke execute on function public.player_value(uuid) from public, anon, authenticated;
revoke execute on function public.new_league_code() from public, anon, authenticated;
revoke execute on function public.league_for_owner(bigint) from public, anon, authenticated;
revoke execute on function public.league_name_ok(text) from public, anon, authenticated;

revoke execute on function public.create_league(text, text) from public, anon;
revoke execute on function public.join_league(text) from public, anon;
revoke execute on function public.leave_league(bigint) from public, anon;
revoke execute on function public.kick_member(bigint, bigint) from public, anon;
revoke execute on function public.delete_league(bigint) from public, anon;
revoke execute on function public.rename_league(bigint, text) from public, anon;
revoke execute on function public.regenerate_league_code(bigint) from public, anon;
revoke execute on function public.set_league_branding(bigint, text, text) from public, anon;
revoke execute on function public.my_leagues() from public, anon;
revoke execute on function public.league_detail(bigint) from public, anon;
grant execute on function public.create_league(text, text) to authenticated;
grant execute on function public.join_league(text) to authenticated;
grant execute on function public.leave_league(bigint) to authenticated;
grant execute on function public.kick_member(bigint, bigint) to authenticated;
grant execute on function public.delete_league(bigint) to authenticated;
grant execute on function public.rename_league(bigint, text) to authenticated;
grant execute on function public.regenerate_league_code(bigint) to authenticated;
grant execute on function public.set_league_branding(bigint, text, text) to authenticated;
grant execute on function public.my_leagues() to authenticated;
grant execute on function public.league_detail(bigint) to authenticated;

revoke execute on function public.league_season_join_value(bigint, uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.close_matchweeks(date) from public, anon, authenticated;
grant execute on function public.close_matchweeks(date) to service_role;
revoke execute on function public.league_classic_table(bigint) from public, anon;
revoke execute on function public.league_player_of_week(bigint, integer) from public, anon;
grant execute on function public.league_classic_table(bigint) to authenticated;
grant execute on function public.league_player_of_week(bigint, integer) to authenticated;

commit;
