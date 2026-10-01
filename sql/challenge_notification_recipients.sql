-- Run in the main Supabase project before deploying the email handler.
-- Only the server's service_role key may call this function. Player email
-- addresses remain in the private schema and are never exposed to the browser.
create or replace function public.challenge_notification_recipients_secure(
  requested_challenge_id uuid
)
returns table(email text)
language sql
security definer
set search_path to ''
as $function$
  select distinct pg_catalog.lower(pg_catalog.btrim(member.email)) as email
  from public.challenges as challenge
  join public.ladder_teams as team
    on team.id = challenge.challenged_team_id
   and team.club_id = challenge.club_id
  join private.team_members as member
    on member.team_id = team.id
   and member.club_id = team.club_id
   and member.ladder = team.ladder
  where challenge.id = requested_challenge_id
    and challenge.status = 'Pending'
    and member.email is not null
    and pg_catalog.btrim(member.email) <> ''
  order by email
  limit 2;
$function$;

revoke all on function public.challenge_notification_recipients_secure(uuid)
  from public, anon, authenticated;
grant execute on function public.challenge_notification_recipients_secure(uuid)
  to service_role;
