-- DRAFT. Run only in the isolated PaddleLadder Pilot Test project after 13 and 14.
-- Adds one invented club. No production names, people or standings are copied.
begin;

do $block$
begin
  if exists (select 1 from public.clubs) then
    raise exception 'Pilot test club seed requires an empty clubs table';
  end if;
end;
$block$;

insert into public.clubs (name, slug, active)
values ('PaddleLadder Test Club', 'paddleladder-test', true);

commit;
