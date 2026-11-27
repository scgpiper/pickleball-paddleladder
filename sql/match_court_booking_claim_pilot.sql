-- Pilot Test follow-up ONLY. Run after match_court_booking_pilot.sql.
-- A claim is an intention to reserve; a booking acknowledgement is separate.
begin;
create table if not exists private.match_court_booking_claims(
  challenge_id uuid primary key references public.challenges(id) on delete cascade,
  claimed_by_team_id uuid not null references public.ladder_teams(id) on delete cascade,
  claimed_at timestamptz not null default now()
);
alter table private.match_court_booking_claims enable row level security;
revoke all on private.match_court_booking_claims from public,anon,authenticated;

create or replace function public.my_match_court_booking_claims_secure()
returns table(challenge_id uuid,claimed_by_team_id uuid,claimed_at timestamptz)
language sql stable security definer set search_path to ''
as $fn$
  select b.challenge_id,b.claimed_by_team_id,b.claimed_at
  from private.match_court_booking_claims b
  join public.challenges c on c.id=b.challenge_id
  where auth.uid() is not null
    and c.status in ('Accepted','Awaiting Confirmation')
    and exists (
      select 1 from private.team_members m
      where m.user_id=auth.uid() and m.club_id=c.club_id and m.ladder=c.ladder
        and m.team_id in(c.challenger_team_id,c.challenged_team_id)
    );
$fn$;

create or replace function public.claim_court_booking_secure(requested_challenge_id uuid)
returns void language plpgsql security definer set search_path to ''
as $fn$
declare
  c public.challenges%rowtype;
  s private.match_schedules%rowtype;
  caller_team uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into c from public.challenges where id=requested_challenge_id for update;
  if not found or c.status <> 'Accepted' then
    raise exception 'An accepted challenge is required';
  end if;
  select * into s from private.match_schedules where challenge_id=c.id for update;
  if not found or s.confirmed_at is null then
    raise exception 'Agree on a match time before volunteering to book';
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
    raise exception 'A court booking has already been reported';
  end if;
  insert into private.match_court_booking_claims(challenge_id,claimed_by_team_id)
    values(c.id,caller_team)
  on conflict(challenge_id) do nothing;
  if not found then
    raise exception 'A team has already volunteered to book this court';
  end if;
end;
$fn$;

create or replace function public.release_court_booking_claim_secure(requested_challenge_id uuid)
returns void language plpgsql security definer set search_path to ''
as $fn$
declare
  c public.challenges%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into c from public.challenges where id=requested_challenge_id for update;
  if not found or c.status <> 'Accepted' then raise exception 'Challenge is no longer active'; end if;
  if exists(select 1 from private.match_court_bookings where challenge_id=c.id) then
    raise exception 'The court was already reported booked';
  end if;
  delete from private.match_court_booking_claims b
  where b.challenge_id=c.id and exists(
    select 1 from private.team_members m
    where m.user_id=auth.uid() and m.club_id=c.club_id and m.ladder=c.ladder
      and m.team_id=b.claimed_by_team_id
  );
  if not found then raise exception 'Only the volunteering team can release the booking task'; end if;
end;
$fn$;

create or replace function public.acknowledge_court_booked_secure(requested_challenge_id uuid)
returns void language plpgsql security definer set search_path to ''
as $fn$
declare
  c public.challenges%rowtype;
  s private.match_schedules%rowtype;
  caller_team uuid;
  claimant uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into c from public.challenges where id=requested_challenge_id for update;
  if not found or c.status<>'Accepted' then raise exception 'An accepted challenge is required'; end if;
  select * into s from private.match_schedules where challenge_id=c.id for update;
  if not found or s.confirmed_at is null then
    raise exception 'Confirm the match date and time first';
  end if;
  if c.play_by is null or now()>c.play_by then
    raise exception 'The match play deadline has passed';
  end if;
  select m.team_id into caller_team from private.team_members m
    where m.user_id=auth.uid() and m.club_id=c.club_id and m.ladder=c.ladder
      and m.team_id in(c.challenger_team_id,c.challenged_team_id)
    order by m.team_id limit 1;
  if caller_team is null then raise exception 'Not a participating team member'; end if;
  select b.claimed_by_team_id into claimant from private.match_court_booking_claims b
    where b.challenge_id=c.id for update;
  if claimant is distinct from caller_team then
    raise exception 'Your team must volunteer to book the court before confirming it';
  end if;
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

revoke all on function public.my_match_court_booking_claims_secure() from public,anon;
revoke all on function public.claim_court_booking_secure(uuid) from public,anon;
revoke all on function public.release_court_booking_claim_secure(uuid) from public,anon;
grant execute on function public.my_match_court_booking_claims_secure() to authenticated;
grant execute on function public.claim_court_booking_secure(uuid) to authenticated;
grant execute on function public.release_court_booking_claim_secure(uuid) to authenticated;
commit;
