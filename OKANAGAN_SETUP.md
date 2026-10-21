# Okanagan Pickleball Ladder — independent pilot

This branch prepares the independent ladder's name and public-facing copy. It is **not ready to deploy for registration**. Its browser database settings are placeholders, and startup stops with a setup message until a separate Supabase project is configured. Do not substitute the VPA project credentials.

Before inviting players:

1. Create an independent Supabase project and a separate Vercel project/domain. Give the independent project its own one active club record representing the Okanagan Pickleball Ladder. Do not connect the VPA database or Auth project.
2. Review and apply the required database schema, RLS policies, secure functions, registration SQL, and notification SQL against that new project. The existing production signup file was written for the VPA schema and needs a fresh schema check before reuse. Open enrollment should require a confirmed email but no club-approved email list. Give only the organizer the administrator role.
3. Set the new project's URL and **publishable** key in `index.html`. Never use a service-role key in this file. Configure Auth redirect URLs and SMTP for the new domain. Set the deployment's `LADDER_SITE_URL` to its HTTPS URL. Configure the notification handler's remaining environment variables with credentials from this independent project only.
4. Verify signup, confirmation, partner acceptance, team selection, challenge response, score submission, public/private challenge visibility, and admin denial for an ordinary player. Confirm notification links point to the independent domain and VPA teams/challenges do not appear.

The club-approved-email draft is for a club-controlled deployment, not this open ladder. A player who joins both separate sites will initially need accounts on each site.
