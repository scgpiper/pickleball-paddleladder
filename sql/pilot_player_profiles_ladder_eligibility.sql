-- Pilot Test only. Run after sql/pilot_open_registration_one_team_per_ladder.sql
-- and sql/pilot_open_registration_team_acceptance_trigger.sql.
-- Adds private self-declared ladder eligibility and protects team acceptance
-- in the database; no existing memberships, invitations or rankings are changed.
BEGIN;

CREATE TABLE IF NOT EXISTS private.player_division_profiles (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  division_category text NOT NULL CHECK (division_category IN ('man','woman','review')),
  registered_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE private.player_division_profiles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.player_division_profiles FROM PUBLIC, anon, authenticated;

-- Used by the browser to complete a verified account's profile.
-- Eligibility selection is fixed after first submission; a future
-- administrative review workflow will handle corrections.
CREATE OR REPLACE FUNCTION public.complete_pilot_player_profile_secure(
  requested_name text,
  requested_category text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  player_name text := pg_catalog.btrim(coalesce(requested_name,''));
  player_category text := pg_catalog.lower(pg_catalog.btrim(coalesce(requested_category,'')));
  existing_category text;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM auth.users
    WHERE id = auth.uid() AND email_confirmed_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Confirm your email before completing your profile';
  END IF;

  IF pg_catalog.length(player_name) NOT BETWEEN 2 AND 80
     OR player_name !~ '^[[:alnum:]][[:alnum:] .''-]*$' THEN
    RAISE EXCEPTION 'Enter a valid player name (2–80 characters)';
  END IF;
  IF player_category NOT IN ('man','woman','review') THEN
    RAISE EXCEPTION 'Choose a division eligibility category';
  END IF;

  SELECT division_category INTO existing_category
  FROM private.player_division_profiles
  WHERE user_id = auth.uid() FOR UPDATE;

  IF existing_category IS NOT NULL AND existing_category <> player_category THEN
    RAISE EXCEPTION 'Contact the administrator to change division eligibility';
  END IF;

  INSERT INTO private.player_division_profiles(user_id,division_category)
  VALUES (auth.uid(),player_category)
  ON CONFLICT (user_id) DO NOTHING;

  -- Existing teammates may complete profiles, but must not silently
  -- rename a player who already has a team registration.
  IF EXISTS (
    SELECT 1 FROM private.team_members WHERE user_id = auth.uid()
  ) AND EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid()
      AND display_name NOT IN ('Member',player_name)
  ) THEN
    RAISE EXCEPTION 'Contact the administrator to change a rostered player name';
  END IF;

  INSERT INTO public.profiles(id,display_name)
  VALUES (auth.uid(),player_name)
  ON CONFLICT (id) DO UPDATE
    SET display_name = EXCLUDED.display_name,updated_at=now();
END;
$function$;

CREATE OR REPLACE FUNCTION public.my_pilot_player_profile_secure()
RETURNS TABLE(display_name text, division_category text, dupr numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
  SELECT p.display_name, d.division_category, p.dupr
  FROM auth.users u
  JOIN public.profiles p ON p.id = u.id
  LEFT JOIN private.player_division_profiles d ON d.user_id = u.id
  WHERE u.id = auth.uid() AND u.email_confirmed_at IS NOT NULL;
$function$;

-- Restrict both a NEW invitation and its acceptance, even if someone
-- bypasses the webpage. Existing accepted invitations are not rechecked.
CREATE OR REPLACE FUNCTION private.enforce_pilot_ladder_eligibility()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  captain_category text;
  partner_category text;
  captain_name text;
  partner_name text;
BEGIN
  IF TG_OP = 'INSERT' OR
     (TG_OP = 'UPDATE' AND NEW.status='accepted'
       AND OLD.status IS DISTINCT FROM 'accepted') THEN

    SELECT d.division_category, p.display_name
      INTO captain_category, captain_name
    FROM private.player_division_profiles d
    JOIN public.profiles p ON p.id=d.user_id
    JOIN auth.users u ON u.id=d.user_id
    JOIN public.club_memberships cm
      ON cm.user_id=u.id AND cm.club_id=NEW.club_id
     AND lower(cm.status::text)='active'
    WHERE u.id=NEW.captain_id
      AND u.email_confirmed_at IS NOT NULL
      AND lower(pg_catalog.btrim(u.email)) =
          lower(pg_catalog.btrim(NEW.captain_email));

    IF captain_category IS NULL OR captain_category='review' THEN
      RAISE EXCEPTION 'Captain must complete an eligible player profile';
    END IF;
    IF captain_name IS DISTINCT FROM NEW.captain_name THEN
      RAISE EXCEPTION 'Captain name must match their registered player profile';
    END IF;
    IF (NEW.ladder='mens' AND captain_category<>'man') OR
       (NEW.ladder='womens' AND captain_category<>'woman') THEN
      RAISE EXCEPTION 'Captain is not eligible for this ladder';
    END IF;

    IF TG_OP = 'UPDATE' THEN
      SELECT d.division_category, p.display_name
        INTO partner_category, partner_name
      FROM private.player_division_profiles d
      JOIN public.profiles p ON p.id=d.user_id
      JOIN auth.users u ON u.id=d.user_id
      JOIN public.club_memberships cm
        ON cm.user_id=u.id AND cm.club_id=NEW.club_id
       AND lower(cm.status::text)='active'
      WHERE u.id=auth.uid()
        AND u.email_confirmed_at IS NOT NULL
        AND lower(pg_catalog.btrim(u.email)) =
            lower(pg_catalog.btrim(NEW.partner_email));

      IF partner_category IS NULL OR partner_category='review' THEN
        RAISE EXCEPTION 'Partner must complete an eligible player profile';
      END IF;
      IF partner_name IS DISTINCT FROM NEW.partner_name THEN
        RAISE EXCEPTION 'Partner name must match their registered player profile';
      END IF;
      IF (NEW.ladder='mens' AND partner_category<>'man') OR
         (NEW.ladder='womens' AND partner_category<>'woman') OR
         (NEW.ladder='mixed' AND partner_category=captain_category) THEN
        RAISE EXCEPTION 'Players do not meet this ladder eligibility rule';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS pilot_registration_division_eligibility
  ON private.team_registration_requests;
CREATE TRIGGER pilot_registration_division_eligibility
  BEFORE INSERT OR UPDATE OF status
  ON private.team_registration_requests
  FOR EACH ROW EXECUTE FUNCTION private.enforce_pilot_ladder_eligibility();

REVOKE ALL ON FUNCTION public.complete_pilot_player_profile_secure(text,text)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.complete_pilot_player_profile_secure(text,text)
  TO authenticated;
REVOKE ALL ON FUNCTION public.my_pilot_player_profile_secure()
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.my_pilot_player_profile_secure()
  TO authenticated;
COMMIT;

-- Test cases after deploying matching web UI:
-- New confirmed user completes a player profile.
-- Woman cannot request a men's team; man cannot request women's team.
-- Mixed team must contain one man and one woman.
-- Second team in same ladder still fails at existing unique indexes.
-- Old test team data is untouched.
