-- Run in the LIVE Supabase SQL editor before the production signup migration.
-- Read-only. This returns counts and configuration flags, not player data.
select
  (select count(*) from public.clubs where active = true) as active_clubs,
  (select count(*) from public.ladder_teams) as ladder_teams,
  (select count(*) from public.ladder_teams where club_id is null) as teams_without_club,
  (select count(*) from private.team_members where club_id is null) as members_without_club,
  (select count(*) from private.team_members m
   join public.ladder_teams t on t.id = m.team_id
   where m.club_id is distinct from t.club_id) as member_team_club_mismatches,
  (select count(*) from public.challenges) as challenge_rows,
  (select count(*) from public.challenge_public_feed) as public_feed_rows,
  (select count(*) from pg_indexes
   where schemaname = 'private' and tablename = 'team_members'
     and indexname in ('team_members_email_ladder_unique',
                       'team_members_user_ladder_unique')) as roster_unique_indexes,
  to_regclass('private.team_registration_requests') is not null as registration_table_exists,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('join_pilot_club_secure',
                       'request_pilot_team_secure',
                       'my_pilot_team_requests_secure',
                       'respond_pilot_team_request_secure',
                       'cancel_pilot_team_request_secure')) as registration_function_count;

-- Expected before applying: active_clubs=1, no null/mismatched club IDs,
-- challenge_rows=public_feed_rows, roster_unique_indexes=2,
-- registration_table_exists=false, registration_function_count=0.
