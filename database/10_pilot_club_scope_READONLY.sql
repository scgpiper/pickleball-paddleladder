-- Run in Supabase SQL Editor. This reads club associations and table constraints.
-- One result table; no data or schema changes.
with findings as (
  select '01 column' as category,
         table_schema || '.' || table_name || '.' || column_name as item,
         data_type || '; nullable=' || is_nullable ||
           '; default=' || coalesce(column_default, '(none)') as details
  from information_schema.columns
  where table_schema in ('public', 'private')
    and table_name in ('ladder_teams', 'team_members')
    and column_name = 'club_id'

  union all

  select '02 club association', 'public.ladder_teams',
         format('rows=%s; club_id null=%s; distinct clubs=%s',
           count(*), count(*) filter (where club_id is null), count(distinct club_id))
  from public.ladder_teams

  union all

  select '02 club association', 'private.team_members',
         format('rows=%s; club_id null=%s; distinct clubs=%s',
           count(*), count(*) filter (where club_id is null), count(distinct club_id))
  from private.team_members

  union all

  select '02 club association', 'team/member club_id mismatches', count(*)::text
  from private.team_members m
  join public.ladder_teams t on t.id = m.team_id
  where m.club_id is distinct from t.club_id

  union all

  select '02 club association', 'public.clubs',
         format('rows=%s; active=%s', count(*), count(*) filter (where active))
  from public.clubs

  union all

  select '03 constraint', n.nspname || '.' || t.relname || '.' || c.conname,
         pg_get_constraintdef(c.oid)
  from pg_constraint c
  join pg_class t on t.oid = c.conrelid
  join pg_namespace n on n.oid = t.relnamespace
  where (n.nspname = 'public' and t.relname = 'ladder_teams')
     or (n.nspname = 'private' and t.relname = 'team_members')
)
select category, item, details from findings order by category, item;
