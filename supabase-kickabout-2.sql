-- PitchMarket Daily Kickabout, part 2: Link-Up and Ball Knowledge, 20 Nov 2026.
-- Run once in the Supabase SQL Editor (paste all of it, click Run), after
-- supabase-daily-kickabout.sql. Safe to run more than once.
-- supabase-schema.sql already includes it.
--
-- Adds Link-Up (connect two players through teammates, using at most 6
-- players) and Ball Knowledge (4 questions, win with 3 right). Scouted
-- drops height, and its nationality clue goes yellow for a player from
-- the same continent. Every game pays 25 Fan Coins for a win, once per
-- game per day, so 100 a day at most.

begin;

-- ---------- Tables ----------

alter table public.players add column if not exists continent text;
-- Whether we have the player's career, so Link-Up can check their teammates.
alter table public.players add column if not exists has_career boolean not null default false;
-- The Wikidata club of each career spell, so teammates are matched on the
-- club itself rather than its name.
alter table public.player_careers add column if not exists club_id text;
create index if not exists player_careers_club on public.player_careers (club_id);
-- Link-Up's second player, and anything else a game needs for the day
-- (Link-Up's best score, Ball Knowledge's questions and answers).
alter table public.daily_puzzles add column if not exists player2_id text references public.players(id);
alter table public.daily_puzzles add column if not exists data jsonb;

-- ---------- Teammates ----------

-- The club where two players were teammates (same club, overlapping
-- years), or null if they never were. Spell years are whole years, so a
-- player who left in January and one who joined that August both count.
create or replace function public.teammate_club(p1 text, p2 text)
 returns text
 language sql
 stable
 set search_path = public
as $function$
  select a.club
  from player_careers a
  join player_careers b on b.club_id = a.club_id
  where a.player_id = p1 and b.player_id = p2 and p1 <> p2 and a.club_id is not null
    and a.start_year <= coalesce(b.end_year, extract(year from now())::int)
    and b.start_year <= coalesce(a.end_year, extract(year from now())::int)
  order by a.start_year desc
  limit 1;
$function$;
revoke execute on function public.teammate_club(text, text) from public, anon, authenticated;

-- Everyone who was ever a teammate of any of the given players.
create or replace function public.teammates_of(p_ids text[])
 returns table(id text)
 language sql
 stable
 set search_path = public
as $function$
  select distinct b.player_id
  from player_careers a
  join player_careers b on b.club_id = a.club_id and b.player_id <> a.player_id
  where a.player_id = any(p_ids) and a.club_id is not null
    and a.start_year <= coalesce(b.end_year, extract(year from now())::int)
    and b.start_year <= coalesce(a.end_year, extract(year from now())::int);
$function$;
revoke execute on function public.teammates_of(text[]) from public, anon, authenticated;

-- ---------- Ball Knowledge questions ----------

-- One question of the given kind, as {q, options[4], answer}, or null if
-- the data can't make one today. Options are shuffled; "answer" is the
-- index of the right one.
create or replace function public.make_question(p_kind text)
 returns jsonb
 language plpgsql
 volatile
 set search_path = public
as $function$
declare
  v_q text;
  v_right text;
  v_wrong text[];
  v_opts text[];
  r record;
begin
  if p_kind = 'previous_club' then
    -- "Before joining X in 2019, which club did P play for?"
    select p.name, c2.club as joined, c2.start_year, c1.club as prev, p.id into r
    from players p
    join player_careers c2 on c2.player_id = p.id and not c2.loan
    join lateral (
      select c.club, c.club_id from player_careers c
      where c.player_id = p.id and c.seq < c2.seq and not c.loan
      order by c.seq desc limit 1
    ) c1 on c1.club_id is distinct from c2.club_id
    where p.active and p.fame >= 40
    order by random() limit 1;
    if r is null then return null; end if;
    v_q := 'Before joining ' || r.joined || ' in ' || r.start_year || ', which club did ' || r.name || ' play for?';
    v_right := r.prev;
    select array_agg(club) into v_wrong from (
      select club from (select club from player_careers group by club having count(*) >= 15) common
      where club not in (select c.club from player_careers c where c.player_id = r.id)
      order by random() limit 3) x;

  elsif p_kind = 'nationality' then
    select p.name, p.nationality into r from players p
    where p.active and p.fame >= 40 and p.nationality is not null order by random() limit 1;
    if r is null then return null; end if;
    v_q := 'Which country does ' || r.name || ' play for?';
    v_right := r.nationality;
    select array_agg(nationality) into v_wrong from (
      select nationality from players where nationality is not null and nationality <> r.nationality
      group by nationality having count(*) >= 20 order by random() limit 3) x;

  elsif p_kind = 'played_for' then
    -- One player who has played for the club, three who never have.
    select t.name as club, t.wikidata_id into r from teams t
    where t.wikidata_id is not null
      and (select count(distinct c.player_id) from player_careers c join players p on p.id = c.player_id
           where c.club_id = t.wikidata_id and p.fame >= 40) >= 3
    order by random() limit 1;
    if r is null then return null; end if;
    v_q := 'Which of these players has played for ' || r.club || '?';
    select p.name into v_right from players p
    where p.fame >= 40 and exists (select 1 from player_careers c where c.player_id = p.id and c.club_id = r.wikidata_id)
    order by random() limit 1;
    select array_agg(name) into v_wrong from (
      select p.name from players p
      where p.active and p.fame >= 40 and exists (select 1 from player_careers c where c.player_id = p.id)
        and not exists (select 1 from player_careers c where c.player_id = p.id and c.club_id = r.wikidata_id)
      order by random() limit 3) x;

  elsif p_kind = 'oldest' then
    -- Four well-known players born in different years.
    select array_agg(name order by birth_date) into v_opts from (
      select distinct on (extract(year from birth_date)) name, birth_date
      from (select name, birth_date from players where active and fame >= 40 and birth_date is not null order by random() limit 40) s
      order by extract(year from birth_date), random()
    ) y;
    if coalesce(array_length(v_opts, 1), 0) < 4 then return null; end if;
    select array_agg(n) into v_opts from (select unnest(v_opts) as n order by random() limit 4) z;
    select name into v_right from players where name = any(v_opts) and active and fame >= 40 order by birth_date limit 1;
    v_q := 'Which of these players is the oldest?';
    v_wrong := array_remove(v_opts, v_right);

  elsif p_kind = 'league' then
    select t.name, t.league, t.league_label into r from teams t
    where t.league in ('epl','laliga','seriea','bundesliga','ligue1','championship','portugal','eredivisie','brazil')
    order by random() limit 1;
    if r is null then return null; end if;
    v_q := 'Which league are ' || r.name || ' in on PitchMarket?';
    v_right := r.league_label;
    select array_agg(league_label) into v_wrong from (
      select distinct league_label from teams
      where league in ('epl','laliga','seriea','bundesliga','ligue1','championship','portugal','eredivisie','brazil')
        and league_label <> r.league_label
      order by 1) x;
    select array_agg(l) into v_wrong from (select unnest(v_wrong) as l order by random() limit 3) x;

  elsif p_kind = 'riser' then
    -- "Which of these clubs' prices has risen most in the last 7 days?"
    -- Four clubs whose prices moved, compared with their last price
    -- before the week began.
    with moves as (
      select t.name, (t.price - h.price) / nullif(h.price, 0) as pct
      from teams t
      join lateral (select ph.price from price_history ph
                    where ph.team_id = t.id and ph.changed_at <= now() - interval '7 days'
                    order by ph.changed_at desc limit 1) h on true
      where t.price <> h.price
    ), four as (select name, pct from moves order by random() limit 4)
    select array_agg(name order by pct desc) into v_opts from four;
    if coalesce(array_length(v_opts, 1), 0) < 4 then return null; end if;
    v_q := 'Which of these clubs'' prices has risen most in the last 7 days?';
    v_right := v_opts[1];
    v_wrong := v_opts[2:4];
  else
    raise exception 'Unknown question kind';
  end if;

  if v_right is null or coalesce(array_length(v_wrong, 1), 0) < 3 then return null; end if;
  select array_agg(o order by random()) into v_opts from unnest(v_wrong[1:3] || v_right) o;
  return jsonb_build_object('q', v_q, 'options', to_jsonb(v_opts), 'answer', array_position(v_opts, v_right) - 1);
end;
$function$;
revoke execute on function public.make_question(text) from public, anon, authenticated;

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
  v_n1 text[];
  v_n2 text[];
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
    -- A proper trail: 4+ spells at 3+ different clubs, every spell dated.
    select id into v_a from (
      select p.id from players p
      where p.active
        and (select count(*) from player_careers c where c.player_id = p.id) >= 4
        and (select count(distinct c.club) from player_careers c where c.player_id = p.id) >= 3
        and not exists (select 1 from player_careers c where c.player_id = p.id and c.start_year is null)
        and p.id not in (select d.player_id from daily_puzzles d
                         where d.game = p_game and d.day > v_day - 120 and d.player_id is not null)
      order by p.fame desc limit 300) pool
    order by random() limit 1;

  elsif p_game = 'linkup' then
    -- Two well-known players who were never teammates, but can be linked
    -- through one or two other players. Two-step links are preferred.
    for attempt in 1..20 loop
      select id into v_a from (
        select p.id from players p
        where p.active and exists (select 1 from player_careers c where c.player_id = p.id and c.club_id is not null)
          and p.id not in (select d.player_id from daily_puzzles d
                           where d.game = p_game and d.day > v_day - 60 and d.player_id is not null)
        order by p.fame desc limit 300) pool
      order by random() limit 1;
      exit when v_a is null;
      select array_agg(id) into v_n1 from teammates_of(array[v_a]);
      select array_agg(id) into v_n2 from teammates_of(coalesce(v_n1, '{}'))
        where id <> v_a and id <> all(coalesce(v_n1, '{}'));
      -- Prefer a player three steps away (two in between), else two steps.
      select p.id into v_b from players p
      where p.active and p.fame >= 30
        and p.id <> v_a and p.id <> all(coalesce(v_n1, '{}')) and p.id <> all(coalesce(v_n2, '{}'))
        and exists (select 1 from teammates_of(array[p.id]) t where t.id = any(coalesce(v_n2, '{}')))
      order by random() limit 1;
      if v_b is not null then
        v_data := jsonb_build_object('par', 2);
      else
        select p.id into v_b from players p
        where p.active and p.fame >= 30 and p.id = any(coalesce(v_n2, '{}'))
        order by random() limit 1;
        if v_b is not null then v_data := jsonb_build_object('par', 1); end if;
      end if;
      exit when v_b is not null;
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

-- Kept for anything still calling it: today's answer for a one-player game.
create or replace function public.daily_player(p_game text)
 returns text
 language sql
 security definer
 set search_path = public
as $function$
  select (daily_puzzle(p_game)).player_id;
$function$;
revoke execute on function public.daily_player(text) from public, anon, authenticated;

-- ---------- Scouted clues ----------

-- Clues for one guess. "match" green, "close" yellow (nationality: same
-- continent; age: within 2 years), "miss" grey, "unknown" when Wikidata
-- has no value. "dir" says whether the answer is higher ("up") or lower.
create or replace function public.scouted_feedback(g public.players, a public.players, p_day date)
 returns jsonb
 language plpgsql
 stable
 set search_path = public
as $function$
declare
  g_age integer := extract(year from age(p_day, g.birth_date));
  a_age integer := extract(year from age(p_day, a.birth_date));
begin
  return jsonb_build_object(
    'id', g.id,
    'name', g.name,
    'league', jsonb_build_object('value', g.league_label,
      'result', case when g.league is null then 'unknown' when g.league = a.league then 'match' else 'miss' end),
    'team', jsonb_build_object('value', g.club_name,
      'result', case when g.team_id is null then 'unknown' when g.team_id = a.team_id then 'match' else 'miss' end),
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

-- ---------- Game state ----------

-- A player's clubs in order, without years: shown for Link-Up's two
-- players, who aren't secret.
create or replace function public.club_trail(p_id text)
 returns jsonb
 language sql
 stable
 set search_path = public
as $function$
  select coalesce(jsonb_agg(club order by first_seq), '[]'::jsonb)
  from (select club, min(seq) as first_seq from player_careers where player_id = p_id and not loan group by club) c;
$function$;
revoke execute on function public.club_trail(text) from public, anon, authenticated;

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
          'reason', case when exists (select 1 from player_careers where player_id = g) then 'not_teammates' else 'no_data' end,
          'after', (select name from players where id = v_end)));
      end if;
    end loop;
    return v_result || jsonb_build_object(
      'max_guesses', 6, 'par', v_puzzle.data->'par',
      'start', jsonb_build_object('id', v_answer.id, 'name', v_answer.name, 'club', v_answer.club_name, 'trail', club_trail(v_answer.id)),
      'target', jsonb_build_object('id', v_target.id, 'name', v_target.name, 'club', v_target.club_name, 'trail', club_trail(v_target.id)),
      'chain', v_chain, 'strikes', v_strikes, 'used', coalesce(array_length(v_guesses, 1), 0),
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
  -- Refused without using a go: we can't check this player's teammates.
  if p_game = 'linkup' and p_player_id <> v_puzzle.player2_id
     and not exists (select 1 from player_careers where player_id = p_player_id) then
    raise exception 'We don''t have this player''s career on file yet, so Link-Up can''t check their teammates. Try someone else.';
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
