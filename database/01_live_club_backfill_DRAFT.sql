-- STAGE 1 ONLY. Prepared against the 2026-09-23 schema inventory.
-- Adds club ownership to the live ladder tables while retaining VPA defaults
-- for existing RPCs. Do not run this by itself: finish and verify the
-- club-aware RPC/RLS migration before admitting a second club.
-- Run against a staging database first; this transaction changes live data.
begin;

do $migration$
declare
  vpa_id uuid;
  relation_name text;
begin
  select id into vpa_id from public.clubs where lower(slug) = 'vpa';
  if vpa_id is null then
    insert into public.clubs (slug, name, active)
    values ('vpa', 'VPA', true) returning id into vpa_id;
  end if;

  -- The current app uses these five tables and private.team_members.
  alter table public.ladder_teams add column if not exists club_id uuid;
  alter table public.challenges add column if not exists club_id uuid;
  alter table public.ladder_movements add column if not exists club_id uuid;
  alter table public.partner_listings add column if not exists club_id uuid;
  alter table public.partner_invites add column if not exists club_id uuid;
  alter table private.team_members add column if not exists club_id uuid;

  -- Existing live data belongs to VPA. Prefer the parent row where possible.
  update public.ladder_teams set club_id = vpa_id where club_id is null;
  update public.partner_listings set club_id = vpa_id where club_id is null;

  update public.challenges c
     set club_id = coalesce(
       (select t.club_id from public.ladder_teams t
        where t.id = c.challenger_team_id),
       (select t.club_id from public.ladder_teams t
        where t.id = c.challenged_team_id), vpa_id)
   where c.club_id is null;
  update public.ladder_movements m
     set club_id = coalesce(
       (select t.club_id from public.ladder_teams t where t.id = m.team_id),
       vpa_id)
   where m.club_id is null;
  update public.partner_invites i
     set club_id = coalesce(
       (select l.club_id from public.partner_listings l where l.id = i.listing_id),
       vpa_id)
   where i.club_id is null;
  update private.team_members m
     set club_id = (select t.club_id from public.ladder_teams t
                    where t.id = m.team_id)
   where m.club_id is null;

  if exists (
    select 1 from public.challenges c
    join public.ladder_teams t on t.id in (
      c.challenger_team_id, c.challenged_team_id,
      c.winner_team_id, c.forfeited_by_team_id, c.submitted_by_team_id)
    where t.club_id is distinct from c.club_id
  ) or exists (
    select 1 from public.ladder_movements m join public.ladder_teams t
      on t.id = m.team_id where t.club_id is distinct from m.club_id
  ) or exists (
    select 1 from public.partner_invites i join public.partner_listings l
      on l.id = i.listing_id where l.club_id is distinct from i.club_id
  ) or exists (
    select 1 from private.team_members m join public.ladder_teams t
      on t.id = m.team_id where t.club_id is distinct from m.club_id
  ) then
    raise exception 'Existing rows connect different clubs; inspect before migrating';
  end if;

  foreach relation_name in array array[
    'public.ladder_teams', 'public.challenges',
    'public.ladder_movements', 'public.partner_listings',
    'public.partner_invites', 'private.team_members'
  ] loop
    execute format('alter table %s alter column club_id set not null',relation_name);
    -- Legacy VPA functions omit club_id. This temporary default keeps VPA
    -- behavior during rollout; remove it when every RPC requires club context.
    execute format('alter table %s alter column club_id set default %L::uuid',
                   relation_name,vpa_id);
    if not exists (
      select 1 from pg_catalog.pg_constraint
      where conrelid = relation_name::regclass
        and conname = replace(relation_name,'.','_') || '_club_id_fkey'
    ) then
      execute format(
        'alter table %s add constraint %I foreign key (club_id) references public.clubs(id)',
        relation_name, replace(relation_name,'.','_') || '_club_id_fkey'
      );
    end if;
  end loop;
end;
$migration$;

create index if not exists ladder_teams_club_ladder_rank_idx
  on public.ladder_teams(club_id, ladder, rank_position);
create index if not exists challenges_club_ladder_created_idx
  on public.challenges(club_id, ladder, created_at desc);
create index if not exists ladder_movements_club_ladder_idx
  on public.ladder_movements(club_id, ladder, created_at desc);
create index if not exists partner_listings_club_ladder_status_idx
  on public.partner_listings(club_id, ladder, status);
create index if not exists partner_invites_club_ladder_idx
  on public.partner_invites(club_id, ladder, created_at desc);
create index if not exists private_team_members_club_ladder_idx
  on private.team_members(club_id, ladder);

commit;
