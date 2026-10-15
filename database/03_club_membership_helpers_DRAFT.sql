-- STAGE 2 DRAFT: club membership and per-club admin helpers.
-- Run only after Stage 1 and after checking the existing club membership
-- policies and complete live RPC rewrites. No production execution yet.
begin;

create or replace function public.is_ladder_club_admin(requested_club_id uuid)
returns boolean
language sql stable security definer set search_path to ''
as $function$
  select auth.uid() is not null
    and (public.is_app_admin() or public.is_club_admin(requested_club_id));
$function$;

-- A signed-in player chooses a club via its own active club page.
-- This grants only "member", never admin. Existing inactive accounts
-- cannot reactivate themselves.
create or replace function public.join_ladder_club_secure(requested_slug text)
returns uuid
language plpgsql security definer set search_path to ''
as $function$
declare
  selected_club_id uuid;
  existing_status text;
begin
  if auth.uid() is null then
    raise exception 'Sign in to join a club.';
  end if;
  select id into selected_club_id
  from public.clubs
  where slug = lower(pg_catalog.btrim(coalesce(requested_slug, '')))
    and active = true;
  if selected_club_id is null then
    raise exception 'Club not found.';
  end if;
  insert into public.club_memberships (club_id, user_id, role, status)
  values (selected_club_id, auth.uid(), 'member', 'active')
  on conflict (club_id, user_id) do nothing;

  select status into existing_status
  from public.club_memberships
  where club_id = selected_club_id and user_id = auth.uid();
  if existing_status <> 'active' then
    raise exception 'This club membership requires administrator review.';
  end if;
  return selected_club_id;
end;
$function$;

revoke all on function public.join_ladder_club_secure(text) from public;
grant execute on function public.join_ladder_club_secure(text) to authenticated;
revoke all on function public.is_ladder_club_admin(uuid) from public;
grant execute on function public.is_ladder_club_admin(uuid) to authenticated;

commit;
