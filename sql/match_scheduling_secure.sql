
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

  insert into private.match_schedules as s
    (challenge_id,proposed_by_team_id,proposed_start,venue,note,confirmed_at,updated_at)
  values (c.id,caller_team,requested_start,cleaned_venue,cleaned_note,null,now())
  on conflict (challenge_id) do update
    set proposed_by_team_id=excluded.proposed_by_team_id,
        proposed_start=excluded.proposed_start,venue=excluded.venue,
        note=excluded.note,confirmed_at=null,updated_at=now();
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
end;
$fn$;

revoke all on function public.my_match_schedules_secure() from public,anon;
revoke all on function public.propose_match_schedule_secure(uuid,timestamptz,text,text) from public,anon;
revoke all on function public.confirm_match_schedule_secure(uuid) from public,anon;
grant execute on function public.my_match_schedules_secure() to authenticated;
grant execute on function public.propose_match_schedule_secure(uuid,timestamptz,text,text) to authenticated;
grant execute on function public.confirm_match_schedule_secure(uuid) to authenticated;

commit;
