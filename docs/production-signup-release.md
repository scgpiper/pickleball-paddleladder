# Production signup release

This branch targets the live VPA Supabase project. The separate pilot preview and its fictional teams remain isolated. Do not merge the pilot-targeted PR #23 into `main`.

## Changes

- Keep the production Supabase URL and publishable key in the browser client.
- Add email/password account creation and partner-confirmed two-player registration.
- Use the existing public challenge projection for history and restricted private challenge reads.
- Install `sql/single_club_team_registration.sql` in the live project before deploying this client. Its RPC names retain `pilot` for compatibility with the exercised pilot flow.

## Release gate

1. Run `sql/production_signup_preflight_READONLY.sql` in the live SQL editor. Confirm exactly one active club, matching club IDs, both roster uniqueness indexes, a backfilled `challenge_public_feed`, and no pre-existing registration table or RPCs. Review the live Auth URL configuration and SMTP confirmation/reset delivery.
2. Take a recoverable database backup. Execute the registration SQL in the live Supabase SQL editor only after release approval. Verify the new table has RLS enabled, no direct grants to browser roles, and its five RPCs are executable by `authenticated` but not `anon`.
3. Deploy the client after the SQL succeeds. Test signed-out public board, new account email confirmation, captain request, partner acceptance, one-team-per-ladder protection, an ordinary player's admin denial, and existing administrator access. Confirm the public history omits private challenge reasons.
4. Only then announce the signup URL to club members. The partner invitation appears in-app; this flow does not send a partner email.

The client is coupled to the registration RPCs. Deploying it before the SQL would make ladder loading fail for signed-in non-admin users. No SQL in this branch has been run against the live project.
