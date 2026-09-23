# Multi-club rollout design (working draft)

## Goal

Each club has its own registration link. A team signs up on its own club's page. The same player may use the same email and sign-in at two or more clubs, with separate team enrollment at each. Every leaderboard, challenge, score, partner action, and club administrator action is scoped to the selected club. Existing VPA records and the current URL remain attached to VPA. No other club is populated with VPA teams.

## Existing app inventory

The page in `index.html` reads `public.ladder_teams`, `public.challenges`, `public.ladder_movements`, `public.partner_listings`, and `public.partner_invites` without a club filter. `private.team_members` associates users and email addresses with teams. The lobby independently reads `ladder_teams`; its VPA name is currently a constant.

The current application calls these authorization and maintenance functions: `is_app_admin`, `user_belongs_to_team`, `admin_get_team_members_secure`, `refresh_challenge_deadlines_secure`, and `refresh_acceptance_enforcement_secure`.

Its mutations use: `admin_assign_team_members_secure`, `set_team_away_secure`, `admin_remove_team_secure`, `admin_add_team_secure`, `review_away_team_secure`, `review_overdue_match_secure`, `record_forfeit_secure`, `issue_challenge_secure`, `respond_to_challenge_secure`, `review_decline_secure`, `cancel_challenge_secure`, `submit_result_secure`, `confirm_result_secure`, `admin_reset_disputed_result_secure`, `remove_partner_listing_secure`, `create_partner_listing_secure`, `send_partner_invite_secure`, `accept_partner_invite_secure`, `decline_partner_invite_secure`, and `cancel_partner_invite_secure`.

## Proposed database boundaries

- `public.clubs`: stable UUID, unique URL slug, display name, optional branding and active flag. Public clients can read active club names and slugs, but only authorized administrators can change their own club metadata.
- `private.club_admins`: `(club_id, user_id)` unique membership. A club administrator has access only to clubs where they are explicitly assigned; the same account may administer multiple clubs if assigned separately. Keep any existing platform owner role separate from club admin privileges.
- Use `private.club_memberships` (or an equivalent registration relation) keyed by `(club_id, user_id)` and, for pending emailed invitations, unique normalized email *within each club*. The same auth user and normalized email may appear in multiple clubs; never impose global unique email or user ID on club membership. Existing `private.team_members` remains the team roster; every roster change must verify the team's club, and any team-level uniqueness on email/user must include the club where needed. Do not require a new Supabase Auth project for each club.
- Add a non-null `club_id` to each directly queried club-owned table: `ladder_teams`, `challenges`, `ladder_movements`, `partner_listings`, and `partner_invites`. Derive and backfill each dependent row from its referenced team or listing where possible, checking for conflicting references. `private.team_members` may inherit its club exclusively through its team foreign key; add a denormalized club ID there only if existing functions or performance require it.
- Replace uniqueness scoped only to ladder or email with appropriate club-aware uniqueness where required. Preserve a team primary key and use composite foreign keys or checked functions so related IDs cannot connect rows from different clubs.
- Enable and verify RLS and grants for every exposed table. Public standings may be readable by club; private emails and user IDs must remain restricted. Set each SECURITY DEFINER function's search path and validate both the caller's club authority and the club of **every** referenced row. Client-provided club IDs are context, not proof of permission. For a team action, derive the club from that team and verify every other team, challenge, invite and listing belongs to it.
- Scheduled/deadline functions must process rows within each club without allowing the caller to supply a target outside authorized scope. The schema inventory is needed to decide whether these functions may be called by clients at all.

## App behavior

Resolve `?club=<slug>` from `clubs`, defaulting to VPA for preexisting links. Display the resolved club name in app header and lobby, with `?club=<slug>&screen=lobby` as a shareable screen link. A missing or inactive slug shows a clear error instead of another club's standings. Filter all five table reads by the resolved club ID; reset selected team, challenge, history, and admin state when clubs change. Evaluate admin access against the selected club and pass club context to functions that require it. A player can visit another club's public page and sign in with the same email, but receives team or admin actions there only after joining that club or being explicitly assigned as its admin. Sign-in links should return to the club URL that initiated sign-in. New club creation and first admin assignment must be a platform-admin-only operation; public visitors cannot self-create a club or appoint themselves.

## Registration rule

A team is registered only in the club whose page created it. A person can join a separate team at another club using the same email and Supabase sign-in. Club membership and team membership must be keyed by club context, so the same email is not treated as a duplicate across clubs. Merely changing the club URL does not move a team, grant club administration, or authorize a challenge. Existing VPA membership is backfilled from VPA rosters.

## Migration order

1. Export metadata with `inspect_schema_readonly.sql`; review columns, existing keys, policies, triggers, and exact function bodies. Inventory currently reads *definitions*, not rows.
2. Build a transaction-safe migration from the **actual** schema. Insert VPA, backfill existing records, add constraints and indexes, and install per-club policies/functions. Detect inconsistent or orphaned historical rows before committing.
3. Verify production data counts and representative VPA standings before and after in a read-only check; exercise signed-out visitor, one email enrolled independently at clubs A and B, club A admin, club B admin, and platform admin against allowed and denied operations. Confirm cross-club IDs are rejected by RPCs even if a client bypasses page filters.
4. Deploy the compatible frontend after the migration and verify the old URL, VPA lobby, and each newly provisioned club URL. Add other clubs only after the isolation tests pass.

## Current state

This document and the schema inventory query are preparation only. No database change or frontend club separation is deployed. The implementation depends on the metadata export because the repository does not contain database migrations or the existing PostgreSQL function definitions.
