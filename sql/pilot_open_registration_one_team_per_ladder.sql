-- Pilot-only change: self-service registration after verified email.
-- Apply ONLY in PaddleLadder Pilot Test after reviewing the read-only preflight.
-- Does not modify team, rank, match, or notification data.
-- Keep the existing one-team-per-club-and-ladder unique indexes.
BEGIN;

DO $check$
DECLARE
  active_club_count integer;
  unique_index_count integer;
  bad_roster_count integer;
BEGIN
  SELECT count(*) INTO active_club_count FROM public.clubs WHERE active = true;
  IF active_club_count <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one active pilot club, found %', active_club_count;
  END IF;

  SELECT count(*) INTO unique_index_count
  FROM pg_indexes
  WHERE schemaname = 'private'
    AND tablename = 'team_members'
    AND indexname IN ('team_members_email_ladder_unique',
                      'team_members_user_ladder_unique');
  IF unique_index_count <> 2 THEN
    RAISE EXCEPTION 'One-team-per-ladder indexes missing; expected 2, found %', unique_index_count;
  END IF;

  SELECT count(*) INTO bad_roster_count
  FROM private.team_members tm
  LEFT JOIN public.ladder_teams t ON t.id = tm.team_id
  WHERE tm.club_id IS NULL
     OR t.id IS NULL
     OR tm.club_id IS DISTINCT FROM t.club_id
     OR tm.ladder IS DISTINCT FROM t.ladder;
  IF bad_roster_count > 0 THEN
    RAISE EXCEPTION 'Existing roster inconsistencies found: %', bad_roster_count;
  END IF;
END
$check$;

-- Confirmed email is sufficient for a NEW membership.
-- Existing inactive memberships remain inactive (do not self-reactivate).
CREATE OR REPLACE FUNCTION public.join_pilot_club_secure()
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  active_club_ids uuid[];
  pilot_club_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM auth.users
    WHERE id = auth.uid() AND email_confirmed_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Confirm your email address before joining the club';
  END IF;

  SELECT pg_catalog.array_agg(id) INTO active_club_ids
  FROM public.clubs WHERE active = true;
  IF pg_catalog.cardinality(active_club_ids) IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Pilot registration requires exactly one active club';
  END IF;
  pilot_club_id := active_club_ids[1];

  INSERT INTO public.club_memberships (club_id, user_id, role, status)
  VALUES (pilot_club_id, auth.uid(), 'member', 'active')
  ON CONFLICT (club_id, user_id) DO NOTHING;

  IF NOT EXISTS (
    SELECT 1 FROM public.club_memberships
    WHERE club_id = pilot_club_id
      AND user_id = auth.uid()
      AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'This club membership is inactive';
  END IF;

  RETURN pilot_club_id;
END;
$function$;

-- Team access must no longer depend on the invitation-only eligibility list.
-- Existing member user IDs take priority; an unlinked legacy player may match
-- by verified email only if that roster row has no user ID yet.
CREATE OR REPLACE FUNCTION public.user_belongs_to_team(requested_team_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM private.team_members tm
    JOIN public.ladder_teams lt
      ON lt.id = tm.team_id
     AND lt.club_id = tm.club_id
     AND lt.ladder = tm.ladder
    JOIN public.club_memberships cm
      ON cm.club_id = lt.club_id
     AND cm.user_id = auth.uid()
     AND lower(cm.status::text) = 'active'
    JOIN auth.users u
      ON u.id = auth.uid()
     AND u.email_confirmed_at IS NOT NULL
    WHERE tm.team_id = requested_team_id
      AND tm.club_id IS NOT NULL
      AND (
        tm.user_id = auth.uid()
        OR (
          tm.user_id IS NULL
          AND lower(pg_catalog.btrim(tm.email)) =
              lower(pg_catalog.btrim(u.email))
        )
      )
  );
$function$;

REVOKE ALL ON FUNCTION public.join_pilot_club_secure() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.join_pilot_club_secure() TO authenticated;
REVOKE ALL ON FUNCTION public.user_belongs_to_team(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.user_belongs_to_team(uuid) TO authenticated;

COMMIT;

-- After applying, test an entirely new verified user:
-- 1. Sign up and verify email. The app should join the club automatically.
-- 2. Sign up a partner and accept one team invitation.
-- 3. Attempt second team in same ladder (must fail).
-- 4. Join a different ladder (must succeed).
-- Existing inactive users must remain blocked.
