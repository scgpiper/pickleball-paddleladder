-- Stage 1: run in the pilot database, then in production.
-- This creates the private list only. It does not change signup yet.
-- Club staff can add approved emails one at a time through the Supabase SQL
-- editor. A full import of both lists is optional when it becomes available.
-- Never commit actual player emails to the repository.
begin;

create table if not exists private.club_signup_eligibility (
  club_id uuid not null references public.clubs(id) on delete cascade,
  email text not null,
  list_type text not null check (list_type in ('member', 'non_member')),
  added_at timestamptz not null default now(),
  primary key (club_id, email),
  check (email = lower(btrim(email)) and email ~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$')
);

alter table private.club_signup_eligibility enable row level security;
revoke all on private.club_signup_eligibility from public, anon, authenticated;

commit;

-- Example approval, run privately in the SQL editor after the club checks an
-- applicant's email and waiver status. Use 'member' or 'non_member'.
-- insert into private.club_signup_eligibility (club_id, email, list_type)
-- select id, lower(btrim('player@example.com')), 'member'
-- from public.clubs where active = true
-- on conflict (club_id, email) do update set list_type = excluded.list_type;
