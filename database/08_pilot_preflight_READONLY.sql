-- Run in Supabase SQL Editor against the existing one-club project.
-- Read-only: compare these definitions with the draft migration before applying it.

select table_schema, table_name, column_name, data_type, is_nullable, column_default
from information_schema.columns
where (table_schema = 'public' and table_name = 'ladder_teams'
       and column_name in ('id','ladder','rank_position','name','players','dupr','is_nr','updated_at'))
   or (table_schema = 'private' and table_name = 'team_members'
       and column_name in ('id','team_id','ladder','user_id','email','club_id'))
order by table_schema, table_name, ordinal_position;

select n.nspname as schema_name, t.relname as table_name,
       i.relname as index_name, pg_get_indexdef(i.oid) as definition
from pg_index x
join pg_class t on t.oid = x.indrelid
join pg_namespace n on n.oid = t.relnamespace
join pg_class i on i.oid = x.indexrelid
where (n.nspname = 'public' and t.relname = 'ladder_teams')
   or (n.nspname = 'private' and t.relname = 'team_members')
order by schema_name, table_name, index_name;

select count(*) as duplicate_player_emails
from (
  select ladder, lower(email) from private.team_members
  group by ladder, lower(email) having count(*) > 1
) duplicates;

select count(*) as duplicate_player_accounts
from (
  select ladder, user_id from private.team_members where user_id is not null
  group by ladder, user_id having count(*) > 1
) duplicates;
