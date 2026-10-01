-- Apply to the main Supabase project before enabling the challenge webhook.
create table if not exists public.challenge_email_notices (
  challenge_id uuid not null references public.challenges(id) on delete cascade,
  email text not null,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  primary key (challenge_id, email)
);

alter table public.challenge_email_notices enable row level security;
revoke all on public.challenge_email_notices from anon, authenticated;
grant all on public.challenge_email_notices to service_role;
