-- Apply after club_signup_eligibility_setup.sql and
-- single_club_team_registration.sql. Pilot first; review before production.
-- A captain can lose club approval after requesting a team. Recheck both
-- players when the invitation is accepted, in the same transaction that
-- creates their team. Raising an error rolls back the team and roster inserts.
begin;

do $preflight$
begin
  if to_regclass('private.club_signup_eligibility') is null
     or to_regclass('private.team_registration_requests') is null then
    raise exception 'Install the eligibility list and team registration first';
  end if;
end;
$preflight$;

create or replace function private.enforce_pilot_team_approval()
returns trigger language plpgsql security definer set search_path to ''
as $function$
begin
  if new.status = 'accepted' and old.status is distinct from 'accepted' then
    if not exists (
      select 1
      from auth.users u
      join private.club_signup_eligibility e
        on e.club_id = new.club_id
       and e.email = pg_catalog.lower(pg_catalog.btrim(u.email))
      where u.id = new.captain_id
        and u.email_confirmed_at is not null
        and pg_catalog.lower(pg_catalog.btrim(new.captain_email)) = e.email
    ) then
      raise exception 'The captain''s email is not currently approved by the club';
    end if;

    if not exists (
      select 1
      from auth.users u
      join private.club_signup_eligibility e
        on e.club_id = new.club_id
       and e.email = pg_catalog.lower(pg_catalog.btrim(u.email))
      where u.id = auth.uid()
        and u.email_confirmed_at is not null
        and pg_catalog.lower(pg_catalog.btrim(new.partner_email)) = e.email
    ) then
      raise exception 'The partner''s email is not currently approved by the club';
    end if;
  end if;
  return new;
end;
$function$;

revoke all on function private.enforce_pilot_team_approval()
  from public, anon, authenticated;

drop trigger if exists enforce_pilot_team_approval
  on private.team_registration_requests;
create trigger enforce_pilot_team_approval
before update of status on private.team_registration_requests
for each row execute function private.enforce_pilot_team_approval();

commit;
