# Challenge email setup

The challenge INSERT database webhook calls the server function. The function
checks a shared secret, looks up the challenged team's assigned player emails,
and uses server-side SMTP. The browser never receives SMTP or service-role keys.
Each challenge/email pair is reserved in `challenge_email_notices` to avoid
repeat email on duplicate webhook delivery.

1. Apply `sql/challenge_email_notices.sql` in the **main** Supabase project.
2. In the main Vercel project, add Production environment variables:
   `SUPABASE_URL` (main project URL),
   `SUPABASE_SERVICE_ROLE_KEY` (main project's secret service-role key),
   `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`,
   `SMTP_FROM`, and a long random `CHALLENGE_WEBHOOK_SECRET`.
   The SMTP values must match a working sender account. Never commit them.
3. Redeploy Production so `/api/challenge-notification` is available.
4. In main Supabase Database Webhooks, create one on
   `public.challenges`, event **INSERT**, POST to
   `https://pickleball-paddleladder.vercel.app/api/challenge-notification`.
   Add HTTP header `x-challenge-webhook-secret` with exactly the secret
   from Vercel. Retain `Content-Type: application/json`.
5. Assign **both** player email addresses to the challenged team before
   issuing the test challenge. Create one test challenge, verify both messages,
   then check `challenge_email_notices` has two `sent_at` values.
   A team with no assigned player emails cannot receive notices.

This sends notices for new challenges only. It does not send an invitation,
acceptance, result, or reminder email. It does not change challenge status if
SMTP fails. A failing webhook is logged by Supabase and Vercel; after fixing
SMTP, the webhook can be delivered again for unsent recipients. Do not tell
players notifications are active until step 5 passes.
