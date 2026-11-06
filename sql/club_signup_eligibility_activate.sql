-- Stage 2: activate after choosing the club's manual approval process.
-- Run in the pilot database first. Run in production with the club's approval.
-- The app calls this function on load for non-admins, and new team requests
-- and partner acceptance call it too. Existing active memberships and other
-- database functions are separate access paths; audit them before rollout.
-- Also apply club_signup_eligibility_team_acceptance.sql to recheck the
-- captain when a pending invitation is accepted.
-- Apply club_signup_eligibility_team_membership.sql to gate actions that
-- use user_belongs_to_team for existing roster members.
-- Initially an empty eligibility table blocks all non-admin enrollment until
-- the club manually approves each email; populate existing approved users
-- before activation if they should continue using the ladder immediately.
begin;

do $preflight$
begin
  if to_regclass('private.club_signup_eligibility') is null then
    raise exception 'Create the private eligibility table first';
  end if;
  if (select count(*) from public.clubs where active = true) <> 1 then
    raise exception 'Expected exactly one active club';
  end if;
end;
$preflight$;

create or replace function public.join_pilot_club_secure()
returns uuid language plpgsql security definer set search_path to ''
as $function$
declare
  active_club_ids uuid[];
  pilot_club_id uuid;
  caller_email text;
begin
  select pg_catalog.lower(pg_catalog.btrim(email)) into caller_email
  from auth.users where id = auth.uid() and email_confirmed_at is not null;
  if caller_email is null then
    raise exception 'Confirm your email address before joining the club';
  end if;

  select pg_catalog.array_agg(id) into active_club_ids
  from public.clubs where active = true;
  if pg_catalog.cardinality(active_club_ids) is distinct from 1 then
    raise exception 'Pilot registration requires exactly one active club';
  end if;
  pilot_club_id := active_club_ids[1];

  if not exists (
    select 1 from private.club_signup_eligibility
    where club_id = pilot_club_id and email = caller_email
  ) then
    raise exception 'Your email has not yet been approved by the club. Contact the club about registration.';
  end if;

  insert into public.club_memberships (club_id, user_id, role, status)
  values (pilot_club_id, auth.uid(), 'member', 'active')
  on conflict (club_id, user_id) do nothing;

  if not exists (
    select 1 from public.club_memberships
    where club_id = pilot_club_id and user_id = auth.uid()
      and status = 'active'
  ) then
    raise exception 'This club membership is inactive';
  end if;

  return pilot_club_id;
end;
$function$;

revoke all on function public.join_pilot_club_secure() from public, anon;
grant execute on function public.join_pilot_club_secure() to authenticated;

commit;
