# One-club pilot release

The first release uses the existing VPA ladder on `main`: Men's, Women's and Mixed doubles, team challenges, two-player team assignment, score confirmation, partner connect, history and admin review. Multi-club selection, regional ladders and four-player teams are later work. The app currently shows its leaderboard to signed-out visitors.

## Pilot registration decision

The club can send one announcement with the app link to its members. Members create their own accounts with email and password; there is no club directory upload, individual invitation, or approval queue for each new account. The existing live app still relies on an admin to assign player emails to teams. Self-service team entry and player confirmation must be built and tested before announcing that members can register their own teams.

Each player should have at most one active team per ladder, enforced by the database against the signed-in account. A captain handles challenges and score entry for the team. Because one person could use different email addresses, make team rosters visible and let an admin review and correct reported duplicates. Email sign-in alone cannot guarantee one account per person. These are pilot requirements, not features delivered by this code change.

## Before announcing to members

1. Confirm the pilot club and agree which standings and history may be public. The existing page serves a public leaderboard.
2. Check live Supabase table grants, RLS policies and every callable write function using separate signed-out, player and admin sessions. The client code does not grant permission; server rules must enforce it.
3. Prepare a separate test Supabase project with invented players and a preview pointing only at that project. Test email confirmation, password sign-in, password reset, existing email-link user setting a password, team entry and player confirmation when implemented, one-team-per-ladder enforcement, challenge, response, score submission, opposing-team confirmation, decline, overdue review, partner invite and sign-out.
4. Verify a sending domain and configure custom SMTP for Supabase Auth before the club announces registration. Confirm email should remain enabled for sign-up. The built-in email sender's low quota blocked a second test account; password sign-in reduces repeat emails but confirmations and resets still send email.
5. Check whether the current team rows are examples or real pilot data. Back up and replace example rows only with the club's approval. Do not delete live rows as part of a code deployment.
6. Verify the old production URL and VPA lobby after merging any pilot fixes. Keep the multi-club draft PRs out of this release.

## This code change

The browser no longer supplies a hardcoded sample leaderboard when a database load fails. After sign-out, it clears signed-in team and invitation state and reloads the public board. The draft adds password account creation, sign-in, reset and password setting for existing email-link accounts. It keeps email-link sign-in as a fallback. No database rows are altered by this change. Password auth needs a preview check with a separate test Supabase project before merging.
