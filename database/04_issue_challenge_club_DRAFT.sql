-- DRAFT: Run only after 01_live_club_backfill_DRAFT.sql and 03 helpers,
-- and only as part of a complete verified multi-club rollout.
CREATE OR REPLACE FUNCTION public.issue_challenge_secure(challenger_id uuid, challenged_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  challenger_team public.ladder_teams%rowtype;
  challenged_team public.ladder_teams%rowtype;
  active_teams_above integer;
  challenge_limit integer;
  new_challenge_id uuid;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  if challenger_id = challenged_id then
    raise exception 'A team cannot challenge itself.';
  end if;

  perform 1
  from public.ladder_teams
  where id in (challenger_id, challenged_id)
  order by id
  for update;

  select *
  into challenger_team
  from public.ladder_teams
  where id = challenger_id;

  select *
  into challenged_team
  from public.ladder_teams
  where id = challenged_id;

  if challenger_team.id is null
     or challenged_team.id is null then
    raise exception 'One of these teams could not be found.';
  end if;

  if not public.user_belongs_to_team(challenger_id)
     and not public.is_ladder_club_admin(challenger_team.club_id) then
    raise exception 'Your account is not assigned to the challenging team.';
  end if;

  if challenger_team.ladder <> challenged_team.ladder then
    raise exception 'Teams must be in the same ladder.';
  end if;

  if challenger_team.club_id is distinct from challenged_team.club_id then
    raise exception 'Teams must belong to the same club.';
  end if;

  if challenger_team.away then
    raise exception 'The challenging team is Away.';
  end if;

  if challenged_team.away then
    raise exception 'The challenged team is Away.';
  end if;

  if challenged_team.rank_position >=
     challenger_team.rank_position then
    raise exception 'A team may only challenge a higher-ranked team.';
  end if;

  if exists (
    select 1
    from public.challenges
    where status in (
      'Pending',
      'Accepted',
      'Awaiting Confirmation',
      'Decline Pending Admin Review',
      'Overdue',
      'Disputed'
    )
    and (
      challenger_team_id in (
        challenger_id,
        challenged_id
      )
      or challenged_team_id in (
        challenger_id,
        challenged_id
      )
    )
  ) then
    raise exception 'One of these teams already has an open challenge.';
  end if;

  if exists (
    select 1
    from public.challenges
    where completed_at >
      now() - interval '7 days'
    and (
      (
        challenger_team_id = challenger_id
        and challenged_team_id = challenged_id
      )
      or
      (
        challenger_team_id = challenged_id
        and challenged_team_id = challenger_id
      )
    )
  ) then
    raise exception 'These teams must wait seven days before a rematch.';
  end if;

  select count(*)
  into active_teams_above
  from public.ladder_teams
  where club_id = challenger_team.club_id
    and ladder = challenger_team.ladder
    and away = false
    and rank_position <
      challenger_team.rank_position
    and rank_position >=
      challenged_team.rank_position;

  challenge_limit :=
    case
      when challenger_team.rank_position <= 10
        or challenged_team.rank_position <= 10
      then 2
      else 3
    end;

  if active_teams_above > challenge_limit then
    raise exception 'That team is outside the allowed challenge range.';
  end if;

  insert into public.challenges (
    club_id,
    ladder,
    challenger_team_id,
    challenged_team_id,
    challenger_name,
    challenged_name,
    status
  )
  values (
    challenger_team.club_id,
    challenger_team.ladder,
    challenger_team.id,
    challenged_team.id,
    challenger_team.name,
    challenged_team.name,
    'Pending'
  )
  returning id into new_challenge_id;

  return new_challenge_id;
end;
$function$

