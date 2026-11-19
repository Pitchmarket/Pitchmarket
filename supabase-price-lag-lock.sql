-- PitchMarket price-lag lock, 19 Nov 2026.
-- Run once in the Supabase SQL Editor (paste all of it, click Run).
-- Safe to run more than once. supabase-schema.sql already includes it.
--
-- Stops players trading on a club between kickoff and the moment its
-- result is priced, when they'd know the score but the price wouldn't
-- show it yet. The price updater fills `fixtures` with each upcoming
-- match's kickoff time; trade() refuses while a club is locked.

begin;

-- 1. Fixtures, written by the price updater (service role). Players have
--    no access to the table itself.
create table if not exists public.fixtures (
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
create index if not exists fixtures_home_kickoff on public.fixtures (home_team_id, kickoff);
create index if not exists fixtures_away_kickoff on public.fixtures (away_team_id, kickoff);
alter table public.fixtures enable row level security;

-- 2. Why a club is locked, or null if it isn't. A club is locked from
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

-- 3. Every locked club, for the site to show "Paused" buttons.
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

-- 4. trade() refuses buys and sells on a locked club.
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

commit;
