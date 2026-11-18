-- PitchMarket database schema (Supabase / Postgres).
--
-- Exported from the live project on 18 Nov 2026, with
-- supabase-security-fixes.sql applied. Running this on an empty Supabase
-- project rebuilds the backend: tables, access rules (RLS), functions
-- and triggers. It creates no data: no teams, settings or players.
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
  is_ultimate     boolean not null default false
);

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

-- Buy or sell whole shares at the price stored in the database.
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

  select price into v_price from teams where id = p_team_id;
  if v_price is null then
    raise exception 'Team not found';
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

-- Top players by coins plus holdings at current prices.
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
  update profiles set display_name = v_name where id = auth.uid();
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
