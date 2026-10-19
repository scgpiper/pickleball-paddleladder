-- Phase 1: run in the PILOT database first, before deploying the client change.
-- A separate public projection preserves history without exposing private
-- decline/cancellation reasons or unconfirmed score submissions.
begin;

create table if not exists public.challenge_public_feed (
  id uuid primary key,
  club_id uuid,
  ladder text not null,
  challenger_team_id uuid,
  challenged_team_id uuid,
  status text not null,
  winner_team_id uuid,
  forfeit boolean not null,
  created_at timestamptz not null,
  accepted_at timestamptz,
  play_by timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  declined_at timestamptz,
  disputed_at timestamptz
);

alter table public.challenge_public_feed enable row level security;
revoke all on public.challenge_public_feed from public, anon, authenticated;
grant select on public.challenge_public_feed to anon, authenticated;

drop policy if exists challenge_public_feed_read on public.challenge_public_feed;
create policy challenge_public_feed_read on public.challenge_public_feed
  for select to anon, authenticated using (true);

create or replace function private.sync_challenge_public_feed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if tg_op = 'DELETE' then
    delete from public.challenge_public_feed where id = old.id;
    return old;
  end if;

  insert into public.challenge_public_feed (
    id, club_id, ladder, challenger_team_id, challenged_team_id,
    status, winner_team_id, forfeit, created_at, accepted_at, play_by,
    completed_at, cancelled_at, declined_at, disputed_at
  ) values (
    new.id, new.club_id, new.ladder, new.challenger_team_id,
    new.challenged_team_id, new.status, new.winner_team_id, new.forfeit,
    new.created_at, new.accepted_at, new.play_by, new.completed_at,
    new.cancelled_at, new.declined_at, new.disputed_at
  ) on conflict (id) do update set
    club_id = excluded.club_id,
    ladder = excluded.ladder,
    challenger_team_id = excluded.challenger_team_id,
    challenged_team_id = excluded.challenged_team_id,
    status = excluded.status,
    winner_team_id = excluded.winner_team_id,
    forfeit = excluded.forfeit,
    created_at = excluded.created_at,
    accepted_at = excluded.accepted_at,
    play_by = excluded.play_by,
    completed_at = excluded.completed_at,
    cancelled_at = excluded.cancelled_at,
    declined_at = excluded.declined_at,
    disputed_at = excluded.disputed_at;
  return new;
end;
$function$;

revoke all on function private.sync_challenge_public_feed() from public, anon, authenticated;

drop trigger if exists sync_challenge_public_feed on public.challenges;
create trigger sync_challenge_public_feed
after insert or update or delete on public.challenges
for each row execute function private.sync_challenge_public_feed();

insert into public.challenge_public_feed (
  id, club_id, ladder, challenger_team_id, challenged_team_id,
  status, winner_team_id, forfeit, created_at, accepted_at, play_by,
  completed_at, cancelled_at, declined_at, disputed_at
)
select id, club_id, ladder, challenger_team_id, challenged_team_id,
       status, winner_team_id, forfeit, created_at, accepted_at, play_by,
       completed_at, cancelled_at, declined_at, disputed_at
from public.challenges
on conflict (id) do update set
  club_id = excluded.club_id,
  ladder = excluded.ladder,
  challenger_team_id = excluded.challenger_team_id,
  challenged_team_id = excluded.challenged_team_id,
  status = excluded.status,
  winner_team_id = excluded.winner_team_id,
  forfeit = excluded.forfeit,
  created_at = excluded.created_at,
  accepted_at = excluded.accepted_at,
  play_by = excluded.play_by,
  completed_at = excluded.completed_at,
  cancelled_at = excluded.cancelled_at,
  declined_at = excluded.declined_at,
  disputed_at = excluded.disputed_at;

commit;

select (select count(*) from public.challenges) as challenge_rows,
       (select count(*) from public.challenge_public_feed) as public_feed_rows;
