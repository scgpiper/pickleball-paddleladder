-- Read-only inventory for the multi-club migration.
-- Run in Supabase SQL Editor with "No limit", then export the result as CSV.
-- This reads definitions and permissions only. It does not read team, user, or match records.
with app_tables as (
  select c.oid, n.nspname as schema_name, c.relname as table_name,
         c.relrowsecurity, c.relforcerowsecurity
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('public','private')
    and c.relkind in ('r','p')
    and not exists (
      select 1 from pg_depend d
      where d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype = 'e'
    )
), inventory as (
  select '01 table / RLS' as category,
         format('%I.%I',t.schema_name,t.table_name) as object_name,
         format('rls_enabled=%s; rls_forced=%s',t.relrowsecurity,t.relforcerowsecurity) as definition
  from app_tables t

  union all
  select '02 column', format('%I.%I.%I',t.schema_name,t.table_name,a.attname),
         format('%s; nullable=%s; default=%s',
           format_type(a.atttypid,a.atttypmod),not a.attnotnull,
           coalesce(pg_get_expr(d.adbin,d.adrelid),'(none)'))
  from app_tables t
  join pg_attribute a on a.attrelid = t.oid and a.attnum > 0 and not a.attisdropped
  left join pg_attrdef d on d.adrelid = t.oid and d.adnum = a.attnum

  union all
  select '03 constraint',format('%I.%I.%I',t.schema_name,t.table_name,k.conname),
         pg_get_constraintdef(k.oid,true)
  from app_tables t join pg_constraint k on k.conrelid = t.oid

  union all
  select '04 index',format('%I.%I.%I',t.schema_name,t.table_name,i.relname),
         pg_get_indexdef(i.oid)
  from app_tables t
  join pg_index x on x.indrelid = t.oid
  join pg_class i on i.oid = x.indexrelid

  union all
  select '05 policy',format('%I.%I.%I',p.schemaname,p.tablename,p.policyname),
         format('AS %s FOR %s TO %s USING (%s) WITH CHECK (%s)',
           p.permissive,p.cmd,array_to_string(p.roles,','),
           coalesce(p.qual,'(none)'),coalesce(p.with_check,'(none)'))
  from pg_policies p
  join app_tables t on t.schema_name = p.schemaname and t.table_name = p.tablename

  union all
  select '06 trigger',format('%I.%I.%I',t.schema_name,t.table_name,g.tgname),
         pg_get_triggerdef(g.oid,true)
  from app_tables t
  join pg_trigger g on g.tgrelid = t.oid and not g.tgisinternal

  union all
  select '07 function',
         format('%I.%I(%s)',n.nspname,p.proname,pg_get_function_identity_arguments(p.oid)),
         pg_get_functiondef(p.oid)
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public','private') and p.prokind in ('f','p')
    and not exists (
      select 1 from pg_depend d
      where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e'
    )
)
select category, object_name, definition
from inventory
order by category, object_name;
