-- Run only in PaddleLadder Pilot Test after scripts 13, 14, 15 and 09.
-- Read-only setup check; no account or production data is returned.
select 'app tables' as check_name,
       count(*)::text as found,
       '21 (20 baseline + registration requests)' as expected
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname in ('public','private') and c.relkind in ('r','p')

union all
select 'app functions', count(*)::text, '43 (38 baseline + 5 registration)'
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname in ('public','private')
  and not exists (
    select 1 from pg_depend d
    where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e'
  )

union all
select 'active test clubs', count(*)::text, '1'
from public.clubs where active = true

union all
select 'registration requests table', count(*)::text, '1'
from information_schema.tables
where table_schema = 'private' and table_name = 'team_registration_requests'

union all
select 'original ladder teams', count(*)::text, '0'
from public.ladder_teams

order by check_name;
