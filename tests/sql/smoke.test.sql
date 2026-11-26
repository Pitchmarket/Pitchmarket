do $$ begin
  assert (select count(*) from pg_proc where proname = 'get_leaderboard') = 1, 'get_leaderboard missing';
end $$;
