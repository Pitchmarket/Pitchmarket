-- PitchMarket error log, 26 Nov 2026.
-- Run once in the Supabase SQL Editor (paste all of it, click Run). Safe to
-- run more than once. supabase-schema.sql already includes it.
--
-- When something breaks on a player's device, the site reports it here (at
-- most 5 reports per visit), and the admin page lists them under "Errors".
-- The same error again within a day only adds to its count, and at most 200
-- new errors an hour are kept, so a broken release or a spammer can't fill
-- the database. Players can send reports but never read them.

begin;

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

commit;
