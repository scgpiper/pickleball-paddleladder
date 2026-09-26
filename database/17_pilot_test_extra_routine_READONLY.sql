-- Run only in PaddleLadder Pilot Test. Read-only check for the one extra routine.
with expected(name) as (
  values ('private.cancel_invalid_pending_challenges'),
         ('private.check_pending_challenges_after_completion'),
         ('private.prevent_late_challenge_acceptance'),
         ('private.set_challenge_play_deadline'),
         ('private.track_challenge_acceptance_period'),
         ('public.accept_partner_invite_secure'),
         ('public.admin_add_team_secure'),
         ('public.admin_assign_team_members_secure'),
         ('public.admin_get_team_members_secure'),
         ('public.admin_remove_team_secure'),
         ('public.admin_reset_disputed_result_secure'),
         ('public.cancel_challenge_secure'),
         ('public.cancel_partner_invite_secure'),
         ('public.cancel_pilot_team_request_secure'),
         ('public.confirm_result_secure'),
         ('public.create_partner_listing_secure'),
         ('public.decline_partner_invite_secure'),
         ('public.enforce_one_team_per_ladder'),
         ('public.get_my_active_clubs_secure'),
         ('public.handle_new_user'),
         ('public.is_app_admin'),
         ('public.is_club_admin'),
         ('public.is_team_member'),
         ('public.issue_challenge_secure'),
         ('public.join_pilot_club_secure'),
         ('public.my_pilot_team_requests_secure'),
         ('public.record_forfeit_secure'),
         ('public.refresh_acceptance_enforcement_secure'),
         ('public.refresh_challenge_deadlines_secure'),
         ('public.remove_partner_listing_secure'),
         ('public.request_pilot_team_secure'),
         ('public.respond_pilot_team_request_secure'),
         ('public.respond_to_challenge_secure'),
         ('public.review_away_team_secure'),
         ('public.review_decline_secure'),
         ('public.review_overdue_match_secure'),
         ('public.send_partner_invite_secure'),
         ('public.set_challenge_deadline'),
         ('public.set_team_away_secure'),
         ('public.submit_result_secure'),
         ('public.team_club_id'),
         ('public.user_belongs_to_team'),
         ('public.validate_new_challenge')
), actual as (
  select n.nspname || '.' || p.proname as name, count(*) as overloads
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public', 'private')
    and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass
                    and d.objid = p.oid and d.deptype = 'e')
  group by 1
)
select a.name, a.overloads from actual a
left join expected e on e.name = a.name
where e.name is null or a.overloads <> 1
order by a.name;
