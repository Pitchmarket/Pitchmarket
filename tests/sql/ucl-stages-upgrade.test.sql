-- Running supabase-ucl-stages.sql (twice) on an installed database: an
-- existing club stays open and a pending normal event still approves.
-- Commits (the upgrade file has its own transaction), so it deletes its
-- rows at the end.

insert into auth.users (id, email) values
  ('c2000000-0000-0000-0000-000000000002', 'upgrade@example.com');
insert into public.teams (id, name, league, league_label, tier, price) values
  ('c2000000-0000-0000-0000-0000000000c1', 'Upgrade FC', 'championsleague', 'Champions League', 'A', 20);
insert into public.match_events (id, source_match_id, home_team_name, away_team_name, home_score, away_score,
                                 home_team_id, home_delta_pct)
values ('c2000000-0000-0000-0000-0000000000e1', 'upgrade-1', 'Upgrade FC', 'Visitors', 1, 0,
        'c2000000-0000-0000-0000-0000000000c1', 5);

\ir ../../supabase-ucl-stages.sql
\ir ../../supabase-ucl-stages.sql

do $$ begin
  assert (select not closed and ucl_stage is null from public.teams
          where id = 'c2000000-0000-0000-0000-0000000000c1'), 'existing club stays open';
  perform set_config('request.jwt.claims', '{"email":"pitchmarketadmin@gmail.com"}', true);
  perform public.approve_match_event('c2000000-0000-0000-0000-0000000000e1', true);
  assert (select status = 'approved' and not stage_rejected from public.match_events
          where id = 'c2000000-0000-0000-0000-0000000000e1'), 'pending event approves';
  assert (select price from public.teams where id = 'c2000000-0000-0000-0000-0000000000c1') = 21.00, 'move applied';
  insert into public.notifications (user_id, team_id, kind, threshold, price, team_name)
  values ('c2000000-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-0000000000c1', 'cashout', 3, 21, 'Upgrade FC');
end $$;

delete from public.match_events where id = 'c2000000-0000-0000-0000-0000000000e1';
delete from public.teams where id = 'c2000000-0000-0000-0000-0000000000c1';
delete from auth.users where id = 'c2000000-0000-0000-0000-000000000002';
