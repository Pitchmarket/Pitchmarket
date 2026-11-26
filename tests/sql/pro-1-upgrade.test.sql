-- Running supabase-pro-1.sql (twice) on an installed database: players
-- given Pro or Ultimate by hand under the old profiles flags keep it as a
-- grant. Commits (the upgrade file has its own transaction), so it
-- deletes its players at the end.

insert into auth.users (id, email) values
  ('b1000000-0000-0000-0000-000000000001', 'oldpro@example.com'),
  ('b2000000-0000-0000-0000-000000000002', 'oldult@example.com'),
  ('b3000000-0000-0000-0000-000000000003', 'oldexpired@example.com'),
  ('b4000000-0000-0000-0000-000000000004', 'hasgrant@example.com'),
  ('b5000000-0000-0000-0000-000000000005', 'plain@example.com');

update public.profiles set is_pro = true, pro_expires_at = now() + interval '30 days'
  where id = 'b1000000-0000-0000-0000-000000000001';
update public.profiles set is_pro = true, is_ultimate = true, pro_expires_at = null
  where id = 'b2000000-0000-0000-0000-000000000002';
update public.profiles set is_pro = true, pro_expires_at = now() - interval '1 day'
  where id = 'b3000000-0000-0000-0000-000000000003';
update public.profiles set is_ultimate = true
  where id = 'b4000000-0000-0000-0000-000000000004';
insert into public.grants (user_id, tier, until, note)
  values ('b4000000-0000-0000-0000-000000000004', 'pro', null, 'given in admin');

\ir ../../supabase-pro-1.sql
\ir ../../supabase-pro-1.sql

do $$ begin
  assert (select tier = 'pro' and until = (select pro_expires_at from public.profiles where id = g.user_id)
                 and note = 'migrated from profiles'
          from public.grants g where user_id = 'b1000000-0000-0000-0000-000000000001'), 'old Pro flag becomes a pro grant with its end date';
  assert (select tier = 'ultimate' and until is null from public.grants
          where user_id = 'b2000000-0000-0000-0000-000000000002'), 'old Ultimate flag becomes an ultimate grant with no end';
  assert public.user_tier('b2000000-0000-0000-0000-000000000002') = 'ultimate', 'migrated player is ultimate';
  assert not exists (select 1 from public.grants where user_id = 'b3000000-0000-0000-0000-000000000003'), 'expired old flag is not migrated';
  assert (select tier = 'pro' and note = 'given in admin' from public.grants
          where user_id = 'b4000000-0000-0000-0000-000000000004'), 'an existing grant is left alone';
  assert not exists (select 1 from public.grants where user_id = 'b5000000-0000-0000-0000-000000000005'), 'no grant for a player without flags';
  assert (select count(*) from public.grants where note = 'migrated from profiles') = 2, 'running twice migrates once';
end $$;

delete from auth.users where id in (
  'b1000000-0000-0000-0000-000000000001', 'b2000000-0000-0000-0000-000000000002',
  'b3000000-0000-0000-0000-000000000003', 'b4000000-0000-0000-0000-000000000004',
  'b5000000-0000-0000-0000-000000000005');
