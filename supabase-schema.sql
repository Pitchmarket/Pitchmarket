-- PitchMarket database schema (Supabase / Postgres).
--
-- Exported from the live project on 18 Nov 2026, with
-- supabase-security-fixes.sql, supabase-price-lag-lock.sql,
-- supabase-trade-cooldown.sql, supabase-names-and-leaderboard.sql,
-- supabase-daily-kickabout.sql, supabase-kickabout-2.sql and
-- supabase-squads.sql applied, and later changes (supabase-error-log.sql,
-- supabase-pro-1.sql, supabase-leagues-1.sql, supabase-ucl-stages.sql)
-- folded in.
-- Running this on an empty Supabase project rebuilds the backend:
-- tables, access rules (RLS), functions and triggers. It creates no
-- data (no teams or players) except the starting payments settings.
--
-- Keep this file in step with the live database. When you change
-- something in the Supabase dashboard, change it here in the same pull
-- request.
--
-- The admin account is identified by email in the policies and in
-- is_admin() below. Search for pitchmarketadmin@gmail.com to
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
  league_order  integer not null default 999,
  -- No trading at all on a closed club (out of, or done with, the
  -- Champions League until reopened).
  closed        boolean not null default false,
  -- How far a Champions League club has got this season.
  ucl_stage     text check (ucl_stage in ('league', 'playoff', 'last16', 'quarters', 'semis',
                                          'final', 'out', 'winners', 'refunded'))
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
  skip_reason      text,
  -- Champions League stage result per side, the AI's own move and the
  -- stage multiplier. For a stage event home_delta_pct / away_delta_pct
  -- hold the move to apply (boosted, or -100 for out).
  home_stage       text check (home_stage in ('playoff', 'last16', 'quarters', 'semis', 'final', 'winners', 'out')),
  away_stage       text check (away_stage in ('playoff', 'last16', 'quarters', 'semis', 'final', 'winners', 'out')),
  home_ai_pct      numeric,
  away_ai_pct      numeric,
  home_multiplier  numeric,
  away_multiplier  numeric,
  -- Admin rejected the stage result; the match was applied as a normal one.
  stage_rejected   boolean not null default false
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
  -- For cashout and refund, threshold is the shares paid out and price
  -- the price per share.
  kind        text not null constraint notifications_kind_check
              check (kind in ('below', 'above', 'cashout', 'refund')),
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
  updated_at       timestamptz not null default now(),
  stage            text,      -- Champions League stage of the match, if known
  leg              smallint
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
-- closed clubs, and while the club is locked for a match (see
-- team_lock_reason).
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
  v_closed boolean;
  v_stage text;
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

  select price, closed, ucl_stage into v_price, v_closed, v_stage from teams where id = p_team_id;
  if v_price is null then
    raise exception 'Team not found';
  end if;

  if v_closed then
    if v_stage = 'out' then
      raise exception 'This club is out of the Champions League. Trading has closed.';
    elsif v_stage = 'winners' then
      raise exception 'The Champions League is over for this season. Trading has closed.';
    else
      raise exception 'Trading on this club has closed.';
    end if;
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

-- get_leaderboard is in the Plans section at the end (it needs user_tier).

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

-- Admin approves or rejects a pending match price change. Rejecting a
-- stage event still applies it, as a normal match (see
-- apply_match_event_core); rejecting a normal event applies nothing.
create or replace function public.approve_match_event(p_event_id uuid, p_approve boolean)
 returns void
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  ev record;
begin
  if not is_admin() then
    raise exception 'Not authorized';
  end if;

  select * into ev from match_events where id = p_event_id and status = 'pending' for update;
  if ev is null then
    raise exception 'Event not found or already reviewed';
  end if;

  if p_approve then
    perform apply_match_event_core(p_event_id, true, auth.jwt() ->> 'email');
  elsif ev.home_stage is not null or ev.away_stage is not null then
    perform apply_match_event_core(p_event_id, false, auth.jwt() ->> 'email');
    update match_events set stage_rejected = true where id = p_event_id;
  else
    update match_events set
      status = 'rejected',
      reviewed_by = auth.jwt() ->> 'email',
      reviewed_at = now()
    where id = p_event_id;
  end if;
end;
$function$;

-- Price updater applies a small move without review. Stage results other
-- than a play-off place wait for the admin. Service role only.
create or replace function public.auto_apply_match_event(p_event_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  ev record;
begin
  select * into ev from match_events where id = p_event_id;
  if coalesce(ev.home_stage, 'playoff') <> 'playoff' or coalesce(ev.away_stage, 'playoff') <> 'playoff' then
    raise exception 'Stage results need approval';
  end if;

  -- Marked approved so it shows in your history, but stamped so you can
  -- always tell at a glance which changes you made and which the
  -- pipeline made on its own.
  perform apply_match_event_core(p_event_id, true, 'auto (' || coalesce(ev.ai_provider, 'ai') || ')');
end;
$function$;

revoke execute on function public.auto_apply_match_event(uuid) from public, anon, authenticated;
grant execute on function public.auto_apply_match_event(uuid) to service_role;

-- Turns every holder's shares in a club into coins at its current price,
-- tells them (a notification of p_kind: cashout or refund), and removes
-- the holdings. Returns how many players were paid. Internal.
create or replace function public.ucl_cash_out(p_team_id uuid, p_kind text)
 returns integer
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  v_team record;
  v_count integer;
begin
  select id, name, price into v_team from teams where id = p_team_id for update;
  if v_team.id is null then
    raise exception 'Team not found';
  end if;

  with paid as (
    select user_id, shares from holdings
    where team_id = p_team_id and shares > 0
    for update
  ), coins as (
    update profiles p set coin_balance = p.coin_balance + round(paid.shares * v_team.price, 2)
    from paid where p.id = paid.user_id
    returning p.id
  )
  insert into notifications (user_id, team_id, kind, threshold, price, team_name)
  select paid.user_id, p_team_id, p_kind, paid.shares, v_team.price, v_team.name from paid;
  get diagnostics v_count = row_count;

  delete from holdings where team_id = p_team_id;
  return v_count;
end;
$function$;

revoke execute on function public.ucl_cash_out(uuid, text) from public, anon, authenticated, service_role;

-- Applies a pending match event: each side's price move, its history row
-- and, with p_use_stage, its Champions League stage (out: price to 0 and
-- closed; winners: holders cashed out and every Champions League club
-- closed). Without p_use_stage a stage event is applied as a normal match
-- with the AI's own move. Internal: approve_match_event,
-- auto_apply_match_event and apply_overdue_stage_events call it.
create or replace function public.apply_match_event_core(p_event_id uuid, p_use_stage boolean, p_reviewer text)
 returns void
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  ev record;
  v_side int;
  v_team uuid;
  v_stage text;
  v_pct numeric;
  v_label text;
  v_result char(1);
  v_new_price numeric;
begin
  select * into ev from match_events where id = p_event_id and status = 'pending' for update;
  if ev is null then
    raise exception 'Event not found or already reviewed';
  end if;

  for v_side in 1..2 loop
    if v_side = 1 then
      v_team := ev.home_team_id;
      v_stage := ev.home_stage;
      v_pct := case when p_use_stage then ev.home_delta_pct else coalesce(ev.home_ai_pct, ev.home_delta_pct) end;
      v_label := 'v ' || ev.away_team_name || ' ' || ev.home_score || '-' || ev.away_score;
      v_result := case when ev.home_score > ev.away_score then 'W'
                       when ev.home_score = ev.away_score then 'D'
                       else 'L' end;
    else
      v_team := ev.away_team_id;
      v_stage := ev.away_stage;
      v_pct := case when p_use_stage then ev.away_delta_pct else coalesce(ev.away_ai_pct, ev.away_delta_pct) end;
      v_label := '@ ' || ev.home_team_name || ' ' || ev.away_score || '-' || ev.home_score;
      v_result := case when ev.away_score > ev.home_score then 'W'
                       when ev.away_score = ev.home_score then 'D'
                       else 'L' end;
    end if;
    continue when v_team is null;

    if p_use_stage and v_stage = 'out' then
      v_pct := -100;
      v_new_price := 0;
    else
      select greatest(0.01, round((price * (1 + v_pct/100))::numeric, 2)) into v_new_price
      from teams where id = v_team for update;
    end if;

    -- History first, then the update with pm.history_written on, so
    -- log_manual_price_change doesn't add a "Manual adjustment" row for
    -- the same move (the row is dated at kickoff, too old for its
    -- 5-second check).
    insert into price_history (team_id, price, delta_pct, source, match_event_id, label, result, changed_at)
    values (v_team, v_new_price, v_pct, 'match', ev.id, v_label, v_result, coalesce(ev.match_date, now()));

    perform set_config('pm.history_written', 'on', true);
    update teams set
      price = v_new_price,
      chg = v_pct,
      updated_at = now(),
      ucl_stage = case when p_use_stage and v_stage is not null then v_stage else ucl_stage end,
      closed = case when p_use_stage and v_stage = 'out' then true else closed end
    where id = v_team;
    perform set_config('pm.history_written', 'off', true);

    if p_use_stage and v_stage = 'winners' then
      perform ucl_cash_out(v_team, 'cashout');
      update teams set closed = true where league = 'championsleague' and not closed;
    end if;
  end loop;

  update match_events set
    status = 'approved',
    reviewed_by = p_reviewer,
    reviewed_at = now()
  where id = p_event_id;
end;
$function$;

revoke execute on function public.apply_match_event_core(uuid, boolean, text) from public, anon, authenticated, service_role;

-- Stage results nobody approved or rejected within 12 hours apply as
-- proposed. Returns how many were applied. Service role only (the price
-- updater calls it on every run).
create or replace function public.apply_overdue_stage_events()
 returns integer
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  v_id uuid;
  v_count integer := 0;
begin
  for v_id in
    select id from match_events
    where status = 'pending'
      and created_at <= now() - interval '12 hours'
      and (coalesce(home_stage, 'playoff') <> 'playoff' or coalesce(away_stage, 'playoff') <> 'playoff')
    order by created_at
    for update skip locked
  loop
    perform apply_match_event_core(v_id, true, 'auto (12h)');
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$function$;

revoke execute on function public.apply_overdue_stage_events() from public, anon, authenticated;
grant execute on function public.apply_overdue_stage_events() to service_role;

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

-- Watchlist size: 2 Free, 5 Pro, 15 Ultimate. Players already over keep
-- their clubs but can't add more.
create or replace function public.watchlist_slot_limit()
 returns trigger
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  v_count int;
  v_limit int;
begin
  v_limit := case user_tier(new.user_id) when 'ultimate' then 15 when 'pro' then 5 else 2 end;
  select count(*) into v_count from watchlist where user_id = new.user_id;
  if v_count >= v_limit then
    raise exception 'Watchlist full: your plan allows % clubs.', v_limit;
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
    -- Skip if the caller has already logged this change: it sets
    -- pm.history_written for the update (see apply_match_event_core), or
    -- logged it a moment ago, so an approved match does not produce two
    -- history rows.
    if coalesce(current_setting('pm.history_written', true), '') <> 'on'
       and not exists (
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
  where w.team_id = new.id
    and w.alert_below is not null
    and old.price >= w.alert_below
    and new.price <  w.alert_below
    and user_tier(w.user_id) <> 'free';

  -- Upward crossings
  insert into notifications (user_id, team_id, kind, threshold, price, team_name)
  select w.user_id, new.id, 'above', w.alert_above, new.price, new.name
  from watchlist w
  where w.team_id = new.id
    and w.alert_above is not null
    and old.price <= w.alert_above
    and new.price >  w.alert_above
    and user_tier(w.user_id) <> 'free';

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

-- ===================================================================
-- Error log (supabase-error-log.sql): browser errors reported by the
-- site, listed in admin under Errors.
-- ===================================================================

create table if not exists public.client_errors (
  id          bigserial primary key,
  first_seen  timestamptz not null default now(),
  last_seen   timestamptz not null default now(),
  count       integer not null default 1,
  message     text not null,
  source      text,              -- file:line:column, e.g. /index.html:3120:14
  page        text,              -- the page and section it happened on
  user_agent  text,              -- the browser and device
  signed_in   boolean not null default false
);
create index if not exists client_errors_last_seen on public.client_errors (last_seen desc);
alter table public.client_errors enable row level security;

drop policy if exists "admin reads errors" on public.client_errors;
create policy "admin reads errors" on public.client_errors
  for select using ((auth.jwt() ->> 'email') = 'pitchmarketadmin@gmail.com');
drop policy if exists "admin clears errors" on public.client_errors;
create policy "admin clears errors" on public.client_errors
  for delete using ((auth.jwt() ->> 'email') = 'pitchmarketadmin@gmail.com');

-- Called by the site: records one error report.
create or replace function public.log_client_error(p_message text, p_source text, p_page text, p_agent text)
 returns void
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  v_msg text := left(btrim(coalesce(p_message, '')), 500);
  v_src text := left(coalesce(p_source, ''), 300);
  v_id bigint;
begin
  if v_msg = '' then return; end if;
  -- Seen today already: count it.
  select id into v_id from client_errors
  where message = v_msg and coalesce(source, '') = v_src and last_seen > now() - interval '1 day'
  order by last_seen desc limit 1;
  if v_id is not null then
    update client_errors set count = least(count + 1, 1000000), last_seen = now(),
      page = left(p_page, 300), user_agent = left(p_agent, 300), signed_in = auth.uid() is not null
    where id = v_id;
    return;
  end if;
  -- Flood guard: at most 200 new errors an hour, and the newest 2,000 kept.
  if (select count(*) from client_errors where first_seen > now() - interval '1 hour') >= 200 then return; end if;
  insert into client_errors (message, source, page, user_agent, signed_in)
  values (v_msg, nullif(v_src, ''), left(p_page, 300), left(p_agent, 300), auth.uid() is not null);
  delete from client_errors where id in (select id from client_errors order by last_seen desc offset 2000);
end;
$function$;
revoke execute on function public.log_client_error(text, text, text, text) from public;
grant execute on function public.log_client_error(text, text, text, text) to anon, authenticated;

-- ===================================================================
-- Plans (supabase-pro-1.sql): Stripe subscriptions, manual grants,
-- user_tier, the leaderboard with tiers, admin plan tools and portfolio
-- snapshots. The watchlist cap and price alerts above use user_tier.
-- ===================================================================

-- ---------- Tables ----------

-- One row per Stripe subscription (the id is Stripe's subscription id).
create table if not exists public.subscriptions (
  id                    text primary key,
  user_id               uuid not null references auth.users(id) on delete cascade,
  stripe_customer_id    text,
  tier                  text check (tier in ('pro', 'ultimate')),
  status                text not null,
  current_period_start  timestamptz,
  current_period_end    timestamptz,
  cancel_at_period_end  boolean not null default false,
  livemode              boolean not null,
  updated_at            timestamptz not null default now()
);
-- For a database that ran an earlier draft of this file.
alter table public.subscriptions add column if not exists current_period_start timestamptz;
create index if not exists subscriptions_user on public.subscriptions (user_id);
alter table public.subscriptions enable row level security;
drop policy if exists "players read own subscriptions" on public.subscriptions;
create policy "players read own subscriptions" on public.subscriptions
  for select using (auth.uid() = user_id);

-- Plans given by hand from admin. No policies: only the admin functions
-- below read or write it.
create table if not exists public.grants (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  tier        text check (tier in ('pro', 'ultimate')),
  until       timestamptz,          -- null: no end date
  note        text,
  granted_at  timestamptz not null default now()
);
alter table public.grants enable row level security;

-- Players given Pro or Ultimate by hand under the old profiles flags
-- (is_pro, is_ultimate, pro_expires_at) keep it as a grant. A player who
-- already has a grant keeps that one.
insert into public.grants (user_id, tier, until, note)
select id, case when is_ultimate then 'ultimate' else 'pro' end, pro_expires_at, 'migrated from profiles'
from public.profiles
where (is_pro or is_ultimate) and (pro_expires_at is null or pro_expires_at > now())
on conflict (user_id) do nothing;

-- Each player's portfolio value at the end of each day (UK date).
create table if not exists public.portfolio_snapshots (
  user_id  uuid references auth.users(id) on delete cascade,
  day      date,
  value    numeric not null,
  primary key (user_id, day)
);
alter table public.portfolio_snapshots enable row level security;
drop policy if exists "players read own snapshots" on public.portfolio_snapshots;
create policy "players read own snapshots" on public.portfolio_snapshots
  for select using (auth.uid() = user_id);

-- Payments settings, edited in admin. Starts in test mode.
insert into public.site_settings (key, value)
values ('payments', '{"mode":"test","portal_url":"","links":{}}'::jsonb)
on conflict (key) do nothing;

-- ---------- Settings ----------

-- Whether the caller is the admin account.
create or replace function public.is_admin()
 returns boolean
 language sql
 stable
 set search_path = public
as $function$
  select coalesce((auth.jwt() ->> 'email') = 'pitchmarketadmin@gmail.com', false);
$function$;

-- Payments mode (off, test or live), portal link and buy links.
create or replace function public.payments_settings()
 returns jsonb
 language sql
 stable
 security definer
 set search_path = public
as $function$
  select coalesce(
    (select value from site_settings where key = 'payments'),
    '{"mode":"test","portal_url":"","links":{}}'::jsonb);
$function$;

-- When the current season started, or null before the first reset (or if
-- the season row doesn't hold a valid date).
create or replace function public.season_start()
 returns timestamptz
 language plpgsql
 stable
 security definer
 set search_path = public
as $function$
declare
  v_start text;
begin
  select value ->> 'start' into v_start from site_settings where key = 'season';
  return nullif(btrim(v_start), '')::timestamptz;
exception when others then
  return null;                      -- not a valid date: no season
end;
$function$;

-- ---------- Plans ----------

-- free 0, pro 1, ultimate 2.
create or replace function public.tier_rank(p_tier text)
 returns integer
 language sql
 immutable
 set search_path = public
as $function$
  select case p_tier when 'ultimate' then 2 when 'pro' then 1 else 0 end;
$function$;

-- Whether a subscription gives its tier now. Active or trialing: until 3
-- days after its period ends (the 3 days only cover a late or lost
-- webhook; a cancelled subscription stops when Stripe reports it
-- canceled). Past due (a failed renewal, where Stripe has already moved
-- the period on): only for 3 days from the start of the new period. A
-- test purchase doesn't count once payments mode is live.
drop function if exists public.subscription_counts(text, timestamptz, boolean);
create or replace function public.subscription_counts(p_status text, p_period_start timestamptz,
  p_period_end timestamptz, p_livemode boolean)
 returns boolean
 language sql
 stable
 set search_path = public
as $function$
  select coalesce(
    p_period_end > now() - interval '3 days'
    and (p_status in ('active', 'trialing')
         or (p_status = 'past_due' and p_period_start > now() - interval '3 days'))
    and (p_livemode or coalesce(payments_settings() ->> 'mode', 'test') <> 'live'),
    false);
$function$;

-- A player's plan: {tier, source, period_end, cancel_at_period_end, test,
-- has_subscription}. The highest tier of a counting subscription and an
-- unexpired grant wins; on a tie the subscription is the source.
create or replace function public.plan_of(p_user uuid)
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path = public
as $function$
declare
  s subscriptions%rowtype;
  g grants%rowtype;
  v_sub int := 0;
  v_grant int := 0;
begin
  select * into s from subscriptions
  where user_id = p_user and tier is not null
    and subscription_counts(status, current_period_start, current_period_end, livemode)
  order by tier_rank(tier) desc, current_period_end desc
  limit 1;
  if found then v_sub := tier_rank(s.tier); end if;

  select * into g from grants
  where user_id = p_user and tier is not null and (until is null or until > now());
  if found then v_grant := tier_rank(g.tier); end if;

  if v_sub > 0 and v_sub >= v_grant then
    return jsonb_build_object('tier', s.tier, 'source', 'stripe',
      'period_end', s.current_period_end, 'cancel_at_period_end', s.cancel_at_period_end,
      'test', not s.livemode, 'has_subscription', true);
  elsif v_grant > 0 then
    return jsonb_build_object('tier', g.tier, 'source', 'grant',
      'period_end', g.until, 'cancel_at_period_end', false,
      'test', coalesce(not s.livemode, false), 'has_subscription', s.id is not null);
  else
    return jsonb_build_object('tier', 'free', 'source', 'free',
      'period_end', null, 'cancel_at_period_end', false,
      'test', false, 'has_subscription', false);
  end if;
end;
$function$;

-- 'free', 'pro' or 'ultimate'. Every limit checks this.
create or replace function public.user_tier(p_user uuid)
 returns text
 language sql
 stable
 security definer
 set search_path = public
as $function$
  select plan_of(p_user) ->> 'tier';
$function$;

-- Called by the page: the signed-in player's plan.
create or replace function public.my_plan()
 returns jsonb
 language sql
 stable
 security definer
 set search_path = public
as $function$
  select case when auth.uid() is null
    then jsonb_build_object('tier', 'free', 'source', 'free')
    else plan_of(auth.uid()) end;
$function$;

-- ---------- Leaderboard ----------

-- Also added by supabase-names-and-leaderboard.sql; repeated here so this
-- file works whichever is run first.
alter table public.profiles add column if not exists hidden_from_leaderboard boolean not null default false;

-- Top players by coins plus holdings at current prices, with their tier
-- for badges. Hidden accounts (the organiser's) are left out.
create function public.get_leaderboard(p_limit integer default 20)
 returns table(display_name text, portfolio_value numeric, tier text)
 language sql
 stable
 security definer
 set search_path = public
as $function$
  select top.display_name, top.portfolio_value, user_tier(top.id) as tier
  from (
    select
      p.id,
      coalesce(p.display_name, 'Trader') as display_name,
      p.coin_balance + coalesce(sum(h.shares * t.price), 0) as portfolio_value
    from profiles p
    left join holdings h on h.user_id = p.id
    left join teams t on t.id = h.team_id
    where not p.hidden_from_leaderboard
    group by p.id, p.display_name, p.coin_balance
    order by portfolio_value desc
    limit p_limit
  ) top
  order by top.portfolio_value desc;
$function$;

-- ---------- Admin ----------

-- Everyone on Pro or Ultimate, plus every grant (even one that has ended).
-- tier/source/until are the plan in force; has_grant, grant_tier and
-- grant_until describe the grant on its own (it may be outranked or ended).
drop function if exists public.admin_list_plans();
create function public.admin_list_plans()
 returns table(user_id uuid, email text, display_name text, tier text, source text, until timestamptz, note text,
   has_grant boolean, grant_tier text, grant_until timestamptz)
 language plpgsql
 stable
 security definer
 set search_path = public
as $function$
#variable_conflict use_column
begin
  if not is_admin() then
    raise exception 'Admins only.';
  end if;
  return query
  select x.user_id, u.email::text, p.display_name,
    pl.plan ->> 'tier', pl.plan ->> 'source',
    -- The end of the plan in force; for an ended grant (free), the grant's end.
    case when pl.plan ->> 'source' = 'free' then g.until else (pl.plan ->> 'period_end')::timestamptz end,
    g.note,
    g.user_id is not null, g.tier, g.until
  from (select s.user_id from subscriptions s union select gr.user_id from grants gr) x
  join auth.users u on u.id = x.user_id
  left join profiles p on p.id = x.user_id
  left join grants g on g.user_id = x.user_id
  cross join lateral (select plan_of(x.user_id) as plan) pl
  where pl.plan ->> 'tier' <> 'free' or g.user_id is not null
  order by lower(u.email);
end;
$function$;

-- Give a player Pro or Ultimate by email, until a date (null: no end).
-- Replaces any grant they already have.
create or replace function public.admin_grant_plan(p_email text, p_tier text, p_until timestamptz, p_note text)
 returns void
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  v_user uuid;
begin
  if not is_admin() then
    raise exception 'Admins only.';
  end if;
  if p_tier is null or p_tier not in ('pro', 'ultimate') then
    raise exception 'Plan must be pro or ultimate.';
  end if;
  select id into v_user from auth.users
  where lower(email) = lower(btrim(coalesce(p_email, '')))
  order by created_at
  limit 1;
  if v_user is null then
    raise exception 'No player with that email.';
  end if;
  insert into grants (user_id, tier, until, note, granted_at)
  values (v_user, p_tier, p_until, nullif(btrim(coalesce(p_note, '')), ''), now())
  on conflict (user_id) do update
    set tier = excluded.tier, until = excluded.until, note = excluded.note, granted_at = now();
end;
$function$;

-- Take away a player's grant. A paid subscription is not affected.
create or replace function public.admin_revoke_grant(p_user uuid)
 returns void
 language plpgsql
 security definer
 set search_path = public
as $function$
begin
  if not is_admin() then
    raise exception 'Admins only.';
  end if;
  delete from grants where user_id = p_user;
end;
$function$;

-- ---------- Portfolio snapshots ----------

-- Records each player's portfolio value (coins plus holdings at current
-- prices) for the trading day that just ended. Does nothing until a season start is
-- recorded. Run again on the same day, it updates the day's values.
-- Returns the number of rows written.
create or replace function public.take_portfolio_snapshots()
 returns integer
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  v_rows integer;
begin
  if season_start() is null then
    return 0;
  end if;
  insert into portfolio_snapshots (user_id, day, value)
  -- The nightly backup runs at 03:23 UTC (3-4am UK time), after the UK date
  -- has turned over, so stamp it with the UK date 6 hours earlier: the
  -- trading day that just ended. A run after 6am UK time stamps that day.
  select p.id, ((now() at time zone 'Europe/London') - interval '6 hours')::date,
         p.coin_balance + coalesce(sum(h.shares * t.price), 0)
  from profiles p
  left join holdings h on h.user_id = p.id
  left join teams t on t.id = h.team_id
  group by p.id, p.coin_balance
  on conflict (user_id, day) do update set value = excluded.value;
  get diagnostics v_rows = row_count;
  return v_rows;
end;
$function$;

-- ---------- Who can call what ----------

grant execute on function public.is_admin() to anon, authenticated;
grant execute on function public.payments_settings() to anon, authenticated;
grant execute on function public.season_start() to anon, authenticated;
grant execute on function public.my_plan() to anon, authenticated;
grant execute on function public.get_leaderboard(integer) to anon, authenticated;

revoke execute on function public.tier_rank(text) from public, anon, authenticated;
revoke execute on function public.subscription_counts(text, timestamptz, timestamptz, boolean) from public, anon, authenticated;
revoke execute on function public.plan_of(uuid) from public, anon, authenticated;
revoke execute on function public.user_tier(uuid) from public, anon, authenticated;
grant execute on function public.plan_of(uuid) to service_role;
grant execute on function public.user_tier(uuid) to service_role;

revoke execute on function public.admin_list_plans() from public, anon;
revoke execute on function public.admin_grant_plan(text, text, timestamptz, text) from public, anon;
revoke execute on function public.admin_revoke_grant(uuid) from public, anon;
grant execute on function public.admin_list_plans() to authenticated;
grant execute on function public.admin_grant_plan(text, text, timestamptz, text) to authenticated;
grant execute on function public.admin_revoke_grant(uuid) to authenticated;

revoke execute on function public.take_portfolio_snapshots() from public, anon, authenticated;
grant execute on function public.take_portfolio_snapshots() to service_role;

-- ===================================================================
-- Private leagues (supabase-leagues-1.sql): leagues and their members
-- (one row per stint), create/join/leave/kick, invite codes, limits,
-- Ultimate branding, weekly scores (closed nightly), the Classic table and
-- Player of the week. Players reach the tables only through these
-- functions.
-- ===================================================================

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
  league_id   bigint not null references public.leagues(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  joined_at   timestamptz not null default now(),
  left_at     timestamptz,
  join_value  numeric not null,
  kicked      boolean not null default false
);
-- For databases that loaded an earlier draft without NOT NULL.
alter table public.league_members alter column league_id set not null;
alter table public.league_members alter column user_id set not null;
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
  -- member. Every current member's player lock is taken first, in user_id
  -- order (after the league row lock, the order join_league uses), so two
  -- hand-overs can't deadlock; the counts are then read under those locks.
  for v_cand in
    select user_id from league_members
    where league_id = p_league and left_at is null
    order by user_id
  loop
    perform pg_advisory_xact_lock(hashtextextended('league-player:' || v_cand::text, 0));
  end loop;
  for v_cand in
    select user_id from league_members
    where league_id = p_league and left_at is null
    order by joined_at, id
  loop
    if (select count(*) from leagues where owner_id = v_cand) < 3 then
      v_next := v_cand;
      exit;
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
-- snapshot step succeeds. A week closes once its Sunday is both on or
-- before the trading day the snapshots use (the UK date 6 hours ago) and
-- over on the UK calendar: Monday's run (trading day Sunday) closes the
-- week just after saving Sunday's snapshot, and a run by hand on Sunday
-- (even after 06:00) closes nothing. A run after 06:00 UK on Monday can't
-- save Sunday's value (it stamps Monday), so if Monday's early run was
-- missed, a late Monday run voids that week. A week counts if its previous
-- Sunday is on or after the season start date; it's scored if both its
-- Sunday and the previous Sunday have snapshots, otherwise void. Does
-- nothing before a season start. p_now (the time of the run) is for tests
-- only.
drop function if exists public.close_matchweeks(date);   -- an earlier draft
create or replace function public.close_matchweeks(p_now timestamptz default null)
 returns integer
 language plpgsql
 volatile
 security definer
 set search_path = public
as $function$
declare
  v_start timestamptz := season_start();
  v_now timestamptz := coalesce(p_now, now());
  v_calendar_day date := (v_now at time zone 'Europe/London')::date;
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
    -- Sundays before today (UK time). That is never later than the
    -- trading day, so a Sunday's snapshots (stamped with that trading day)
    -- were saved by the time it closes: the backup calls this only after
    -- this run's snapshots.
    select d::date
    from generate_series(v_first, v_calendar_day - 1, interval '7 days') d
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
revoke execute on function public.close_matchweeks(timestamptz) from public, anon, authenticated;
grant execute on function public.close_matchweeks(timestamptz) to service_role;
revoke execute on function public.league_classic_table(bigint) from public, anon;
revoke execute on function public.league_player_of_week(bigint, integer) from public, anon;
grant execute on function public.league_classic_table(bigint) to authenticated;
grant execute on function public.league_player_of_week(bigint, integer) to authenticated;

