-- Apply in the main Supabase project before deploying the matching app change.
-- Existing pending challenges will use the new 24-hour response limit.

create or replace function private.prevent_late_challenge_acceptance()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if old.status = 'Pending'
     and new.status = 'Accepted'
     and old.created_at <= now() - interval '24 hours' then

    raise exception
      'The 24-hour response period has expired. This challenge requires Admin review.';
  end if;

  return new;
end;
$function$;

create or replace function public.refresh_challenge_deadlines_secure()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  pending_expired integer := 0;
  matches_overdue integer := 0;
  check_time timestamp with time zone := now();
begin
  -- Pending challenges receive 24 hours for a response.
  update public.challenges
  set
    status = 'Decline Pending Admin Review',
    decline_reason = 'No response within 24 hours.',
    declined_at = check_time,
    updated_at = check_time
  where club_id is not null
    and status = 'Pending'
    and created_at <= check_time - interval '24 hours';

  get diagnostics pending_expired = row_count;

  -- Accepted matches become overdue after their play-by deadline.
  update public.challenges
  set
    status = 'Overdue',
    overdue_at = check_time,
    updated_at = check_time
  where club_id is not null
    and status = 'Accepted'
    and (
      play_by <= check_time
      or (
        play_by is null
        and accepted_at <= check_time - interval '7 days'
      )
    );

  get diagnostics matches_overdue = row_count;

  return jsonb_build_object(
    'pending_sent_to_admin_review', pending_expired,
    'matches_marked_overdue', matches_overdue
  );
end;
$function$;
