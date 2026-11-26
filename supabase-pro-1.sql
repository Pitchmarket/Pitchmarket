-- PitchMarket Pro and Ultimate, part 1: plans, 26 Nov 2026.
-- Run once in the Supabase SQL Editor (paste all of it, click Run). Safe to
-- run more than once. supabase-schema.sql already includes it.
--
-- What changes:
--   * New private table subscriptions: one row per Stripe subscription,
--     written only by the stripe-webhook Edge Function. Players can read
--     their own rows.
--   * New private table grants: Pro or Ultimate given by hand from admin,
--     with an optional end date.
--   * user_tier(player) says free, pro or ultimate: the highest of a paid
--     subscription that counts (active or trialing with its period ended
--     less than 3 days ago, or past_due for 3 days from the start of the
--     new period, and not a test purchase once payments mode is live) and
--     a grant that hasn't ended. Everything below uses it.
--   * Players given Pro or Ultimate by hand under the old profiles flags
--     (is_pro, is_ultimate, pro_expires_at) get a matching grant; after
--     that those flags are no longer read.
--   * my_plan() tells the page the signed-in player's plan.
--   * Watchlist caps are now 2 (Free), 5 (Pro) and 15 (Ultimate). Players
--     already over keep their clubs but can't add more.
--   * Price alerts fire for any Pro or Ultimate player.
--   * The leaderboard also returns each player's tier, for badges. Adds
--     profiles.hidden_from_leaderboard if supabase-names-and-leaderboard.sql
--     hasn't been run yet.
--   * Admin can list plans, give a plan by email and take a grant away.
--   * Payments settings (site_settings key "payments") start in test mode.
--   * Portfolio snapshots: take_portfolio_snapshots(), called by the nightly
--     backup, records each player's portfolio value once a season start is
--     recorded (site_settings key "season", set by supabase-season-reset.sql).
--     Until then it does nothing.

begin;

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

-- ---------- Watchlist caps and price alerts ----------

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

drop trigger if exists watchlist_limit_check on public.watchlist;
create trigger watchlist_limit_check
  before insert on public.watchlist
  for each row execute function public.watchlist_slot_limit();

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

-- ---------- Leaderboard ----------

-- Also added by supabase-names-and-leaderboard.sql; repeated here so this
-- file works whichever is run first.
alter table public.profiles add column if not exists hidden_from_leaderboard boolean not null default false;

-- Top players by coins plus holdings at current prices, with their tier
-- for badges. Hidden accounts (the organiser's) are left out.
drop function if exists public.get_leaderboard(integer);
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

commit;

-- Check: the payments settings, and how many subscriptions and grants are stored.
select public.payments_settings() as payments,
  (select count(*) from public.subscriptions) as subscriptions,
  (select count(*) from public.grants) as grants;
