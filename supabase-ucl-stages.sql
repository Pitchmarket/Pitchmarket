-- PitchMarket Champions League stages, part 1: the database, 28 Nov 2026.
-- Run once in the Supabase SQL Editor (paste all of it, click Run), after
-- supabase-leagues-1.sql. Safe to run more than once. supabase-schema.sql
-- already includes it.
--
-- What changes:
--   * teams gets closed (no trading at all when true) and ucl_stage (how far
--     a Champions League club has got: league, playoff, last16, quarters,
--     semis, final, out, winners or refunded).
--   * match_events gets a stage result per side (home_stage, away_stage:
--     playoff, last16, quarters, semis, final, winners or out), the AI's own
--     move (home_ai_pct, away_ai_pct), the stage multiplier
--     (home_multiplier, away_multiplier) and stage_rejected. For a stage
--     event home_delta_pct / away_delta_pct hold the move to apply (boosted,
--     or -100 for out).
--   * fixtures gets stage and leg, for later projects.
--   * notifications can also be a cashout or a refund: threshold is the
--     shares paid out and price the price per share.
--   * approve_match_event and auto_apply_match_event now share
--     apply_match_event_core. Approving a stage event applies the boosted
--     move and the stage; out sends the club to 0 and closes it; winners
--     cashes out every holder of the club (ucl_cash_out) and closes every
--     Champions League club. Rejecting a stage event applies it as a normal
--     match (the AI's move, no stage) and marks it stage_rejected. Normal
--     events behave as before, except an approved match no longer also
--     logs a "Manual adjustment" history row.
--   * auto_apply_match_event refuses stage events other than playoff.
--   * apply_overdue_stage_events (service role only) applies stage events
--     left pending for 12 hours.
--   * trade() refuses closed clubs.
--   * approve_match_event checks the admin with is_admin(), so a call
--     with no email claim is refused too.
--   * log_manual_price_change skips its "Manual adjustment" row while
--     pm.history_written is on (set by apply_match_event_core around its
--     teams update, which has already written the match's history row).

begin;

-- ---------- Columns ----------

alter table public.teams add column if not exists closed boolean not null default false;
alter table public.teams add column if not exists ucl_stage text
  check (ucl_stage in ('league', 'playoff', 'last16', 'quarters', 'semis', 'final', 'out', 'winners', 'refunded'));

alter table public.match_events add column if not exists home_stage text
  check (home_stage in ('playoff', 'last16', 'quarters', 'semis', 'final', 'winners', 'out'));
alter table public.match_events add column if not exists away_stage text
  check (away_stage in ('playoff', 'last16', 'quarters', 'semis', 'final', 'winners', 'out'));
alter table public.match_events add column if not exists home_ai_pct numeric;
alter table public.match_events add column if not exists away_ai_pct numeric;
alter table public.match_events add column if not exists home_multiplier numeric;
alter table public.match_events add column if not exists away_multiplier numeric;
alter table public.match_events add column if not exists stage_rejected boolean not null default false;

alter table public.fixtures add column if not exists stage text;
alter table public.fixtures add column if not exists leg smallint;

alter table public.notifications drop constraint if exists notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('below', 'above', 'cashout', 'refund'));

-- ---------- Trading ----------

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

-- ---------- Applying match events ----------

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

-- ---------- History ----------

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

commit;
