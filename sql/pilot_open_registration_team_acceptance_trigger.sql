-- PaddleLadder Pilot Test only: replace outdated allowlist check in
-- team invitation acceptance trigger with confirmed-user and active-club checks.
-- Preserve the trigger and existing one-team-per-ladder constraints.
BEGIN;

CREATE OR REPLACE FUNCTION private.enforce_pilot_team_approval()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF NEW.status = 'accepted'
     AND OLD.status IS DISTINCT FROM 'accepted' THEN

    IF NOT EXISTS (
      SELECT 1
      FROM auth.users u
      JOIN public.club_memberships cm
        ON cm.user_id = u.id
       AND cm.club_id = NEW.club_id
       AND lower(cm.status::text) = 'active'
      WHERE u.id = NEW.captain_id
        AND u.email_confirmed_at IS NOT NULL
        AND lower(pg_catalog.btrim(u.email)) =
            lower(pg_catalog.btrim(NEW.captain_email))
    ) THEN
      RAISE EXCEPTION 'The captain must have a confirmed email and active club membership';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM auth.users u
      JOIN public.club_memberships cm
        ON cm.user_id = u.id
       AND cm.club_id = NEW.club_id
       AND lower(cm.status::text) = 'active'
      WHERE u.id = auth.uid()
        AND u.email_confirmed_at IS NOT NULL
        AND lower(pg_catalog.btrim(u.email)) =
            lower(pg_catalog.btrim(NEW.partner_email))
    ) THEN
      RAISE EXCEPTION 'The partner must have a confirmed email and active club membership';
    END IF;

  END IF;

  RETURN NEW;
END;
$function$;

COMMIT;
