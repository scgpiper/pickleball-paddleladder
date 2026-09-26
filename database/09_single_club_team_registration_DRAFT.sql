-- DRAFT for the existing VPA single-club tables. Review against the live schema
-- and exercise with separate test accounts before running on production.
-- This does not implement the deferred multi-club design.

begin;

create table if not exists private.team_registration_requests (
  id uuid primary key default gen_random_uuid(),
  ladder text not null check (ladder in ('mens', 'womens', 'mixed')),
  team_name text not null,
  captain_id uuid not null references auth.users(id) on delete cascade,
  captain_email text not null,
  captain_name text not null,
  captain_dupr numeric,
  captain_is_nr boolean not null default false,
  partner_email text not null,
  partner_name text not null,
  partner_dupr numeric,
  partner_is_nr boolean not null default false,
  status text not null default 'pending'
    check (status in ('pending', 'accepted', 'declined')),
  created_team_id uuid references public.ladder_teams(id) on delete set null,
  created_at timestamptz not null default now(),
  decided_at timestamptz
);

create unique index if not exists team_registration_one_pending_per_captain
  on private.team_registration_requests (ladder, captain_id)
  where status = 'pending';

create index if not exists team_registration_partner_pending
  on private.team_registration_requests (lower(partner_email), created_at)
  where status = 'pending';

-- Keep the rule in the database even if a different team-writing RPC is called.
-- An existing duplicate must be resolved before this migration can commit.
create unique index if not exists pilot_team_member_email_ladder_unique
  on private.team_members (ladder, lower(email));
create unique index if not exists pilot_team_member_user_ladder_unique
  on private.team_members (ladder, user_id) where user_id is not null;

revoke all on private.team_registration_requests from public, anon, authenticated;

create or replace function public.request_pilot_team_secure(
  requested_ladder text,
  requested_team_name text,
  requested_captain_name text,
  requested_captain_dupr numeric,
  requested_captain_is_nr boolean,
  requested_partner_name text,
  requested_partner_dupr numeric,
  requested_partner_is_nr boolean,
  requested_partner_email text
) returns uuid
language plpgsql security definer set search_path to ''
as $function$
declare
  caller_email text;
  target_ladder text := lower(pg_catalog.btrim(coalesce(requested_ladder, '')));
  team_name text := pg_catalog.btrim(coalesce(requested_team_name, ''));
  captain_name text := pg_catalog.btrim(coalesce(requested_captain_name, ''));
  partner_name text := pg_catalog.btrim(coalesce(requested_partner_name, ''));
  partner_email text := lower(pg_catalog.btrim(coalesce(requested_partner_email, '')));
  new_request_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Sign in before creating a team';
  end if;

  select lower(email) into caller_email from auth.users
  where id = auth.uid() and email_confirmed_at is not null;
  if caller_email is null then
    raise exception 'Confirm your email address before creating a team';
  end if;

  if target_ladder not in ('mens', 'womens', 'mixed')
     or pg_catalog.length(team_name) not between 2 and 80
     or pg_catalog.length(captain_name) not between 2 and 80
     or pg_catalog.length(partner_name) not between 2 and 80
     -- The existing board inserts names into HTML; allow plain names only.
     or team_name !~ '^[[:alnum:]][[:alnum:] .''-]*$'
     or captain_name !~ '^[[:alnum:]][[:alnum:] .''-]*$'
     or partner_name !~ '^[[:alnum:]][[:alnum:] .''-]*$'
     or partner_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
     or partner_email = caller_email then
    raise exception 'Check the ladder, names, and partner email';
  end if;

  if (not coalesce(requested_captain_is_nr, false)
        and (requested_captain_dupr is null or requested_captain_dupr <= 0 or requested_captain_dupr > 10))
     or (not coalesce(requested_partner_is_nr, false)
        and (requested_partner_dupr is null or requested_partner_dupr <= 0 or requested_partner_dupr > 10)) then
    raise exception 'Enter each player''s DUPR or mark them NR';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('pilot-roster:' || target_ladder));

  if exists (
    select 1 from private.team_members m
    where m.ladder = target_ladder
      and (m.user_id = auth.uid() or lower(m.email) in (caller_email, partner_email))
  ) then
    raise exception 'One of these players is already on a team in this ladder';
  end if;

  if exists (
    select 1 from public.ladder_teams t
    where t.ladder = target_ladder and lower(t.name) = lower(team_name)
  ) then
    raise exception 'That team name is already used in this ladder';
  end if;

  insert into private.team_registration_requests (
    ladder, team_name, captain_id, captain_email, captain_name,
    captain_dupr, captain_is_nr, partner_email, partner_name,
    partner_dupr, partner_is_nr
  ) values (
    target_ladder, team_name, auth.uid(), caller_email, captain_name,
    case when coalesce(requested_captain_is_nr, false) then null else requested_captain_dupr end,
    coalesce(requested_captain_is_nr, false), partner_email, partner_name,
    case when coalesce(requested_partner_is_nr, false) then null else requested_partner_dupr end,
    coalesce(requested_partner_is_nr, false)
  ) returning id into new_request_id;

  return new_request_id;
end;
$function$;

create or replace function public.my_pilot_team_requests_secure()
returns table (
  id uuid, ladder text, team_name text, captain_name text,
  captain_email text, partner_name text, partner_email text,
  status text, am_captain boolean, created_team_id uuid
)
language sql stable security definer set search_path to ''
as $function$
  select r.id, r.ladder, r.team_name, r.captain_name, r.captain_email,
         r.partner_name, r.partner_email, r.status,
         r.captain_id = auth.uid(), r.created_team_id
  from private.team_registration_requests r
  join auth.users u on u.id = auth.uid() and u.email_confirmed_at is not null
  where r.captain_id = auth.uid()
     or lower(r.partner_email) = lower(u.email)
  order by r.created_at desc
  limit 30;
$function$;

create or replace function public.respond_pilot_team_request_secure(
  requested_request_id uuid, requested_accept boolean
) returns uuid
language plpgsql security definer set search_path to ''
as $function$
declare
  r private.team_registration_requests%rowtype;
  partner_email text;
  new_team_id uuid;
  target_rank integer;
  combined_dupr numeric;
  team_is_nr boolean;
begin
  if auth.uid() is null then
    raise exception 'Sign in before responding';
  end if;

  select lower(email) into partner_email from auth.users
  where id = auth.uid() and email_confirmed_at is not null;
  select * into r from private.team_registration_requests
  where id = requested_request_id for update;

  if not found or partner_email is null
     or r.partner_email <> partner_email
     or r.captain_id = auth.uid() then
    raise exception 'Team request not found';
  end if;

  if r.status <> 'pending' then
    raise exception 'This team request is already closed';
  end if;

  if not coalesce(requested_accept, false) then
    update private.team_registration_requests
    set status = 'declined', decided_at = now()
    where id = r.id;
    return null;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('pilot-roster:' || r.ladder));

  if exists (
    select 1 from private.team_members m
    where m.ladder = r.ladder
      and (m.user_id in (r.captain_id, auth.uid())
           or lower(m.email) in (r.captain_email, r.partner_email))
  ) then
    raise exception 'One of these players is already on a team in this ladder';
  end if;

  if exists (
    select 1 from public.ladder_teams t
    where t.ladder = r.ladder and lower(t.name) = lower(r.team_name)
  ) then
    raise exception 'That team name is already used in this ladder';
  end if;

  team_is_nr := r.captain_is_nr or r.partner_is_nr;
  combined_dupr := case when team_is_nr then null
    else pg_catalog.round(r.captain_dupr + r.partner_dupr, 2) end;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('ladder:pilot:' || r.ladder));

  if not team_is_nr then
    select t.rank_position into target_rank
    from public.ladder_teams t
    where t.ladder = r.ladder and t.rank_position >= 11
      and (t.is_nr = true or t.dupr is null or t.dupr < combined_dupr)
    order by t.rank_position limit 1;
  end if;

  if target_rank is null then
    select coalesce(max(t.rank_position), 0) + 1 into target_rank
    from public.ladder_teams t where t.ladder = r.ladder;
  end if;

  update public.ladder_teams
  set rank_position = rank_position + 1, updated_at = now()
  where ladder = r.ladder and rank_position >= target_rank;

  insert into public.ladder_teams (ladder, rank_position, name, players, dupr, is_nr)
  values (r.ladder, target_rank, r.team_name,
          r.captain_name || ' / ' || r.partner_name, combined_dupr, team_is_nr)
  returning id into new_team_id;

  insert into private.team_members (team_id, ladder, user_id, email)
  values (new_team_id, r.ladder, r.captain_id, r.captain_email),
         (new_team_id, r.ladder, auth.uid(), r.partner_email);

  update private.team_registration_requests
  set status = 'accepted', decided_at = now(), created_team_id = new_team_id
  where id = r.id;

  -- Other outstanding invitations involving either player can no longer be accepted.
  update private.team_registration_requests
  set status = 'declined', decided_at = now()
  where id <> r.id and ladder = r.ladder and status = 'pending'
    and (captain_id in (r.captain_id, auth.uid())
         or partner_email in (r.captain_email, r.partner_email));

  return new_team_id;
end;
$function$;

create or replace function public.cancel_pilot_team_request_secure(requested_request_id uuid)
returns void language plpgsql security definer set search_path to ''
as $function$
begin
  update private.team_registration_requests
  set status = 'declined', decided_at = now()
  where id = requested_request_id and captain_id = auth.uid() and status = 'pending';
  if not found then
    raise exception 'Pending team request not found';
  end if;
end;
$function$;

revoke all on function public.request_pilot_team_secure(text,text,text,numeric,boolean,text,numeric,boolean,text) from public, anon;
revoke all on function public.my_pilot_team_requests_secure() from public, anon;
revoke all on function public.respond_pilot_team_request_secure(uuid,boolean) from public, anon;
revoke all on function public.cancel_pilot_team_request_secure(uuid) from public, anon;
grant execute on function public.request_pilot_team_secure(text,text,text,numeric,boolean,text,numeric,boolean,text) to authenticated;
grant execute on function public.my_pilot_team_requests_secure() to authenticated;
grant execute on function public.respond_pilot_team_request_secure(uuid,boolean) to authenticated;
grant execute on function public.cancel_pilot_team_request_secure(uuid) to authenticated;

commit;
