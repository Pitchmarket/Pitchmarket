-- PitchMarket season reset.
-- Run in the Supabase SQL Editor when a new competition starts
-- (paste all of it, click Run).
--
-- Resets player data only: everyone's holdings, trade history and
-- portfolio snapshots are deleted and every balance goes back to 2,000
-- Fan Coins. It also records the season start (site_settings key
-- "season"): portfolio snapshots and season stats count from then.
-- Needs supabase-pro-1.sql to have been run first.
--
-- Kept as they are: club prices, price history (so every chart keeps
-- its data), match events, site content, accounts, display names,
-- Pro and Ultimate plans (subscriptions and grants), watchlists and
-- price alerts.
--
-- This can't be undone. To keep a record of the old season first,
-- export the holdings, trades and profiles tables as CSV from the Table
-- Editor before running it.

begin;

delete from public.holdings;
delete from public.trades;
delete from public.portfolio_snapshots;
update public.profiles set coin_balance = 2000;

insert into public.site_settings (key, value, updated_at)
values ('season', jsonb_build_object('start', now()), now())
on conflict (key) do update set value = excluded.value, updated_at = excluded.updated_at;

commit;

-- Check: should return 0, 0, 0, 0 and the time you ran it.
select
  (select count(*) from public.holdings) as holdings_left,
  (select count(*) from public.trades) as trades_left,
  (select count(*) from public.portfolio_snapshots) as snapshots_left,
  (select count(*) from public.profiles where coin_balance <> 2000) as balances_not_reset,
  public.season_start() as season_start;
