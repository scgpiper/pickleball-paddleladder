-- Run in the EXISTING PaddleLadder project, then export the result as CSV.
-- Reads structure only: table columns, constraints, indexes, RLS, and policies.
-- It does not read player rows, auth users, passwords, or secrets.
with objects as (
  select '01 table' as category,
         n.nspname || '.' || c.relname as item,
         jsonb_build_object('rls', c.relrowsecurity, 'force_rls', c.relforcerowsecurity)::text as definition
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('public', 'private') and c.relkind in ('r', 'p')

  union all

  select '02 column', table_schema || '.' || table_name || '.' || column_name,
         jsonb_build_object('type', data_type, 'udt_schema', udt_schema,
           'udt_name', udt_name, 'max_length', character_maximum_length,
           'nullable', is_nullable, 'default', column_default,
           'identity', is_identity, 'generated', is_generated,
           'generation_expression', generation_expression,
           'ordinal', ordinal_position)::text
  from information_schema.columns
  where table_schema in ('public', 'private')

  union all

  select '03 constraint', n.nspname || '.' || t.relname || '.' || c.conname,
         pg_get_constraintdef(c.oid)
  from pg_constraint c
  join pg_class t on t.oid = c.conrelid
  join pg_namespace n on n.oid = t.relnamespace
  where n.nspname in ('public', 'private')

  union all

  select '04 index', n.nspname || '.' || t.relname || '.' || i.relname,
         pg_get_indexdef(i.oid)
  from pg_index x
  join pg_class t on t.oid = x.indrelid
  join pg_namespace n on n.oid = t.relnamespace
  join pg_class i on i.oid = x.indexrelid
  where n.nspname in ('public', 'private')

  union all

  select '05 policy', schemaname || '.' || tablename || '.' || policyname,
         jsonb_build_object('cmd', cmd, 'roles', roles, 'permissive', permissive,
           'using', qual, 'check', with_check)::text
  from pg_policies
  where schemaname in ('public', 'private')
)
select category,
       jsonb_agg(jsonb_build_object('item', item, 'definition', definition)
                 order by item)::text as details
from objects
group by category
order by category;
