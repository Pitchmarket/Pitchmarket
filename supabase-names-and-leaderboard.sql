-- PitchMarket display names and leaderboard, 19 Nov 2026.
-- Run once in the Supabase SQL Editor (paste all of it, click Run).
-- Safe to run more than once. supabase-schema.sql already includes it.
--
-- 1. Display names are unique, ignoring capitals, so nobody can pose as
--    another player.
-- 2. Names starting with "Trader-" are kept for the automatic default.
-- 3. Accounts can be hidden from the leaderboard. This hides the admin
--    account and 27hufferdinea, since the organiser runs the competition
--    rather than playing in it.
--
-- The last statement lists every hidden account, so you can check the
-- right ones were caught.

begin;

-- Give any duplicate names (ignoring capitals) back the default, keeping
-- the oldest account's name, so the unique index below can be created.
update public.profiles p
set display_name = 'Trader-' || substr(p.id::text, 1, 6)
from (
  select id, row_number() over (partition by lower(display_name) order by created_at, id) as n
  from public.profiles
  where display_name is not null
) d
where d.id = p.id and d.n > 1;

create unique index if not exists profiles_display_name_unique
  on public.profiles (lower(display_name));

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

alter table public.profiles
  add column if not exists hidden_from_leaderboard boolean not null default false;

update public.profiles
set hidden_from_leaderboard = true
where lower(email) = 'pitchmarketadmin@gmail.com'
   or lower(split_part(email, '@', 1)) = '27hufferdinea'
   or lower(display_name) = '27hufferdinea';

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

commit;

-- Check: these accounts are now hidden from the leaderboard.
select email, display_name from public.profiles where hidden_from_leaderboard order by email;
