-- DRAFT: New club-scoped admin roster reader. Original zero-argument
-- function remains restricted to the platform app administrator.
create or replace function public.admin_get_team_members_secure(requested_club_id uuid)
returns table(team_id uuid, email text)
language plpgsql stable security definer set search_path to ''
as $function$
begin
  if requested_club_id is null
     or auth.uid() is null
     or not coalesce(public.is_ladder_club_admin(requested_club_id), false) then
    raise exception 'Club administrator access required';
  end if;
  return query
    select m.team_id, m.email
    from private.team_members m
    where m.club_id = requested_club_id
    order by m.team_id, m.email;
end;
$function$;

revoke all on function public.admin_get_team_members_secure(uuid) from public;
grant execute on function public.admin_get_team_members_secure(uuid) to authenticated;
