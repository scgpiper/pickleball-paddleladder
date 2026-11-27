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

## Court booking responsibility (Pilot Test only)
- After the court-booking acknowledgement migration, apply `sql/match_court_booking_claim_pilot.sql` in Pilot Test **before** opening the newest preview; the app calls a new RPC on load.
- **I'll Book the Court** reserves responsibility, NOT the actual court. Both teams can see which team volunteered.
- **I've Booked the Court** is shown only to the volunteering team and records their report that a real external reservation is complete.
- **I Can't Book It** releases the task for another team to volunteer, before booking is reported.
- Booking claims are private to participating teams; the one-time claiming function is concurrency protected, and the existing seven-day deadline remains authoritative.
- Note: no email event is currently sent for the volunteer/release actions; the existing `booked` event remains the notification trigger for the completed reservation.

## Court booking acknowledgment
- Apply `sql/match_court_booking_pilot.sql` **after** the original scheduling migration, initially in Pilot Test only.
- Once a match date/time is confirmed, either participating team can click **I Booked the Court** after an actual external reservation.
- This stores who reported the booking and shows **Court booking reported** to both teams. It does **not** verify a reservation with VPA or book anything automatically.
- The action is accepted once per challenge; if a booking is cancelled or needs changing, a future controlled correction flow is needed.
- `booked` event is recorded for the opposing team to receive a notification when the webhook is configured.

## Setup in isolated staging Supabase project
1. Confirm `private.team_members` and `public.challenges` schema columns match the migration's assumptions.
2. Apply `sql/match_scheduling_secure.sql` (if not already installed) followed by `sql/match_court_booking_pilot.sql` in staging SQL editor, **not** production.
3. Check function privileges: anon cannot execute RPCs; authenticated may execute only the three participant-checked RPCs; service_role exclusively executes the notification lookup.
4. Add a new Vercel environment variable `MATCH_SCHEDULE_WEBHOOK_SECRET` (strong random secret); set `PADDLELADDER_BASE_URL` to the actual Pilot Test preview address; use **Pilot Test** `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`, not the live database; reuse existing SMTP settings only when appropriate for testing.
5. In Supabase Database Webhooks, create an INSERT webhook for table `public.match_schedule_events` aimed at `https://<preview-host>/api/match-schedule-notification`; set header `x-match-schedule-webhook-secret` equal to the Vercel secret. Do **not** disclose the secret in screenshots.
6. Ensure the preview is wired to staging Supabase credentials, not the production DB.
7. Run `node --test tests/*.test.js` (requires `npm ci` first) and review results.
8. Verify access with two authenticated staging teams: proposed -> email to other team -> counteroffer -> email -> confirm -> email to proposing team -> agreed time displayed on both accounts -> a team reports an actual booking -> opposing team sees status and receives email.
9. Verify attacker cases: unauthenticated user, unrelated player, own-team confirmation, proposed date outside the accepted challenge window, changes after confirmation, booking acknowledgment before a confirmed date, duplicate booking acknowledgment, data and emails invisible to bystanders. Confirm that legacy challenge flow and score entry still work.
10. Only after staging checks pass, apply migration to production **before** merging PR #29; configure production webhook to the production endpoint, set production secret; merge and run a controlled two-team smoke test.

## Important limitations
- Webhook delivery requires manual Supabase/Vercel configuration; simply merging this PR does not activate email notifications.
- The email notice is reserved before SMTP send and released on caught failures. As with any SMTP system, interruption between SMTP acceptance and recording success can cause a duplicate on retry.
- The application has no chat inbox or automated court reservation. Scheduling consists of structured offers plus an optional note.
- Notes are private to authorized match participants but are not sent in email.
- The current initial-version UI treats the scheduled time as final after both sides confirm. Changes afterward require administrator intervention or a subsequent enhancement.
