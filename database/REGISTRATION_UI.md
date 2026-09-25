# Registration UI rollout

The client screens are implemented behind `ENABLE_CLUB_REQUESTS = false` in `index.html`. Keep the switch off in previews and production until the approval functions in draft PR #7 have been reviewed, deployed and tested, and the multi-club authorization rollout has passed its isolation checks.

With the switch enabled, a signed-in applicant can request membership in an active club, view pending/approved/rejected request status, and reapply after rejection. A club admin or owner can review only their club's pending requests; a platform app admin may review any selected club. The server RPCs must enforce these permissions. No request can activate membership from client-side code.

Before enabling, confirm the `request_ladder_club_secure`, `my_ladder_club_requests_secure`, `pending_ladder_club_requests_secure`, and `review_ladder_club_request_secure` signatures and grants match the client. Test an applicant, a club A admin, a club B admin and a platform admin. Verify rejection, reapplication, inactive/invited accounts, duplicate requests and refresh after approval. Do not assume the public club list or pilot leaderboard is a safe model for future private club data; their RLS and visibility are a separate gate.
