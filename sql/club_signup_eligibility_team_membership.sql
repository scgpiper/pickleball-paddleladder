-- Pilot first. Requires club_signup_eligibility_setup.sql.
-- This is the pilot's current user_belongs_to_team definition with a current,
-- confirmed-email approval check. Removing an email from the private list
-- immediately makes this helper return false, even for an existing roster row
-- and an active club membership. It is used by challenges and private reads.
begin;

do $preflight$
begin
  if to_regclass('private.club_signup_eligibility') is null then
    raise exception 'Install the private club eligibility list first';
  end if;
end;
$preflight$;

create or replace function public.user_belongs_to_team(requested_team_id uuid)
returns boolean language sql stable security definer set search_path to ''
as $function$
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
    join auth.users u
      on u.id = auth.uid()
     and u.email_confirmed_at is not null
    join private.club_signup_eligibility e
      on e.club_id = lt.club_id
     and e.email = pg_catalog.lower(pg_catalog.btrim(u.email))
    where tm.team_id = requested_team_id
      and tm.club_id is not null
      and (
        tm.user_id = auth.uid()
        or pg_catalog.lower(pg_catalog.btrim(tm.email)) = e.email
      )
  );
$function$;

revoke all on function public.user_belongs_to_team(uuid) from public, anon;
grant execute on function public.user_belongs_to_team(uuid) to authenticated;

commit;
