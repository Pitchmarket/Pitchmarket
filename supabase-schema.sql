-- PitchMarket database schema (Supabase / Postgres).
--
-- Exported from the live project on 18 Nov 2026, with
-- supabase-security-fixes.sql, supabase-price-lag-lock.sql,
-- supabase-trade-cooldown.sql, supabase-names-and-leaderboard.sql and
-- supabase-daily-kickabout.sql applied.
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
-- Daily Kickabout games (Scouted, Journeyman)
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

-- Today's answer for a game, picked the first time it's asked for: one of
-- the 300 best-known suitable players, not used in the last 120 days.
-- md5(id || day || game) shuffles them the same way for everyone, and
-- differently for each game, so the two games never share an answer.
create or replace function public.daily_player(p_game text)
 returns text
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  v_day date := kickabout_day();
  v_id text;
begin
  select player_id into v_id from daily_puzzles where day = v_day and game = p_game;
  if v_id is not null then return v_id; end if;

  if p_game = 'scouted' then
    select id into v_id from (
      select p.id from players p
      where p.active and p.birth_date is not null and p.nationality is not null
        and p.position_group is not null and p.height_cm is not null and p.team_id is not null
        and p.id not in (select d.player_id from daily_puzzles d
                         where d.game = p_game and d.day > v_day - 120 and d.player_id is not null)
      order by p.fame desc
      limit 300
    ) pool
    order by md5(id || v_day::text || p_game)
    limit 1;
  elsif p_game = 'journeyman' then
    -- A proper trail: 4+ spells at 3+ different clubs, every spell dated.
    select id into v_id from (
      select p.id from players p
      where p.active
        and (select count(*) from player_careers c where c.player_id = p.id) >= 4
        and (select count(distinct c.club) from player_careers c where c.player_id = p.id) >= 3
        and not exists (select 1 from player_careers c where c.player_id = p.id and c.start_year is null)
        and p.id not in (select d.player_id from daily_puzzles d
                         where d.game = p_game and d.day > v_day - 120 and d.player_id is not null)
      order by p.fame desc
      limit 300
    ) pool
    order by md5(id || v_day::text || p_game)
    limit 1;
  else
    raise exception 'Unknown game';
  end if;

  if v_id is null then
    raise exception 'Today''s puzzle isn''t ready yet: the player list is still loading. Try again later.';
  end if;
  insert into daily_puzzles (day, game, player_id) values (v_day, p_game, v_id) on conflict do nothing;
  select player_id into v_id from daily_puzzles where day = v_day and game = p_game;
  return v_id;
end;
$function$;
revoke execute on function public.daily_player(text) from public, anon, authenticated;

-- Scouted clues for one guess against the answer. "match" is green,
-- "close" is yellow (age within 2 years, height within 3 cm), "miss" is
-- grey and "unknown" means Wikidata has no value for the guessed player.
-- "dir" says whether the answer is higher ("up") or lower ("down").
create or replace function public.scouted_feedback(g public.players, a public.players, p_day date)
 returns jsonb
 language plpgsql
 stable
 set search_path = public
as $function$
declare
  g_age integer := extract(year from age(p_day, g.birth_date));
  a_age integer := extract(year from age(p_day, a.birth_date));
begin
  return jsonb_build_object(
    'id', g.id,
    'name', g.name,
    'league', jsonb_build_object('value', g.league_label,
      'result', case when g.league is null then 'unknown' when g.league = a.league then 'match' else 'miss' end),
    'team', jsonb_build_object('value', g.club_name,
      'result', case when g.team_id is null then 'unknown' when g.team_id = a.team_id then 'match' else 'miss' end),
    'nationality', jsonb_build_object('value', g.nationality,
      'result', case when g.nationality is null then 'unknown' when lower(g.nationality) = lower(a.nationality) then 'match' else 'miss' end),
    'age', jsonb_build_object('value', g_age,
      'result', case when g_age is null then 'unknown' when g_age = a_age then 'match' when abs(g_age - a_age) <= 2 then 'close' else 'miss' end,
      'dir', case when g_age is null or g_age = a_age then null when a_age > g_age then 'up' else 'down' end),
    'position', jsonb_build_object('value', g.position_group,
      'result', case when g.position_group is null then 'unknown' when g.position_group = a.position_group then 'match' else 'miss' end),
    'height', jsonb_build_object('value', g.height_cm,
      'result', case when g.height_cm is null then 'unknown' when g.height_cm = a.height_cm then 'match' when abs(g.height_cm - a.height_cm) <= 3 then 'close' else 'miss' end,
      'dir', case when g.height_cm is null or g.height_cm = a.height_cm then null when a.height_cm > g.height_cm then 'up' else 'down' end)
  );
end;
$function$;
revoke execute on function public.scouted_feedback(public.players, public.players, date) from public, anon, authenticated;

-- Everything the page needs to draw a game for the signed-in player (or
-- a signed-out visitor, who sees a fresh game). The answer is only
-- included once the player has finished.
create or replace function public.kickabout_state(p_game text)
 returns jsonb
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  v_day date := kickabout_day();
  v_answer players;
  v_play game_plays;
  v_guesses text[];
  v_rows integer;
  v_shown integer;
  v_result jsonb;
begin
  if p_game not in ('scouted', 'journeyman') then raise exception 'Unknown game'; end if;
  select * into v_answer from players where id = daily_player(p_game);
  select * into v_play from game_plays where user_id = auth.uid() and day = v_day and game = p_game;
  v_guesses := coalesce(v_play.guesses, '{}');

  v_result := jsonb_build_object(
    'game', p_game,
    'day', v_day,
    'signed_in', auth.uid() is not null,
    'finished', coalesce(v_play.finished, false),
    'won', coalesce(v_play.won, false),
    'coins', coalesce(v_play.coins, 0),
    'answer', case when coalesce(v_play.finished, false)
      then jsonb_build_object('id', v_answer.id, 'name', v_answer.name, 'club', v_answer.club_name,
                              'nationality', v_answer.nationality, 'position', v_answer.position_group,
                              'height', v_answer.height_cm, 'age', extract(year from age(v_day, v_answer.birth_date)))
      end
  );

  if p_game = 'scouted' then
    return v_result || jsonb_build_object(
      'max_guesses', 10,
      'guesses', coalesce((
        select jsonb_agg(scouted_feedback(g, v_answer, v_day) order by u.n)
        from unnest(v_guesses) with ordinality as u(id, n)
        join players g on g.id = u.id
      ), '[]'::jsonb));
  end if;

  -- Journeyman: the first spell is shown from the start, each wrong guess
  -- shows one more, and when all are showing there's one last guess. So a
  -- career with N spells allows N guesses.
  select count(*) into v_rows from player_careers where player_id = v_answer.id;
  v_shown := case when coalesce(v_play.finished, false) then v_rows
                  else least(v_rows, 1 + coalesce(array_length(v_guesses, 1), 0)) end;
  return v_result || jsonb_build_object(
    'max_guesses', v_rows,
    'total_rows', v_rows,
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object('club', c.club, 'start', c.start_year, 'end', c.end_year,
                                          'apps', c.apps, 'goals', c.goals, 'loan', c.loan) order by c.seq)
      from player_careers c where c.player_id = v_answer.id and c.seq <= v_shown
    ), '[]'::jsonb),
    'guesses', coalesce((
      select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name) order by u.n)
      from unnest(v_guesses) with ordinality as u(id, n)
      join players g on g.id = u.id
    ), '[]'::jsonb));
end;
$function$;

-- Make a guess. Pays 25 Fan Coins for a win, once per game per day.
create or replace function public.kickabout_guess(p_game text, p_player_id text)
 returns jsonb
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  v_day date := kickabout_day();
  v_answer text;
  v_play game_plays;
  v_max integer;
  v_won boolean;
  v_count integer;
begin
  if auth.uid() is null then raise exception 'Sign in to play.'; end if;
  if p_game not in ('scouted', 'journeyman') then raise exception 'Unknown game'; end if;
  if not exists (select 1 from players where id = p_player_id) then
    raise exception 'Pick a player from the list.';
  end if;

  v_answer := daily_player(p_game);
  insert into game_plays (user_id, day, game) values (auth.uid(), v_day, p_game) on conflict do nothing;
  -- Locked, so two guesses sent at once are handled one after the other.
  select * into v_play from game_plays where user_id = auth.uid() and day = v_day and game = p_game for update;

  if v_play.finished then raise exception 'You''ve finished today''s game. A new one starts at midnight UK time.'; end if;
  if p_player_id = any(v_play.guesses) then raise exception 'You''ve already guessed that player.'; end if;

  if p_game = 'scouted' then v_max := 10;
  else select count(*) into v_max from player_careers where player_id = v_answer;
  end if;

  v_won := p_player_id = v_answer;
  v_count := coalesce(array_length(v_play.guesses, 1), 0) + 1;
  update game_plays set
    guesses = guesses || p_player_id,
    won = v_won,
    finished = v_won or v_count >= v_max,
    coins = case when v_won then 25 else 0 end,
    updated_at = now()
  where user_id = auth.uid() and day = v_day and game = p_game;

  if v_won then
    update profiles set coin_balance = coin_balance + 25 where id = auth.uid();
  end if;
  return kickabout_state(p_game);
end;
$function$;
