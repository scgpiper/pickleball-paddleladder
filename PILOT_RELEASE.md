# One-club pilot release

The first release uses the existing VPA ladder on `main`: Men's, Women's and Mixed doubles, team challenges, two-player team assignment, score confirmation, partner connect, history and admin review. Multi-club selection, regional ladders and four-player teams are later work. The app currently shows its leaderboard to signed-out visitors.

## Before inviting members

1. Confirm the pilot club and agree which standings and history may be public. The existing page serves a public leaderboard.
2. Check live Supabase table grants, RLS policies and every callable write function using separate signed-out, player and admin sessions. The client code does not grant permission; server rules must enforce it.
3. Prepare a separate test Supabase project with invented players and a preview pointing only at that project. Test sign-in, admin team creation/assignment, challenge, response, score submission, opposing-team confirmation, decline, overdue review, partner invite and sign-out.
4. Verify a sending domain and configure custom SMTP for Supabase Auth before invitations. The built-in email sender's low quota blocked a second test account.
5. Check whether the current team rows are examples or real pilot data. Back up and replace example rows only with the club's approval. Do not delete live rows as part of a code deployment.
6. Verify the old production URL and VPA lobby after merging any pilot fixes. Keep the multi-club draft PRs out of this release.

## This code change

The browser no longer supplies a hardcoded sample leaderboard when a database load fails. After sign-out, it clears signed-in team and invitation state and reloads the public board. No database rows are altered by this change.
