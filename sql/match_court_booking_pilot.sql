-- Apply ONLY after match_scheduling_secure.sql in an isolated Pilot Test database.
-- Adds optional court-booked acknowledgement; does not make or verify an external reservation.
begin;
create table if not exists private.match_court_bookings (
  challenge_id uuid primary key references public.challenges(id) on delete cascade,
  booked_by_team_id uuid not null references public.ladder_teams(id) on delete cascade,
  acknowledged_at timestamptz not null default now()
);
alter table private.match_court_bookings enable row level security;
revoke all on private.match_court_bookings from public,anon,authenticated;

create or replace function public.my_match_court_bookings_secure()
returns table(challenge_id uuid,booked_by_team_id uuid,acknowledged_at timestamptz)
language sql stable security definer set search_path to ''
as $fn$
  select b.challenge_id,b.booked_by_team_id,b.acknowledged_at
  from private.match_court_bookings b
  join public.challenges c on c.id=b.challenge_id
  where auth.uid() is not null
    and c.status in ('Accepted','Awaiting Confirmation')
    and exists(
      select 1 from private.team_members m
      where m.user_id=auth.uid()
        and m.club_id=c.club_id
        and m.ladder=c.ladder
        and m.team_id in (c.challenger_team_id,c.challenged_team_id)
    );
$fn$;

create or replace function public.acknowledge_court_booked_secure(requested_challenge_id uuid)
returns void language plpgsql security definer set search_path to ''
as $fn$
declare
  c public.challenges%rowtype;
  s private.match_schedules%rowtype;
  caller_team uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into c from public.challenges where id=requested_challenge_id for update;
  if not found or c.status<>'Accepted' then
    raise exception 'An accepted challenge is required';
  end if;
  select * into s from private.match_schedules where challenge_id=c.id for update;
  if not found or s.confirmed_at is null then
    raise exception 'Confirm the match date and time before marking the court booked';
  end if;
  if c.play_by is null or now()>c.play_by then
    raise exception 'The match play deadline has passed';
  end if;
  select m.team_id into caller_team from private.team_members m
  where m.user_id=auth.uid() and m.club_id=c.club_id and m.ladder=c.ladder
    and m.team_id in(c.challenger_team_id,c.challenged_team_id)
  order by m.team_id limit 1;
  if caller_team is null then raise exception 'Not a participating team member'; end if;
  if exists(select 1 from private.match_court_bookings where challenge_id=c.id) then
    raise exception 'Court booking already acknowledged';
  end if;
  insert into private.match_court_bookings(challenge_id,booked_by_team_id)
    values(c.id,caller_team);
  insert into public.match_schedule_events
    (challenge_id,event_type,recipient_team_id,proposed_start,venue)
  values(c.id,'booked',
    case when caller_team=c.challenger_team_id then c.challenged_team_id
         else c.challenger_team_id end,
    s.proposed_start,s.venue);
end;
$fn$;

-- Allow a booking notification to be delivered using the existing secure outbox.
alter table public.match_schedule_events
  drop constraint if exists match_schedule_events_event_type_check;
alter table public.match_schedule_events
  add constraint match_schedule_events_event_type_check
  check(event_type in ('proposed','confirmed','booked'));

revoke all on function public.my_match_court_bookings_secure() from public,anon;
revoke all on function public.acknowledge_court_booked_secure(uuid) from public,anon;
grant execute on function public.my_match_court_bookings_secure() to authenticated;
grant execute on function public.acknowledge_court_booked_secure(uuid) to authenticated;
commit;
