-- DRAFT. Run only in the isolated PaddleLadder Pilot Test project, after 13_pilot_test_baseline_DRAFT.sql.
-- Restores app-owned routines, public-table read policies and triggers from the production metadata export.
-- Direct table writes are intentionally withheld; app changes use the security-definer RPCs.
-- Do not run against the original Pickleball PaddleLadder project.
begin;
set local search_path = public, private, auth, pg_catalog;

-- public.is_app_admin()
CREATE OR REPLACE FUNCTION public.is_app_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1
    from private.app_admins
    where user_id = auth.uid()
  );
$function$;

-- public.is_club_admin(p_club_id uuid)
CREATE OR REPLACE FUNCTION public.is_club_admin(p_club_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
    from public.club_memberships
    where club_id = p_club_id
      and user_id = auth.uid()
      and status = 'active'
      and role in ('admin','owner')
  );
$function$;

-- public.is_team_member(p_team_id uuid)
CREATE OR REPLACE FUNCTION public.is_team_member(p_team_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
    from public.team_members
    where team_id = p_team_id
      and user_id = auth.uid()
      and active = true
  );
$function$;

-- public.team_club_id(p_team_id uuid)
CREATE OR REPLACE FUNCTION public.team_club_id(p_team_id uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select l.club_id
  from public.teams t
  join public.ladders l on l.id = t.ladder_id
  where t.id = p_team_id;
$function$;

-- public.user_belongs_to_team(requested_team_id uuid)
CREATE OR REPLACE FUNCTION public.user_belongs_to_team(requested_team_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1
    from private.team_members tm
    join public.ladder_teams lt
      on lt.id = tm.team_id
     and lt.club_id = tm.club_id
    join public.club_memberships cm
      on cm.club_id = lt.club_id
     and cm.user_id = auth.uid()
     and lower(cm.status::text) = 'active'
    where tm.team_id = requested_team_id
      and tm.club_id is not null
      and (
        tm.user_id = auth.uid()
        or lower(tm.email) = lower(
          coalesce(
            auth.jwt()->>'email',
            ''
          )
        )
      )
  );
$function$;

-- private.cancel_invalid_pending_challenges(requested_club_id uuid, requested_ladder text)
CREATE OR REPLACE FUNCTION private.cancel_invalid_pending_challenges(requested_club_id uuid, requested_ladder text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  pending_item record;
  available_teams integer;
  maximum_distance integer;
  cancelled_count integer := 0;
  cancellation_reason text;
begin
  if requested_club_id is null then
    raise exception 'Club is required.';
  end if;

  if requested_ladder not in ('mens', 'womens', 'mixed') then
    raise exception 'Invalid ladder.';
  end if;

  for pending_item in
    select
      challenge.id,
      challenge.challenger_team_id,
      challenge.challenged_team_id,
      challenger.ladder as challenger_ladder,
      challenged.ladder as challenged_ladder,
      challenger.rank_position as challenger_rank,
      challenged.rank_position as challenged_rank,
      challenger.away as challenger_away,
      challenged.away as challenged_away
    from public.challenges as challenge
    left join public.ladder_teams as challenger
      on challenger.id = challenge.challenger_team_id
     and challenger.club_id = requested_club_id
    left join public.ladder_teams as challenged
      on challenged.id = challenge.challenged_team_id
     and challenged.club_id = requested_club_id
    where challenge.club_id = requested_club_id
      and challenge.ladder = requested_ladder
      and challenge.status = 'Pending'
    for update of challenge
  loop
    cancellation_reason := null;

    if pending_item.challenger_team_id is null
       or pending_item.challenged_team_id is null
       or pending_item.challenger_rank is null
       or pending_item.challenged_rank is null then

      cancellation_reason :=
        'A team is no longer available on this ladder.';

    elsif pending_item.challenger_ladder <> requested_ladder
       or pending_item.challenged_ladder <> requested_ladder then

      cancellation_reason :=
        'A team is no longer on the same ladder.';

    elsif pending_item.challenger_away
       or pending_item.challenged_away then

      cancellation_reason :=
        'One of the teams is currently Away.';

    elsif pending_item.challenger_rank <=
          pending_item.challenged_rank then

      cancellation_reason :=
        'Ranking changed — the challenged team is no longer above the challenger.';

    else
      select count(*)
      into available_teams
      from public.ladder_teams
      where club_id = requested_club_id
        and ladder = requested_ladder
        and away = false
        and rank_position >= pending_item.challenged_rank
        and rank_position < pending_item.challenger_rank;

      maximum_distance :=
        case
          when pending_item.challenger_rank <= 10
            or pending_item.challenged_rank <= 10
          then 2
          else 3
        end;

      if available_teams > maximum_distance then
        cancellation_reason :=
          'Ranking changed — challenge is now outside the allowed range.';
      end if;
    end if;

    if cancellation_reason is not null then
      update public.challenges
      set
        status = 'Cancelled',
        cancel_reason = cancellation_reason,
        cancelled_at = now(),
        updated_at = now()
      where id = pending_item.id
        and club_id = requested_club_id;

      cancelled_count := cancelled_count + 1;
    end if;
  end loop;

  return cancelled_count;
end;
$function$;

-- private.check_pending_challenges_after_completion()
CREATE OR REPLACE FUNCTION private.check_pending_challenges_after_completion()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.status = 'Completed'
     and old.status is distinct from new.status then

    perform private.cancel_invalid_pending_challenges(
      new.ladder
    );
  end if;

  return new;
end;
$function$;

-- private.prevent_late_challenge_acceptance()
CREATE OR REPLACE FUNCTION private.prevent_late_challenge_acceptance()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if old.status = 'Pending'
     and new.status = 'Accepted'
     and old.created_at <= now() - interval '72 hours' then

    raise exception
      'The 72-hour response period has expired. This challenge requires Admin review.';
  end if;

  return new;
end;
$function$;

-- private.set_challenge_play_deadline()
CREATE OR REPLACE FUNCTION private.set_challenge_play_deadline()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if tg_op = 'INSERT' then
    if new.status = 'Accepted' then
      new.accepted_at :=
        coalesce(new.accepted_at, now());

      new.play_by :=
        coalesce(
          new.play_by,
          new.accepted_at + interval '7 days'
        );
    end if;

  elsif tg_op = 'UPDATE' then
    if new.status = 'Accepted'
       and old.status is distinct from new.status then

      new.accepted_at :=
        coalesce(new.accepted_at, now());

      new.play_by :=
        coalesce(
          new.play_by,
          new.accepted_at + interval '7 days'
        );
    end if;
  end if;

  return new;
end;
$function$;

-- private.track_challenge_acceptance_period()
CREATE OR REPLACE FUNCTION private.track_challenge_acceptance_period()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  -- Receiving a challenge starts tracking if no period exists.
  if tg_op = 'INSERT' then
    if new.status = 'Pending'
       and new.club_id is not null
       and new.challenged_team_id is not null then

      update public.ladder_teams
      set
        acceptance_period_started_at =
          coalesce(
            acceptance_period_started_at,
            new.created_at,
            now()
          ),
        updated_at = now()
      where id = new.challenged_team_id
        and club_id = new.club_id;
    end if;

  elsif tg_op = 'UPDATE' then
    -- Accepting at least one challenge satisfies the current period.
    if new.status = 'Accepted'
       and old.status is distinct from new.status
       and new.club_id is not null
       and new.challenged_team_id is not null then

      update public.ladder_teams
      set
        acceptance_period_started_at =
          coalesce(
            acceptance_period_started_at,
            new.accepted_at,
            now()
          ),
        accepted_in_period = true,
        updated_at = now()
      where id = new.challenged_team_id
        and club_id = new.club_id;
    end if;
  end if;

  return new;
end;
$function$;

-- public.accept_partner_invite_secure(requested_invite_id uuid, requested_team_name text)
CREATE OR REPLACE FUNCTION public.accept_partner_invite_secure(requested_invite_id uuid, requested_team_name text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  invite_record public.partner_invites%rowtype;
  listing_record public.partner_listings%rowtype;
  normalized_team_name text;
  combined_dupr numeric;
  team_is_nr boolean;
  insertion_rank integer;
  new_team_id uuid;
  sender_email text;
  recipient_email text;
  moved_team record;
  action_time timestamp with time zone := now();
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  normalized_team_name := trim(requested_team_name);

  if normalized_team_name = '' then
    raise exception 'Please enter a team name.';
  end if;

  select *
  into invite_record
  from public.partner_invites
  where id = requested_invite_id
  for update;

  if not found then
    raise exception 'Partner invitation not found.';
  end if;

  if invite_record.club_id is null then
    raise exception 'This partner invitation is not assigned to a club.';
  end if;

  if invite_record.status <> 'Pending' then
    raise exception 'This invitation is no longer pending.';
  end if;

  if invite_record.recipient_user_id = auth.uid() then
    if not exists(
      select 1
      from public.club_memberships cm
      where cm.club_id = invite_record.club_id
        and cm.user_id = auth.uid()
        and lower(cm.status::text) = 'active'
    ) then
      raise exception 'You are not an active member of this club.';
    end if;
  else
    if not public.is_app_admin()
       or not exists(
         select 1
         from public.club_memberships cm
         where cm.club_id = invite_record.club_id
           and cm.user_id = auth.uid()
           and lower(cm.status::text) = 'active'
           and lower(cm.role::text) = 'admin'
       ) then
      raise exception
        'Only the invited player or a club administrator can accept this invitation.';
    end if;
  end if;

  select *
  into listing_record
  from public.partner_listings
  where id = invite_record.listing_id
  for update;

  if not found or listing_record.status <> 'Active' then
    raise exception 'The partner listing is no longer active.';
  end if;

  if listing_record.club_id is distinct from invite_record.club_id then
    raise exception
      'The invitation and partner listing do not belong to the same club.';
  end if;

  if invite_record.sender_user_id is null
     or invite_record.recipient_user_id is null then
    raise exception 'Both players must have signed-in accounts.';
  end if;

  if invite_record.sender_user_id =
     invite_record.recipient_user_id then
    raise exception 'A player cannot form a team with themselves.';
  end if;

  if not exists(
    select 1
    from public.club_memberships cm
    where cm.club_id = invite_record.club_id
      and cm.user_id = invite_record.sender_user_id
      and lower(cm.status::text) = 'active'
  ) or not exists(
    select 1
    from public.club_memberships cm
    where cm.club_id = invite_record.club_id
      and cm.user_id = invite_record.recipient_user_id
      and lower(cm.status::text) = 'active'
  ) then
    raise exception 'Both players must be active members of this club.';
  end if;

  if invite_record.ladder = 'mens'
     and (
       lower(invite_record.sender_gender) <> 'male'
       or lower(invite_record.recipient_gender) <> 'male'
     ) then
    raise exception
      'Men''s teams must contain two male players.';
  end if;

  if invite_record.ladder = 'womens'
     and (
       lower(invite_record.sender_gender) <> 'female'
       or lower(invite_record.recipient_gender) <> 'female'
     ) then
    raise exception
      'Women''s teams must contain two female players.';
  end if;

  if invite_record.ladder = 'mixed'
     and lower(invite_record.sender_gender) =
         lower(invite_record.recipient_gender) then
    raise exception
      'Mixed teams must contain one male and one female player.';
  end if;

  if exists(
    select 1
    from private.team_members tm
    where tm.club_id = invite_record.club_id
      and tm.ladder = invite_record.ladder
      and tm.user_id in (
        invite_record.sender_user_id,
        invite_record.recipient_user_id
      )
  ) then
    raise exception
      'One of these players is already assigned to a team in this ladder.';
  end if;

  if exists(
    select 1
    from public.ladder_teams lt
    where lt.club_id = invite_record.club_id
      and lt.ladder = invite_record.ladder
      and lower(lt.name) = lower(normalized_team_name)
  ) then
    raise exception 'That team name is already being used.';
  end if;

  select email
  into sender_email
  from auth.users
  where id = invite_record.sender_user_id;

  select email
  into recipient_email
  from auth.users
  where id = invite_record.recipient_user_id;

  if sender_email is null or recipient_email is null then
    raise exception 'Both player email addresses are required.';
  end if;

  team_is_nr :=
    invite_record.sender_is_nr
    or invite_record.recipient_is_nr;

  if team_is_nr then
    combined_dupr := null;
  else
    combined_dupr :=
      invite_record.sender_dupr +
      invite_record.recipient_dupr;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext(
      'paddleladder_team_creation_' ||
      invite_record.club_id::text ||
      '_' ||
      invite_record.ladder
    )
  );

  perform id
  from public.ladder_teams
  where club_id = invite_record.club_id
    and ladder = invite_record.ladder
  order by rank_position
  for update;

  select coalesce(max(rank_position), 0) + 1
  into insertion_rank
  from public.ladder_teams
  where club_id = invite_record.club_id
    and ladder = invite_record.ladder;

  -- Rated teams may be placed by DUPR, but never above rank 11.
  if not team_is_nr then
    select rank_position
    into insertion_rank
    from public.ladder_teams
    where club_id = invite_record.club_id
      and ladder = invite_record.ladder
      and rank_position >= 11
      and (
        is_nr = true
        or dupr is null
        or dupr < combined_dupr
      )
    order by rank_position
    limit 1;

    if insertion_rank is null then
      select coalesce(max(rank_position), 0) + 1
      into insertion_rank
      from public.ladder_teams
      where club_id = invite_record.club_id
        and ladder = invite_record.ladder;
    end if;
  end if;

  -- Make space for the new team.
  for moved_team in
    select id, name, rank_position
    from public.ladder_teams
    where club_id = invite_record.club_id
      and ladder = invite_record.ladder
      and rank_position >= insertion_rank
    order by rank_position desc
  loop
    insert into public.ladder_movements(
      club_id,
      team_id,
      team_name,
      ladder,
      from_rank,
      to_rank,
      reason,
      created_at
    )
    values(
      invite_record.club_id,
      moved_team.id,
      moved_team.name,
      invite_record.ladder,
      moved_team.rank_position,
      moved_team.rank_position + 1,
      'Shifted after new team entry',
      action_time
    );

    update public.ladder_teams
    set
      rank_position = moved_team.rank_position + 1,
      updated_at = action_time
    where id = moved_team.id
      and club_id = invite_record.club_id;
  end loop;

  insert into public.ladder_teams(
    club_id,
    ladder,
    rank_position,
    name,
    players,
    dupr,
    is_nr,
    wins,
    losses,
    away,
    created_at,
    updated_at
  )
  values(
    invite_record.club_id,
    invite_record.ladder,
    insertion_rank,
    normalized_team_name,
    invite_record.sender_name ||
      ' / ' ||
      invite_record.recipient_name,
    combined_dupr,
    team_is_nr,
    0,
    0,
    false,
    action_time,
    action_time
  )
  returning id into new_team_id;

  insert into private.team_members(
    club_id,
    team_id,
    user_id,
    email,
    ladder,
    created_at
  )
  values
  (
    invite_record.club_id,
    new_team_id,
    invite_record.sender_user_id,
    lower(sender_email),
    invite_record.ladder,
    action_time
  ),
  (
    invite_record.club_id,
    new_team_id,
    invite_record.recipient_user_id,
    lower(recipient_email),
    invite_record.ladder,
    action_time
  );

  update public.partner_invites
  set
    status = 'Accepted',
    accepted_at = action_time
  where id = requested_invite_id
    and club_id = invite_record.club_id;

  update public.partner_listings
  set
    status = 'Removed',
    removed_at = action_time
  where club_id = invite_record.club_id
    and ladder = invite_record.ladder
    and owner_user_id in (
      invite_record.sender_user_id,
      invite_record.recipient_user_id
    )
    and status = 'Active';

  update public.partner_invites
  set
    status = 'Cancelled',
    cancelled_at = action_time
  where club_id = invite_record.club_id
    and id <> requested_invite_id
    and ladder = invite_record.ladder
    and status = 'Pending'
    and (
      sender_user_id in (
        invite_record.sender_user_id,
        invite_record.recipient_user_id
      )
      or recipient_user_id in (
        invite_record.sender_user_id,
        invite_record.recipient_user_id
      )
    );

  perform private.cancel_invalid_pending_challenges(
    invite_record.club_id,
    invite_record.ladder
  );

  return new_team_id;
end;
$function$;

-- public.admin_add_team_secure(requested_ladder text, requested_team_name text, requested_players text, requested_dupr numeric, requested_is_nr boolean)
CREATE OR REPLACE FUNCTION public.admin_add_team_secure(requested_ladder text, requested_team_name text, requested_players text, requested_dupr numeric, requested_is_nr boolean)
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
  current_club_id uuid;
  admin_club_count bigint;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in';
  end if;

  select
    count(*),
    (pg_catalog.array_agg(
      membership.club_id
      order by membership.created_at
    ))[1]
  into
    admin_club_count,
    current_club_id
  from public.club_memberships as membership
  join public.clubs as club
    on club.id = membership.club_id
  where membership.user_id = auth.uid()
    and membership.role = 'admin'
    and membership.status = 'active'
    and club.active = true;

  if admin_club_count = 0 then
    raise exception 'Active club administrator access required';
  end if;

  if admin_club_count > 1 then
    raise exception 'More than one administered club was found';
  end if;

  normalized_ladder :=
    pg_catalog.lower(
      pg_catalog.btrim(
        pg_catalog.coalesce(requested_ladder, '')
      )
    );

  normalized_name :=
    pg_catalog.btrim(
      pg_catalog.coalesce(requested_team_name, '')
    );

  normalized_players :=
    pg_catalog.btrim(
      pg_catalog.coalesce(requested_players, '')
    );

  if normalized_ladder not in ('mens', 'womens', 'mixed') then
    raise exception 'Invalid ladder';
  end if;

  if normalized_name = '' then
    raise exception 'Team name is required';
  end if;

  if normalized_players = '' then
    raise exception 'Player names are required';
  end if;

  if not pg_catalog.coalesce(requested_is_nr, false)
     and (requested_dupr is null or requested_dupr <= 0) then
    raise exception 'A valid combined DUPR is required';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext(
      'club-ladder:'
      || current_club_id::text
      || ':'
      || normalized_ladder
    )
  );

  if exists (
    select 1
    from public.ladder_teams as team
    where team.club_id = current_club_id
      and team.ladder = normalized_ladder
      and pg_catalog.lower(team.name) =
          pg_catalog.lower(normalized_name)
  ) then
    raise exception 'That team name is already used in this club ladder';
  end if;

  target_rank := null;

  if not pg_catalog.coalesce(requested_is_nr, false) then
    select team.rank_position
    into target_rank
    from public.ladder_teams as team
    where team.club_id = current_club_id
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
    select pg_catalog.coalesce(
      pg_catalog.max(team.rank_position),
      0
    ) + 1
    into target_rank
    from public.ladder_teams as team
    where team.club_id = current_club_id
      and team.ladder = normalized_ladder;
  end if;

  update public.ladder_teams
  set
    rank_position = rank_position + 1,
    updated_at = pg_catalog.now()
  where club_id = current_club_id
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
    current_club_id,
    normalized_ladder,
    target_rank,
    normalized_name,
    normalized_players,
    case
      when pg_catalog.coalesce(requested_is_nr, false)
        then null
      else requested_dupr
    end,
    pg_catalog.coalesce(requested_is_nr, false)
  )
  returning id into new_team_id;

  return new_team_id;
end;
$function$;

-- public.admin_assign_team_members_secure(requested_team_id uuid, requested_email_one text, requested_email_two text)
CREATE OR REPLACE FUNCTION public.admin_assign_team_members_secure(requested_team_id uuid, requested_email_one text, requested_email_two text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  current_club_id uuid;
  admin_club_ids uuid[];
  team_ladder text;
  normalized_email_one text;
  normalized_email_two text;
  first_user_id uuid;
  second_user_id uuid;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in';
  end if;

  select array_agg(membership.club_id order by membership.created_at)
  into admin_club_ids
  from public.club_memberships as membership
  join public.clubs as club
    on club.id = membership.club_id
  where membership.user_id = auth.uid()
    and membership.role = 'admin'
    and membership.status = 'active'
    and club.active = true;

  if cardinality(coalesce(admin_club_ids, '{}'::uuid[])) <> 1 then
    raise exception 'Exactly one active club administrator membership is required';
  end if;

  current_club_id := admin_club_ids[1];

  select team.ladder
  into team_ladder
  from public.ladder_teams as team
  where team.id = requested_team_id
    and team.club_id = current_club_id
  for update;

  if not found then
    raise exception 'Team not found in your club';
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
       '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  then
    raise exception 'The first email address is invalid';
  end if;

  if normalized_email_two is not null
     and normalized_email_two !~
       '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  then
    raise exception 'The second email address is invalid';
  end if;

  if normalized_email_one is not null
     and normalized_email_one = normalized_email_two
  then
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
    where member.club_id = current_club_id
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
    where member.club_id = current_club_id
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
  where team_id = requested_team_id
    and club_id = current_club_id;

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
      current_club_id,
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
      current_club_id,
      second_user_id,
      normalized_email_two,
      team_ladder
    );
  end if;
end;
$function$;

-- public.admin_get_team_members_secure()
CREATE OR REPLACE FUNCTION public.admin_get_team_members_secure()
 RETURNS TABLE(team_id uuid, email text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  active_club_id uuid;
  active_admin_clubs integer;
begin
  if auth.uid() is null
     or not coalesce(public.is_app_admin(), false) then
    raise exception 'Administrator access required';
  end if;

  select
    count(*)::integer,
    min(cm.club_id::text)::uuid
  into
    active_admin_clubs,
    active_club_id
  from public.club_memberships cm
  where cm.user_id = auth.uid()
    and lower(cm.status::text) = 'active'
    and lower(cm.role::text) = 'admin';

  if active_admin_clubs = 0 then
    raise exception 'You are not an active club administrator.';
  end if;

  if active_admin_clubs > 1 then
    raise exception 'Please select a club before viewing team members.';
  end if;

  return query
  select
    member.team_id,
    member.email
  from private.team_members as member
  where member.club_id = active_club_id
  order by member.team_id, member.email;
end;
$function$;

-- public.admin_remove_team_secure(requested_team_id uuid)
CREATE OR REPLACE FUNCTION public.admin_remove_team_secure(requested_team_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  team_club_id uuid;
  team_ladder text;
  removed_rank integer;
  removed_name text;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select
    team.club_id,
    team.ladder,
    team.rank_position,
    team.name
  into
    team_club_id,
    team_ladder,
    removed_rank,
    removed_name
  from public.ladder_teams as team
  where team.id = requested_team_id
  for update;

  if not found then
    raise exception 'Team not found';
  end if;

  if team_club_id is null then
    raise exception 'This team is not assigned to a club.';
  end if;

  if not coalesce(public.is_app_admin(), false)
     or not exists(
       select 1
       from public.club_memberships cm
       where cm.club_id = team_club_id
         and cm.user_id = auth.uid()
         and lower(cm.status::text) = 'active'
         and lower(cm.role::text) = 'admin'
     ) then
    raise exception 'Club administrator access required';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext(
      'ladder:' || team_club_id::text || ':' || team_ladder
    )
  );

  if exists (
    select 1
    from public.challenges as challenge
    where challenge.club_id = team_club_id
      and (
        challenge.challenger_team_id = requested_team_id
        or challenge.challenged_team_id = requested_team_id
      )
      and challenge.status in (
        'Pending',
        'Accepted',
        'Awaiting Confirmation',
        'Decline Pending Admin Review',
        'Overdue',
        'Disputed'
      )
  ) then
    raise exception
      'This team has an open challenge that must be closed first';
  end if;

  delete from public.ladder_teams
  where id = requested_team_id
    and club_id = team_club_id;

  with moved_teams as (
    update public.ladder_teams as team
    set
      rank_position = team.rank_position - 1,
      updated_at = now()
    where team.club_id = team_club_id
      and team.ladder = team_ladder
      and team.rank_position > removed_rank
    returning
      team.id,
      team.name,
      team.ladder,
      team.rank_position + 1 as from_rank,
      team.rank_position as to_rank
  )
  insert into public.ladder_movements (
    club_id,
    team_id,
    team_name,
    ladder,
    from_rank,
    to_rank,
    reason
  )
  select
    team_club_id,
    moved.id,
    moved.name,
    moved.ladder,
    moved.from_rank,
    moved.to_rank,
    'Team removed by Admin: ' || removed_name
  from moved_teams as moved;

  perform private.cancel_invalid_pending_challenges(
    team_club_id,
    team_ladder
  );
end;
$function$;

-- public.admin_reset_disputed_result_secure(requested_challenge_id uuid)
CREATE OR REPLACE FUNCTION public.admin_reset_disputed_result_secure(requested_challenge_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  disputed_match public.challenges%rowtype;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select *
  into disputed_match
  from public.challenges
  where id = requested_challenge_id
  for update;

  if not found then
    raise exception 'Challenge not found.';
  end if;

  if disputed_match.club_id is null then
    raise exception 'This challenge is not assigned to a club.';
  end if;

  if not public.is_app_admin()
     or not exists(
       select 1
       from public.club_memberships cm
       where cm.club_id = disputed_match.club_id
         and cm.user_id = auth.uid()
         and lower(cm.status::text) = 'active'
         and lower(cm.role::text) = 'admin'
     ) then
    raise exception
      'Only a club administrator can reopen a disputed result.';
  end if;

  if disputed_match.status <> 'Disputed' then
    raise exception 'Only a disputed result can be reopened.';
  end if;

  update public.challenges
  set
    status = 'Accepted',
    scores = null,
    winner_team_id = null,
    winner_name = null,
    submitted_by_team_id = null,
    disputed_at = null,
    updated_at = now()
  where id = requested_challenge_id
    and club_id = disputed_match.club_id;
end;
$function$;

-- public.cancel_challenge_secure(requested_challenge_id uuid)
CREATE OR REPLACE FUNCTION public.cancel_challenge_secure(requested_challenge_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  selected_challenge public.challenges%rowtype;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select *
  into selected_challenge
  from public.challenges
  where id = requested_challenge_id
  for update;

  if selected_challenge.id is null then
    raise exception 'This challenge could not be found.';
  end if;

  if selected_challenge.club_id is null then
    raise exception 'This challenge is not assigned to a club.';
  end if;

  if selected_challenge.status <> 'Pending' then
    raise exception 'Only a pending challenge can be cancelled.';
  end if;

  if public.user_belongs_to_team(
       selected_challenge.challenger_team_id
     ) then
    if not exists(
      select 1
      from public.club_memberships cm
      where cm.club_id = selected_challenge.club_id
        and cm.user_id = auth.uid()
        and lower(cm.status::text) = 'active'
    ) then
      raise exception 'You are not an active member of this club.';
    end if;
  else
    if not public.is_app_admin()
       or not exists(
         select 1
         from public.club_memberships cm
         where cm.club_id = selected_challenge.club_id
           and cm.user_id = auth.uid()
           and lower(cm.status::text) = 'active'
           and lower(cm.role::text) = 'admin'
       ) then
      raise exception
        'Only the challenging team or a club administrator can cancel this challenge.';
    end if;
  end if;

  update public.challenges
  set
    status = 'Cancelled',
    cancel_reason = 'Cancelled by the challenging team.',
    cancelled_at = now(),
    updated_at = now()
  where id = selected_challenge.id
    and club_id = selected_challenge.club_id;

  return 'Cancelled';
end;
$function$;

-- public.cancel_partner_invite_secure(requested_invite_id uuid)
CREATE OR REPLACE FUNCTION public.cancel_partner_invite_secure(requested_invite_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  invite_record public.partner_invites%rowtype;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select *
  into invite_record
  from public.partner_invites
  where id = requested_invite_id
  for update;

  if not found then
    raise exception 'Partner invitation not found.';
  end if;

  if invite_record.club_id is null then
    raise exception 'This partner invitation is not assigned to a club.';
  end if;

  if invite_record.sender_user_id = auth.uid() then
    if not exists(
      select 1
      from public.club_memberships cm
      where cm.club_id = invite_record.club_id
        and cm.user_id = auth.uid()
        and lower(cm.status::text) = 'active'
    ) then
      raise exception 'You are not an active member of this club.';
    end if;
  else
    if not public.is_app_admin()
       or not exists(
         select 1
         from public.club_memberships cm
         where cm.club_id = invite_record.club_id
           and cm.user_id = auth.uid()
           and lower(cm.status::text) = 'active'
           and lower(cm.role::text) = 'admin'
       ) then
      raise exception
        'Only the sender or a club administrator can cancel this invitation.';
    end if;
  end if;

  if invite_record.status <> 'Pending' then
    raise exception 'This invitation is no longer pending.';
  end if;

  update public.partner_invites
  set
    status = 'Cancelled',
    cancelled_at = now()
  where id = requested_invite_id
    and club_id = invite_record.club_id;

  return 'Partner invitation cancelled.';
end;
$function$;

-- public.confirm_result_secure(requested_challenge_id uuid, requested_action text)
CREATE OR REPLACE FUNCTION public.confirm_result_secure(requested_challenge_id uuid, requested_action text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  challenge_record public.challenges%rowtype;
  action_text text;
  confirming_team_id uuid;
  losing_team_id uuid;
  challenger_rank integer;
  challenged_rank integer;
  moved_team record;
  action_time timestamptz := now();
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  action_text := lower(trim(requested_action));

  if action_text not in ('confirm', 'dispute') then
    raise exception 'Action must be Confirm or Dispute.';
  end if;

  select *
  into challenge_record
  from public.challenges
  where id = requested_challenge_id
  for update;

  if not found then
    raise exception 'Challenge not found.';
  end if;

  if challenge_record.club_id is null then
    raise exception 'This challenge is not assigned to a club.';
  end if;

  if challenge_record.status <> 'Awaiting Confirmation' then
    raise exception 'This result is not awaiting confirmation.';
  end if;

  if challenge_record.submitted_by_team_id is null then
    raise exception 'The submitting team could not be identified.';
  end if;

  if challenge_record.submitted_by_team_id =
     challenge_record.challenger_team_id then
    confirming_team_id :=
      challenge_record.challenged_team_id;

  elsif challenge_record.submitted_by_team_id =
        challenge_record.challenged_team_id then
    confirming_team_id :=
      challenge_record.challenger_team_id;

  else
    raise exception 'The result was submitted by an invalid team.';
  end if;

  if not exists(
    select 1
    from public.ladder_teams lt
    where lt.id = confirming_team_id
      and lt.club_id = challenge_record.club_id
  ) then
    raise exception 'The confirming team does not belong to this club.';
  end if;

  if public.user_belongs_to_team(confirming_team_id) then
    if not exists(
      select 1
      from public.club_memberships cm
      where cm.club_id = challenge_record.club_id
        and cm.user_id = auth.uid()
        and lower(cm.status::text) = 'active'
    ) then
      raise exception 'You are not an active member of this club.';
    end if;
  else
    if not public.is_app_admin()
       or not exists(
         select 1
         from public.club_memberships cm
         where cm.club_id = challenge_record.club_id
           and cm.user_id = auth.uid()
           and lower(cm.status::text) = 'active'
           and lower(cm.role::text) = 'admin'
       ) then
      raise exception
        'Only the opposing team or a club administrator can review this result.';
    end if;
  end if;

  if action_text = 'dispute' then
    update public.challenges
    set
      status = 'Disputed',
      disputed_at = action_time,
      updated_at = action_time
    where id = requested_challenge_id
      and club_id = challenge_record.club_id;

    return 'Disputed';
  end if;

  if challenge_record.winner_team_id not in (
    challenge_record.challenger_team_id,
    challenge_record.challenged_team_id
  ) then
    raise exception 'A valid winning team was not recorded.';
  end if;

  losing_team_id :=
    case
      when challenge_record.winner_team_id =
           challenge_record.challenger_team_id
      then challenge_record.challenged_team_id
      else challenge_record.challenger_team_id
    end;

  -- Lock this club's ladder while standings are updated.
  perform id
  from public.ladder_teams
  where club_id = challenge_record.club_id
    and ladder = challenge_record.ladder
  order by rank_position
  for update;

  select rank_position
  into challenger_rank
  from public.ladder_teams
  where id = challenge_record.challenger_team_id
    and club_id = challenge_record.club_id;

  select rank_position
  into challenged_rank
  from public.ladder_teams
  where id = challenge_record.challenged_team_id
    and club_id = challenge_record.club_id;

  if challenger_rank is null or challenged_rank is null then
    raise exception 'One of the teams could not be found in this club.';
  end if;

  update public.ladder_teams
  set
    wins = wins + 1,
    updated_at = action_time
  where id = challenge_record.winner_team_id
    and club_id = challenge_record.club_id;

  update public.ladder_teams
  set
    losses = losses + 1,
    updated_at = action_time
  where id = losing_team_id
    and club_id = challenge_record.club_id;

  -- A successful challenger takes the challenged team's rank.
  if challenge_record.winner_team_id =
     challenge_record.challenger_team_id
     and challenger_rank > challenged_rank then

    for moved_team in
      select id, name, rank_position
      from public.ladder_teams
      where club_id = challenge_record.club_id
        and ladder = challenge_record.ladder
        and rank_position >= challenged_rank
        and rank_position < challenger_rank
        and id <> challenge_record.challenger_team_id
      order by rank_position
    loop
      insert into public.ladder_movements(
        club_id,
        team_id,
        team_name,
        ladder,
        from_rank,
        to_rank,
        reason,
        created_at
      )
      values(
        challenge_record.club_id,
        moved_team.id,
        moved_team.name,
        challenge_record.ladder,
        moved_team.rank_position,
        moved_team.rank_position + 1,
        'Shifted after challenge result',
        action_time
      );

      update public.ladder_teams
      set
        rank_position = moved_team.rank_position + 1,
        updated_at = action_time
      where id = moved_team.id
        and club_id = challenge_record.club_id;
    end loop;

    insert into public.ladder_movements(
      club_id,
      team_id,
      team_name,
      ladder,
      from_rank,
      to_rank,
      reason,
      created_at
    )
    values(
      challenge_record.club_id,
      challenge_record.challenger_team_id,
      challenge_record.challenger_name,
      challenge_record.ladder,
      challenger_rank,
      challenged_rank,
      'Won challenge against ' ||
        challenge_record.challenged_name,
      action_time
    );

    update public.ladder_teams
    set
      rank_position = challenged_rank,
      updated_at = action_time
    where id = challenge_record.challenger_team_id
      and club_id = challenge_record.club_id;
  end if;

  update public.challenges
  set
    status = 'Completed',
    completed_at = action_time,
    updated_at = action_time
  where id = requested_challenge_id
    and club_id = challenge_record.club_id;

  perform private.cancel_invalid_pending_challenges(
    challenge_record.club_id,
    challenge_record.ladder
  );

  return 'Completed';
end;
$function$;

-- public.create_partner_listing_secure(requested_name text, requested_gender text, requested_dupr text, requested_ladder text)
CREATE OR REPLACE FUNCTION public.create_partner_listing_secure(requested_name text, requested_gender text, requested_dupr text, requested_ladder text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  normalized_name text;
  normalized_gender text;
  normalized_ladder text;
  normalized_dupr text;
  dupr_value numeric;
  listing_is_nr boolean := false;
  new_listing_id uuid;
  signed_in_email text;
  active_club_id uuid;
  active_memberships integer;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select
    count(*)::integer,
    min(cm.club_id::text)::uuid
  into
    active_memberships,
    active_club_id
  from public.club_memberships cm
  where cm.user_id = auth.uid()
    and lower(cm.status::text) = 'active';

  if active_memberships = 0 then
    raise exception 'You do not have an active club membership.';
  end if;

  if active_memberships > 1 then
    raise exception 'Please select a club before creating a partner listing.';
  end if;

  normalized_name := trim(requested_name);
  normalized_gender := lower(trim(requested_gender));
  normalized_ladder := lower(trim(requested_ladder));
  normalized_dupr := upper(trim(requested_dupr));
  signed_in_email := lower(auth.jwt() ->> 'email');

  if normalized_name = '' then
    raise exception 'Please enter your name.';
  end if;

  if normalized_gender not in ('male', 'female') then
    raise exception 'Gender must be Male or Female.';
  end if;

  if normalized_ladder not in ('mens', 'womens', 'mixed') then
    raise exception 'Please select a valid ladder.';
  end if;

  if normalized_ladder = 'mens'
     and normalized_gender <> 'male' then
    raise exception
      'Only male players may list for the Men''s ladder.';
  end if;

  if normalized_ladder = 'womens'
     and normalized_gender <> 'female' then
    raise exception
      'Only female players may list for the Women''s ladder.';
  end if;

  if normalized_dupr = 'NR' then
    listing_is_nr := true;
    dupr_value := null;
  else
    if normalized_dupr !~ '^[0-9]+([.][0-9]+)?$' then
      raise exception 'Please enter a valid DUPR or NR.';
    end if;

    dupr_value := normalized_dupr::numeric;

    if dupr_value <= 0 or dupr_value > 99.99 then
      raise exception 'Please enter a valid DUPR or NR.';
    end if;
  end if;

  if exists(
    select 1
    from private.team_members tm
    where tm.club_id = active_club_id
      and tm.ladder = normalized_ladder
      and (
        tm.user_id = auth.uid()
        or (
          signed_in_email is not null
          and lower(tm.email) = signed_in_email
        )
      )
  ) then
    raise exception
      'You are already assigned to a team in this ladder.';
  end if;

  if exists(
    select 1
    from public.partner_listings pl
    where pl.club_id = active_club_id
      and pl.owner_user_id = auth.uid()
      and pl.ladder = normalized_ladder
      and pl.status = 'Active'
  ) then
    raise exception
      'You already have an active listing for this ladder.';
  end if;

  insert into public.partner_listings(
    club_id,
    owner_user_id,
    name,
    gender,
    dupr,
    is_nr,
    ladder,
    status,
    created_at,
    updated_at
  )
  values(
    active_club_id,
    auth.uid(),
    normalized_name,
    case
      when normalized_gender = 'male' then 'Male'
      else 'Female'
    end,
    dupr_value,
    listing_is_nr,
    normalized_ladder,
    'Active',
    now(),
    now()
  )
  returning id into new_listing_id;

  return new_listing_id;
end;
$function$;

-- public.decline_partner_invite_secure(requested_invite_id uuid)
CREATE OR REPLACE FUNCTION public.decline_partner_invite_secure(requested_invite_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  invite_record public.partner_invites%rowtype;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select *
  into invite_record
  from public.partner_invites
  where id = requested_invite_id
  for update;

  if not found then
    raise exception 'Partner invitation not found.';
  end if;

  if invite_record.club_id is null then
    raise exception 'This partner invitation is not assigned to a club.';
  end if;

  if invite_record.recipient_user_id = auth.uid() then
    if not exists(
      select 1
      from public.club_memberships cm
      where cm.club_id = invite_record.club_id
        and cm.user_id = auth.uid()
        and lower(cm.status::text) = 'active'
    ) then
      raise exception 'You are not an active member of this club.';
    end if;
  else
    if not public.is_app_admin()
       or not exists(
         select 1
         from public.club_memberships cm
         where cm.club_id = invite_record.club_id
           and cm.user_id = auth.uid()
           and lower(cm.status::text) = 'active'
           and lower(cm.role::text) = 'admin'
       ) then
      raise exception
        'Only the invited player or a club administrator can decline this invitation.';
    end if;
  end if;

  if invite_record.status <> 'Pending' then
    raise exception 'This invitation is no longer pending.';
  end if;

  update public.partner_invites
  set
    status = 'Declined',
    declined_at = now()
  where id = requested_invite_id
    and club_id = invite_record.club_id;

  return 'Partner invitation declined.';
end;
$function$;

-- public.enforce_one_team_per_ladder()
CREATE OR REPLACE FUNCTION public.enforce_one_team_per_ladder()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  target_ladder uuid;
begin
  select ladder_id
  into target_ladder
  from public.teams
  where id = new.team_id;

  if exists (
    select 1
    from public.team_members tm
    join public.teams t on t.id = tm.team_id
    where tm.user_id = new.user_id
      and tm.active = true
      and t.ladder_id = target_ladder
      and tm.team_id <> new.team_id
  ) then
    raise exception
      'Player already belongs to an active team in this ladder';
  end if;

  return new;
end;
$function$;

-- public.get_my_active_clubs_secure()
CREATE OR REPLACE FUNCTION public.get_my_active_clubs_secure()
 RETURNS TABLE(club_id uuid, club_name text, club_slug text, member_role text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  return query
  select
    c.id,
    c.name,
    c.slug,
    cm.role::text
  from public.club_memberships cm
  join public.clubs c
    on c.id = cm.club_id
  where cm.user_id = auth.uid()
    and lower(cm.status::text) = 'active'
  order by c.name;
end;
$function$;

-- public.handle_new_user()
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data ->> 'full_name',
      new.raw_user_meta_data ->> 'name',
      'Member'
    )
  )
  on conflict (id) do nothing;

  return new;
end;
$function$;

-- public.issue_challenge_secure(challenger_id uuid, challenged_id uuid)
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

  if challenger_team.club_id is null
     or challenged_team.club_id is null then
    raise exception 'Both teams must be assigned to a club.';
  end if;

  if challenger_team.club_id <> challenged_team.club_id then
    raise exception 'Teams must belong to the same club.';
  end if;

  if public.user_belongs_to_team(challenger_id) then
    if not exists(
      select 1
      from public.club_memberships cm
      where cm.club_id = challenger_team.club_id
        and cm.user_id = auth.uid()
        and lower(cm.status::text) = 'active'
    ) then
      raise exception 'You are not an active member of this club.';
    end if;
  else
    if not public.is_app_admin()
       or not exists(
         select 1
         from public.club_memberships cm
         where cm.club_id = challenger_team.club_id
           and cm.user_id = auth.uid()
           and lower(cm.status::text) = 'active'
           and lower(cm.role::text) = 'admin'
       ) then
      raise exception
        'Your account is not assigned to the challenging team.';
    end if;
  end if;

  if challenger_team.ladder <> challenged_team.ladder then
    raise exception 'Teams must be in the same ladder.';
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
    from public.challenges c
    where c.club_id = challenger_team.club_id
      and c.status in (
        'Pending',
        'Accepted',
        'Awaiting Confirmation',
        'Decline Pending Admin Review',
        'Overdue',
        'Disputed'
      )
      and (
        c.challenger_team_id in (
          challenger_id,
          challenged_id
        )
        or c.challenged_team_id in (
          challenger_id,
          challenged_id
        )
      )
  ) then
    raise exception 'One of these teams already has an open challenge.';
  end if;

  if exists (
    select 1
    from public.challenges c
    where c.club_id = challenger_team.club_id
      and c.completed_at > now() - interval '7 days'
      and (
        (
          c.challenger_team_id = challenger_id
          and c.challenged_team_id = challenged_id
        )
        or
        (
          c.challenger_team_id = challenged_id
          and c.challenged_team_id = challenger_id
        )
      )
  ) then
    raise exception 'These teams must wait seven days before a rematch.';
  end if;

  select count(*)
  into active_teams_above
  from public.ladder_teams lt
  where lt.club_id = challenger_team.club_id
    and lt.ladder = challenger_team.ladder
    and lt.away = false
    and lt.rank_position < challenger_team.rank_position
    and lt.rank_position >= challenged_team.rank_position;

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
$function$;

-- public.record_forfeit_secure(requested_challenge_id uuid, forfeiting_team_id uuid)
CREATE OR REPLACE FUNCTION public.record_forfeit_secure(requested_challenge_id uuid, forfeiting_team_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  challenge_record public.challenges%rowtype;
  winning_team_id uuid;
  winning_team public.ladder_teams%rowtype;
  challenger_rank integer;
  challenged_rank integer;
  moved_team record;
  action_time timestamp with time zone := now();
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select *
  into challenge_record
  from public.challenges
  where id = requested_challenge_id
  for update;

  if not found then
    raise exception 'Challenge not found.';
  end if;

  if challenge_record.club_id is null then
    raise exception 'This challenge is not assigned to a club.';
  end if;

  if not public.is_app_admin()
     or not exists(
       select 1
       from public.club_memberships cm
       where cm.club_id = challenge_record.club_id
         and cm.user_id = auth.uid()
         and lower(cm.status::text) = 'active'
         and lower(cm.role::text) = 'admin'
     ) then
    raise exception 'Only a club administrator can record a forfeit.';
  end if;

  if challenge_record.status <> 'Overdue' then
    raise exception 'Only an overdue match can be recorded as a forfeit.';
  end if;

  if forfeiting_team_id not in (
    challenge_record.challenger_team_id,
    challenge_record.challenged_team_id
  ) then
    raise exception 'The forfeiting team is not part of this match.';
  end if;

  winning_team_id :=
    case
      when forfeiting_team_id =
           challenge_record.challenger_team_id
      then challenge_record.challenged_team_id
      else challenge_record.challenger_team_id
    end;

  -- Lock this club's ladder before standings change.
  perform id
  from public.ladder_teams
  where club_id = challenge_record.club_id
    and ladder = challenge_record.ladder
  order by rank_position
  for update;

  select *
  into winning_team
  from public.ladder_teams
  where id = winning_team_id
    and club_id = challenge_record.club_id;

  if not found then
    raise exception 'The winning team could not be found in this club.';
  end if;

  select rank_position
  into challenger_rank
  from public.ladder_teams
  where id = challenge_record.challenger_team_id
    and club_id = challenge_record.club_id;

  select rank_position
  into challenged_rank
  from public.ladder_teams
  where id = challenge_record.challenged_team_id
    and club_id = challenge_record.club_id;

  if challenger_rank is null or challenged_rank is null then
    raise exception 'One of the teams could not be found in this club.';
  end if;

  update public.ladder_teams
  set
    wins = wins + 1,
    updated_at = action_time
  where id = winning_team_id
    and club_id = challenge_record.club_id;

  update public.ladder_teams
  set
    losses = losses + 1,
    updated_at = action_time
  where id = forfeiting_team_id
    and club_id = challenge_record.club_id;

  -- Normal movement applies only if the challenger wins.
  if winning_team_id = challenge_record.challenger_team_id
     and challenger_rank > challenged_rank then

    for moved_team in
      select id, name, rank_position
      from public.ladder_teams
      where club_id = challenge_record.club_id
        and ladder = challenge_record.ladder
        and rank_position >= challenged_rank
        and rank_position < challenger_rank
        and id <> challenge_record.challenger_team_id
      order by rank_position
    loop
      insert into public.ladder_movements(
        club_id,
        team_id,
        team_name,
        ladder,
        from_rank,
        to_rank,
        reason,
        created_at
      )
      values(
        challenge_record.club_id,
        moved_team.id,
        moved_team.name,
        challenge_record.ladder,
        moved_team.rank_position,
        moved_team.rank_position + 1,
        'Shifted after forfeit result',
        action_time
      );

      update public.ladder_teams
      set
        rank_position = moved_team.rank_position + 1,
        updated_at = action_time
      where id = moved_team.id
        and club_id = challenge_record.club_id;
    end loop;

    insert into public.ladder_movements(
      club_id,
      team_id,
      team_name,
      ladder,
      from_rank,
      to_rank,
      reason,
      created_at
    )
    values(
      challenge_record.club_id,
      challenge_record.challenger_team_id,
      challenge_record.challenger_name,
      challenge_record.ladder,
      challenger_rank,
      challenged_rank,
      'Won by forfeit against ' ||
        challenge_record.challenged_name,
      action_time
    );

    update public.ladder_teams
    set
      rank_position = challenged_rank,
      updated_at = action_time
    where id = challenge_record.challenger_team_id
      and club_id = challenge_record.club_id;
  end if;

  update public.challenges
  set
    status = 'Completed',
    winner_team_id = winning_team_id,
    winner_name = winning_team.name,
    forfeited_by_team_id = forfeiting_team_id,
    forfeit = true,
    scores = null,
    completed_at = action_time,
    updated_at = action_time
  where id = requested_challenge_id
    and club_id = challenge_record.club_id;

  perform private.cancel_invalid_pending_challenges(
    challenge_record.club_id,
    challenge_record.ladder
  );

  return 'Forfeit recorded — standings updated.';
end;
$function$;

-- public.refresh_acceptance_enforcement_secure()
CREATE OR REPLACE FUNCTION public.refresh_acceptance_enforcement_secure()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  due_team record;
  team_record public.ladder_teams%rowtype;
  team_below public.ladder_teams%rowtype;
  moved_team record;
  new_missed_periods integer;
  check_time timestamp with time zone := now();
  satisfied_count integer := 0;
  penalty_count integer := 0;
  removed_count integer := 0;
begin
  -- Prevent two enforcement checks from running simultaneously.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext(
      'paddleladder_acceptance_enforcement'
    )
  );

  for due_team in
    select id, club_id
    from public.ladder_teams
    where club_id is not null
      and acceptance_period_started_at is not null
      and acceptance_period_started_at <=
          check_time - interval '14 days'
    order by club_id, ladder, rank_position
  loop
    select *
    into team_record
    from public.ladder_teams
    where id = due_team.id
      and club_id = due_team.club_id
    for update;

    if not found then
      continue;
    end if;

    -- The team accepted at least one challenge.
    if team_record.accepted_in_period then
      update public.ladder_teams
      set
        acceptance_period_started_at = null,
        accepted_in_period = false,
        missed_periods = 0,
        updated_at = check_time
      where id = team_record.id
        and club_id = team_record.club_id;

      satisfied_count := satisfied_count + 1;
      continue;
    end if;

    new_missed_periods :=
      team_record.missed_periods + 1;

    -- Four missed challenged periods removes the team.
    if new_missed_periods >= 4 then
      perform id
      from public.ladder_teams
      where club_id = team_record.club_id
        and ladder = team_record.ladder
      order by rank_position
      for update;

      update public.challenges
      set
        status = 'Cancelled',
        cancel_reason =
          'Team removed after four missed acceptance periods.',
        cancelled_at = check_time,
        updated_at = check_time
      where club_id = team_record.club_id
        and status in (
          'Pending',
          'Accepted',
          'Awaiting Confirmation',
          'Decline Pending Admin Review',
          'Overdue',
          'Disputed'
        )
        and (
          challenger_team_id = team_record.id
          or challenged_team_id = team_record.id
        );

      delete from private.team_members
      where club_id = team_record.club_id
        and team_id = team_record.id;

      delete from public.ladder_teams
      where id = team_record.id
        and club_id = team_record.club_id;

      for moved_team in
        select id, name, rank_position
        from public.ladder_teams
        where club_id = team_record.club_id
          and ladder = team_record.ladder
          and rank_position > team_record.rank_position
        order by rank_position
      loop
        insert into public.ladder_movements(
          club_id,
          team_id,
          team_name,
          ladder,
          from_rank,
          to_rank,
          reason,
          created_at
        )
        values(
          team_record.club_id,
          moved_team.id,
          moved_team.name,
          team_record.ladder,
          moved_team.rank_position,
          moved_team.rank_position - 1,
          'Moved up after inactive team removal',
          check_time
        );

        update public.ladder_teams
        set
          rank_position = moved_team.rank_position - 1,
          updated_at = check_time
        where id = moved_team.id
          and club_id = team_record.club_id;
      end loop;

      perform private.cancel_invalid_pending_challenges(
        team_record.club_id,
        team_record.ladder
      );

      removed_count := removed_count + 1;
      continue;
    end if;

    -- A missed period drops the team one same-club ladder position.
    perform id
    from public.ladder_teams
    where club_id = team_record.club_id
      and ladder = team_record.ladder
    order by rank_position
    for update;

    select *
    into team_below
    from public.ladder_teams
    where club_id = team_record.club_id
      and ladder = team_record.ladder
      and rank_position > team_record.rank_position
    order by rank_position
    limit 1;

    if found then
      insert into public.ladder_movements(
        club_id,
        team_id,
        team_name,
        ladder,
        from_rank,
        to_rank,
        reason,
        created_at
      )
      values
      (
        team_record.club_id,
        team_record.id,
        team_record.name,
        team_record.ladder,
        team_record.rank_position,
        team_below.rank_position,
        'Missed 14-day acceptance period',
        check_time
      ),
      (
        team_record.club_id,
        team_below.id,
        team_below.name,
        team_below.ladder,
        team_below.rank_position,
        team_record.rank_position,
        'Moved up after acceptance penalty',
        check_time
      );

      update public.ladder_teams
      set
        rank_position = team_below.rank_position,
        acceptance_period_started_at = null,
        accepted_in_period = false,
        missed_periods = new_missed_periods,
        updated_at = check_time
      where id = team_record.id
        and club_id = team_record.club_id;

      update public.ladder_teams
      set
        rank_position = team_record.rank_position,
        updated_at = check_time
      where id = team_below.id
        and club_id = team_record.club_id;

      perform private.cancel_invalid_pending_challenges(
        team_record.club_id,
        team_record.ladder
      );
    else
      -- The last-ranked team records the miss but cannot drop farther.
      update public.ladder_teams
      set
        acceptance_period_started_at = null,
        accepted_in_period = false,
        missed_periods = new_missed_periods,
        updated_at = check_time
      where id = team_record.id
        and club_id = team_record.club_id;
    end if;

    penalty_count := penalty_count + 1;
  end loop;

  return jsonb_build_object(
    'periods_satisfied', satisfied_count,
    'penalties_applied', penalty_count,
    'teams_removed', removed_count
  );
end;
$function$;

-- public.refresh_challenge_deadlines_secure()
CREATE OR REPLACE FUNCTION public.refresh_challenge_deadlines_secure()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  pending_expired integer := 0;
  matches_overdue integer := 0;
  check_time timestamp with time zone := now();
begin
  -- Pending challenges receive 72 hours for a response.
  update public.challenges
  set
    status = 'Decline Pending Admin Review',
    decline_reason = 'No response within 72 hours.',
    declined_at = check_time,
    updated_at = check_time
  where club_id is not null
    and status = 'Pending'
    and created_at <= check_time - interval '72 hours';

  get diagnostics pending_expired = row_count;

  -- Accepted matches become overdue after their play-by deadline.
  update public.challenges
  set
    status = 'Overdue',
    overdue_at = check_time,
    updated_at = check_time
  where club_id is not null
    and status = 'Accepted'
    and (
      play_by <= check_time
      or (
        play_by is null
        and accepted_at <= check_time - interval '7 days'
      )
    );

  get diagnostics matches_overdue = row_count;

  return jsonb_build_object(
    'pending_sent_to_admin_review', pending_expired,
    'matches_marked_overdue', matches_overdue
  );
end;
$function$;

-- public.remove_partner_listing_secure(requested_listing_id uuid)
CREATE OR REPLACE FUNCTION public.remove_partner_listing_secure(requested_listing_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  listing_record public.partner_listings%rowtype;
  action_time timestamp with time zone := now();
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select *
  into listing_record
  from public.partner_listings
  where id = requested_listing_id
  for update;

  if not found then
    raise exception 'Partner listing not found.';
  end if;

  if listing_record.club_id is null then
    raise exception 'This partner listing is not assigned to a club.';
  end if;

  if listing_record.owner_user_id = auth.uid() then
    if not exists(
      select 1
      from public.club_memberships cm
      where cm.club_id = listing_record.club_id
        and cm.user_id = auth.uid()
        and lower(cm.status::text) = 'active'
    ) then
      raise exception 'You are not an active member of this club.';
    end if;
  else
    if not public.is_app_admin()
       or not exists(
         select 1
         from public.club_memberships cm
         where cm.club_id = listing_record.club_id
           and cm.user_id = auth.uid()
           and lower(cm.status::text) = 'active'
           and lower(cm.role::text) = 'admin'
       ) then
      raise exception
        'You can only remove your own listing unless you are a club administrator.';
    end if;
  end if;

  if listing_record.status <> 'Active' then
    raise exception 'This partner listing is no longer active.';
  end if;

  update public.partner_listings
  set
    status = 'Removed',
    removed_at = action_time
  where id = requested_listing_id
    and club_id = listing_record.club_id;

  update public.partner_invites
  set
    status = 'Cancelled',
    cancelled_at = action_time
  where club_id = listing_record.club_id
    and listing_id = requested_listing_id
    and status = 'Pending';

  return 'Partner listing removed.';
end;
$function$;

-- public.respond_to_challenge_secure(challenge_id uuid, response text, decline_reason text)
CREATE OR REPLACE FUNCTION public.respond_to_challenge_secure(challenge_id uuid, response text, decline_reason text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  selected_challenge public.challenges%rowtype;
  current_challenger_rank integer;
  normalized_response text;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  normalized_response := lower(trim(response));

  if normalized_response not in ('accept', 'decline') then
    raise exception 'Response must be accept or decline.';
  end if;

  select *
  into selected_challenge
  from public.challenges
  where id = challenge_id
  for update;

  if selected_challenge.id is null then
    raise exception 'This challenge could not be found.';
  end if;

  if selected_challenge.club_id is null then
    raise exception 'This challenge is not assigned to a club.';
  end if;

  if selected_challenge.status <> 'Pending' then
    raise exception 'This challenge is no longer waiting for a response.';
  end if;

  if public.user_belongs_to_team(
       selected_challenge.challenged_team_id
     ) then
    if not exists(
      select 1
      from public.club_memberships cm
      where cm.club_id = selected_challenge.club_id
        and cm.user_id = auth.uid()
        and lower(cm.status::text) = 'active'
    ) then
      raise exception 'You are not an active member of this club.';
    end if;
  else
    if not public.is_app_admin()
       or not exists(
         select 1
         from public.club_memberships cm
         where cm.club_id = selected_challenge.club_id
           and cm.user_id = auth.uid()
           and lower(cm.status::text) = 'active'
           and lower(cm.role::text) = 'admin'
       ) then
      raise exception 'Only the challenged team can respond.';
    end if;
  end if;

  select rank_position
  into current_challenger_rank
  from public.ladder_teams
  where id = selected_challenge.challenger_team_id
    and club_id = selected_challenge.club_id;

  if current_challenger_rank is null then
    raise exception 'The challenging team is no longer available.';
  end if;

  if exists (
    select 1
    from public.challenges as other_challenge
    join public.ladder_teams as other_challenger
      on other_challenger.id =
         other_challenge.challenger_team_id
     and other_challenger.club_id =
         selected_challenge.club_id
    where other_challenge.club_id =
          selected_challenge.club_id
      and other_challenge.id <>
          selected_challenge.id
      and other_challenge.challenged_team_id =
          selected_challenge.challenged_team_id
      and other_challenge.status = 'Pending'
      and other_challenger.rank_position <
          current_challenger_rank
  ) then
    raise exception 'The highest-ranked challenger must be answered first.';
  end if;

  if normalized_response = 'accept' then
    update public.challenges
    set
      status = 'Accepted',
      accepted_at = now(),
      updated_at = now()
    where id = selected_challenge.id
      and club_id = selected_challenge.club_id;

    return 'Accepted';
  end if;

  if decline_reason is null
     or trim(decline_reason) = '' then
    raise exception 'A decline reason is required.';
  end if;

  update public.challenges
  set
    status = 'Decline Pending Admin Review',
    decline_reason = trim(decline_reason),
    declined_at = now(),
    updated_at = now()
  where id = selected_challenge.id
    and club_id = selected_challenge.club_id;

  return 'Decline Pending Admin Review';
end;
$function$;

-- public.review_away_team_secure(requested_team_id uuid, requested_action text)
CREATE OR REPLACE FUNCTION public.review_away_team_secure(requested_team_id uuid, requested_action text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  team_record public.ladder_teams%rowtype;
  action_text text;
  action_time timestamp with time zone := now();
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  action_text := lower(trim(requested_action));

  if action_text not in ('reactivate', 'extend') then
    raise exception 'Action must be Reactivate or Extend.';
  end if;

  select *
  into team_record
  from public.ladder_teams
  where id = requested_team_id
  for update;

  if not found then
    raise exception 'Team not found.';
  end if;

  if team_record.club_id is null then
    raise exception 'This team is not assigned to a club.';
  end if;

  if not public.is_app_admin()
     or not exists(
       select 1
       from public.club_memberships cm
       where cm.club_id = team_record.club_id
         and cm.user_id = auth.uid()
         and lower(cm.status::text) = 'active'
         and lower(cm.role::text) = 'admin'
     ) then
    raise exception 'Only a club administrator can review Away teams.';
  end if;

  if not team_record.away then
    raise exception 'This team is not currently marked Away.';
  end if;

  if action_text = 'reactivate' then
    update public.ladder_teams
    set
      away = false,
      away_started_at = null,
      away_review_at = null,
      updated_at = action_time
    where id = requested_team_id
      and club_id = team_record.club_id;

    return 'Team reactivated.';
  end if;

  update public.ladder_teams
  set
    away = true,
    away_review_at = action_time + interval '30 days',
    updated_at = action_time
  where id = requested_team_id
    and club_id = team_record.club_id;

  return 'Away period extended for 30 days.';
end;
$function$;

-- public.review_decline_secure(requested_challenge_id uuid, requested_decision text)
CREATE OR REPLACE FUNCTION public.review_decline_secure(requested_challenge_id uuid, requested_decision text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  challenge_record public.challenges%rowtype;
  decision_text text;
  declining_team public.ladder_teams%rowtype;
  team_below public.ladder_teams%rowtype;
  review_time timestamp with time zone := now();
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  decision_text := lower(trim(requested_decision));

  if decision_text not in ('approve', 'reject') then
    raise exception 'Decision must be Approve or Reject.';
  end if;

  select *
  into challenge_record
  from public.challenges
  where id = requested_challenge_id
  for update;

  if not found then
    raise exception 'Challenge not found.';
  end if;

  if challenge_record.club_id is null then
    raise exception 'This challenge is not assigned to a club.';
  end if;

  if not public.is_app_admin()
     or not exists(
       select 1
       from public.club_memberships cm
       where cm.club_id = challenge_record.club_id
         and cm.user_id = auth.uid()
         and lower(cm.status::text) = 'active'
         and lower(cm.role::text) = 'admin'
     ) then
    raise exception 'Only a club administrator can review declined challenges.';
  end if;

  if challenge_record.status <>
     'Decline Pending Admin Review' then
    raise exception 'This challenge is not awaiting decline review.';
  end if;

  if decision_text = 'approve' then
    update public.challenges
    set
      status = 'Declined',
      decline_reviewed_at = review_time,
      updated_at = review_time
    where id = requested_challenge_id
      and club_id = challenge_record.club_id;

    return 'Decline approved — no ranking change.';
  end if;

  if challenge_record.challenged_team_id is null then
    raise exception 'The declining team could not be found.';
  end if;

  -- Lock this club's ladder before changing positions.
  perform id
  from public.ladder_teams
  where club_id = challenge_record.club_id
    and ladder = challenge_record.ladder
  order by rank_position
  for update;

  select *
  into declining_team
  from public.ladder_teams
  where id = challenge_record.challenged_team_id
    and club_id = challenge_record.club_id;

  if not found then
    raise exception 'The declining team is no longer on this club ladder.';
  end if;

  select *
  into team_below
  from public.ladder_teams
  where club_id = challenge_record.club_id
    and ladder = declining_team.ladder
    and rank_position > declining_team.rank_position
  order by rank_position
  limit 1;

  if found then
    insert into public.ladder_movements(
      club_id,
      team_id,
      team_name,
      ladder,
      from_rank,
      to_rank,
      reason,
      created_at
    )
    values
    (
      challenge_record.club_id,
      declining_team.id,
      declining_team.name,
      declining_team.ladder,
      declining_team.rank_position,
      team_below.rank_position,
      'Decline penalty',
      review_time
    ),
    (
      challenge_record.club_id,
      team_below.id,
      team_below.name,
      team_below.ladder,
      team_below.rank_position,
      declining_team.rank_position,
      'Moved up after decline penalty',
      review_time
    );

    update public.ladder_teams
    set
      rank_position = team_below.rank_position,
      updated_at = review_time
    where id = declining_team.id
      and club_id = challenge_record.club_id;

    update public.ladder_teams
    set
      rank_position = declining_team.rank_position,
      updated_at = review_time
    where id = team_below.id
      and club_id = challenge_record.club_id;
  end if;

  update public.challenges
  set
    status = 'Declined - Penalty Applied',
    decline_reviewed_at = review_time,
    updated_at = review_time
  where id = requested_challenge_id
    and club_id = challenge_record.club_id;

  perform private.cancel_invalid_pending_challenges(
    challenge_record.club_id,
    challenge_record.ladder
  );

  return 'Decline rejected — penalty applied.';
end;
$function$;

-- public.review_overdue_match_secure(requested_challenge_id uuid, requested_action text)
CREATE OR REPLACE FUNCTION public.review_overdue_match_secure(requested_challenge_id uuid, requested_action text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  challenge_record public.challenges%rowtype;
  action_text text;
  action_time timestamp with time zone := now();
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  action_text := lower(trim(requested_action));

  if action_text not in ('extend', 'cancel') then
    raise exception 'Action must be Extend or Cancel.';
  end if;

  select *
  into challenge_record
  from public.challenges
  where id = requested_challenge_id
  for update;

  if not found then
    raise exception 'Challenge not found.';
  end if;

  if challenge_record.club_id is null then
    raise exception 'This challenge is not assigned to a club.';
  end if;

  if not public.is_app_admin()
     or not exists(
       select 1
       from public.club_memberships cm
       where cm.club_id = challenge_record.club_id
         and cm.user_id = auth.uid()
         and lower(cm.status::text) = 'active'
         and lower(cm.role::text) = 'admin'
     ) then
    raise exception 'Only a club administrator can review overdue matches.';
  end if;

  if challenge_record.status <> 'Overdue' then
    raise exception 'This match is not currently overdue.';
  end if;

  if action_text = 'extend' then
    update public.challenges
    set
      status = 'Accepted',
      play_by = action_time + interval '7 days',
      overdue_at = null,
      updated_at = action_time
    where id = requested_challenge_id
      and club_id = challenge_record.club_id;

    return 'Match extended for 7 days.';
  end if;

  update public.challenges
  set
    status = 'Cancelled',
    cancel_reason = 'Overdue match cancelled by Admin.',
    cancelled_at = action_time,
    updated_at = action_time
  where id = requested_challenge_id
    and club_id = challenge_record.club_id;

  return 'Overdue match cancelled — no standings changed.';
end;
$function$;

-- public.send_partner_invite_secure(requested_listing_id uuid, requested_sender_name text, requested_sender_gender text, requested_sender_dupr text)
CREATE OR REPLACE FUNCTION public.send_partner_invite_secure(requested_listing_id uuid, requested_sender_name text, requested_sender_gender text, requested_sender_dupr text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  listing_record public.partner_listings%rowtype;
  normalized_name text;
  normalized_gender text;
  normalized_dupr text;
  sender_dupr_value numeric;
  sender_is_nr_value boolean := false;
  signed_in_email text;
  new_invite_id uuid;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select *
  into listing_record
  from public.partner_listings
  where id = requested_listing_id
  for update;

  if not found then
    raise exception 'Partner listing not found.';
  end if;

  if listing_record.club_id is null then
    raise exception 'This partner listing is not assigned to a club.';
  end if;

  if not exists(
    select 1
    from public.club_memberships cm
    where cm.club_id = listing_record.club_id
      and cm.user_id = auth.uid()
      and lower(cm.status::text) = 'active'
  ) then
    raise exception 'You are not an active member of this club.';
  end if;

  if listing_record.status <> 'Active' then
    raise exception 'This partner listing is no longer active.';
  end if;

  if listing_record.owner_user_id = auth.uid() then
    raise exception 'You cannot invite yourself.';
  end if;

  normalized_name := trim(requested_sender_name);
  normalized_gender := lower(trim(requested_sender_gender));
  normalized_dupr := upper(trim(requested_sender_dupr));
  signed_in_email := lower(auth.jwt() ->> 'email');

  if normalized_name = '' then
    raise exception 'Please enter your name.';
  end if;

  if normalized_gender not in ('male', 'female') then
    raise exception 'Gender must be Male or Female.';
  end if;

  if normalized_dupr = 'NR' then
    sender_is_nr_value := true;
    sender_dupr_value := null;
  else
    if normalized_dupr !~ '^[0-9]+([.][0-9]+)?$' then
      raise exception 'Please enter a valid DUPR or NR.';
    end if;

    sender_dupr_value := normalized_dupr::numeric;

    if sender_dupr_value <= 0
       or sender_dupr_value > 99.99 then
      raise exception 'Please enter a valid DUPR or NR.';
    end if;
  end if;

  if listing_record.ladder = 'mens'
     and (
       normalized_gender <> 'male'
       or lower(listing_record.gender) <> 'male'
     ) then
    raise exception
      'Men''s teams must contain two male players.';
  end if;

  if listing_record.ladder = 'womens'
     and (
       normalized_gender <> 'female'
       or lower(listing_record.gender) <> 'female'
     ) then
    raise exception
      'Women''s teams must contain two female players.';
  end if;

  if listing_record.ladder = 'mixed'
     and normalized_gender = lower(listing_record.gender) then
    raise exception
      'Mixed teams must contain one male and one female player.';
  end if;

  if exists(
    select 1
    from private.team_members tm
    where tm.club_id = listing_record.club_id
      and tm.ladder = listing_record.ladder
      and (
        tm.user_id = auth.uid()
        or (
          signed_in_email is not null
          and lower(tm.email) = signed_in_email
        )
      )
  ) then
    raise exception
      'You are already assigned to a team in this ladder.';
  end if;

  if exists(
    select 1
    from private.team_members tm
    where tm.club_id = listing_record.club_id
      and tm.ladder = listing_record.ladder
      and tm.user_id = listing_record.owner_user_id
  ) then
    raise exception
      'The listed player is already assigned to a team in this ladder.';
  end if;

  if exists(
    select 1
    from public.partner_invites pi
    where pi.club_id = listing_record.club_id
      and pi.listing_id = requested_listing_id
      and pi.sender_user_id = auth.uid()
      and pi.status = 'Pending'
  ) then
    raise exception
      'You already sent a pending invitation to this player.';
  end if;

  insert into public.partner_invites(
    club_id,
    listing_id,
    ladder,
    sender_user_id,
    recipient_user_id,
    sender_name,
    recipient_name,
    sender_gender,
    recipient_gender,
    sender_dupr,
    recipient_dupr,
    sender_is_nr,
    recipient_is_nr,
    status,
    created_at
  )
  values(
    listing_record.club_id,
    listing_record.id,
    listing_record.ladder,
    auth.uid(),
    listing_record.owner_user_id,
    normalized_name,
    listing_record.name,
    case
      when normalized_gender = 'male' then 'Male'
      else 'Female'
    end,
    listing_record.gender,
    sender_dupr_value,
    listing_record.dupr,
    sender_is_nr_value,
    listing_record.is_nr,
    'Pending',
    now()
  )
  returning id into new_invite_id;

  return new_invite_id;
end;
$function$;

-- public.set_challenge_deadline()
CREATE OR REPLACE FUNCTION public.set_challenge_deadline()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if new.status = 'accepted'
     and old.status is distinct from 'accepted'
  then
    new.accepted_at := coalesce(new.accepted_at, now());
    new.play_by := new.accepted_at + interval '7 days';
  end if;

  return new;
end;
$function$;

-- public.set_team_away_secure(requested_team_id uuid, requested_away boolean)
CREATE OR REPLACE FUNCTION public.set_team_away_secure(requested_team_id uuid, requested_away boolean)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  selected_team public.ladder_teams%rowtype;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select *
  into selected_team
  from public.ladder_teams
  where id = requested_team_id
  for update;

  if selected_team.id is null then
    raise exception 'This team could not be found.';
  end if;

  if selected_team.club_id is null then
    raise exception 'This team is not assigned to a club.';
  end if;

  if public.user_belongs_to_team(selected_team.id) then
    if not exists(
      select 1
      from public.club_memberships cm
      where cm.club_id = selected_team.club_id
        and cm.user_id = auth.uid()
        and lower(cm.status::text) = 'active'
    ) then
      raise exception 'You are not an active member of this club.';
    end if;
  else
    if not public.is_app_admin()
       or not exists(
         select 1
         from public.club_memberships cm
         where cm.club_id = selected_team.club_id
           and cm.user_id = auth.uid()
           and lower(cm.status::text) = 'active'
           and lower(cm.role::text) = 'admin'
       ) then
      raise exception
        'Only a team member or club administrator can change Away status.';
    end if;
  end if;

  if requested_away then
    if selected_team.rank_position <= 10 then
      raise exception 'Teams in the Top 10 cannot mark themselves Away.';
    end if;

    if exists (
      select 1
      from public.challenges c
      where c.club_id = selected_team.club_id
        and c.status in (
          'Pending',
          'Accepted',
          'Awaiting Confirmation',
          'Decline Pending Admin Review',
          'Overdue',
          'Disputed'
        )
        and (
          c.challenger_team_id = selected_team.id
          or c.challenged_team_id = selected_team.id
        )
    ) then
      raise exception 'The team must close its current challenge before going Away.';
    end if;

    update public.ladder_teams
    set
      away = true,
      away_started_at = now(),
      away_review_at = now() + interval '30 days',
      updated_at = now()
    where id = selected_team.id
      and club_id = selected_team.club_id;

    return 'Away';
  end if;

  update public.ladder_teams
  set
    away = false,
    away_started_at = null,
    away_review_at = null,
    updated_at = now()
  where id = selected_team.id
    and club_id = selected_team.club_id;

  return 'Active';
end;
$function$;

-- public.submit_result_secure(requested_challenge_id uuid, submitting_team_id uuid, submitted_scores jsonb)
CREATE OR REPLACE FUNCTION public.submit_result_secure(requested_challenge_id uuid, submitting_team_id uuid, submitted_scores jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  selected_challenge public.challenges%rowtype;
  game jsonb;
  game_number integer;
  game_count integer;
  challenger_score integer;
  challenged_score integer;
  challenger_games integer := 0;
  challenged_games integer := 0;
  winning_team_id uuid;
  winning_team_name text;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select *
  into selected_challenge
  from public.challenges
  where id = requested_challenge_id
  for update;

  if selected_challenge.id is null then
    raise exception 'This challenge could not be found.';
  end if;

  if selected_challenge.club_id is null then
    raise exception 'This challenge is not assigned to a club.';
  end if;

  if selected_challenge.status <> 'Accepted' then
    raise exception 'Results can only be submitted for an accepted match.';
  end if;

  if submitting_team_id not in (
    selected_challenge.challenger_team_id,
    selected_challenge.challenged_team_id
  ) then
    raise exception 'The submitting team is not part of this match.';
  end if;

  if not exists(
    select 1
    from public.ladder_teams lt
    where lt.id = submitting_team_id
      and lt.club_id = selected_challenge.club_id
  ) then
    raise exception 'The submitting team does not belong to this club.';
  end if;

  if public.user_belongs_to_team(submitting_team_id) then
    if not exists(
      select 1
      from public.club_memberships cm
      where cm.club_id = selected_challenge.club_id
        and cm.user_id = auth.uid()
        and lower(cm.status::text) = 'active'
    ) then
      raise exception 'You are not an active member of this club.';
    end if;
  else
    if not public.is_app_admin()
       or not exists(
         select 1
         from public.club_memberships cm
         where cm.club_id = selected_challenge.club_id
           and cm.user_id = auth.uid()
           and lower(cm.status::text) = 'active'
           and lower(cm.role::text) = 'admin'
       ) then
      raise exception 'Your account is not assigned to the submitting team.';
    end if;
  end if;

  if jsonb_typeof(submitted_scores) <> 'array' then
    raise exception 'Scores must be submitted as a game list.';
  end if;

  game_count := jsonb_array_length(submitted_scores);

  if game_count < 3 or game_count > 5 then
    raise exception 'A match must contain between three and five games.';
  end if;

  for game_number in 0..game_count - 1 loop
    game := submitted_scores->game_number;

    if jsonb_typeof(game) <> 'array'
       or jsonb_array_length(game) <> 2 then
      raise exception 'Each game must contain exactly two scores.';
    end if;

    if jsonb_typeof(game->0) <> 'number'
       or jsonb_typeof(game->1) <> 'number' then
      raise exception 'Every game score must be a number.';
    end if;

    challenger_score := (game->>0)::integer;
    challenged_score := (game->>1)::integer;

    if challenger_score < 0 or challenged_score < 0 then
      raise exception 'Game scores cannot be negative.';
    end if;

    if challenger_score = challenged_score then
      raise exception 'A game cannot end in a tie.';
    end if;

    if greatest(challenger_score, challenged_score) < 11 then
      raise exception 'A game must be played to at least 11 points.';
    end if;

    if abs(challenger_score - challenged_score) < 2 then
      raise exception 'A game must be won by at least two points.';
    end if;

    if challenger_games = 3 or challenged_games = 3 then
      raise exception 'Extra games cannot be entered after the match is won.';
    end if;

    if challenger_score > challenged_score then
      challenger_games := challenger_games + 1;
    else
      challenged_games := challenged_games + 1;
    end if;
  end loop;

  if challenger_games <> 3 and challenged_games <> 3 then
    raise exception 'One team must win exactly three games.';
  end if;

  if challenger_games = 3 then
    winning_team_id :=
      selected_challenge.challenger_team_id;
    winning_team_name :=
      selected_challenge.challenger_name;
  else
    winning_team_id :=
      selected_challenge.challenged_team_id;
    winning_team_name :=
      selected_challenge.challenged_name;
  end if;

  update public.challenges
  set
    scores = submitted_scores,
    submitted_by_team_id = submitting_team_id,
    winner_team_id = winning_team_id,
    winner_name = winning_team_name,
    status = 'Awaiting Confirmation',
    updated_at = now()
  where id = selected_challenge.id
    and club_id = selected_challenge.club_id;

  return 'Awaiting Confirmation';
end;
$function$;

-- public.validate_new_challenge()
CREATE OR REPLACE FUNCTION public.validate_new_challenge()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  challenger_ladder uuid;
  opponent_ladder uuid;
  challenger_rank integer;
  opponent_rank integer;
begin
  select ladder_id, rank
  into challenger_ladder, challenger_rank
  from public.teams
  where id = new.challenger_team_id;

  select ladder_id, rank
  into opponent_ladder, opponent_rank
  from public.teams
  where id = new.challenged_team_id;

  if challenger_ladder is null or opponent_ladder is null then
    raise exception 'One or both teams do not exist';
  end if;

  if challenger_ladder <> opponent_ladder then
    raise exception 'Teams must be in the same ladder';
  end if;

  if opponent_rank >= challenger_rank then
    raise exception 'You may only challenge a team ranked above you';
  end if;

  if challenger_rank - opponent_rank > 3 then
    raise exception 'A team may challenge no more than 3 positions above';
  end if;

  new.ladder_id := challenger_ladder;
  new.challenger_rank_at_issue := challenger_rank;
  new.challenged_rank_at_issue := opponent_rank;

  return new;
end;
$function$;

-- The source inventory covered public/private tables, not triggers attached to auth.users.
-- Recreate the profile-on-signup behavior for this isolated test project.
create trigger pilot_profile_on_signup after insert on auth.users
for each row execute function public.handle_new_user();

CREATE TRIGGER check_pending_challenges_after_completion AFTER UPDATE OF status ON challenges FOR EACH ROW EXECUTE FUNCTION private.check_pending_challenges_after_completion();
CREATE TRIGGER prevent_late_challenge_acceptance BEFORE UPDATE OF status ON challenges FOR EACH ROW EXECUTE FUNCTION private.prevent_late_challenge_acceptance();
CREATE TRIGGER set_challenge_play_deadline BEFORE INSERT OR UPDATE OF status ON challenges FOR EACH ROW EXECUTE FUNCTION private.set_challenge_play_deadline();
CREATE TRIGGER track_challenge_acceptance_period AFTER INSERT OR UPDATE OF status ON challenges FOR EACH ROW EXECUTE FUNCTION private.track_challenge_acceptance_period();
CREATE TRIGGER set_challenge_deadline_trigger BEFORE UPDATE ON legacy_challenges FOR EACH ROW EXECUTE FUNCTION set_challenge_deadline();
CREATE TRIGGER validate_new_challenge_trigger BEFORE INSERT ON legacy_challenges FOR EACH ROW EXECUTE FUNCTION validate_new_challenge();
CREATE TRIGGER enforce_one_team_per_ladder_trigger BEFORE INSERT OR UPDATE ON team_members FOR EACH ROW EXECUTE FUNCTION enforce_one_team_per_ladder();

-- Use public read permissions with the original row-level read policies.
-- Do not grant INSERT, UPDATE or DELETE directly to browser roles.
grant select on all tables in schema public to anon, authenticated;

create policy "audit_admin_read" on public.audit_log as permissive for select to authenticated using (((club_id IS NOT NULL) AND is_club_admin(club_id)));
create policy "Anyone can view challenge history" on public.challenges as permissive for select to anon, authenticated using (true);
create policy "memberships_read" on public.club_memberships as permissive for select to authenticated using (((user_id = auth.uid()) OR is_club_admin(club_id)));
create policy "clubs_public_read" on public.clubs as permissive for select to public using ((active = true));
create policy "Anyone can view ladder movements" on public.ladder_movements as permissive for select to anon, authenticated using (true);
create policy "Anyone can view ladder state" on public.ladder_state as permissive for select to anon, authenticated using (true);
create policy "Anyone can view ladder teams" on public.ladder_teams as permissive for select to anon, authenticated using (true);
create policy "ladders_public_read" on public.ladders as permissive for select to public using ((active = true));
create policy "challenges_create" on public.legacy_challenges as permissive for insert to authenticated with check (is_team_member(challenger_team_id));
create policy "challenges_read" on public.legacy_challenges as permissive for select to authenticated using ((is_team_member(challenger_team_id) OR is_team_member(challenged_team_id) OR is_club_admin(team_club_id(challenger_team_id))));
create policy "challenges_update" on public.legacy_challenges as permissive for update to authenticated using ((is_team_member(challenger_team_id) OR is_team_member(challenged_team_id) OR is_club_admin(team_club_id(challenger_team_id))));
create policy "match_games_read" on public.match_games as permissive for select to authenticated using (true);
create policy "matches_read" on public.matches as permissive for select to authenticated using ((EXISTS ( SELECT 1
   FROM legacy_challenges c
  WHERE ((c.id = matches.challenge_id) AND (is_team_member(c.challenger_team_id) OR is_team_member(c.challenged_team_id) OR is_club_admin(team_club_id(c.challenger_team_id)))))));
create policy "Players can view their partner invitations" on public.partner_invites as permissive for select to authenticated using (((sender_user_id = auth.uid()) OR (recipient_user_id = auth.uid()) OR is_app_admin()));
create policy "Anyone can view active partner listings" on public.partner_listings as permissive for select to anon, authenticated using ((status = 'Active'::text));
create policy "Owners and Admin can view their removed listings" on public.partner_listings as permissive for select to authenticated using (((owner_user_id = auth.uid()) OR is_app_admin()));
create policy "profiles_public_read" on public.profiles as permissive for select to public using (true);
create policy "profiles_update_self" on public.profiles as permissive for update to authenticated using ((id = auth.uid())) with check ((id = auth.uid()));
create policy "ranking_history_public_read" on public.ranking_history as permissive for select to public using (true);
create policy "team_members_public_read" on public.team_members as permissive for select to public using ((active = true));
create policy "teams_public_read" on public.teams as permissive for select to public using ((status <> 'removed'::text));

-- All app-owned public RPCs are callable only by authenticated users.
-- Trigger functions are invoked by their triggers; private functions remain inaccessible.
revoke all on FUNCTION public.is_app_admin() from public, anon, authenticated;
grant execute on FUNCTION public.is_app_admin() to authenticated;
revoke all on FUNCTION public.is_club_admin(p_club_id uuid) from public, anon, authenticated;
grant execute on FUNCTION public.is_club_admin(p_club_id uuid) to authenticated;
revoke all on FUNCTION public.is_team_member(p_team_id uuid) from public, anon, authenticated;
grant execute on FUNCTION public.is_team_member(p_team_id uuid) to authenticated;
revoke all on FUNCTION public.team_club_id(p_team_id uuid) from public, anon, authenticated;
grant execute on FUNCTION public.team_club_id(p_team_id uuid) to authenticated;
revoke all on FUNCTION public.user_belongs_to_team(requested_team_id uuid) from public, anon, authenticated;
grant execute on FUNCTION public.user_belongs_to_team(requested_team_id uuid) to authenticated;
revoke all on FUNCTION private.cancel_invalid_pending_challenges(requested_club_id uuid, requested_ladder text) from public, anon, authenticated;
revoke all on FUNCTION private.check_pending_challenges_after_completion() from public, anon, authenticated;
revoke all on FUNCTION private.prevent_late_challenge_acceptance() from public, anon, authenticated;
revoke all on FUNCTION private.set_challenge_play_deadline() from public, anon, authenticated;
revoke all on FUNCTION private.track_challenge_acceptance_period() from public, anon, authenticated;
revoke all on FUNCTION public.accept_partner_invite_secure(requested_invite_id uuid, requested_team_name text) from public, anon, authenticated;
grant execute on FUNCTION public.accept_partner_invite_secure(requested_invite_id uuid, requested_team_name text) to authenticated;
revoke all on FUNCTION public.admin_add_team_secure(requested_ladder text, requested_team_name text, requested_players text, requested_dupr numeric, requested_is_nr boolean) from public, anon, authenticated;
grant execute on FUNCTION public.admin_add_team_secure(requested_ladder text, requested_team_name text, requested_players text, requested_dupr numeric, requested_is_nr boolean) to authenticated;
revoke all on FUNCTION public.admin_assign_team_members_secure(requested_team_id uuid, requested_email_one text, requested_email_two text) from public, anon, authenticated;
grant execute on FUNCTION public.admin_assign_team_members_secure(requested_team_id uuid, requested_email_one text, requested_email_two text) to authenticated;
revoke all on FUNCTION public.admin_get_team_members_secure() from public, anon, authenticated;
grant execute on FUNCTION public.admin_get_team_members_secure() to authenticated;
revoke all on FUNCTION public.admin_remove_team_secure(requested_team_id uuid) from public, anon, authenticated;
grant execute on FUNCTION public.admin_remove_team_secure(requested_team_id uuid) to authenticated;
revoke all on FUNCTION public.admin_reset_disputed_result_secure(requested_challenge_id uuid) from public, anon, authenticated;
grant execute on FUNCTION public.admin_reset_disputed_result_secure(requested_challenge_id uuid) to authenticated;
revoke all on FUNCTION public.cancel_challenge_secure(requested_challenge_id uuid) from public, anon, authenticated;
grant execute on FUNCTION public.cancel_challenge_secure(requested_challenge_id uuid) to authenticated;
revoke all on FUNCTION public.cancel_partner_invite_secure(requested_invite_id uuid) from public, anon, authenticated;
grant execute on FUNCTION public.cancel_partner_invite_secure(requested_invite_id uuid) to authenticated;
revoke all on FUNCTION public.confirm_result_secure(requested_challenge_id uuid, requested_action text) from public, anon, authenticated;
grant execute on FUNCTION public.confirm_result_secure(requested_challenge_id uuid, requested_action text) to authenticated;
revoke all on FUNCTION public.create_partner_listing_secure(requested_name text, requested_gender text, requested_dupr text, requested_ladder text) from public, anon, authenticated;
grant execute on FUNCTION public.create_partner_listing_secure(requested_name text, requested_gender text, requested_dupr text, requested_ladder text) to authenticated;
revoke all on FUNCTION public.decline_partner_invite_secure(requested_invite_id uuid) from public, anon, authenticated;
grant execute on FUNCTION public.decline_partner_invite_secure(requested_invite_id uuid) to authenticated;
revoke all on FUNCTION public.enforce_one_team_per_ladder() from public, anon, authenticated;
grant execute on FUNCTION public.enforce_one_team_per_ladder() to authenticated;
revoke all on FUNCTION public.get_my_active_clubs_secure() from public, anon, authenticated;
grant execute on FUNCTION public.get_my_active_clubs_secure() to authenticated;
revoke all on FUNCTION public.handle_new_user() from public, anon, authenticated;
grant execute on FUNCTION public.handle_new_user() to authenticated;
revoke all on FUNCTION public.issue_challenge_secure(challenger_id uuid, challenged_id uuid) from public, anon, authenticated;
grant execute on FUNCTION public.issue_challenge_secure(challenger_id uuid, challenged_id uuid) to authenticated;
revoke all on FUNCTION public.record_forfeit_secure(requested_challenge_id uuid, forfeiting_team_id uuid) from public, anon, authenticated;
grant execute on FUNCTION public.record_forfeit_secure(requested_challenge_id uuid, forfeiting_team_id uuid) to authenticated;
revoke all on FUNCTION public.refresh_acceptance_enforcement_secure() from public, anon, authenticated;
grant execute on FUNCTION public.refresh_acceptance_enforcement_secure() to authenticated;
revoke all on FUNCTION public.refresh_challenge_deadlines_secure() from public, anon, authenticated;
grant execute on FUNCTION public.refresh_challenge_deadlines_secure() to authenticated;
revoke all on FUNCTION public.remove_partner_listing_secure(requested_listing_id uuid) from public, anon, authenticated;
grant execute on FUNCTION public.remove_partner_listing_secure(requested_listing_id uuid) to authenticated;
revoke all on FUNCTION public.respond_to_challenge_secure(challenge_id uuid, response text, decline_reason text) from public, anon, authenticated;
grant execute on FUNCTION public.respond_to_challenge_secure(challenge_id uuid, response text, decline_reason text) to authenticated;
revoke all on FUNCTION public.review_away_team_secure(requested_team_id uuid, requested_action text) from public, anon, authenticated;
grant execute on FUNCTION public.review_away_team_secure(requested_team_id uuid, requested_action text) to authenticated;
revoke all on FUNCTION public.review_decline_secure(requested_challenge_id uuid, requested_decision text) from public, anon, authenticated;
grant execute on FUNCTION public.review_decline_secure(requested_challenge_id uuid, requested_decision text) to authenticated;
revoke all on FUNCTION public.review_overdue_match_secure(requested_challenge_id uuid, requested_action text) from public, anon, authenticated;
grant execute on FUNCTION public.review_overdue_match_secure(requested_challenge_id uuid, requested_action text) to authenticated;
revoke all on FUNCTION public.send_partner_invite_secure(requested_listing_id uuid, requested_sender_name text, requested_sender_gender text, requested_sender_dupr text) from public, anon, authenticated;
grant execute on FUNCTION public.send_partner_invite_secure(requested_listing_id uuid, requested_sender_name text, requested_sender_gender text, requested_sender_dupr text) to authenticated;
revoke all on FUNCTION public.set_challenge_deadline() from public, anon, authenticated;
grant execute on FUNCTION public.set_challenge_deadline() to authenticated;
revoke all on FUNCTION public.set_team_away_secure(requested_team_id uuid, requested_away boolean) from public, anon, authenticated;
grant execute on FUNCTION public.set_team_away_secure(requested_team_id uuid, requested_away boolean) to authenticated;
revoke all on FUNCTION public.submit_result_secure(requested_challenge_id uuid, submitting_team_id uuid, submitted_scores jsonb) from public, anon, authenticated;
grant execute on FUNCTION public.submit_result_secure(requested_challenge_id uuid, submitting_team_id uuid, submitted_scores jsonb) to authenticated;
revoke all on FUNCTION public.validate_new_challenge() from public, anon, authenticated;
grant execute on FUNCTION public.validate_new_challenge() to authenticated;

commit;
