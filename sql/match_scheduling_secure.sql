
-- Proposed migration for PILOT/STAGING first; not applied to production.
-- Scheduling is private to participating teams. Challenge status and play_by remain authoritative.
begin;

create table if not exists private.match_schedules (
  challenge_id uuid primary key references public.challenges(id) on delete cascade,
  proposed_by_team_id uuid not null references public.ladder_teams(id) on delete cascade,
  proposed_start timestamptz not null,
  venue text not null,
  note text not null default '',
  confirmed_at timestamptz,
  updated_at timestamptz not null default now()
);
alter table private.match_schedules enable row level security;

-- Outbox contains event references only; no personal contact details.
create table if not exists public.match_schedule_events (
  id uuid primary key default gen_random_uuid(),
  challenge_id uuid not null references public.challenges(id) on delete cascade,
  event_type text not null check (event_type in ('proposed','confirmed')),
  recipient_team_id uuid not null references public.ladder_teams(id) on delete cascade,
  proposed_start timestamptz not null,
  venue text not null,
  created_at timestamptz not null default now()
);
alter table public.match_schedule_events enable row level security;
revoke all on public.match_schedule_events from public,anon,authenticated;
grant select on public.match_schedule_events to service_role;
revoke all on private.match_schedules from public, anon, authenticated;

create or replace function public.my_match_schedules_secure()
returns table(challenge_id uuid, proposed_by_team_id uuid, proposed_start timestamptz,
              venue text, note text, confirmed_at timestamptz, updated_at timestamptz)
language sql stable security definer set search_path to ''
as $fn$
  select s.challenge_id, s.proposed_by_team_id, s.proposed_start,
         s.venue, s.note, s.confirmed_at, s.updated_at
  from private.match_schedules s
  join public.challenges c on c.id = s.challenge_id
  where auth.uid() is not null
    and (
      exists (select 1 from private.team_members m
              where m.team_id = c.challenger_team_id and m.user_id = auth.uid())
      or exists (select 1 from private.team_members m
              where m.team_id = c.challenged_team_id and m.user_id = auth.uid())
    )
    and c.status in ('Accepted','Awaiting Confirmation');
$fn$;

create or replace function public.propose_match_schedule_secure(
  requested_challenge_id uuid, requested_start timestamptz,
  requested_venue text, requested_note text default ''
) returns void
language plpgsql security definer set search_path to ''
as $fn$
declare
  c public.challenges%rowtype;
  caller_team uuid;
  cleaned_venue text := pg_catalog.btrim(coalesce(requested_venue,''));
  cleaned_note text := pg_catalog.btrim(coalesce(requested_note,''));
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into c from public.challenges
    where id = requested_challenge_id for update;
  if not found or c.status <> 'Accepted' then
    raise exception 'Scheduling is only available for accepted challenges';
  end if;
  select m.team_id into caller_team
    from private.team_members m
    where m.user_id = auth.uid()
      and m.team_id in (c.challenger_team_id,c.challenged_team_id)
    limit 1;
  if caller_team is null then raise exception 'Not a participating team member'; end if;
  if requested_start is null
      or requested_start <= now()
      or requested_start > c.play_by then
    raise exception 'Choose a future time before the seven-day match deadline';
  end if;
  if pg_catalog.length(cleaned_venue) not between 2 and 120
      or pg_catalog.length(cleaned_note) > 500 then
    raise exception 'Venue must be 2–120 characters; note at most 500 characters';
  end if;

  if exists (select 1 from private.match_schedules where challenge_id=c.id and confirmed_at is not null) then
    raise exception 'The scheduled time is confirmed; contact the administrator to change it';
  end if;
  insert into private.match_schedules as s
    (challenge_id,proposed_by_team_id,proposed_start,venue,note,confirmed_at,updated_at)
  values (c.id,caller_team,requested_start,cleaned_venue,cleaned_note,null,now())
  on conflict (challenge_id) do update
    set proposed_by_team_id=excluded.proposed_by_team_id,
        proposed_start=excluded.proposed_start,venue=excluded.venue,
        note=excluded.note,confirmed_at=null,updated_at=now();
  insert into public.match_schedule_events(challenge_id,event_type,recipient_team_id,proposed_start,venue)
    values (c.id,'proposed',case when caller_team=c.challenger_team_id then c.challenged_team_id else c.challenger_team_id end,requested_start,cleaned_venue);
end;
$fn$;

create or replace function public.confirm_match_schedule_secure(requested_challenge_id uuid)
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
    raise exception 'Challenge is no longer available for scheduling';
  end if;
  select * into s from private.match_schedules where challenge_id=c.id for update;
  if not found then raise exception 'No proposed schedule to confirm'; end if;
  select m.team_id into caller_team from private.team_members m
    where m.user_id=auth.uid()
      and m.team_id in (c.challenger_team_id,c.challenged_team_id)
    limit 1;
  if caller_team is null or caller_team = s.proposed_by_team_id then
    raise exception 'The opposing team must confirm the proposed time';
  end if;
  if s.proposed_start <= now() or s.proposed_start > c.play_by then
    raise exception 'Proposed time is outside the remaining match window';
  end if;
  update private.match_schedules set confirmed_at=now(),updated_at=now()
    where challenge_id=c.id and confirmed_at is null;
  if not found then raise exception 'This time was already confirmed'; end if;
  insert into public.match_schedule_events(challenge_id,event_type,recipient_team_id,proposed_start,venue)
    values(c.id,'confirmed',s.proposed_by_team_id,s.proposed_start,s.venue);
end;
$fn$;

revoke all on function public.my_match_schedules_secure() from public,anon;
revoke all on function public.propose_match_schedule_secure(uuid,timestamptz,text,text) from public,anon;
revoke all on function public.confirm_match_schedule_secure(uuid) from public,anon;
grant execute on function public.my_match_schedules_secure() to authenticated;
grant execute on function public.propose_match_schedule_secure(uuid,timestamptz,text,text) to authenticated;
grant execute on function public.confirm_match_schedule_secure(uuid) to authenticated;

-- Server-only event lookup provides schedule and recipient addresses to webhook handler.
create or replace function public.match_schedule_notification_secure(requested_event_id uuid)
returns table(event_type text, event_created_at timestamptz,
  challenge_id uuid, proposed_start timestamptz, venue text,
  challenger_name text, challenged_name text, recipient_email text)
language sql stable security definer set search_path to ''
as $fn$
  select e.event_type,e.created_at,e.challenge_id,
         e.proposed_start,e.venue,ct.name::text,dt.name::text,
         lower(pg_catalog.btrim(m.email)) as recipient_email
  from public.match_schedule_events e
  join public.challenges c on c.id=e.challenge_id
  join private.match_schedules s on s.challenge_id=e.challenge_id
  join public.ladder_teams ct on ct.id=c.challenger_team_id and ct.club_id=c.club_id
  join public.ladder_teams dt on dt.id=c.challenged_team_id and dt.club_id=c.club_id
  join private.team_members m on m.club_id=c.club_id and m.ladder=c.ladder
    and m.team_id=e.recipient_team_id
  where e.id=requested_event_id
    and c.status in ('Accepted','Awaiting Confirmation')
    and m.email is not null and pg_catalog.btrim(m.email)<>''
  order by recipient_email
  limit 2;
$fn$;
revoke all on function public.match_schedule_notification_secure(uuid) from public,anon,authenticated;
grant execute on function public.match_schedule_notification_secure(uuid) to service_role;

create table if not exists public.match_schedule_email_notices (
  event_id uuid not null references public.match_schedule_events(id) on delete cascade,
  email text not null,
  sent_at timestamptz,
  primary key(event_id,email)
);
alter table public.match_schedule_email_notices enable row level security;
revoke all on public.match_schedule_email_notices from public,anon,authenticated;
grant select,insert,update,delete on public.match_schedule_email_notices to service_role;

commit;
