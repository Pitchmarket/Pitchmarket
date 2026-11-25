-- PitchMarket database schema (Supabase / Postgres).
--
-- Exported from the live project on 18 Nov 2026, with
-- supabase-security-fixes.sql, supabase-price-lag-lock.sql,
-- supabase-trade-cooldown.sql, supabase-names-and-leaderboard.sql,
-- supabase-daily-kickabout.sql, supabase-kickabout-2.sql and
-- supabase-squads.sql applied.
-- Running this on an empty Supabase project rebuilds the backend:
-- tables, access rules (RLS), functions and triggers. It creates no
-- data: no teams, settings or players.
--
-- Keep this file in step with the live database. When you change
-- something in the Supabase dashboard, change it here in the same pull
-- request.
--
-- The admin account is identified by email in the policies and in
-- approve_match_event below. Search for pitchmarketadmin@gmail.com to
-- change it.

-- =====================================================================
-- Tables
-- =====================================================================

create table public.teams (
  id            uuid primary key default gen_random_uuid(),
  league        text not null,
  league_label  text not null,
  name          text not null,
  tier          text not null,
  price         numeric not null default 10,
  chg           numeric not null default 0,
  updated_at    timestamptz not null default now(),
  league_order  integer not null default 999
);

create table public.profiles (
  id              uuid primary key references auth.users(id) on delete cascade,
  email           text,
  display_name    text,
  coin_balance    numeric not null default 2000,
  created_at      timestamptz not null default now(),
  is_pro          boolean not null default false,
  pro_expires_at  timestamptz,
  is_ultimate     boolean not null default false,
  -- Set by hand in the SQL Editor for accounts that run the competition
  -- rather than play in it (see get_leaderboard).
  hidden_from_leaderboard boolean not null default false
);
-- Display names are unique, ignoring capitals.
create unique index profiles_display_name_unique on public.profiles (lower(display_name));

create table public.holdings (
  id       uuid primary key default gen_random_uuid(),
  user_id  uuid not null references auth.users(id) on delete cascade,
  team_id  uuid not null references public.teams(id) on delete cascade,
  shares   numeric not null default 0,
  unique (user_id, team_id)
);

create table public.trades (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  team_id     uuid not null references public.teams(id) on delete cascade,
  side        text not null check (side in ('buy', 'sell')),
  qty         numeric not null,
  price       numeric not null,
  created_at  timestamptz not null default now()
);
create index trades_user_created on public.trades (user_id, created_at);

create table public.site_settings (
  key         text primary key,
  value       jsonb not null,
  updated_at  timestamptz not null default now()
);

create table public.match_events (
  id               uuid primary key default gen_random_uuid(),
  source_match_id  text not null unique,
  competition      text,
  home_team_name   text,
  away_team_name   text,
  home_score       integer,
  away_score       integer,
  match_date       timestamptz,
  home_team_id     uuid references public.teams(id),
  away_team_id     uuid references public.teams(id),
  home_delta_pct   numeric,
  away_delta_pct   numeric,
  ai_reason        text,
  ai_provider      text,
  status           text not null default 'pending'
                   check (status in ('pending', 'approved', 'rejected', 'skipped')),
  reviewed_by      text,
  reviewed_at      timestamptz,
  created_at       timestamptz not null default now(),
  skip_reason      text
);

create table public.price_history (
  id              uuid primary key default gen_random_uuid(),
  team_id         uuid not null references public.teams(id) on delete cascade,
  price           numeric not null,
  delta_pct       numeric,
  source          text not null default 'match' check (source in ('match', 'admin', 'seed')),
  match_event_id  uuid references public.match_events(id) on delete set null,
  label           text,
  result          char(1) check (result in ('W', 'D', 'L')),
  changed_at      timestamptz not null default now()
);

create table public.watchlist (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  team_id      uuid not null references public.teams(id) on delete cascade,
  alert_below  numeric,
  alert_above  numeric,
  created_at   timestamptz not null default now(),
  unique (user_id, team_id)
);

create table public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  team_id     uuid references public.teams(id) on delete cascade,
  kind        text not null check (kind in ('below', 'above')),
  threshold   numeric not null,
  price       numeric not null,
  team_name   text not null,
  read        boolean not null default false,
  created_at  timestamptz not null default now()
);

-- Upcoming and recent matches, written by the price updater. Used to
-- lock trading on a club between kickoff and its result being priced.
create table public.fixtures (
  source_match_id  text primary key,
  competition      text,
  home_team_id     uuid references public.teams(id) on delete set null,
  away_team_id     uuid references public.teams(id) on delete set null,
  home_team_name   text,
  away_team_name   text,
  kickoff          timestamptz not null,
  feed_status      text,
  updated_at       timestamptz not null default now()
);
create index fixtures_home_kickoff on public.fixtures (home_team_id, kickoff);
create index fixtures_away_kickoff on public.fixtures (away_team_id, kickoff);

-- =====================================================================
-- Access rules (row level security)
-- Players never write profiles, holdings or trades directly: every
-- change goes through the trade() function below.
-- =====================================================================

alter table public.teams          enable row level security;
alter table public.profiles       enable row level security;
alter table public.holdings       enable row level security;
alter table public.trades         enable row level security;
alter table public.site_settings  enable row level security;
alter table public.match_events   enable row level security;
alter table public.price_history  enable row level security;
alter table public.watchlist      enable row level security;
alter table public.notifications  enable row level security;
alter table public.fixtures       enable row level security;  -- no policies: service role only

create policy "teams are publicly readable" on public.teams
  for select using (true);
create policy "only admin can edit teams" on public.teams
  for update using ((auth.jwt() ->> 'email') = 'pitchmarketadmin@gmail.com');
create policy "only admin can insert teams" on public.teams
  for insert with check ((auth.jwt() ->> 'email') = 'pitchmarketadmin@gmail.com');
create policy "only admin can delete teams" on public.teams
  for delete using ((auth.jwt() ->> 'email') = 'pitchmarketadmin@gmail.com');

create policy "settings are publicly readable" on public.site_settings
  for select using (true);
create policy "only admin can insert settings" on public.site_settings
  for insert with check ((auth.jwt() ->> 'email') = 'pitchmarketadmin@gmail.com');
create policy "only admin can update settings" on public.site_settings
  for update using ((auth.jwt() ->> 'email') = 'pitchmarketadmin@gmail.com');

create policy "users see own profile" on public.profiles
  for select using (auth.uid() = id);
create policy "users see own holdings" on public.holdings
  for select using (auth.uid() = user_id);
create policy "users see own trades" on public.trades
  for select using (auth.uid() = user_id);

-- The price updater writes match events with the service role key,
-- which bypasses these rules.
create policy "admin can view match events" on public.match_events
  for select using ((auth.jwt() ->> 'email') = 'pitchmarketadmin@gmail.com');

create policy "price history is publicly readable" on public.price_history
  for select using (true);
create policy "only admin can insert price history" on public.price_history
  for insert with check ((auth.jwt() ->> 'email') = 'pitchmarketadmin@gmail.com');

create policy "users read own watchlist" on public.watchlist
  for select using (auth.uid() = user_id);
create policy "users add to own watchlist" on public.watchlist
  for insert with check (auth.uid() = user_id);
create policy "users update own watchlist" on public.watchlist
  for update using (auth.uid() = user_id);
create policy "users remove from own watchlist" on public.watchlist
  for delete using (auth.uid() = user_id);

create policy "users read own notifications" on public.notifications
  for select using (auth.uid() = user_id);
create policy "users update own notifications" on public.notifications
  for update using (auth.uid() = user_id);
create policy "users delete own notifications" on public.notifications
  for delete using (auth.uid() = user_id);

-- =====================================================================
-- Functions
-- =====================================================================

-- Why a club is locked, or null if it isn't. A club is locked from
--    kickoff until its match event is approved or rejected (by admin or
--    auto-apply). Postponed, cancelled or suspended matches don't lock,
--    and no lock lasts more than 72 hours, so a broken updater can't
--    freeze a club forever.
create or replace function public.team_lock_reason(p_team_id uuid)
 returns text
 language sql
 stable
 security definer
 set search_path = public
as $function$
  select 'Trading on this team is paused until its match result ('
         || coalesce(f.home_team_name, '?') || ' v ' || coalesce(f.away_team_name, '?')
         || ') has been priced.'
  from fixtures f
  where p_team_id in (f.home_team_id, f.away_team_id)
    and f.kickoff <= now()
    and f.kickoff > now() - interval '72 hours'
    and coalesce(f.feed_status, '') not in ('POSTPONED', 'CANCELLED', 'SUSPENDED')
    and not exists (
      select 1 from match_events e
      where e.source_match_id = f.source_match_id
        and e.status in ('approved', 'rejected')
    )
  order by f.kickoff
  limit 1;
$function$;
revoke execute on function public.team_lock_reason(uuid) from public, anon, authenticated;

-- Every locked club, for the site to show "Paused" buttons.
create or replace function public.get_locked_teams()
 returns table(team_id uuid)
 language sql
 stable
 security definer
 set search_path = public
as $function$
  select distinct t.id
  from fixtures f
  cross join lateral (values (f.home_team_id), (f.away_team_id)) as t(id)
  where t.id is not null
    and f.kickoff <= now()
    and f.kickoff > now() - interval '72 hours'
    and coalesce(f.feed_status, '') not in ('POSTPONED', 'CANCELLED', 'SUSPENDED')
    and not exists (
      select 1 from match_events e
      where e.source_match_id = f.source_match_id
        and e.status in ('approved', 'rejected')
    );
$function$;

-- Buy or sell whole shares at the price stored in the database. Refuses
-- while the club is locked for a match (see team_lock_reason).
create or replace function public.trade(p_team_id uuid, p_side text, p_qty numeric)
 returns void
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  v_price numeric;
  v_balance numeric;
  v_cost numeric;
  v_shares numeric;
  v_lock text;
begin
  if auth.uid() is null then
    raise exception 'Sign in required';
  end if;
  -- NaN and Infinity sort above every number, so the upper cap rejects them too.
  if p_qty is null or p_qty <= 0 or p_qty > 1000000 or p_qty <> trunc(p_qty) then
    raise exception 'Quantity must be a whole number greater than zero';
  end if;

  -- Every trade by this player waits here until their previous one finishes.
  select coin_balance into v_balance from profiles where id = auth.uid() for update;
  if v_balance is null then
    raise exception 'Sign in required';
  end if;

  -- One trade every 3 seconds per player, so a script can't fire hundreds
  -- of trades. Checked after the lock above, so two at once can't both pass.
  if exists (
    select 1 from trades
    where user_id = auth.uid() and created_at > now() - interval '3 seconds'
  ) then
    raise exception 'Please wait a few seconds between trades';
  end if;

  select price into v_price from teams where id = p_team_id;
  if v_price is null then
    raise exception 'Team not found';
  end if;

  v_lock := team_lock_reason(p_team_id);
  if v_lock is not null then
    raise exception '%', v_lock;
  end if;

  v_cost := v_price * p_qty;

  if p_side = 'buy' then
    if v_balance < v_cost then
      raise exception 'Not enough Fan Coins for this trade';
    end if;

    update profiles set coin_balance = coin_balance - v_cost where id = auth.uid();

    insert into holdings (user_id, team_id, shares)
      values (auth.uid(), p_team_id, p_qty)
      on conflict (user_id, team_id)
      do update set shares = holdings.shares + p_qty;

  elsif p_side = 'sell' then
    select shares into v_shares from holdings
      where user_id = auth.uid() and team_id = p_team_id for update;
    if v_shares is null or v_shares < p_qty then
      raise exception 'You do not own that many shares';
    end if;

    update holdings set shares = shares - p_qty
      where user_id = auth.uid() and team_id = p_team_id;

    update profiles set coin_balance = coin_balance + v_cost where id = auth.uid();

  else
    raise exception 'Invalid trade side';
  end if;

  insert into trades (user_id, team_id, side, qty, price)
    values (auth.uid(), p_team_id, p_side, p_qty, v_price);
end;
$function$;

-- Top players by coins plus holdings at current prices. Hidden accounts
-- (the organiser's) are left out.
create or replace function public.get_leaderboard(p_limit integer default 20)
 returns table(display_name text, portfolio_value numeric)
 language sql
 security definer
 set search_path = public
as $function$
  select
    coalesce(p.display_name, 'Trader') as display_name,
    p.coin_balance + coalesce(sum(h.shares * t.price), 0) as portfolio_value
  from profiles p
  left join holdings h on h.user_id = p.id
  left join teams t on t.id = h.team_id
  where not p.hidden_from_leaderboard
  group by p.id, p.display_name, p.coin_balance
  order by portfolio_value desc
  limit p_limit;
$function$;

create or replace function public.set_display_name(p_name text)
 returns void
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  v_name text := btrim(p_name);
begin
  if v_name is null or v_name !~ '^[A-Za-z0-9 ._-]{2,24}$' then
    raise exception 'Display name must be 2-24 letters, numbers, spaces, dots, dashes or underscores';
  end if;
  if lower(v_name) like 'trader-%' then
    raise exception 'Names starting with "Trader-" are kept for new accounts. Pick something else.';
  end if;
  begin
    update profiles set display_name = v_name where id = auth.uid();
  exception when unique_violation then
    raise exception 'That name is already taken. Try another.';
  end;
end;
$function$;

create or replace function public.clear_read_notifications()
 returns void
 language sql
 security definer
 set search_path = public
as $function$
  delete from notifications where user_id = auth.uid() and read = true;
$function$;

-- Admin approves or rejects a pending match price change.
create or replace function public.approve_match_event(p_event_id uuid, p_approve boolean)
 returns void
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  ev record;
  v_new_price numeric;
  v_result char(1);
begin
  if auth.jwt() ->> 'email' <> 'pitchmarketadmin@gmail.com' then
    raise exception 'Not authorized';
  end if;

  select * into ev from match_events where id = p_event_id and status = 'pending';
  if ev is null then
    raise exception 'Event not found or already reviewed';
  end if;

  if p_approve then
    -- Home team
    if ev.home_team_id is not null then
      update teams set
        price = greatest(0.01, round((price * (1 + ev.home_delta_pct/100))::numeric, 2)),
        chg = ev.home_delta_pct,
        updated_at = now()
      where id = ev.home_team_id
      returning price into v_new_price;

      v_result := case when ev.home_score > ev.away_score then 'W'
                       when ev.home_score = ev.away_score then 'D'
                       else 'L' end;

      insert into price_history (team_id, price, delta_pct, source, match_event_id, label, result, changed_at)
      values (ev.home_team_id, v_new_price, ev.home_delta_pct, 'match', ev.id,
              'v ' || ev.away_team_name || ' ' || ev.home_score || '-' || ev.away_score,
              v_result, coalesce(ev.match_date, now()));
    end if;

    -- Away team
    if ev.away_team_id is not null then
      update teams set
        price = greatest(0.01, round((price * (1 + ev.away_delta_pct/100))::numeric, 2)),
        chg = ev.away_delta_pct,
        updated_at = now()
      where id = ev.away_team_id
      returning price into v_new_price;

      v_result := case when ev.away_score > ev.home_score then 'W'
                       when ev.away_score = ev.home_score then 'D'
                       else 'L' end;

      insert into price_history (team_id, price, delta_pct, source, match_event_id, label, result, changed_at)
      values (ev.away_team_id, v_new_price, ev.away_delta_pct, 'match', ev.id,
              '@ ' || ev.home_team_name || ' ' || ev.away_score || '-' || ev.home_score,
              v_result, coalesce(ev.match_date, now()));
    end if;
  end if;

  update match_events set
    status = case when p_approve then 'approved' else 'rejected' end,
    reviewed_by = auth.jwt() ->> 'email',
    reviewed_at = now()
  where id = p_event_id;
end;
$function$;

-- Price updater applies a small move without review. Service role only.
create or replace function public.auto_apply_match_event(p_event_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  ev record;
  v_new_price numeric;
  v_result char(1);
begin
  select * into ev from match_events where id = p_event_id and status = 'pending';
  if ev is null then
    raise exception 'Event not found or already reviewed';
  end if;

  if ev.home_team_id is not null then
    update teams set
      price = greatest(0.01, round((price * (1 + ev.home_delta_pct/100))::numeric, 2)),
      chg = ev.home_delta_pct,
      updated_at = now()
    where id = ev.home_team_id
    returning price into v_new_price;

    v_result := case when ev.home_score > ev.away_score then 'W'
                     when ev.home_score = ev.away_score then 'D'
                     else 'L' end;

    insert into price_history (team_id, price, delta_pct, source, match_event_id, label, result, changed_at)
    values (ev.home_team_id, v_new_price, ev.home_delta_pct, 'match', ev.id,
            'v ' || ev.away_team_name || ' ' || ev.home_score || '-' || ev.away_score,
            v_result, coalesce(ev.match_date, now()));
  end if;

  if ev.away_team_id is not null then
    update teams set
      price = greatest(0.01, round((price * (1 + ev.away_delta_pct/100))::numeric, 2)),
      chg = ev.away_delta_pct,
      updated_at = now()
    where id = ev.away_team_id
    returning price into v_new_price;

    v_result := case when ev.away_score > ev.home_score then 'W'
                     when ev.away_score = ev.home_score then 'D'
                     else 'L' end;

    insert into price_history (team_id, price, delta_pct, source, match_event_id, label, result, changed_at)
    values (ev.away_team_id, v_new_price, ev.away_delta_pct, 'match', ev.id,
            '@ ' || ev.home_team_name || ' ' || ev.away_score || '-' || ev.home_score,
            v_result, coalesce(ev.match_date, now()));
  end if;

  -- Marked approved so it shows in your history, but stamped so you can
  -- always tell at a glance which changes you made and which the
  -- pipeline made on its own.
  update match_events set
    status = 'approved',
    reviewed_by = 'auto (' || coalesce(ai_provider, 'ai') || ')',
    reviewed_at = now()
  where id = p_event_id;
end;
$function$;

revoke execute on function public.auto_apply_match_event(uuid) from public, anon, authenticated;
grant execute on function public.auto_apply_match_event(uuid) to service_role;

-- =====================================================================
-- Trigger functions and triggers
-- =====================================================================

-- Create a profile with 2,000 coins for every new sign-up.
create or replace function public.handle_new_user()
 returns trigger
 language plpgsql
 security definer
 set search_path = public
as $function$
begin
  insert into public.profiles (id, email, display_name, coin_balance)
  values (new.id, new.email, 'Trader-' || substr(new.id::text, 1, 6), 2000);
  return new;
end;
$function$;

-- The trigger lives on auth.users, so the export didn't list it. This
-- is the standard Supabase setup; the name on the live project may differ.
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Watchlist size: 5 free, 25 Pro, unlimited Ultimate.
create or replace function public.watchlist_slot_limit()
 returns trigger
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  v_count int;
  v_limit int;
  v_pro boolean;
  v_ultimate boolean;
begin
  select is_pro, is_ultimate into v_pro, v_ultimate
  from profiles where id = new.user_id;

  if coalesce(v_ultimate, false) then
    return new;                     -- unlimited
  elsif coalesce(v_pro, false) then
    v_limit := 25;
  else
    v_limit := 5;
  end if;

  select count(*) into v_count from watchlist where user_id = new.user_id;
  if v_count >= v_limit then
    raise exception 'Watchlist full: your plan allows % teams. Upgrade for more slots.', v_limit;
  end if;
  return new;
end;
$function$;

create trigger watchlist_limit_check
  before insert on public.watchlist
  for each row execute function public.watchlist_slot_limit();

-- Record admin price edits in price_history.
create or replace function public.log_manual_price_change()
 returns trigger
 language plpgsql
 security definer
 set search_path = public
as $function$
begin
  if new.price is distinct from old.price then
    -- Skip if the approval function already logged this change a moment
    -- ago, so an approved match does not produce two history rows.
    if not exists (
      select 1 from price_history
      where team_id = new.id and changed_at > now() - interval '5 seconds'
    ) then
      insert into price_history (team_id, price, delta_pct, source, label)
      values (new.id, new.price, new.chg, 'admin', 'Manual adjustment');
    end if;
  end if;
  return new;
end;
$function$;

create trigger log_price_change
  after update on public.teams
  for each row execute function public.log_manual_price_change();

-- Price alerts for Pro and Ultimate players when a team crosses a level.
create or replace function public.fire_price_alerts()
 returns trigger
 language plpgsql
 security definer
 set search_path = public
as $function$
begin
  if new.price is not distinct from old.price then
    return new;
  end if;

  -- Downward crossings
  insert into notifications (user_id, team_id, kind, threshold, price, team_name)
  select w.user_id, new.id, 'below', w.alert_below, new.price, new.name
  from watchlist w
  join profiles p on p.id = w.user_id
  where w.team_id = new.id
    and w.alert_below is not null
    and old.price >= w.alert_below
    and new.price <  w.alert_below
    and (coalesce(p.is_pro, false) or coalesce(p.is_ultimate, false));

  -- Upward crossings
  insert into notifications (user_id, team_id, kind, threshold, price, team_name)
  select w.user_id, new.id, 'above', w.alert_above, new.price, new.name
  from watchlist w
  join profiles p on p.id = w.user_id
  where w.team_id = new.id
    and w.alert_above is not null
    and old.price <= w.alert_above
    and new.price >  w.alert_above
    and (coalesce(p.is_pro, false) or coalesce(p.is_ultimate, false));

  return new;
end;
$function$;

create trigger price_alert_trigger
  after update on public.teams
  for each row execute function public.fire_price_alerts();

-- =====================================================================
-- Daily Kickabout games (Scouted, Journeyman, Link-Up, Ball Knowledge)
-- Player data comes from Wikidata through import-players.js.
-- =====================================================================

-- ---------- Tables ----------

-- Each club's Wikidata entry, filled in by the importer. Set it by hand
-- to correct a wrong match; the importer never overwrites one.
alter table public.teams add column if not exists wikidata_id text;

create table if not exists public.players (
  id              text primary key,             -- Wikidata ID, e.g. Q28967995
  name            text not null,
  birth_date      date,
  nationality     text,
  position        text,                         -- as Wikidata has it, e.g. "centre-back"
  position_group  text,                         -- Goalkeeper, Defender, Midfielder or Forward
  height_cm       integer,
  team_id         uuid references public.teams(id) on delete set null,
  club_name       text,
  league          text,
  league_label    text,
  fame            integer not null default 0,   -- Wikipedia languages with a page on them
  active          boolean not null default true,
  updated_at      timestamptz not null default now()
);
create index if not exists players_active_fame on public.players (active, fame desc);
alter table public.players enable row level security;
drop policy if exists "players are publicly readable" on public.players;
create policy "players are publicly readable" on public.players for select using (true);

-- Club-by-club careers. Hidden from players (no policies): reading them
-- would give Journeyman away. Rows reach the page through kickabout_state.
create table if not exists public.player_careers (
  player_id   text not null references public.players(id) on delete cascade,
  seq         integer not null,
  club        text not null,
  start_year  integer,
  end_year    integer,
  apps        integer,
  goals       integer,
  loan        boolean not null default false,
  primary key (player_id, seq)
);
alter table public.player_careers enable row level security;

-- Each day's answer per game. Hidden from players (no policies).
create table if not exists public.daily_puzzles (
  day         date not null,
  game        text not null,
  player_id   text references public.players(id),
  created_at  timestamptz not null default now(),
  primary key (day, game)
);
alter table public.daily_puzzles enable row level security;

-- One row per player, game and day: their guesses so far and the result.
create table if not exists public.game_plays (
  user_id     uuid not null references auth.users(id) on delete cascade,
  day         date not null,
  game        text not null,
  guesses     text[] not null default '{}',
  finished    boolean not null default false,
  won         boolean not null default false,
  coins       integer not null default 0,
  updated_at  timestamptz not null default now(),
  primary key (user_id, day, game)
);
alter table public.game_plays enable row level security;
drop policy if exists "users read own plays" on public.game_plays;
create policy "users read own plays" on public.game_plays for select using (auth.uid() = user_id);

-- ---------- Functions ----------

-- Today's date for the games: midnight UK time, so a whole friend group
-- gets a new puzzle at the same moment.
create or replace function public.kickabout_day()
 returns date
 language sql
 stable
 set search_path = public
as $function$
  select (now() at time zone 'Europe/London')::date;
$function$;

-- ---------- Tables ----------

alter table public.players add column if not exists continent text;
-- Whether we have the player's career, so Link-Up can check their teammates.
alter table public.players add column if not exists has_career boolean not null default false;
-- Whether that career's latest spell is at the player's current club, so
-- Journeyman never shows a trail that stops short.
alter table public.players add column if not exists career_current boolean not null default false;
-- The Wikidata club of each career spell, so teammates are matched on the
-- club itself rather than its name.
alter table public.player_careers add column if not exists club_id text;
create index if not exists player_careers_club on public.player_careers (club_id);
-- Link-Up's second player, and anything else a game needs for the day
-- (Link-Up's best score, Ball Knowledge's questions and answers).
alter table public.daily_puzzles add column if not exists player2_id text references public.players(id);
alter table public.daily_puzzles add column if not exists data jsonb;
-- The club the player is at now: its Wikidata ID, or "fd:<id>" for a club
-- that isn't listed on the site. Players with the same key are teammates.
alter table public.players add column if not exists club_key text;
create index if not exists players_club_key on public.players (club_key) where active;
-- Senior national-team spells, for international teammates. Hidden from
-- players (no policies), like careers.
create table if not exists public.player_intl (
  player_id   text not null references public.players(id) on delete cascade,
  team_id     text not null,      -- the national team, matched on this (its country name)
  team        text not null,      -- the country, e.g. "England"
  start_year  integer not null,
  end_year    integer             -- null: still being picked
);
create index if not exists player_intl_player on public.player_intl (player_id);
create index if not exists player_intl_team on public.player_intl (team_id);
alter table public.player_intl enable row level security;

-- ---------- Teammates ----------

-- Every teammate of the given players, with how they were teammates:
-- kind 1, at the same club at the same time (from careers); kind 2, in the
-- same squad right now; kind 3, capped by the same country at the same time.
-- Spell years are whole years, so a player who left in January and one who
-- joined that August both count.
create or replace function public.teammate_edges(p_ids text[])
 returns table(src text, dst text, via text, kind integer)
 language sql
 stable
 set search_path = public
as $function$
  select a.player_id, b.player_id, a.club, 1
  from player_careers a
  join player_careers b on b.club_id = a.club_id and b.player_id <> a.player_id
  where a.player_id = any(p_ids) and a.club_id is not null
    and a.start_year <= coalesce(b.end_year, extract(year from now())::int)
    and b.start_year <= coalesce(a.end_year, extract(year from now())::int)
  union all
  select a.id, b.id, a.club_name, 2
  from players a
  join players b on b.club_key = a.club_key and b.id <> a.id and b.active
  where a.id = any(p_ids) and a.active and a.club_key is not null
  union all
  select a.player_id, b.player_id, a.team || ' (international)', 3
  from player_intl a
  join player_intl b on b.team_id = a.team_id and b.player_id <> a.player_id
  where a.player_id = any(p_ids)
    and a.start_year <= coalesce(b.end_year, extract(year from now())::int)
    and b.start_year <= coalesce(a.end_year, extract(year from now())::int);
$function$;
revoke execute on function public.teammate_edges(text[]) from public, anon, authenticated;

-- How two players were teammates ("Arsenal", "England (international)"),
-- or null if they never were. A club is named before a country.
create or replace function public.teammate_club(p1 text, p2 text)
 returns text
 language sql
 stable
 set search_path = public
as $function$
  select via from teammate_edges(array[p1]) where dst = p2 order by kind limit 1;
$function$;
revoke execute on function public.teammate_club(text, text) from public, anon, authenticated;

-- Everyone who was ever a teammate of any of the given players.
create or replace function public.teammates_of(p_ids text[])
 returns table(id text)
 language sql
 stable
 set search_path = public
as $function$
  select distinct dst from teammate_edges(p_ids);
$function$;
revoke execute on function public.teammates_of(text[]) from public, anon, authenticated;

-- ---------- Shortest link ----------
--
-- A search outwards from both players at once, through active players
-- only (the ones you can pick). Side 'a' grows from the start player, side
-- 'b' from the target; where they meet is the shortest link.

-- Adds the next ring of teammates on one side.
create or replace function public.link_expand(p_side text, p_depth integer)
 returns integer
 language plpgsql
 set search_path = public
as $function$
declare
  n integer;
begin
  insert into pm_link (side, id, parent, via, depth)
  select distinct on (e.dst) p_side, e.dst, e.src, e.via, p_depth
  from teammate_edges(array(select id from pm_link where side = p_side and depth = p_depth - 1)) e
  join players p on p.id = e.dst and p.active
  order by e.dst, e.kind
  on conflict (side, id) do nothing;
  get diagnostics n = row_count;
  return n;
end;
$function$;
revoke execute on function public.link_expand(text, integer) from public, anon, authenticated;

-- The path where the two sides meet, as [{id, name, via}] from the first
-- player after the start up to the target, or null if they haven't met.
create or replace function public.link_path()
 returns jsonb
 language plpgsql
 set search_path = public
as $function$
declare
  v_meet text;
  v_cur text;
  v_out jsonb := '[]'::jsonb;
  r record;
begin
  select x.id into v_meet from pm_link x join pm_link y on y.id = x.id and y.side = 'b'
  where x.side = 'a' order by x.depth + y.depth, x.depth limit 1;
  if v_meet is null then return null; end if;
  -- Start side: from the meeting player back to the start, added in front.
  v_cur := v_meet;
  loop
    select * into r from pm_link where side = 'a' and id = v_cur;
    exit when r.parent is null;
    v_out := jsonb_build_array(jsonb_build_object('id', r.id, 'name', (select name from players where id = r.id), 'via', r.via)) || v_out;
    v_cur := r.parent;
  end loop;
  -- Target side: from the meeting player on to the target.
  v_cur := v_meet;
  loop
    select * into r from pm_link where side = 'b' and id = v_cur;
    exit when r.parent is null;
    v_out := v_out || jsonb_build_array(jsonb_build_object('id', r.parent, 'name', (select name from players where id = r.parent), 'via', r.via));
    v_cur := r.parent;
  end loop;
  return v_out;
end;
$function$;
revoke execute on function public.link_path() from public, anon, authenticated;

-- Starts a fresh search from one or both players.
create or replace function public.link_reset(p_a text, p_b text)
 returns void
 language plpgsql
 set search_path = public
as $function$
begin
  if to_regclass('pg_temp.pm_link') is null then
    create temp table pm_link (side text, id text, parent text, via text, depth integer, primary key (side, id)) on commit drop;
  else
    truncate pm_link;
  end if;
  if p_a is not null then insert into pm_link values ('a', p_a, null, null, 0); end if;
  if p_b is not null then insert into pm_link values ('b', p_b, null, null, 0); end if;
end;
$function$;
revoke execute on function public.link_reset(text, text) from public, anon, authenticated;

-- The shortest link between two players with at most 3 players in
-- between, as link_path() gives it, or null if there's none that short.
create or replace function public.shortest_link(p_a text, p_b text)
 returns jsonb
 language plpgsql
 set search_path = public
as $function$
declare
  v_path jsonb;
begin
  perform link_reset(p_a, p_b);
  v_path := link_path();
  if v_path is not null then return v_path; end if;
  perform link_expand('a', 1);  v_path := link_path(); if v_path is not null then return v_path; end if;
  perform link_expand('b', 1);  v_path := link_path(); if v_path is not null then return v_path; end if;
  perform link_expand('a', 2);  v_path := link_path(); if v_path is not null then return v_path; end if;
  perform link_expand('b', 2);  return link_path();
end;
$function$;
revoke execute on function public.shortest_link(text, text) from public, anon, authenticated;

-- ---------- Ball Knowledge questions ----------

-- One question of the given kind, as {q, options[4], answer}, or null if
-- the data can't make one today. Options are shuffled; "answer" is the
-- index of the right one.
create or replace function public.make_question(p_kind text)
 returns jsonb
 language plpgsql
 volatile
 set search_path = public
as $function$
declare
  v_q text;
  v_right text;
  v_wrong text[];
  v_opts text[];
  r record;
begin
  if p_kind = 'previous_club' then
    -- "Before joining X in 2019, which club did P play for?"
    select p.name, c2.club as joined, c2.start_year, c1.club as prev, p.id into r
    from players p
    join player_careers c2 on c2.player_id = p.id and not c2.loan
    join lateral (
      select c.club, c.club_id from player_careers c
      where c.player_id = p.id and c.seq < c2.seq and not c.loan
      order by c.seq desc limit 1
    ) c1 on c1.club_id is distinct from c2.club_id
    where p.active and p.fame >= 40
    order by random() limit 1;
    if r is null then return null; end if;
    v_q := 'Before joining ' || r.joined || ' in ' || r.start_year || ', which club did ' || r.name || ' play for?';
    v_right := r.prev;
    select array_agg(club) into v_wrong from (
      select club from (select club from player_careers group by club having count(*) >= 15) common
      where club not in (select c.club from player_careers c where c.player_id = r.id)
      order by random() limit 3) x;

  elsif p_kind = 'nationality' then
    select p.name, p.nationality into r from players p
    where p.active and p.fame >= 40 and p.nationality is not null order by random() limit 1;
    if r is null then return null; end if;
    v_q := 'Which country does ' || r.name || ' play for?';
    v_right := r.nationality;
    select array_agg(nationality) into v_wrong from (
      select nationality from players where nationality is not null and nationality <> r.nationality
      group by nationality having count(*) >= 20 order by random() limit 3) x;

  elsif p_kind = 'played_for' then
    -- One player who has played for the club, three who never have.
    select t.name as club, t.wikidata_id into r from teams t
    where t.wikidata_id is not null
      and (select count(distinct c.player_id) from player_careers c join players p on p.id = c.player_id
           where c.club_id = t.wikidata_id and p.fame >= 40) >= 3
    order by random() limit 1;
    if r is null then return null; end if;
    v_q := 'Which of these players has played for ' || r.club || '?';
    select p.name into v_right from players p
    where p.fame >= 40 and exists (select 1 from player_careers c where c.player_id = p.id and c.club_id = r.wikidata_id)
    order by random() limit 1;
    select array_agg(name) into v_wrong from (
      select p.name from players p
      where p.active and p.fame >= 40 and exists (select 1 from player_careers c where c.player_id = p.id)
        and not exists (select 1 from player_careers c where c.player_id = p.id and c.club_id = r.wikidata_id)
      order by random() limit 3) x;

  elsif p_kind = 'oldest' then
    -- Four well-known players born in different years.
    select array_agg(name order by birth_date) into v_opts from (
      select distinct on (extract(year from birth_date)) name, birth_date
      from (select name, birth_date from players where active and fame >= 40 and birth_date is not null order by random() limit 40) s
      order by extract(year from birth_date), random()
    ) y;
    if coalesce(array_length(v_opts, 1), 0) < 4 then return null; end if;
    select array_agg(n) into v_opts from (select unnest(v_opts) as n order by random() limit 4) z;
    select name into v_right from players where name = any(v_opts) and active and fame >= 40 order by birth_date limit 1;
    v_q := 'Which of these players is the oldest?';
    v_wrong := array_remove(v_opts, v_right);

  elsif p_kind = 'league' then
    select t.name, t.league, t.league_label into r from teams t
    where t.league in ('epl','laliga','seriea','bundesliga','ligue1','championship','portugal','eredivisie','brazil')
    order by random() limit 1;
    if r is null then return null; end if;
    v_q := 'Which league are ' || r.name || ' in on PitchMarket?';
    v_right := r.league_label;
    select array_agg(league_label) into v_wrong from (
      select distinct league_label from teams
      where league in ('epl','laliga','seriea','bundesliga','ligue1','championship','portugal','eredivisie','brazil')
        and league_label <> r.league_label
      order by 1) x;
    select array_agg(l) into v_wrong from (select unnest(v_wrong) as l order by random() limit 3) x;

  elsif p_kind = 'riser' then
    -- "Which of these clubs' prices has risen most in the last 7 days?"
    -- Four clubs whose prices moved, compared with their last price
    -- before the week began.
    with moves as (
      select t.name, (t.price - h.price) / nullif(h.price, 0) as pct
      from teams t
      join lateral (select ph.price from price_history ph
                    where ph.team_id = t.id and ph.changed_at <= now() - interval '7 days'
                    order by ph.changed_at desc limit 1) h on true
      where t.price <> h.price
    ), four as (select name, pct from moves order by random() limit 4)
    select array_agg(name order by pct desc) into v_opts from four;
    if coalesce(array_length(v_opts, 1), 0) < 4 then return null; end if;
    v_q := 'Which of these clubs'' prices has risen most in the last 7 days?';
    v_right := v_opts[1];
    v_wrong := v_opts[2:4];
  else
    raise exception 'Unknown question kind';
  end if;

  if v_right is null or coalesce(array_length(v_wrong, 1), 0) < 3 then return null; end if;
  select array_agg(o order by random()) into v_opts from unnest(v_wrong[1:3] || v_right) o;
  return jsonb_build_object('q', v_q, 'options', to_jsonb(v_opts), 'answer', array_position(v_opts, v_right) - 1);
end;
$function$;
revoke execute on function public.make_question(text) from public, anon, authenticated;

-- ---------- Daily puzzles ----------

-- Today's puzzle for a game, made the first time anyone asks for it.
create or replace function public.daily_puzzle(p_game text)
 returns public.daily_puzzles
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  v_day date := kickabout_day();
  v_row daily_puzzles;
  v_a text;
  v_b text;
  v_data jsonb;
  v_cand text;
  v_path jsonb;
  v_kinds text[];
  v_qs jsonb := '[]'::jsonb;
  v_question jsonb;
  k text;
begin
  select * into v_row from daily_puzzles where day = v_day and game = p_game;
  if found then return v_row; end if;

  if p_game = 'scouted' then
    -- One of the 300 best-known players with every clue filled in, not
    -- used in the last 120 days.
    select id into v_a from (
      select p.id from players p
      where p.active and p.birth_date is not null and p.nationality is not null
        and p.position_group is not null and p.team_id is not null
        and p.id not in (select d.player_id from daily_puzzles d
                         where d.game = p_game and d.day > v_day - 120 and d.player_id is not null)
      order by p.fame desc limit 300) pool
    order by random() limit 1;

  elsif p_game = 'journeyman' then
    -- A proper trail: 4+ spells at 3+ different clubs, every spell dated,
    -- and up to date with the player's current club.
    select id into v_a from (
      select p.id from players p
      where p.active and p.career_current
        and (select count(*) from player_careers c where c.player_id = p.id) >= 4
        and (select count(distinct c.club) from player_careers c where c.player_id = p.id) >= 3
        and not exists (select 1 from player_careers c where c.player_id = p.id and c.start_year is null)
        and p.id not in (select d.player_id from daily_puzzles d
                         where d.game = p_game and d.day > v_day - 120 and d.player_id is not null)
      order by p.fame desc limit 300) pool
    order by random() limit 1;

  elsif p_game = 'linkup' then
    -- Two well-known players who were never teammates. Prefer a pair with
    -- two players in between at best, else one. The shortest link is kept
    -- to show at the end.
    for attempt in 1..15 loop
      select id into v_a from (
        select p.id from players p
        where p.active and exists (select 1 from player_careers c where c.player_id = p.id and c.club_id is not null)
          and p.id not in (select d.player_id from daily_puzzles d
                           where d.game = p_game and d.day > v_day - 60 and d.player_id is not null)
        order by p.fame desc limit 300) pool
      order by random() limit 1;
      exit when v_a is null;
      -- Everyone within two steps of the start player.
      perform link_reset(v_a, null);
      perform link_expand('a', 1);
      perform link_expand('a', 2);
      -- A well-known player further away whose teammates reach that ring:
      -- three steps, two players in between.
      for v_cand in
        select p.id from players p
        where p.active and p.fame >= 30 and exists (select 1 from player_careers c where c.player_id = p.id)
          and not exists (select 1 from pm_link l where l.side = 'a' and l.id = p.id)
        order by random() limit 40
      loop
        delete from pm_link where side = 'b';
        insert into pm_link values ('b', v_cand, null, null, 0);
        perform link_expand('b', 1);
        v_path := link_path();
        if v_path is not null then v_b := v_cand; exit; end if;
      end loop;
      if v_b is null then
        -- Else someone two steps away: one player in between.
        delete from pm_link where side = 'b';
        select l.id into v_b from pm_link l join players p on p.id = l.id
        where l.side = 'a' and l.depth = 2 and p.fame >= 30
          and exists (select 1 from player_careers c where c.player_id = p.id)
        order by random() limit 1;
        if v_b is not null then
          insert into pm_link values ('b', v_b, null, null, 0);
          v_path := link_path();
        end if;
      end if;
      if v_b is not null and v_path is not null then
        v_data := jsonb_build_object('par', jsonb_array_length(v_path) - 1, 'best', v_path);
        exit;
      end if;
      v_b := null;
    end loop;
    if v_b is null then v_a := null; end if;

  elsif p_game = 'ballknowledge' then
    -- Four questions of different kinds, in random order.
    select array_agg(kind order by random()) into v_kinds
    from unnest(array['previous_club','nationality','played_for','oldest','league','riser']) kind;
    foreach k in array v_kinds loop
      exit when jsonb_array_length(v_qs) = 4;
      v_question := make_question(k);
      if v_question is not null then v_qs := v_qs || jsonb_build_array(v_question); end if;
    end loop;
    if jsonb_array_length(v_qs) = 4 then v_data := jsonb_build_object('questions', v_qs); v_a := 'quiz'; end if;
  else
    raise exception 'Unknown game';
  end if;

  if v_a is null then
    raise exception 'Today''s puzzle isn''t ready yet: the player list is still loading. Try again later.';
  end if;
  insert into daily_puzzles (day, game, player_id, player2_id, data)
  values (v_day, p_game, case when p_game = 'ballknowledge' then null else v_a end, v_b, v_data)
  on conflict do nothing;
  select * into v_row from daily_puzzles where day = v_day and game = p_game;
  return v_row;
end;
$function$;
revoke execute on function public.daily_puzzle(text) from public, anon, authenticated;

-- Kept for anything still calling it: today's answer for a one-player game.
create or replace function public.daily_player(p_game text)
 returns text
 language sql
 security definer
 set search_path = public
as $function$
  select (daily_puzzle(p_game)).player_id;
$function$;
revoke execute on function public.daily_player(text) from public, anon, authenticated;

-- ---------- Scouted clues ----------

-- Clues for one guess. "match" green, "close" yellow (nationality: same
-- continent; age: within 2 years), "miss" grey, "unknown" when Wikidata
-- has no value. "dir" says whether the answer is higher ("up") or lower.
create or replace function public.scouted_feedback(g public.players, a public.players, p_day date)
 returns jsonb
 language plpgsql
 stable
 set search_path = public
as $function$
declare
  g_age integer := extract(year from age(p_day, g.birth_date));
  a_age integer := extract(year from age(p_day, a.birth_date));
  g_club text := coalesce(g.club_key, g.team_id::text);
  a_club text := coalesce(a.club_key, a.team_id::text);
begin
  return jsonb_build_object(
    'id', g.id,
    'name', g.name,
    'league', jsonb_build_object('value', g.league_label,
      'result', case when g.league is null then 'unknown' when g.league = a.league then 'match' else 'miss' end),
    'team', jsonb_build_object('value', g.club_name,
      'result', case when g_club is null then 'unknown' when g_club = a_club then 'match' else 'miss' end),
    'nationality', jsonb_build_object('value', g.nationality,
      'result', case when g.nationality is null then 'unknown'
                     when lower(g.nationality) = lower(a.nationality) then 'match'
                     when g.continent is not null and g.continent = a.continent then 'close'
                     else 'miss' end),
    'age', jsonb_build_object('value', g_age,
      'result', case when g_age is null then 'unknown' when g_age = a_age then 'match' when abs(g_age - a_age) <= 2 then 'close' else 'miss' end,
      'dir', case when g_age is null or g_age = a_age then null when a_age > g_age then 'up' else 'down' end),
    'position', jsonb_build_object('value', g.position_group,
      'result', case when g.position_group is null then 'unknown' when g.position_group = a.position_group then 'match' else 'miss' end)
  );
end;
$function$;
revoke execute on function public.scouted_feedback(public.players, public.players, date) from public, anon, authenticated;

-- ---------- Game state ----------

-- A player's clubs in order, without years: shown for Link-Up's two
-- players, who aren't secret.
create or replace function public.club_trail(p_id text)
 returns jsonb
 language sql
 stable
 set search_path = public
as $function$
  select coalesce(jsonb_agg(club order by first_seq), '[]'::jsonb)
  from (select club, min(seq) as first_seq from player_careers where player_id = p_id and not loan group by club) c;
$function$;
revoke execute on function public.club_trail(text) from public, anon, authenticated;

-- Everything the page needs to draw a game for the signed-in player (or a
-- signed-out visitor, who sees a fresh game). Answers only appear once
-- the player has finished.
create or replace function public.kickabout_state(p_game text)
 returns jsonb
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  v_day date := kickabout_day();
  v_puzzle daily_puzzles;
  v_answer players;
  v_target players;
  v_play game_plays;
  v_guesses text[];
  v_finished boolean;
  v_rows integer;
  v_shown integer;
  v_result jsonb;
  v_end text;
  v_club text;
  v_best jsonb;
  v_chain jsonb := '[]'::jsonb;
  v_strikes jsonb := '[]'::jsonb;
  v_qs jsonb;
  v_out jsonb := '[]'::jsonb;
  g text;
  i integer;
begin
  if p_game not in ('scouted', 'journeyman', 'linkup', 'ballknowledge') then raise exception 'Unknown game'; end if;
  v_puzzle := daily_puzzle(p_game);
  select * into v_answer from players where id = v_puzzle.player_id;
  select * into v_play from game_plays where user_id = auth.uid() and day = v_day and game = p_game;
  v_guesses := coalesce(v_play.guesses, '{}');
  v_finished := coalesce(v_play.finished, false);

  v_result := jsonb_build_object(
    'game', p_game, 'day', v_day, 'signed_in', auth.uid() is not null,
    'finished', v_finished, 'won', coalesce(v_play.won, false), 'coins', coalesce(v_play.coins, 0));

  if p_game = 'scouted' then
    return v_result || jsonb_build_object(
      'max_guesses', 10,
      'answer', case when v_finished then jsonb_build_object('id', v_answer.id, 'name', v_answer.name) end,
      'guesses', coalesce((
        select jsonb_agg(scouted_feedback(gp, v_answer, v_day) order by u.n)
        from unnest(v_guesses) with ordinality as u(id, n)
        join players gp on gp.id = u.id
      ), '[]'::jsonb));

  elsif p_game = 'journeyman' then
    -- The first spell shows from the start, each wrong guess shows one
    -- more, and with all showing there's one last guess: N spells, N guesses.
    select count(*) into v_rows from player_careers where player_id = v_answer.id;
    v_shown := case when v_finished then v_rows else least(v_rows, 1 + coalesce(array_length(v_guesses, 1), 0)) end;
    return v_result || jsonb_build_object(
      'max_guesses', v_rows, 'total_rows', v_rows,
      'answer', case when v_finished then jsonb_build_object('id', v_answer.id, 'name', v_answer.name) end,
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object('club', c.club, 'start', c.start_year, 'end', c.end_year,
                                            'apps', c.apps, 'goals', c.goals, 'loan', c.loan) order by c.seq)
        from player_careers c where c.player_id = v_answer.id and c.seq <= v_shown), '[]'::jsonb),
      'guesses', coalesce((
        select jsonb_agg(jsonb_build_object('id', gp.id, 'name', gp.name) order by u.n)
        from unnest(v_guesses) with ordinality as u(id, n) join players gp on gp.id = u.id), '[]'::jsonb));

  elsif p_game = 'linkup' then
    -- Replay the guesses: a teammate of the chain's last player joins the
    -- chain, anyone else is a miss. Guessing the target checks the final link.
    select * into v_target from players where id = v_puzzle.player2_id;
    -- The shortest link, worked out once (puzzles made before this update
    -- don't have it yet) and shown when you finish.
    if v_finished and v_puzzle.data->'best' is null then
      v_best := shortest_link(v_answer.id, v_target.id);
      if v_best is not null then
        update daily_puzzles set data = coalesce(data, '{}'::jsonb)
          || jsonb_build_object('best', v_best, 'par', jsonb_array_length(v_best) - 1)
        where day = v_puzzle.day and game = p_game
        returning * into v_puzzle;
      end if;
    end if;
    v_end := v_answer.id;
    foreach g in array v_guesses loop
      v_club := teammate_club(v_end, g);
      if g = v_target.id then
        if v_club is not null then
          v_chain := v_chain || jsonb_build_array(jsonb_build_object('id', g, 'name', v_target.name, 'via', v_club, 'target', true));
        else
          v_strikes := v_strikes || jsonb_build_array(jsonb_build_object('id', g, 'name', v_target.name, 'reason', 'not_linked'));
        end if;
      elsif v_club is not null then
        v_chain := v_chain || jsonb_build_array(jsonb_build_object('id', g, 'name', (select name from players where id = g), 'via', v_club));
        v_end := g;
      else
        v_strikes := v_strikes || jsonb_build_array(jsonb_build_object('id', g, 'name', (select name from players where id = g),
          'reason', 'not_teammates',
          'after', (select name from players where id = v_end)));
      end if;
    end loop;
    return v_result || jsonb_build_object(
      'max_guesses', 6, 'par', v_puzzle.data->'par',
      'start', jsonb_build_object('id', v_answer.id, 'name', v_answer.name, 'club', v_answer.club_name, 'trail', club_trail(v_answer.id)),
      'target', jsonb_build_object('id', v_target.id, 'name', v_target.name, 'club', v_target.club_name, 'trail', club_trail(v_target.id)),
      'chain', v_chain, 'strikes', v_strikes, 'used', coalesce(array_length(v_guesses, 1), 0),
      'best', case when v_finished then v_puzzle.data->'best' end,
      -- How the chain's last player links to the target, once they do.
      'closing', case when not exists (select 1 from jsonb_array_elements(v_chain) e where e->>'target' = 'true')
                 then teammate_club(v_end, v_target.id) end);

  else -- ballknowledge
    v_qs := v_puzzle.data->'questions';
    for i in 0..jsonb_array_length(v_qs) - 1 loop
      v_out := v_out || jsonb_build_array(
        jsonb_build_object('q', v_qs->i->'q', 'options', v_qs->i->'options')
        || case when i < coalesce(array_length(v_guesses, 1), 0)
                then jsonb_build_object('chosen', v_guesses[i + 1]::int, 'answer', v_qs->i->'answer')
                else '{}'::jsonb end);
    end loop;
    return v_result || jsonb_build_object(
      'max_guesses', 4, 'needed', 3, 'questions', v_out,
      'correct', (select count(*) from unnest(v_guesses) with ordinality u(c, n)
                  where u.c::int = (v_qs->(u.n::int - 1)->>'answer')::int));
  end if;
end;
$function$;

-- Make a guess (a player's Wikidata ID, or for Ball Knowledge the chosen
-- option, 0 to 3). Pays 25 Fan Coins for a win, once per game per day.
create or replace function public.kickabout_guess(p_game text, p_player_id text)
 returns jsonb
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  v_day date := kickabout_day();
  v_puzzle daily_puzzles;
  v_play game_plays;
  v_count integer;
  v_won boolean := false;
  v_done boolean := false;
  v_state jsonb;
begin
  if auth.uid() is null then raise exception 'Sign in to play.'; end if;
  if p_game not in ('scouted', 'journeyman', 'linkup', 'ballknowledge') then raise exception 'Unknown game'; end if;
  if p_game = 'ballknowledge' then
    if p_player_id is null or p_player_id !~ '^[0-3]$' then raise exception 'Pick one of the four answers.'; end if;
  elsif not exists (select 1 from players where id = p_player_id) then
    raise exception 'Pick a player from the list.';
  end if;

  v_puzzle := daily_puzzle(p_game);
  insert into game_plays (user_id, day, game) values (auth.uid(), v_day, p_game) on conflict do nothing;
  -- Locked, so two guesses sent at once are handled one after the other.
  select * into v_play from game_plays where user_id = auth.uid() and day = v_day and game = p_game for update;

  if v_play.finished then raise exception 'You''ve finished today''s game. A new one starts at midnight UK time.'; end if;
  if p_game <> 'ballknowledge' and p_player_id = any(v_play.guesses) then raise exception 'You''ve already guessed that player.'; end if;
  if p_game = 'linkup' and p_player_id = v_puzzle.player_id then raise exception 'That''s the player you start from.'; end if;
  -- Refused without using a go: someone no longer in any squad, whose
  -- teammates we can't check.
  if p_game = 'linkup' and p_player_id <> v_puzzle.player2_id
     and not exists (select 1 from players where id = p_player_id and active) then
    raise exception 'That player isn''t in a squad in our leagues any more, so Link-Up can''t check their teammates. Try someone else.';
  end if;

  update game_plays set guesses = guesses || p_player_id, updated_at = now()
  where user_id = auth.uid() and day = v_day and game = p_game;
  v_count := coalesce(array_length(v_play.guesses, 1), 0) + 1;

  if p_game = 'scouted' then
    v_won := p_player_id = v_puzzle.player_id;
    v_done := v_won or v_count >= 10;
  elsif p_game = 'journeyman' then
    v_won := p_player_id = v_puzzle.player_id;
    v_done := v_won or v_count >= (select count(*) from player_careers where player_id = v_puzzle.player_id);
  elsif p_game = 'linkup' then
    -- Won once the last player in the chain was a teammate of the target
    -- (or the target was guessed as the final link).
    v_state := kickabout_state(p_game);
    select coalesce(bool_or(e->>'target' = 'true'), false) into v_won
    from jsonb_array_elements(v_state->'chain') e;
    if not v_won then
      v_won := teammate_club(coalesce(v_state->'chain'->-1->>'id', v_puzzle.player_id), v_puzzle.player2_id) is not null;
    end if;
    v_done := v_won or v_count >= 6;
  else -- ballknowledge
    v_done := v_count >= 4;
    if v_done then
      v_won := (select count(*) from unnest(v_play.guesses || p_player_id) with ordinality u(c, n)
                where u.c::int = (v_puzzle.data->'questions'->(u.n::int - 1)->>'answer')::int) >= 3;
    end if;
  end if;

  update game_plays set won = v_won, finished = v_done, coins = case when v_won then 25 else 0 end
  where user_id = auth.uid() and day = v_day and game = p_game;
  if v_won then
    update profiles set coin_balance = coin_balance + 25 where id = auth.uid();
  end if;
  return kickabout_state(p_game);
end;
$function$;
