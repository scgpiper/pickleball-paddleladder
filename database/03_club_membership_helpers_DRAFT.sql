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

-- The old self-join helper must fail closed. Registration is a request,
-- reviewed by the requested club's administrator in stage 08.
create or replace function public.join_ladder_club_secure(requested_slug text)
returns uuid
language plpgsql security definer set search_path to ''
as $function$
begin
  raise exception 'Club registration requires administrator approval. Use the membership request flow.';
end;
$function$;

revoke all on function public.join_ladder_club_secure(text) from public;
revoke all on function public.join_ladder_club_secure(text) from anon, authenticated;
revoke all on function public.is_ladder_club_admin(uuid) from public;
grant execute on function public.is_ladder_club_admin(uuid) to authenticated;

commit;
