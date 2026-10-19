-- Phase 2: run ONLY after the updated client uses challenge_public_feed.
-- First validate on the PILOT database with participant, unrelated member,
-- signed-out, and admin sessions. Then repeat for production.
begin;

alter policy "Anyone can view challenge history"
on public.challenges
to authenticated
using (
  public.is_app_admin()
  or public.is_club_admin(club_id)
  or public.user_belongs_to_team(challenger_team_id)
  or public.user_belongs_to_team(challenged_team_id)
);

drop policy if exists challenges_anon_without_private_reasons
on public.challenges;

commit;

select policyname, roles, qual
from pg_policies
where schemaname = 'public' and tablename = 'challenges'
order by policyname;
