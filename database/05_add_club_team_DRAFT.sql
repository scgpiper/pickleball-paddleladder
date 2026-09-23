-- DRAFT: New overload for club admins. Requires Stage 1 and club helper.
-- The original five-argument VPA function remains for compatibility until
-- the complete frontend and backend cutover is verified.
CREATE OR REPLACE FUNCTION public.admin_add_team_secure(requested_club_id uuid, requested_ladder text, requested_team_name text, requested_players text, requested_dupr numeric, requested_is_nr boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  normalized_ladder text;
  normalized_name text;
  normalized_players text;
  target_rank integer;
  new_team_id uuid;
begin
  if requested_club_id is null or auth.uid() is null
     or not coalesce(public.is_ladder_club_admin(requested_club_id), false) then
    raise exception 'Administrator access required';
  end if;

  if not exists (select 1 from public.clubs where id = requested_club_id and active = true) then
    raise exception 'Club not found';
  end if;

  normalized_ladder :=
    lower(pg_catalog.btrim(coalesce(requested_ladder, '')));

  normalized_name :=
    pg_catalog.btrim(coalesce(requested_team_name, ''));

  normalized_players :=
    pg_catalog.btrim(coalesce(requested_players, ''));

  if normalized_ladder not in ('mens', 'womens', 'mixed') then
    raise exception 'Invalid ladder';
  end if;

  if normalized_name = '' then
    raise exception 'Team name is required';
  end if;

  if normalized_players = '' then
    raise exception 'Player names are required';
  end if;

  if not coalesce(requested_is_nr, false)
     and (requested_dupr is null or requested_dupr <= 0) then
    raise exception 'A valid combined DUPR is required';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext('ladder:' || requested_club_id::text || ':' || normalized_ladder)
  );

  if exists (
    select 1
    from public.ladder_teams as team
    where team.club_id = requested_club_id
      and team.ladder = normalized_ladder
      and lower(team.name) = lower(normalized_name)
  ) then
    raise exception 'That team name is already used in this ladder';
  end if;

  target_rank := null;

  if not coalesce(requested_is_nr, false) then
    select team.rank_position
    into target_rank
    from public.ladder_teams as team
    where team.club_id = requested_club_id
      and team.ladder = normalized_ladder
      and team.rank_position >= 11
      and (
        team.is_nr = true
        or team.dupr is null
        or team.dupr < requested_dupr
      )
    order by team.rank_position
    limit 1;
  end if;

  if target_rank is null then
    select coalesce(max(team.rank_position), 0) + 1
    into target_rank
    from public.ladder_teams as team
    where team.club_id = requested_club_id
      and team.ladder = normalized_ladder;
  end if;

  update public.ladder_teams
  set
    rank_position = rank_position + 1,
    updated_at = now()
  where club_id = requested_club_id
    and ladder = normalized_ladder
    and rank_position >= target_rank;

  insert into public.ladder_teams (
    club_id,
    ladder,
    rank_position,
    name,
    players,
    dupr,
    is_nr
  )
  values (
    requested_club_id,
    normalized_ladder,
    target_rank,
    normalized_name,
    normalized_players,
    case
      when coalesce(requested_is_nr, false) then null
      else requested_dupr
    end,
    coalesce(requested_is_nr, false)
  )
  returning id into new_team_id;

  return new_team_id;
end;
$function$

