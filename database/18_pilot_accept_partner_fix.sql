-- Apply only in PaddleLadder Pilot Test, after the original registration setup.
-- Replaces the acceptance routine; the pending invitation stays intact.

create or replace function public.respond_pilot_team_request_secure(
  requested_request_id uuid, requested_accept boolean
) returns uuid
language plpgsql security definer set search_path to ''
as $function$
declare
  r private.team_registration_requests%rowtype;
  partner_email text;
  active_club_ids uuid[];
  new_team_id uuid;
  target_rank integer;
  combined_dupr numeric;
  team_is_nr boolean;
begin
  if auth.uid() is null then
    raise exception 'Sign in before responding';
  end if;

  select lower(email) into partner_email from auth.users
  where id = auth.uid() and email_confirmed_at is not null;
  select * into r from private.team_registration_requests
  where id = requested_request_id for update;

  if not found or partner_email is null
     or r.partner_email <> partner_email
     or r.captain_id = auth.uid() then
    raise exception 'Team request not found';
  end if;

  if r.status <> 'pending' then
    raise exception 'This team request is already closed';
  end if;

  if not coalesce(requested_accept, false) then
    update private.team_registration_requests
    set status = 'declined', decided_at = now()
    where id = r.id;
    return null;
  end if;

  select pg_catalog.array_agg(id) into active_club_ids
  from public.clubs where active = true;
  if pg_catalog.cardinality(active_club_ids) is distinct from 1
     or active_club_ids[1] is distinct from r.club_id then
    raise exception 'Pilot team registration requires the one active club';
  end if;
  perform public.join_pilot_club_secure();

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('pilot-roster:' || r.club_id || ':' || r.ladder));

  if exists (
    select 1 from private.team_members m
    where m.club_id = r.club_id and m.ladder = r.ladder
      and (m.user_id in (r.captain_id, auth.uid())
           or lower(m.email) in (r.captain_email, r.partner_email))
  ) then
    raise exception 'One of these players is already on a team in this ladder';
  end if;

  if exists (
    select 1 from public.ladder_teams t
    where t.club_id = r.club_id and t.ladder = r.ladder
      and lower(t.name) = lower(r.team_name)
  ) then
    raise exception 'That team name is already used in this ladder';
  end if;

  team_is_nr := r.captain_is_nr or r.partner_is_nr;
  combined_dupr := case when team_is_nr then null
    else pg_catalog.round(r.captain_dupr + r.partner_dupr, 2) end;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('ladder:pilot:' || r.club_id || ':' || r.ladder));

  if not team_is_nr then
    select t.rank_position into target_rank
    from public.ladder_teams t
    where t.club_id = r.club_id and t.ladder = r.ladder and t.rank_position >= 11
      and (t.is_nr = true or t.dupr is null or t.dupr < combined_dupr)
    order by t.rank_position limit 1;
  end if;

  if target_rank is null then
    select coalesce(max(t.rank_position), 0) + 1 into target_rank
    from public.ladder_teams t where t.club_id = r.club_id and t.ladder = r.ladder;
  end if;

  update public.ladder_teams
  set rank_position = rank_position + 1, updated_at = now()
  where club_id = r.club_id and ladder = r.ladder and rank_position >= target_rank;

  insert into public.ladder_teams (club_id, ladder, rank_position, name, players, dupr, is_nr)
  values (r.club_id, r.ladder, target_rank, r.team_name,
          r.captain_name || ' / ' || r.partner_name, combined_dupr, team_is_nr)
  returning id into new_team_id;

  insert into private.team_members (club_id, team_id, ladder, user_id, email)
  values (r.club_id, new_team_id, r.ladder, r.captain_id, r.captain_email),
         (r.club_id, new_team_id, r.ladder, auth.uid(), r.partner_email);

  update private.team_registration_requests
  set status = 'accepted', decided_at = now(), created_team_id = new_team_id
  where id = r.id;

  -- Other outstanding invitations involving either player can no longer be accepted.
  update private.team_registration_requests as pending
  set status = 'declined', decided_at = now()
  where pending.id <> r.id and pending.club_id = r.club_id
    and pending.ladder = r.ladder and pending.status = 'pending'
    and (pending.captain_id in (r.captain_id, auth.uid())
         or pending.partner_email in (r.captain_email, r.partner_email));

  return new_team_id;
end;
$function$;
