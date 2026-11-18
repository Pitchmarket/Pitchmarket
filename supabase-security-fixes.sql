-- PitchMarket security fixes, 18 Nov 2026.
-- Run once in the Supabase SQL Editor (paste all of it, click Run).
-- Safe to run more than once. supabase-schema.sql already includes
-- these changes.

begin;

-- 1. Only the price updater may auto-apply match results.
--    auto_apply_match_event had no permission check, so any visitor
--    could call it. The updater uses the service role key, so it keeps
--    working.
revoke execute on function public.auto_apply_match_event(uuid) from public, anon, authenticated;
grant execute on function public.auto_apply_match_event(uuid) to service_role;

-- 2. Trades: lock the player's profile row for the whole trade, so two
--    trades sent at the same moment can't both spend the same coins or
--    sell the same shares twice. Whole shares only, capped per trade.
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

-- 3. Display names: 2-24 letters, numbers, spaces, dots, dashes or
--    underscores. Anything else (including HTML) is refused.
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

-- 4. New players get "Trader-xxxxxx" instead of the start of their email
--    address, which was shown publicly on the leaderboard.
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

--    Existing players: replace names that are just their email prefix,
--    or that break the rule above.
update profiles
set display_name = 'Trader-' || substr(id::text, 1, 6)
where display_name = split_part(email, '@', 1)
   or display_name is null
   or display_name !~ '^[A-Za-z0-9 ._-]{2,24}$';

-- 5. Pin search_path on every SECURITY DEFINER function, so none of them
--    can be tricked into using a look-alike table or function.
alter function public.approve_match_event(uuid, boolean) set search_path = public;
alter function public.auto_apply_match_event(uuid)       set search_path = public;
alter function public.clear_read_notifications()         set search_path = public;
alter function public.fire_price_alerts()                set search_path = public;
alter function public.get_leaderboard(integer)           set search_path = public;
alter function public.log_manual_price_change()          set search_path = public;
alter function public.watchlist_slot_limit()             set search_path = public;

commit;
