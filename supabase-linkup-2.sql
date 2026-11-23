-- PitchMarket Daily Kickabout: every player, international teammates and
-- the shortest link, 23 Nov 2026.
-- Run once in the Supabase SQL Editor (paste all of it, click Run), after
-- supabase-kickabout-2.sql. Safe to run more than once. It includes
-- everything in supabase-squads.sql, so that file no longer needs running
-- separately. supabase-schema.sql already includes it.
--
-- Then run the "Import players for Daily Kickabout" workflow, which fills
-- in every player and their international caps.
--
-- What changes:
--   * Link-Up counts three kinds of teammate: players at the same club at
--     the same time (as before), players in the same squad right now, and
--     players capped by the same senior national team at the same time.
--   * Every active player can be used in Link-Up, not only those with a
--     career on file.
--   * When you finish Link-Up you see the shortest possible link.
--   * Scouted's Team clue works for players at clubs that aren't listed
--     for trading.

begin;

-- ---------- Columns and tables ----------

-- Whether we have the player's career, so Link-Up can show their clubs.
alter table public.players add column if not exists has_career boolean not null default false;
-- Whether that career's latest spell is at the player's current club, so
-- Journeyman never shows a trail that stops short.
alter table public.players add column if not exists career_current boolean not null default false;
-- The club the player is at now: its Wikidata ID, or "fd:<id>" for a club
-- that isn't listed on the site. Players with the same key are teammates.
alter table public.players add column if not exists club_key text;
create index if not exists players_club_key on public.players (club_key) where active;
-- Until the next import fills it in, use the site club's Wikidata ID.
update public.players p set club_key = t.wikidata_id
from public.teams t
where p.team_id = t.id and p.club_key is null and t.wikidata_id is not null;

-- Senior national-team spells, for international teammates. Hidden from
-- players (no policies), like careers.
create table if not exists public.player_intl (
  player_id   text not null references public.players(id) on delete cascade,
  team_id     text not null,      -- Wikidata ID of the national team
  team        text not null,      -- the country, e.g. "England"
  start_year  integer not null,
  end_year    integer             -- null: still being picked
);
create index if not exists player_intl_player on public.player_intl (player_id);
create index if not exists player_intl_team on public.player_intl (team_id);
alter table public.player_intl enable row level security;

-- ---------- Teammates ----------

-- Every teammate of the given players, with how they were teammates:
-- kind 1, at the same club at the same time (from careers); kind 2, in the
-- same squad right now; kind 3, capped by the same country at the same time.
-- Spell years are whole years, so a player who left in January and one who
-- joined that August both count.
create or replace function public.teammate_edges(p_ids text[])
 returns table(src text, dst text, via text, kind integer)
 language sql
 stable
 set search_path = public
as $function$
  select a.player_id, b.player_id, a.club, 1
  from player_careers a
  join player_careers b on b.club_id = a.club_id and b.player_id <> a.player_id
  where a.player_id = any(p_ids) and a.club_id is not null
    and a.start_year <= coalesce(b.end_year, extract(year from now())::int)
    and b.start_year <= coalesce(a.end_year, extract(year from now())::int)
  union all
  select a.id, b.id, a.club_name, 2
  from players a
  join players b on b.club_key = a.club_key and b.id <> a.id and b.active
  where a.id = any(p_ids) and a.active and a.club_key is not null
  union all
  select a.player_id, b.player_id, a.team || ' (international)', 3
  from player_intl a
  join player_intl b on b.team_id = a.team_id and b.player_id <> a.player_id
  where a.player_id = any(p_ids)
    and a.start_year <= coalesce(b.end_year, extract(year from now())::int)
    and b.start_year <= coalesce(a.end_year, extract(year from now())::int);
$function$;
revoke execute on function public.teammate_edges(text[]) from public, anon, authenticated;

-- How two players were teammates ("Arsenal", "England (international)"),
-- or null if they never were. A club is named before a country.
create or replace function public.teammate_club(p1 text, p2 text)
 returns text
 language sql
 stable
 set search_path = public
as $function$
  select via from teammate_edges(array[p1]) where dst = p2 order by kind limit 1;
$function$;
revoke execute on function public.teammate_club(text, text) from public, anon, authenticated;

-- Everyone who was ever a teammate of any of the given players.
create or replace function public.teammates_of(p_ids text[])
 returns table(id text)
 language sql
 stable
 set search_path = public
as $function$
  select distinct dst from teammate_edges(p_ids);
$function$;
revoke execute on function public.teammates_of(text[]) from public, anon, authenticated;

-- ---------- Shortest link ----------
--
-- A search outwards from both players at once, through active players
-- only (the ones you can pick). Side 'a' grows from the start player, side
-- 'b' from the target; where they meet is the shortest link.

-- Adds the next ring of teammates on one side.
create or replace function public.link_expand(p_side text, p_depth integer)
 returns integer
 language plpgsql
 set search_path = public
as $function$
declare
  n integer;
begin
  insert into pm_link (side, id, parent, via, depth)
  select distinct on (e.dst) p_side, e.dst, e.src, e.via, p_depth
  from teammate_edges(array(select id from pm_link where side = p_side and depth = p_depth - 1)) e
  join players p on p.id = e.dst and p.active
  order by e.dst, e.kind
  on conflict (side, id) do nothing;
  get diagnostics n = row_count;
  return n;
end;
$function$;
revoke execute on function public.link_expand(text, integer) from public, anon, authenticated;

-- The path where the two sides meet, as [{id, name, via}] from the first
-- player after the start up to the target, or null if they haven't met.
create or replace function public.link_path()
 returns jsonb
 language plpgsql
 set search_path = public
as $function$
declare
  v_meet text;
  v_cur text;
  v_out jsonb := '[]'::jsonb;
  r record;
begin
  select x.id into v_meet from pm_link x join pm_link y on y.id = x.id and y.side = 'b'
  where x.side = 'a' order by x.depth + y.depth, x.depth limit 1;
  if v_meet is null then return null; end if;
  -- Start side: from the meeting player back to the start, added in front.
  v_cur := v_meet;
  loop
    select * into r from pm_link where side = 'a' and id = v_cur;
    exit when r.parent is null;
    v_out := jsonb_build_array(jsonb_build_object('id', r.id, 'name', (select name from players where id = r.id), 'via', r.via)) || v_out;
    v_cur := r.parent;
  end loop;
  -- Target side: from the meeting player on to the target.
  v_cur := v_meet;
  loop
    select * into r from pm_link where side = 'b' and id = v_cur;
    exit when r.parent is null;
    v_out := v_out || jsonb_build_array(jsonb_build_object('id', r.parent, 'name', (select name from players where id = r.parent), 'via', r.via));
    v_cur := r.parent;
  end loop;
  return v_out;
end;
$function$;
revoke execute on function public.link_path() from public, anon, authenticated;

-- Starts a fresh search from one or both players.
create or replace function public.link_reset(p_a text, p_b text)
 returns void
 language plpgsql
 set search_path = public
as $function$
begin
  if to_regclass('pg_temp.pm_link') is null then
    create temp table pm_link (side text, id text, parent text, via text, depth integer, primary key (side, id)) on commit drop;
  else
    truncate pm_link;
  end if;
  if p_a is not null then insert into pm_link values ('a', p_a, null, null, 0); end if;
  if p_b is not null then insert into pm_link values ('b', p_b, null, null, 0); end if;
end;
$function$;
revoke execute on function public.link_reset(text, text) from public, anon, authenticated;

-- The shortest link between two players with at most 3 players in
-- between, as link_path() gives it, or null if there's none that short.
create or replace function public.shortest_link(p_a text, p_b text)
 returns jsonb
 language plpgsql
 set search_path = public
as $function$
declare
  v_path jsonb;
begin
  perform link_reset(p_a, p_b);
  v_path := link_path();
  if v_path is not null then return v_path; end if;
  perform link_expand('a', 1);  v_path := link_path(); if v_path is not null then return v_path; end if;
  perform link_expand('b', 1);  v_path := link_path(); if v_path is not null then return v_path; end if;
  perform link_expand('a', 2);  v_path := link_path(); if v_path is not null then return v_path; end if;
  perform link_expand('b', 2);  return link_path();
end;
$function$;
revoke execute on function public.shortest_link(text, text) from public, anon, authenticated;

-- ---------- Scouted ----------

create or replace function public.scouted_feedback(g public.players, a public.players, p_day date)
 returns jsonb
 language plpgsql
 stable
 set search_path = public
as $function$
declare
  g_age integer := extract(year from age(p_day, g.birth_date));
  a_age integer := extract(year from age(p_day, a.birth_date));
  g_club text := coalesce(g.club_key, g.team_id::text);
  a_club text := coalesce(a.club_key, a.team_id::text);
begin
  return jsonb_build_object(
    'id', g.id,
    'name', g.name,
    'league', jsonb_build_object('value', g.league_label,
      'result', case when g.league is null then 'unknown' when g.league = a.league then 'match' else 'miss' end),
    'team', jsonb_build_object('value', g.club_name,
      'result', case when g_club is null then 'unknown' when g_club = a_club then 'match' else 'miss' end),
    'nationality', jsonb_build_object('value', g.nationality,
      'result', case when g.nationality is null then 'unknown'
                     when lower(g.nationality) = lower(a.nationality) then 'match'
                     when g.continent is not null and g.continent = a.continent then 'close'
                     else 'miss' end),
    'age', jsonb_build_object('value', g_age,
      'result', case when g_age is null then 'unknown' when g_age = a_age then 'match' when abs(g_age - a_age) <= 2 then 'close' else 'miss' end,
      'dir', case when g_age is null or g_age = a_age then null when a_age > g_age then 'up' else 'down' end),
    'position', jsonb_build_object('value', g.position_group,
      'result', case when g.position_group is null then 'unknown' when g.position_group = a.position_group then 'match' else 'miss' end)
  );
end;
$function$;
revoke execute on function public.scouted_feedback(public.players, public.players, date) from public, anon, authenticated;

-- ---------- Daily puzzles ----------

-- Today's puzzle for a game, made the first time anyone asks for it.
create or replace function public.daily_puzzle(p_game text)
 returns public.daily_puzzles
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  v_day date := kickabout_day();
  v_row daily_puzzles;
  v_a text;
  v_b text;
  v_data jsonb;
  v_cand text;
  v_path jsonb;
  v_kinds text[];
  v_qs jsonb := '[]'::jsonb;
  v_question jsonb;
  k text;
begin
  select * into v_row from daily_puzzles where day = v_day and game = p_game;
  if found then return v_row; end if;

  if p_game = 'scouted' then
    -- One of the 300 best-known players with every clue filled in, not
    -- used in the last 120 days.
    select id into v_a from (
      select p.id from players p
      where p.active and p.birth_date is not null and p.nationality is not null
        and p.position_group is not null and p.team_id is not null
        and p.id not in (select d.player_id from daily_puzzles d
                         where d.game = p_game and d.day > v_day - 120 and d.player_id is not null)
      order by p.fame desc limit 300) pool
    order by random() limit 1;

  elsif p_game = 'journeyman' then
    -- A proper trail: 4+ spells at 3+ different clubs, every spell dated,
    -- and up to date with the player's current club.
    select id into v_a from (
      select p.id from players p
      where p.active and p.career_current
        and (select count(*) from player_careers c where c.player_id = p.id) >= 4
        and (select count(distinct c.club) from player_careers c where c.player_id = p.id) >= 3
        and not exists (select 1 from player_careers c where c.player_id = p.id and c.start_year is null)
        and p.id not in (select d.player_id from daily_puzzles d
                         where d.game = p_game and d.day > v_day - 120 and d.player_id is not null)
      order by p.fame desc limit 300) pool
    order by random() limit 1;

  elsif p_game = 'linkup' then
    -- Two well-known players who were never teammates. Prefer a pair with
    -- two players in between at best, else one. The shortest link is kept
    -- to show at the end.
    for attempt in 1..15 loop
      select id into v_a from (
        select p.id from players p
        where p.active and exists (select 1 from player_careers c where c.player_id = p.id and c.club_id is not null)
          and p.id not in (select d.player_id from daily_puzzles d
                           where d.game = p_game and d.day > v_day - 60 and d.player_id is not null)
        order by p.fame desc limit 300) pool
      order by random() limit 1;
      exit when v_a is null;
      -- Everyone within two steps of the start player.
      perform link_reset(v_a, null);
      perform link_expand('a', 1);
      perform link_expand('a', 2);
      -- A well-known player further away whose teammates reach that ring:
      -- three steps, two players in between.
      for v_cand in
        select p.id from players p
        where p.active and p.fame >= 30 and exists (select 1 from player_careers c where c.player_id = p.id)
          and not exists (select 1 from pm_link l where l.side = 'a' and l.id = p.id)
        order by random() limit 40
      loop
        delete from pm_link where side = 'b';
        insert into pm_link values ('b', v_cand, null, null, 0);
        perform link_expand('b', 1);
        v_path := link_path();
        if v_path is not null then v_b := v_cand; exit; end if;
      end loop;
      if v_b is null then
        -- Else someone two steps away: one player in between.
        delete from pm_link where side = 'b';
        select l.id into v_b from pm_link l join players p on p.id = l.id
        where l.side = 'a' and l.depth = 2 and p.fame >= 30
          and exists (select 1 from player_careers c where c.player_id = p.id)
        order by random() limit 1;
        if v_b is not null then
          insert into pm_link values ('b', v_b, null, null, 0);
          v_path := link_path();
        end if;
      end if;
      if v_b is not null and v_path is not null then
        v_data := jsonb_build_object('par', jsonb_array_length(v_path) - 1, 'best', v_path);
        exit;
      end if;
      v_b := null;
    end loop;
    if v_b is null then v_a := null; end if;

  elsif p_game = 'ballknowledge' then
    -- Four questions of different kinds, in random order.
    select array_agg(kind order by random()) into v_kinds
    from unnest(array['previous_club','nationality','played_for','oldest','league','riser']) kind;
    foreach k in array v_kinds loop
      exit when jsonb_array_length(v_qs) = 4;
      v_question := make_question(k);
      if v_question is not null then v_qs := v_qs || jsonb_build_array(v_question); end if;
    end loop;
    if jsonb_array_length(v_qs) = 4 then v_data := jsonb_build_object('questions', v_qs); v_a := 'quiz'; end if;
  else
    raise exception 'Unknown game';
  end if;

  if v_a is null then
    raise exception 'Today''s puzzle isn''t ready yet: the player list is still loading. Try again later.';
  end if;
  insert into daily_puzzles (day, game, player_id, player2_id, data)
  values (v_day, p_game, case when p_game = 'ballknowledge' then null else v_a end, v_b, v_data)
  on conflict do nothing;
  select * into v_row from daily_puzzles where day = v_day and game = p_game;
  return v_row;
end;
$function$;
revoke execute on function public.daily_puzzle(text) from public, anon, authenticated;

-- ---------- Game state ----------

-- Everything the page needs to draw a game for the signed-in player (or a
-- signed-out visitor, who sees a fresh game). Answers only appear once
-- the player has finished.
create or replace function public.kickabout_state(p_game text)
 returns jsonb
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  v_day date := kickabout_day();
  v_puzzle daily_puzzles;
  v_answer players;
  v_target players;
  v_play game_plays;
  v_guesses text[];
  v_finished boolean;
  v_rows integer;
  v_shown integer;
  v_result jsonb;
  v_end text;
  v_club text;
  v_best jsonb;
  v_chain jsonb := '[]'::jsonb;
  v_strikes jsonb := '[]'::jsonb;
  v_qs jsonb;
  v_out jsonb := '[]'::jsonb;
  g text;
  i integer;
begin
  if p_game not in ('scouted', 'journeyman', 'linkup', 'ballknowledge') then raise exception 'Unknown game'; end if;
  v_puzzle := daily_puzzle(p_game);
  select * into v_answer from players where id = v_puzzle.player_id;
  select * into v_play from game_plays where user_id = auth.uid() and day = v_day and game = p_game;
  v_guesses := coalesce(v_play.guesses, '{}');
  v_finished := coalesce(v_play.finished, false);

  v_result := jsonb_build_object(
    'game', p_game, 'day', v_day, 'signed_in', auth.uid() is not null,
    'finished', v_finished, 'won', coalesce(v_play.won, false), 'coins', coalesce(v_play.coins, 0));

  if p_game = 'scouted' then
    return v_result || jsonb_build_object(
      'max_guesses', 10,
      'answer', case when v_finished then jsonb_build_object('id', v_answer.id, 'name', v_answer.name) end,
      'guesses', coalesce((
        select jsonb_agg(scouted_feedback(gp, v_answer, v_day) order by u.n)
        from unnest(v_guesses) with ordinality as u(id, n)
        join players gp on gp.id = u.id
      ), '[]'::jsonb));

  elsif p_game = 'journeyman' then
    -- The first spell shows from the start, each wrong guess shows one
    -- more, and with all showing there's one last guess: N spells, N guesses.
    select count(*) into v_rows from player_careers where player_id = v_answer.id;
    v_shown := case when v_finished then v_rows else least(v_rows, 1 + coalesce(array_length(v_guesses, 1), 0)) end;
    return v_result || jsonb_build_object(
      'max_guesses', v_rows, 'total_rows', v_rows,
      'answer', case when v_finished then jsonb_build_object('id', v_answer.id, 'name', v_answer.name) end,
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object('club', c.club, 'start', c.start_year, 'end', c.end_year,
                                            'apps', c.apps, 'goals', c.goals, 'loan', c.loan) order by c.seq)
        from player_careers c where c.player_id = v_answer.id and c.seq <= v_shown), '[]'::jsonb),
      'guesses', coalesce((
        select jsonb_agg(jsonb_build_object('id', gp.id, 'name', gp.name) order by u.n)
        from unnest(v_guesses) with ordinality as u(id, n) join players gp on gp.id = u.id), '[]'::jsonb));

  elsif p_game = 'linkup' then
    -- Replay the guesses: a teammate of the chain's last player joins the
    -- chain, anyone else is a miss. Guessing the target checks the final link.
    select * into v_target from players where id = v_puzzle.player2_id;
    -- The shortest link, worked out once (puzzles made before this update
    -- don't have it yet) and shown when you finish.
    if v_finished and v_puzzle.data->'best' is null then
      v_best := shortest_link(v_answer.id, v_target.id);
      if v_best is not null then
        update daily_puzzles set data = coalesce(data, '{}'::jsonb)
          || jsonb_build_object('best', v_best, 'par', jsonb_array_length(v_best) - 1)
        where day = v_puzzle.day and game = p_game
        returning * into v_puzzle;
      end if;
    end if;
    v_end := v_answer.id;
    foreach g in array v_guesses loop
      v_club := teammate_club(v_end, g);
      if g = v_target.id then
        if v_club is not null then
          v_chain := v_chain || jsonb_build_array(jsonb_build_object('id', g, 'name', v_target.name, 'via', v_club, 'target', true));
        else
          v_strikes := v_strikes || jsonb_build_array(jsonb_build_object('id', g, 'name', v_target.name, 'reason', 'not_linked'));
        end if;
      elsif v_club is not null then
        v_chain := v_chain || jsonb_build_array(jsonb_build_object('id', g, 'name', (select name from players where id = g), 'via', v_club));
        v_end := g;
      else
        v_strikes := v_strikes || jsonb_build_array(jsonb_build_object('id', g, 'name', (select name from players where id = g),
          'reason', 'not_teammates',
          'after', (select name from players where id = v_end)));
      end if;
    end loop;
    return v_result || jsonb_build_object(
      'max_guesses', 6, 'par', v_puzzle.data->'par',
      'start', jsonb_build_object('id', v_answer.id, 'name', v_answer.name, 'club', v_answer.club_name, 'trail', club_trail(v_answer.id)),
      'target', jsonb_build_object('id', v_target.id, 'name', v_target.name, 'club', v_target.club_name, 'trail', club_trail(v_target.id)),
      'chain', v_chain, 'strikes', v_strikes, 'used', coalesce(array_length(v_guesses, 1), 0),
      'best', case when v_finished then v_puzzle.data->'best' end,
      -- How the chain's last player links to the target, once they do.
      'closing', case when not exists (select 1 from jsonb_array_elements(v_chain) e where e->>'target' = 'true')
                 then teammate_club(v_end, v_target.id) end);

  else -- ballknowledge
    v_qs := v_puzzle.data->'questions';
    for i in 0..jsonb_array_length(v_qs) - 1 loop
      v_out := v_out || jsonb_build_array(
        jsonb_build_object('q', v_qs->i->'q', 'options', v_qs->i->'options')
        || case when i < coalesce(array_length(v_guesses, 1), 0)
                then jsonb_build_object('chosen', v_guesses[i + 1]::int, 'answer', v_qs->i->'answer')
                else '{}'::jsonb end);
    end loop;
    return v_result || jsonb_build_object(
      'max_guesses', 4, 'needed', 3, 'questions', v_out,
      'correct', (select count(*) from unnest(v_guesses) with ordinality u(c, n)
                  where u.c::int = (v_qs->(u.n::int - 1)->>'answer')::int));
  end if;
end;
$function$;

-- Make a guess (a player's Wikidata ID, or for Ball Knowledge the chosen
-- option, 0 to 3). Pays 25 Fan Coins for a win, once per game per day.
create or replace function public.kickabout_guess(p_game text, p_player_id text)
 returns jsonb
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  v_day date := kickabout_day();
  v_puzzle daily_puzzles;
  v_play game_plays;
  v_count integer;
  v_won boolean := false;
  v_done boolean := false;
  v_state jsonb;
begin
  if auth.uid() is null then raise exception 'Sign in to play.'; end if;
  if p_game not in ('scouted', 'journeyman', 'linkup', 'ballknowledge') then raise exception 'Unknown game'; end if;
  if p_game = 'ballknowledge' then
    if p_player_id is null or p_player_id !~ '^[0-3]$' then raise exception 'Pick one of the four answers.'; end if;
  elsif not exists (select 1 from players where id = p_player_id) then
    raise exception 'Pick a player from the list.';
  end if;

  v_puzzle := daily_puzzle(p_game);
  insert into game_plays (user_id, day, game) values (auth.uid(), v_day, p_game) on conflict do nothing;
  -- Locked, so two guesses sent at once are handled one after the other.
  select * into v_play from game_plays where user_id = auth.uid() and day = v_day and game = p_game for update;

  if v_play.finished then raise exception 'You''ve finished today''s game. A new one starts at midnight UK time.'; end if;
  if p_game <> 'ballknowledge' and p_player_id = any(v_play.guesses) then raise exception 'You''ve already guessed that player.'; end if;
  if p_game = 'linkup' and p_player_id = v_puzzle.player_id then raise exception 'That''s the player you start from.'; end if;
  -- Refused without using a go: someone no longer in any squad, whose
  -- teammates we can't check.
  if p_game = 'linkup' and p_player_id <> v_puzzle.player2_id
     and not exists (select 1 from players where id = p_player_id and active) then
    raise exception 'That player isn''t in a squad in our leagues any more, so Link-Up can''t check their teammates. Try someone else.';
  end if;

  update game_plays set guesses = guesses || p_player_id, updated_at = now()
  where user_id = auth.uid() and day = v_day and game = p_game;
  v_count := coalesce(array_length(v_play.guesses, 1), 0) + 1;

  if p_game = 'scouted' then
    v_won := p_player_id = v_puzzle.player_id;
    v_done := v_won or v_count >= 10;
  elsif p_game = 'journeyman' then
    v_won := p_player_id = v_puzzle.player_id;
    v_done := v_won or v_count >= (select count(*) from player_careers where player_id = v_puzzle.player_id);
  elsif p_game = 'linkup' then
    -- Won once the last player in the chain was a teammate of the target
    -- (or the target was guessed as the final link).
    v_state := kickabout_state(p_game);
    select coalesce(bool_or(e->>'target' = 'true'), false) into v_won
    from jsonb_array_elements(v_state->'chain') e;
    if not v_won then
      v_won := teammate_club(coalesce(v_state->'chain'->-1->>'id', v_puzzle.player_id), v_puzzle.player2_id) is not null;
    end if;
    v_done := v_won or v_count >= 6;
  else -- ballknowledge
    v_done := v_count >= 4;
    if v_done then
      v_won := (select count(*) from unnest(v_play.guesses || p_player_id) with ordinality u(c, n)
                where u.c::int = (v_puzzle.data->'questions'->(u.n::int - 1)->>'answer')::int) >= 3;
    end if;
  end if;

  update game_plays set won = v_won, finished = v_done, coins = case when v_won then 25 else 0 end
  where user_id = auth.uid() and day = v_day and game = p_game;
  if v_won then
    update profiles set coin_balance = coin_balance + 25 where id = auth.uid();
  end if;
  return kickabout_state(p_game);
end;
$function$;

commit;
