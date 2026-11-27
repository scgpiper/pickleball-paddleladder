# Match scheduling release checklist (PR #29)

**Do not merge before staging database setup and acceptance tests.** The updated app calls new Supabase RPCs on initial page load, so merging before applying its SQL would block the main application.

## Architecture
- `private.match_schedules`: one current proposal per accepted challenge, readable only via participant-checked RPC.
- Proposal/counteroffer replaces the current unconfirmed proposal and notifies the opposing team.
- Opponent confirmation locks the schedule and notifies the proposing team.
- `public.match_schedule_events`: private event outbox with immutable recipient team, time and venue.
- `public.match_schedule_email_notices`: service-role-only SMTP duplicate suppression.
- Email contains time, venue, and team names but **not** private note text or player addresses.
- The original challenge deadline, score workflow, and rankings are unchanged.
- CourtReserve link opens a separate site. Booking is never automatic.
- App refresh is required to see other players' scheduling updates until realtime/polling is added.

## Setup in isolated staging Supabase project
1. Confirm `private.team_members` and `public.challenges` schema columns match the migration's assumptions.
2. Apply `sql/match_scheduling_secure.sql` in staging SQL editor, **not** production.
3. Check function privileges: anon cannot execute RPCs; authenticated may execute only the three participant-checked RPCs; service_role exclusively executes the notification lookup.
4. Add a new Vercel environment variable `MATCH_SCHEDULE_WEBHOOK_SECRET` (strong random secret); reuse the existing SMTP and service role settings for the test deployment.
5. In Supabase Database Webhooks, create an INSERT webhook for table `public.match_schedule_events` aimed at `https://<preview-host>/api/match-schedule-notification`; set header `x-match-schedule-webhook-secret` equal to the Vercel secret. Do **not** disclose the secret in screenshots.
6. Ensure the preview is wired to staging Supabase credentials, not the production DB.
7. Run `node --test tests/*.test.js` (requires `npm ci` first) and review results.
8. Verify access with two real authenticated staging teams: proposed -> email to other team -> counteroffer -> email -> confirm -> email to proposing team -> agreed time displayed on both accounts.
9. Verify attacker cases: unauthenticated user, unrelated player, own-team confirmation, proposed date outside the accepted challenge window, changes after confirmation, data and emails invisible to bystanders. Confirm that legacy challenge flow and score entry still work.
10. Only after staging checks pass, apply migration to production **before** merging PR #29; configure production webhook to the production endpoint, set production secret; merge and run a controlled two-team smoke test.

## Important limitations
- Webhook delivery requires manual Supabase/Vercel configuration; simply merging this PR does not activate email notifications.
- The email notice is reserved before SMTP send and released on caught failures. As with any SMTP system, interruption between SMTP acceptance and recording success can cause a duplicate on retry.
- The application has no chat inbox or automated court reservation. Scheduling consists of structured offers plus an optional note.
- Notes are private to authorized match participants but are not sent in email.
- The current initial-version UI treats the scheduled time as final after both sides confirm. Changes afterward require administrator intervention or a subsequent enhancement.
