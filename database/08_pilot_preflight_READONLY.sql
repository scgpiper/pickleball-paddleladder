-- Run once in Supabase SQL Editor. All findings appear in ONE results table.
-- This only reads schema definitions and duplicate counts; it changes nothing.
with findings as (
  select '01 column' as category,
         table_schema || '.' || table_name || '.' || column_name as item,
         data_type || '; nullable=' || is_nullable ||
           '; default=' || coalesce(column_default, '(none)') as details
  from information_schema.columns
  where (table_schema = 'public' and table_name = 'ladder_teams'
         and column_name in ('id','ladder','rank_position','name','players','dupr','is_nr','updated_at'))
     or (table_schema = 'private' and table_name = 'team_members'
         and column_name in ('id','team_id','ladder','user_id','email','club_id'))

  union all

  select '02 index', n.nspname || '.' || t.relname || '.' || i.relname,
         pg_get_indexdef(i.oid)
  from pg_index x
  join pg_class t on t.oid = x.indrelid
  join pg_namespace n on n.oid = t.relnamespace
  join pg_class i on i.oid = x.indexrelid
  where (n.nspname = 'public' and t.relname = 'ladder_teams')
     or (n.nspname = 'private' and t.relname = 'team_members')

  union all

  select '03 duplicate count', 'same email in the same ladder',
         count(*)::text
  from (
    select ladder, lower(email) from private.team_members
    group by ladder, lower(email) having count(*) > 1
  ) duplicates

  union all

  select '03 duplicate count', 'same account in the same ladder',
         count(*)::text
  from (
    select ladder, user_id from private.team_members where user_id is not null
    group by ladder, user_id having count(*) > 1
  ) duplicates
)
select category, item, details from findings order by category, item;
