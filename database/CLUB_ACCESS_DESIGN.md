# Club access and registration design

This records the intended multi-club behavior. It is a design for the next database and application changes, not a claim that the current preview enforces it.

## Groups and visibility

- A club owns its teams, challenges, results, movements, partner listings and invitations. The regional ladder is another group with the same isolation rules; participating clubs do not automatically share their private data with it.
- A club's leaderboard is private by default. Its administrator can explicitly make the leaderboard public. A public leaderboard exposes only approved standings fields, never member emails, invitations, moderation queues or private team details.
- Anyone may view an opted-in public leaderboard, including members of other clubs. Private leaderboards require an active, approved membership in that club. A user may belong to multiple clubs and select which one to use; the selection scopes all reads and writes.
- The regional ladder can accept applicants from several clubs, subject to regional administrator approval. Membership in a participating club alone does not grant regional access.

## Registration and roles

1. A person can create an account and request membership in a club, or apply to the regional ladder. A request starts in `pending` status and does not grant access.
2. An administrator of the requested club reviews and approves or rejects that request. A regional administrator reviews requests for the regional ladder. The applicant sees their status and can retry only within the authentication provider's limits.
3. Club administrators manage only their own club. Platform administrators can manage club creation and assignments, with privileged actions audited. An administrator's app-wide account must not silently confer membership in every club.
4. A user can have several independently approved memberships. On sign-in, offer a group choice; allow switching groups later. Clear cached group data when switching or signing out.
5. Team creation and other writes require the server to verify an approved membership, appropriate role and selected group. The server determines or checks the group ID; a browser-provided ID alone never authorizes a write.

## Implementation gates before enabling another club

- Add a reviewed schema for groups (clubs and regional groups), membership requests, approved memberships and roles, publication preference, and club ownership of every group-specific record. Migrate existing pilot data deliberately.
- Review and test Supabase row-level security for every direct table read and write, including anonymous access only to explicitly public leaderboard fields. Check that users cannot gain access by changing a query filter, group ID or RPC argument.
- Review all SECURITY DEFINER functions, club-aware reads and writes, team creation, invitations, deadline refresh, and administrative functions. Ensure each verifies the caller and group in the database. Restrict grants and add cross-club denial tests.
- Implement request and approval UI, public/private group selection, and an administrator UI for changing visibility. Provide clear pending/rejected/approved states.
- Configure a production email sender with a verified domain and custom SMTP before relying on email sign-in for a larger audience. Supabase's default mail service is rate-limited; raising a client-side retry count will not raise its quota.
- Validate the full flow with separate non-admin users and clubs, and keep the current pull request in draft until server-side checks pass.

## Current preview boundary

The preview's only operational ladder is the existing pilot. The club chooser accepts multiple active memberships, but choosing any other club shows an unavailable message and does not load its data. Its public pilot board and app-wide admin behavior remain legacy features to revisit alongside the database rollout. The preview does not yet offer registration requests, approvals or configurable leaderboard visibility.
