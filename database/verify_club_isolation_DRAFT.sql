-- Read-only verification. Run AFTER stage 1 in staging/production,
-- and repeat after stage 2 and after onboarding another club.
-- Every violation_count should be zero. No player data is returned.
with violations as (
  select 'challenge / challenger club mismatch' as check_name, count(*) as violation_count
  from public.challenges c join public.ladder_teams t
    on t.id = c.challenger_team_id
  where t.club_id is distinct from c.club_id
  union all
  select 'challenge / challenged club mismatch', count(*)
  from public.challenges c join public.ladder_teams t
    on t.id = c.challenged_team_id
  where t.club_id is distinct from c.club_id
  union all
  select 'challenge / winner club mismatch', count(*)
  from public.challenges c join public.ladder_teams t
    on t.id = c.winner_team_id
  where t.club_id is distinct from c.club_id
  union all
  select 'challenge / forfeit club mismatch', count(*)
  from public.challenges c join public.ladder_teams t
    on t.id = c.forfeited_by_team_id
  where t.club_id is distinct from c.club_id
  union all
  select 'challenge / submitting club mismatch', count(*)
  from public.challenges c join public.ladder_teams t
    on t.id = c.submitted_by_team_id
  where t.club_id is distinct from c.club_id
  union all
  select 'movement / team club mismatch', count(*)
  from public.ladder_movements m join public.ladder_teams t
    on t.id = m.team_id where t.club_id is distinct from m.club_id
  union all
  select 'roster / team club mismatch', count(*)
  from private.team_members m join public.ladder_teams t
    on t.id = m.team_id where t.club_id is distinct from m.club_id
  union all
  select 'invite / listing club mismatch', count(*)
  from public.partner_invites i join public.partner_listings l
    on l.id = i.listing_id where l.club_id is distinct from i.club_id
  union all
  select 'duplicate rank in club ladder', count(*)
  from (
    select club_id, ladder, rank_position
    from public.ladder_teams
    group by club_id, ladder, rank_position
    having count(*) > 1
  ) duplicates
)
select * from violations order by check_name;

-- Club counts show whether existing VPA standings remain intact.
select c.slug, c.name,
       count(distinct t.id) as teams,
       count(distinct ch.id) as challenges
from public.clubs c
left join public.ladder_teams t on t.club_id = c.id
left join public.challenges ch on ch.club_id = c.id
group by c.id, c.slug, c.name
order by c.slug;
