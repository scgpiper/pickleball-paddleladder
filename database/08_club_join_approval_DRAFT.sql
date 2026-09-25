-- DRAFT ONLY. Do not run against production without inspecting existing
-- clubs, club_memberships, roles, grants and policies, then testing in staging.
-- Verified against read-only live schema inspection on 2026-09-24:
-- clubs(id, name, slug, active), club_memberships(club_id, user_id, role,
-- status) with unique (club_id, user_id); status is active/invited/inactive.
-- Existing is_club_admin requires active admin/owner membership; is_app_admin
-- checks private.app_admins. Verify grants, ownership and staging behavior
-- separately. This is not the complete multi-club rollout.
begin;

create table if not exists public.club_join_requests (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references public.clubs(id),
  user_id uuid not null references auth.users(id),
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected')),
  requested_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id),
  unique (club_id, user_id)
);

alter table public.club_join_requests enable row level security;
revoke all on public.club_join_requests from public, anon, authenticated;

-- Access to request records goes only through checked functions. The table
-- owner of these SECURITY DEFINER functions must be able to access the table.
create or replace function public.request_ladder_club_secure(requested_slug text)
returns text
language plpgsql security definer set search_path to ''
as $function$
declare
  selected_club_id uuid;
  current_status text;
begin
  if auth.uid() is null then
    raise exception 'Sign in to request club access.';
  end if;

  select id into selected_club_id
  from public.clubs
  where slug = lower(pg_catalog.btrim(coalesce(requested_slug, '')))
    and active = true;
  if selected_club_id is null then
    raise exception 'Club not found.';
  end if;

  select status into current_status
  from public.club_memberships
  where club_id = selected_club_id and user_id = auth.uid();
  if current_status = 'active' then
    return 'approved';
  end if;
  if current_status is not null then
    raise exception 'Your existing club account needs administrator review.';
  end if;

  insert into public.club_join_requests (club_id, user_id)
  values (selected_club_id, auth.uid())
  on conflict (club_id, user_id) do update
    set status = 'pending',
        requested_at = now(),
        reviewed_at = null,
        reviewed_by = null
    where club_join_requests.status = 'rejected';

  select status into current_status
  from public.club_join_requests
  where club_id = selected_club_id and user_id = auth.uid();
  if current_status <> 'pending' then
    raise exception 'This request needs administrator review.';
  end if;

  return 'pending';
end;
$function$;

create or replace function public.review_ladder_club_request_secure(
  requested_request_id uuid, requested_approve boolean
)
returns text
language plpgsql security definer set search_path to ''
as $function$
declare
  request_row public.club_join_requests%rowtype;
begin
  if auth.uid() is null or requested_approve is null then
    raise exception 'Administrator decision required.';
  end if;

  select * into request_row
  from public.club_join_requests
  where id = requested_request_id
  for update;
  if not found or request_row.status <> 'pending' then
    raise exception 'Pending request not found.';
  end if;
  if not (
    coalesce(public.is_club_admin(request_row.club_id), false)
    or coalesce(public.is_app_admin(), false)
  ) then
    raise exception 'Club administrator access required.';
  end if;

  if requested_approve then
    -- A pre-existing disabled or special-role membership needs manual review.
    -- Never overwrite its status or role through this request flow.
    insert into public.club_memberships (club_id, user_id, role, status)
    values (request_row.club_id, request_row.user_id, 'member', 'active')
    on conflict (club_id, user_id) do nothing;

    if not exists (
      select 1 from public.club_memberships
      where club_id = request_row.club_id
        and user_id = request_row.user_id
        and status = 'active'
    ) then
      raise exception 'Existing membership requires separate review.';
    end if;
  end if;

  update public.club_join_requests
  set status = case when requested_approve then 'approved' else 'rejected' end,
      reviewed_at = now(),
      reviewed_by = auth.uid()
  where id = request_row.id;

  return case when requested_approve then 'approved' else 'rejected' end;
end;
$function$;

create or replace function public.my_ladder_club_requests_secure()
returns table(club_id uuid, club_name text, status text, requested_at timestamptz)
language plpgsql stable security definer set search_path to ''
as $function$
begin
  if auth.uid() is null then
    raise exception 'Sign in to see your requests.';
  end if;
  return query
    select r.club_id, c.name::text, r.status, r.requested_at
    from public.club_join_requests r
    join public.clubs c on c.id = r.club_id
    where r.user_id = auth.uid()
    order by r.requested_at desc;
end;
$function$;

create or replace function public.pending_ladder_club_requests_secure(
  requested_club_id uuid
)
returns table(request_id uuid, applicant_email text, requested_at timestamptz)
language plpgsql stable security definer set search_path to ''
as $function$
begin
  if auth.uid() is null or requested_club_id is null or not (
    coalesce(public.is_club_admin(requested_club_id), false)
    or coalesce(public.is_app_admin(), false)
  ) then
    raise exception 'Club administrator access required.';
  end if;
  return query
    select r.id, u.email::text, r.requested_at
    from public.club_join_requests r
    join auth.users u on u.id = r.user_id
    where r.club_id = requested_club_id and r.status = 'pending'
    order by r.requested_at;
end;
$function$;

revoke all on function public.request_ladder_club_secure(text) from public, anon;
grant execute on function public.request_ladder_club_secure(text) to authenticated;
revoke all on function public.review_ladder_club_request_secure(uuid, boolean)
  from public, anon;
grant execute on function public.review_ladder_club_request_secure(uuid, boolean)
  to authenticated;
revoke all on function public.my_ladder_club_requests_secure() from public, anon;
grant execute on function public.my_ladder_club_requests_secure() to authenticated;
revoke all on function public.pending_ladder_club_requests_secure(uuid)
  from public, anon;
grant execute on function public.pending_ladder_club_requests_secure(uuid)
  to authenticated;

commit;

-- Remaining work: request/approval UI; group visibility flag and safe public
-- standings projection; RLS/RPC rewrites and cross-club integration tests.
