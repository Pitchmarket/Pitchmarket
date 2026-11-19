-- PitchMarket Daily Kickabout: players from current squads, 20 Nov 2026.
-- Run once in the Supabase SQL Editor (paste all of it, click Run), after
-- supabase-kickabout-2.sql. Safe to run more than once.
-- supabase-schema.sql already includes it.
--
-- The player import now takes squads from football-data.org, so players
-- are listed at their real current club. Wikidata careers can lag behind
-- for some players, so Journeyman only picks a player whose career is up
-- to date with their current club.

begin;

-- Whether we have the player's career, so Link-Up can check their teammates.
alter table public.players add column if not exists has_career boolean not null default false;
-- Whether that career's latest spell is at the player's current club, so
-- Journeyman never shows a trail that stops short.
alter table public.players add column if not exists career_current boolean not null default false;

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

commit;
