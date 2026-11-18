-- PitchMarket season reset.
-- Run in the Supabase SQL Editor when a new competition starts
-- (paste all of it, click Run).
--
-- Resets player data only: everyone's holdings and trade history are
-- deleted and every balance goes back to 2,000 Fan Coins.
--
-- Kept as they are: club prices, price history (so every chart keeps
-- its data), match events, site content, accounts, display names,
-- Pro status, watchlists and price alerts.
--
-- This can't be undone. To keep a record of the old season first,
-- export the holdings, trades and profiles tables as CSV from the Table
-- Editor before running it.

begin;

delete from public.holdings;
delete from public.trades;
update public.profiles set coin_balance = 2000;

commit;

-- Check: should return 0, 0 and 0.
select
  (select count(*) from public.holdings) as holdings_left,
  (select count(*) from public.trades) as trades_left,
  (select count(*) from public.profiles where coin_balance <> 2000) as balances_not_reset;
