-- DRAFT: Requires Stage 1, club helper and Stage 2 club-scoped indexes.
-- Preserves per-ladder one-team rule *within* each club while permitting
-- the same email/account at another club.
CREATE OR REPLACE FUNCTION public.admin_assign_team_members_secure(requested_team_id uuid, requested_email_one text, requested_email_two text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  team_ladder text;
  team_club_id uuid;
  normalized_email_one text;
  normalized_email_two text;
  first_user_id uuid;
  second_user_id uuid;
begin
  select team.ladder, team.club_id
  into team_ladder, team_club_id
  from public.ladder_teams as team
  where team.id = requested_team_id
  for update;

  if not found then
    raise exception 'Team not found';
  end if;

  if auth.uid() is null or not coalesce(public.is_ladder_club_admin(team_club_id), false) then
    raise exception 'Administrator access required';
  end if;

  normalized_email_one :=
    nullif(
      lower(pg_catalog.btrim(coalesce(requested_email_one, ''))),
      ''
    );

  normalized_email_two :=
    nullif(
      lower(pg_catalog.btrim(coalesce(requested_email_two, ''))),
      ''
    );

  if normalized_email_one is not null
     and normalized_email_one !~
       '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
    raise exception 'The first email address is invalid';
  end if;

  if normalized_email_two is not null
     and normalized_email_two !~
       '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
    raise exception 'The second email address is invalid';
  end if;

  if normalized_email_one is not null
     and normalized_email_one = normalized_email_two then
    raise exception 'Enter two different email addresses';
  end if;

  if normalized_email_one is not null then
    select user_record.id
    into first_user_id
    from auth.users as user_record
    where lower(user_record.email) = normalized_email_one
    order by user_record.created_at desc
    limit 1;
  end if;

  if normalized_email_two is not null then
    select user_record.id
    into second_user_id
    from auth.users as user_record
    where lower(user_record.email) = normalized_email_two
    order by user_record.created_at desc
    limit 1;
  end if;

  if exists (
    select 1
    from private.team_members as member
    where member.club_id = team_club_id
      and member.ladder = team_ladder
      and member.team_id <> requested_team_id
      and member.email in (
        normalized_email_one,
        normalized_email_two
      )
  ) then
    raise exception
      'One of these emails is already assigned to another team in this ladder';
  end if;

  if exists (
    select 1
    from private.team_members as member
    where member.club_id = team_club_id
      and member.ladder = team_ladder
      and member.team_id <> requested_team_id
      and (
        (
          first_user_id is not null
          and member.user_id = first_user_id
        )
        or
        (
          second_user_id is not null
          and member.user_id = second_user_id
        )
      )
  ) then
    raise exception
      'One of these accounts is already assigned to another team in this ladder';
  end if;

  delete from private.team_members
  where team_id = requested_team_id;

  if normalized_email_one is not null then
    insert into private.team_members (
      team_id,
      club_id,
      user_id,
      email,
      ladder
    )
    values (
      requested_team_id,
      team_club_id,
      first_user_id,
      normalized_email_one,
      team_ladder
    );
  end if;

  if normalized_email_two is not null then
    insert into private.team_members (
      team_id,
      club_id,
      user_id,
      email,
      ladder
    )
    values (
      requested_team_id,
      team_club_id,
      second_user_id,
      normalized_email_two,
      team_ladder
    );
  end if;
end;
$function$

