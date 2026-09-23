-- STAGE 2 DRAFT: Run only after stage 1 and after ALL live RPCs and
-- security policies have been made club-aware and verified in staging.
-- This replaces global per-ladder uniqueness with per-club uniqueness.
begin;

-- Add replacement indexes before dropping existing unique indexes so
-- an unexpected duplicate aborts without leaving constraints weakened.
create unique index if not exists ladder_teams_club_name_unique
  on public.ladder_teams (club_id, ladder, lower(name));
create unique index if not exists private_team_members_club_email_ladder_unique
  on private.team_members (club_id, ladder, lower(email));
create unique index if not exists private_team_members_club_user_ladder_unique
  on private.team_members (club_id, ladder, user_id)
  where user_id is not null;
create unique index if not exists partner_listings_club_one_active_per_user_ladder
  on public.partner_listings (club_id, owner_user_id, ladder)
  where status = 'Active';

drop index if exists public.ladder_teams_name_unique;
drop index if exists private.team_members_email_ladder_unique;
drop index if exists private.team_members_user_ladder_unique;
drop index if exists public.partner_listings_one_active_per_user_ladder;

commit;
