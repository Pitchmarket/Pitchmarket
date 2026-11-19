-- PitchMarket Daily Kickabout: Scouted and Journeyman, 19 Nov 2026.
-- Run once in the Supabase SQL Editor (paste all of it, click Run).
-- Safe to run more than once. supabase-schema.sql already includes it.
--
-- Player data comes from Wikidata through import-players.js (weekly
-- GitHub Action). Each day everyone gets the same Scouted and Journeyman
-- player, picked here the first time someone opens the game. The answer
-- stays in the database until a player has finished: guesses are checked
-- by kickabout_guess(), which also pays 25 Fan Coins for a win, once per
-- game per day. The day rolls over at midnight UK time.

begin;

-- ---------- Tables ----------

-- Each club's Wikidata entry, filled in by the importer. Set it by hand
-- to correct a wrong match; the importer never overwrites one.
alter table public.teams add column if not exists wikidata_id text;

create table if not exists public.players (
  id              text primary key,             -- Wikidata ID, e.g. Q28967995
  name            text not null,
  birth_date      date,
  nationality     text,
  position        text,                         -- as Wikidata has it, e.g. "centre-back"
  position_group  text,                         -- Goalkeeper, Defender, Midfielder or Forward
  height_cm       integer,
  team_id         uuid references public.teams(id) on delete set null,
  club_name       text,
  league          text,
  league_label    text,
  fame            integer not null default 0,   -- Wikipedia languages with a page on them
  active          boolean not null default true,
  updated_at      timestamptz not null default now()
);
create index if not exists players_active_fame on public.players (active, fame desc);
alter table public.players enable row level security;
drop policy if exists "players are publicly readable" on public.players;
create policy "players are publicly readable" on public.players for select using (true);

-- Club-by-club careers. Hidden from players (no policies): reading them
-- would give Journeyman away. Rows reach the page through kickabout_state.
create table if not exists public.player_careers (
  player_id   text not null references public.players(id) on delete cascade,
  seq         integer not null,
  club        text not null,
  start_year  integer,
  end_year    integer,
  apps        integer,
  goals       integer,
  loan        boolean not null default false,
  primary key (player_id, seq)
);
alter table public.player_careers enable row level security;

-- Each day's answer per game. Hidden from players (no policies).
create table if not exists public.daily_puzzles (
  day         date not null,
  game        text not null,
  player_id   text references public.players(id),
  created_at  timestamptz not null default now(),
  primary key (day, game)
);
alter table public.daily_puzzles enable row level security;

-- One row per player, game and day: their guesses so far and the result.
create table if not exists public.game_plays (
  user_id     uuid not null references auth.users(id) on delete cascade,
  day         date not null,
  game        text not null,
  guesses     text[] not null default '{}',
  finished    boolean not null default false,
  won         boolean not null default false,
  coins       integer not null default 0,
  updated_at  timestamptz not null default now(),
  primary key (user_id, day, game)
);
alter table public.game_plays enable row level security;
drop policy if exists "users read own plays" on public.game_plays;
create policy "users read own plays" on public.game_plays for select using (auth.uid() = user_id);

-- ---------- Functions ----------

-- Today's date for the games: midnight UK time, so a whole friend group
-- gets a new puzzle at the same moment.
create or replace function public.kickabout_day()
 returns date
 language sql
 stable
 set search_path = public
as $function$
  select (now() at time zone 'Europe/London')::date;
$function$;

-- Today's answer for a game, picked the first time it's asked for: one of
-- the 300 best-known suitable players, not used in the last 120 days.
-- md5(id || day || game) shuffles them the same way for everyone, and
-- differently for each game, so the two games never share an answer.
create or replace function public.daily_player(p_game text)
 returns text
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  v_day date := kickabout_day();
  v_id text;
begin
  select player_id into v_id from daily_puzzles where day = v_day and game = p_game;
  if v_id is not null then return v_id; end if;

  if p_game = 'scouted' then
    select id into v_id from (
      select p.id from players p
      where p.active and p.birth_date is not null and p.nationality is not null
        and p.position_group is not null and p.height_cm is not null and p.team_id is not null
        and p.id not in (select d.player_id from daily_puzzles d
                         where d.game = p_game and d.day > v_day - 120 and d.player_id is not null)
      order by p.fame desc
      limit 300
    ) pool
    order by md5(id || v_day::text || p_game)
    limit 1;
  elsif p_game = 'journeyman' then
    -- A proper trail: 4+ spells at 3+ different clubs, every spell dated.
    select id into v_id from (
      select p.id from players p
      where p.active
        and (select count(*) from player_careers c where c.player_id = p.id) >= 4
        and (select count(distinct c.club) from player_careers c where c.player_id = p.id) >= 3
        and not exists (select 1 from player_careers c where c.player_id = p.id and c.start_year is null)
        and p.id not in (select d.player_id from daily_puzzles d
                         where d.game = p_game and d.day > v_day - 120 and d.player_id is not null)
      order by p.fame desc
      limit 300
    ) pool
    order by md5(id || v_day::text || p_game)
    limit 1;
  else
    raise exception 'Unknown game';
  end if;

  if v_id is null then
    raise exception 'Today''s puzzle isn''t ready yet: the player list is still loading. Try again later.';
  end if;
  insert into daily_puzzles (day, game, player_id) values (v_day, p_game, v_id) on conflict do nothing;
  select player_id into v_id from daily_puzzles where day = v_day and game = p_game;
  return v_id;
end;
$function$;
revoke execute on function public.daily_player(text) from public, anon, authenticated;

-- Scouted clues for one guess against the answer. "match" is green,
-- "close" is yellow (age within 2 years, height within 3 cm), "miss" is
-- grey and "unknown" means Wikidata has no value for the guessed player.
-- "dir" says whether the answer is higher ("up") or lower ("down").
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
      'result', case when g.nationality is null then 'unknown' when lower(g.nationality) = lower(a.nationality) then 'match' else 'miss' end),
    'age', jsonb_build_object('value', g_age,
      'result', case when g_age is null then 'unknown' when g_age = a_age then 'match' when abs(g_age - a_age) <= 2 then 'close' else 'miss' end,
      'dir', case when g_age is null or g_age = a_age then null when a_age > g_age then 'up' else 'down' end),
    'position', jsonb_build_object('value', g.position_group,
      'result', case when g.position_group is null then 'unknown' when g.position_group = a.position_group then 'match' else 'miss' end),
    'height', jsonb_build_object('value', g.height_cm,
      'result', case when g.height_cm is null then 'unknown' when g.height_cm = a.height_cm then 'match' when abs(g.height_cm - a.height_cm) <= 3 then 'close' else 'miss' end,
      'dir', case when g.height_cm is null or g.height_cm = a.height_cm then null when a.height_cm > g.height_cm then 'up' else 'down' end)
  );
end;
$function$;
revoke execute on function public.scouted_feedback(public.players, public.players, date) from public, anon, authenticated;

-- Everything the page needs to draw a game for the signed-in player (or
-- a signed-out visitor, who sees a fresh game). The answer is only
-- included once the player has finished.
create or replace function public.kickabout_state(p_game text)
 returns jsonb
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  v_day date := kickabout_day();
  v_answer players;
  v_play game_plays;
  v_guesses text[];
  v_rows integer;
  v_shown integer;
  v_result jsonb;
begin
  if p_game not in ('scouted', 'journeyman') then raise exception 'Unknown game'; end if;
  select * into v_answer from players where id = daily_player(p_game);
  select * into v_play from game_plays where user_id = auth.uid() and day = v_day and game = p_game;
  v_guesses := coalesce(v_play.guesses, '{}');

  v_result := jsonb_build_object(
    'game', p_game,
    'day', v_day,
    'signed_in', auth.uid() is not null,
    'finished', coalesce(v_play.finished, false),
    'won', coalesce(v_play.won, false),
    'coins', coalesce(v_play.coins, 0),
    'answer', case when coalesce(v_play.finished, false)
      then jsonb_build_object('id', v_answer.id, 'name', v_answer.name, 'club', v_answer.club_name,
                              'nationality', v_answer.nationality, 'position', v_answer.position_group,
                              'height', v_answer.height_cm, 'age', extract(year from age(v_day, v_answer.birth_date)))
      end
  );

  if p_game = 'scouted' then
    return v_result || jsonb_build_object(
      'max_guesses', 10,
      'guesses', coalesce((
        select jsonb_agg(scouted_feedback(g, v_answer, v_day) order by u.n)
        from unnest(v_guesses) with ordinality as u(id, n)
        join players g on g.id = u.id
      ), '[]'::jsonb));
  end if;

  -- Journeyman: the first spell is shown from the start, each wrong guess
  -- shows one more, and when all are showing there's one last guess. So a
  -- career with N spells allows N guesses.
  select count(*) into v_rows from player_careers where player_id = v_answer.id;
  v_shown := case when coalesce(v_play.finished, false) then v_rows
                  else least(v_rows, 1 + coalesce(array_length(v_guesses, 1), 0)) end;
  return v_result || jsonb_build_object(
    'max_guesses', v_rows,
    'total_rows', v_rows,
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object('club', c.club, 'start', c.start_year, 'end', c.end_year,
                                          'apps', c.apps, 'goals', c.goals, 'loan', c.loan) order by c.seq)
      from player_careers c where c.player_id = v_answer.id and c.seq <= v_shown
    ), '[]'::jsonb),
    'guesses', coalesce((
      select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name) order by u.n)
      from unnest(v_guesses) with ordinality as u(id, n)
      join players g on g.id = u.id
    ), '[]'::jsonb));
end;
$function$;

-- Make a guess. Pays 25 Fan Coins for a win, once per game per day.
create or replace function public.kickabout_guess(p_game text, p_player_id text)
 returns jsonb
 language plpgsql
 security definer
 set search_path = public
as $function$
declare
  v_day date := kickabout_day();
  v_answer text;
  v_play game_plays;
  v_max integer;
  v_won boolean;
  v_count integer;
begin
  if auth.uid() is null then raise exception 'Sign in to play.'; end if;
  if p_game not in ('scouted', 'journeyman') then raise exception 'Unknown game'; end if;
  if not exists (select 1 from players where id = p_player_id) then
    raise exception 'Pick a player from the list.';
  end if;

  v_answer := daily_player(p_game);
  insert into game_plays (user_id, day, game) values (auth.uid(), v_day, p_game) on conflict do nothing;
  -- Locked, so two guesses sent at once are handled one after the other.
  select * into v_play from game_plays where user_id = auth.uid() and day = v_day and game = p_game for update;

  if v_play.finished then raise exception 'You''ve finished today''s game. A new one starts at midnight UK time.'; end if;
  if p_player_id = any(v_play.guesses) then raise exception 'You''ve already guessed that player.'; end if;

  if p_game = 'scouted' then v_max := 10;
  else select count(*) into v_max from player_careers where player_id = v_answer;
  end if;

  v_won := p_player_id = v_answer;
  v_count := coalesce(array_length(v_play.guesses, 1), 0) + 1;
  update game_plays set
    guesses = guesses || p_player_id,
    won = v_won,
    finished = v_won or v_count >= v_max,
    coins = case when v_won then 25 else 0 end,
    updated_at = now()
  where user_id = auth.uid() and day = v_day and game = p_game;

  if v_won then
    update profiles set coin_balance = coin_balance + 25 where id = auth.uid();
  end if;
  return kickabout_state(p_game);
end;
$function$;

commit;
