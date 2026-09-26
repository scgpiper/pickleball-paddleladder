-- Run in the ORIGINAL Pickleball PaddleLadder project, not PaddleLadder Pilot Test.
-- Read-only inventory of application routines, triggers, and API-role privileges.
-- This reads definitions and grants; it does not read table rows or change anything.

with findings as (
  select '01 routine' as category,
         n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as item,
         pg_get_functiondef(p.oid) as definition
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private')
     and not exists (
       select 1 from pg_depend d
        where d.classid = 'pg_proc'::regclass
          and d.objid = p.oid and d.deptype = 'e'
     )

  union all

  select '02 trigger', n.nspname || '.' || c.relname || '.' || t.tgname,
         pg_get_triggerdef(t.oid, true)
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in ('public', 'private') and not t.tgisinternal

  union all

  select '03 table privilege', table_schema || '.' || table_name || '.' || grantee || '.' || privilege_type,
         'is_grantable=' || is_grantable
    from information_schema.role_table_grants
   where table_schema in ('public', 'private')
     and grantee in ('anon', 'authenticated', 'service_role')

  union all

  select '04 routine privilege', n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
         jsonb_build_object('owner', pg_get_userbyid(p.proowner),
                            'acl', coalesce(p.proacl::text, '(default)'))::text
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private')
     and not exists (
       select 1 from pg_depend d
        where d.classid = 'pg_proc'::regclass
          and d.objid = p.oid and d.deptype = 'e'
     )
)
select category, jsonb_agg(jsonb_build_object('item', item, 'definition', definition)
                           order by item) as details
  from findings
 group by category
 order by category;
