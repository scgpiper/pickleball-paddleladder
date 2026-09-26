-- DRAFT. Run only in the isolated PaddleLadder Pilot Test project.
-- Generated from the September 25 production metadata inventory; no production rows are copied.
-- This builds table shapes, keys, checks and indexes. RPCs, policies, grants, and test data follow separately.
-- Do not run against the original Pickleball PaddleLadder project.
begin;
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
set local search_path = public, private, auth, pg_catalog;

create table private.app_admins (
  user_id uuid not null,
  created_at timestamp with time zone not null default now()
);

create table private.ladder_state_backup_20260922 (
  id integer,
  teams jsonb,
  pending_challenges jsonb,
  challenge_history jsonb,
  match_history jsonb,
  partner_listings jsonb,
  partner_invites jsonb,
  ladder_movement_history jsonb,
  version bigint,
  updated_at timestamp with time zone
);

create table private.team_members (
  team_id uuid not null,
  user_id uuid,
  email text not null,
  created_at timestamp with time zone not null default now(),
  ladder text not null,
  club_id uuid
);

create table public.audit_log (
  id uuid not null default gen_random_uuid(),
  club_id uuid,
  actor_user_id uuid,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamp with time zone not null default now()
);

create table public.challenges (
  id uuid not null default gen_random_uuid(),
  ladder text not null,
  challenger_team_id uuid,
  challenged_team_id uuid,
  challenger_name text not null,
  challenged_name text not null,
  status text not null default 'Pending'::text,
  scores jsonb,
  submitted_by_team_id uuid,
  winner_team_id uuid,
  winner_name text,
  decline_reason text,
  cancel_reason text,
  forfeit boolean not null default false,
  forfeited_by_team_id uuid,
  created_at timestamp with time zone not null default now(),
  accepted_at timestamp with time zone,
  declined_at timestamp with time zone,
  disputed_at timestamp with time zone,
  cancelled_at timestamp with time zone,
  completed_at timestamp with time zone,
  updated_at timestamp with time zone not null default now(),
  play_by timestamp with time zone,
  overdue_at timestamp with time zone,
  decline_reviewed_at timestamp with time zone,
  club_id uuid
);

create table public.club_memberships (
  id uuid not null default gen_random_uuid(),
  club_id uuid not null,
  user_id uuid not null,
  role text not null default 'member'::text,
  status text not null default 'active'::text,
  created_at timestamp with time zone not null default now()
);

create table public.clubs (
  id uuid not null default gen_random_uuid(),
  name text not null,
  slug text not null,
  active boolean not null default true,
  created_at timestamp with time zone not null default now()
);

create table public.ladder_movements (
  id uuid not null default gen_random_uuid(),
  team_id uuid,
  team_name text not null,
  ladder text not null,
  from_rank integer not null,
  to_rank integer not null,
  reason text not null,
  created_at timestamp with time zone not null default now(),
  club_id uuid
);

create table public.ladder_state (
  id integer not null,
  teams jsonb not null default '[]'::jsonb,
  pending_challenges jsonb not null default '[]'::jsonb,
  challenge_history jsonb not null default '[]'::jsonb,
  match_history jsonb not null default '[]'::jsonb,
  partner_listings jsonb not null default '[]'::jsonb,
  partner_invites jsonb not null default '[]'::jsonb,
  ladder_movement_history jsonb not null default '[]'::jsonb,
  version bigint not null default 1,
  updated_at timestamp with time zone not null default now()
);

create table public.ladder_teams (
  id uuid not null default gen_random_uuid(),
  ladder text not null,
  rank_position integer not null,
  name text not null,
  players text not null,
  dupr numeric,
  is_nr boolean not null default false,
  wins integer not null default 0,
  losses integer not null default 0,
  away boolean not null default false,
  away_started_at timestamp with time zone,
  away_review_at timestamp with time zone,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  acceptance_period_started_at timestamp with time zone,
  accepted_in_period boolean not null default false,
  missed_periods integer not null default 0,
  club_id uuid
);

create table public.ladders (
  id uuid not null default gen_random_uuid(),
  club_id uuid not null,
  name text not null,
  code text not null,
  active boolean not null default true,
  split_enabled boolean not null default false,
  lower_division_min numeric not null default 5.000,
  lower_division_max numeric not null default 6.999,
  upper_division_min numeric not null default 7.000,
  upper_division_max numeric not null default 11.000,
  created_at timestamp with time zone not null default now()
);

create table public.leaderboard_view (
  ladder_id uuid,
  ladder_name text,
  ladder_code text,
  team_id uuid,
  rank integer,
  team_name text,
  player_1 text,
  player_2 text,
  player_1_dupr numeric,
  player_2_dupr numeric,
  current_combined_dupr numeric,
  entry_combined_dupr numeric,
  wins integer,
  losses integer,
  matches_played integer,
  status text
);

create table public.legacy_challenges (
  id uuid not null default gen_random_uuid(),
  ladder_id uuid not null,
  challenger_team_id uuid not null,
  challenged_team_id uuid not null,
  challenger_rank_at_issue integer not null,
  challenged_rank_at_issue integer not null,
  issued_by uuid,
  issued_at timestamp with time zone not null default now(),
  status text not null default 'pending'::text,
  accepted_at timestamp with time zone,
  play_by timestamp with time zone,
  completed_at timestamp with time zone,
  cancelled_at timestamp with time zone,
  created_at timestamp with time zone not null default now()
);

create table public.match_games (
  id uuid not null default gen_random_uuid(),
  match_id uuid not null,
  game_number smallint not null,
  challenger_score integer not null,
  challenged_score integer not null,
  created_at timestamp with time zone not null default now()
);

create table public.matches (
  id uuid not null default gen_random_uuid(),
  challenge_id uuid not null,
  ladder_id uuid not null,
  played_at timestamp with time zone,
  submitted_by uuid,
  status text not null default 'submitted'::text,
  winner_team_id uuid,
  loser_team_id uuid,
  confirmed_by uuid,
  confirmed_at timestamp with time zone,
  notes text,
  created_at timestamp with time zone not null default now()
);

create table public.partner_invites (
  id uuid not null default gen_random_uuid(),
  listing_id uuid,
  ladder text not null,
  sender_user_id uuid not null,
  recipient_user_id uuid not null,
  sender_name text not null,
  recipient_name text not null,
  sender_gender text not null,
  recipient_gender text not null,
  sender_dupr numeric,
  recipient_dupr numeric,
  sender_is_nr boolean not null default false,
  recipient_is_nr boolean not null default false,
  status text not null default 'Pending'::text,
  created_at timestamp with time zone not null default now(),
  accepted_at timestamp with time zone,
  declined_at timestamp with time zone,
  cancelled_at timestamp with time zone,
  club_id uuid
);

create table public.partner_listings (
  id uuid not null default gen_random_uuid(),
  owner_user_id uuid not null,
  name text not null,
  gender text not null,
  dupr numeric,
  is_nr boolean not null default false,
  ladder text not null,
  status text not null default 'Active'::text,
  created_at timestamp with time zone not null default now(),
  removed_at timestamp with time zone,
  updated_at timestamp with time zone not null default now(),
  club_id uuid
);

create table public.profiles (
  id uuid not null,
  display_name text not null default 'Member'::text,
  dupr numeric,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now()
);

create table public.ranking_history (
  id uuid not null default gen_random_uuid(),
  ladder_id uuid not null,
  team_id uuid not null,
  old_rank integer,
  new_rank integer,
  reason text not null,
  related_challenge_id uuid,
  related_match_id uuid,
  changed_by uuid,
  changed_at timestamp with time zone not null default now()
);

create table public.team_members (
  team_id uuid not null,
  user_id uuid not null,
  slot smallint not null,
  dupr_at_entry numeric,
  active boolean not null default true,
  joined_at timestamp with time zone not null default now()
);

create table public.teams (
  id uuid not null default gen_random_uuid(),
  ladder_id uuid not null,
  name text not null,
  rank integer not null,
  wins integer not null default 0,
  losses integer not null default 0,
  entry_combined_dupr numeric,
  status text not null default 'available'::text,
  created_by uuid,
  joined_at timestamp with time zone not null default now(),
  last_accepted_challenge_at timestamp with time zone,
  challenge_strikes integer not null default 0,
  inactive_since timestamp with time zone,
  inactive_drops integer not null default 0,
  created_at timestamp with time zone not null default now()
);

alter table private.app_admins add constraint app_admins_pkey PRIMARY KEY (user_id);
alter table private.team_members add constraint team_members_ladder_check CHECK ((ladder = ANY (ARRAY['mens'::text, 'womens'::text, 'mixed'::text])));
alter table private.team_members add constraint team_members_pkey PRIMARY KEY (team_id, email);
alter table public.audit_log add constraint audit_log_pkey PRIMARY KEY (id);
alter table public.challenges add constraint challenges_ladder_check CHECK ((ladder = ANY (ARRAY['mens'::text, 'womens'::text, 'mixed'::text])));
alter table public.challenges add constraint challenges_pkey1 PRIMARY KEY (id);
alter table public.club_memberships add constraint club_memberships_club_id_user_id_key UNIQUE (club_id, user_id);
alter table public.club_memberships add constraint club_memberships_pkey PRIMARY KEY (id);
alter table public.club_memberships add constraint membership_role_check CHECK ((role = ANY (ARRAY['member'::text, 'admin'::text, 'owner'::text])));
alter table public.club_memberships add constraint membership_status_check CHECK ((status = ANY (ARRAY['active'::text, 'invited'::text, 'inactive'::text])));
alter table public.clubs add constraint clubs_pkey PRIMARY KEY (id);
alter table public.clubs add constraint clubs_slug_key UNIQUE (slug);
alter table public.ladder_movements add constraint ladder_movements_ladder_check CHECK ((ladder = ANY (ARRAY['mens'::text, 'womens'::text, 'mixed'::text])));
alter table public.ladder_movements add constraint ladder_movements_pkey PRIMARY KEY (id);
alter table public.ladder_state add constraint ladder_state_id_check CHECK ((id = 1));
alter table public.ladder_state add constraint ladder_state_pkey PRIMARY KEY (id);
alter table public.ladder_teams add constraint ladder_teams_ladder_check CHECK ((ladder = ANY (ARRAY['mens'::text, 'womens'::text, 'mixed'::text])));
alter table public.ladder_teams add constraint ladder_teams_losses_check CHECK ((losses >= 0));
alter table public.ladder_teams add constraint ladder_teams_pkey PRIMARY KEY (id);
alter table public.ladder_teams add constraint ladder_teams_rank_position_check CHECK ((rank_position > 0));
alter table public.ladder_teams add constraint ladder_teams_wins_check CHECK ((wins >= 0));
alter table public.ladders add constraint ladders_club_id_code_key UNIQUE (club_id, code);
alter table public.ladders add constraint ladders_pkey PRIMARY KEY (id);
alter table public.legacy_challenges add constraint challenge_different_teams_check CHECK ((challenger_team_id <> challenged_team_id));
alter table public.legacy_challenges add constraint challenge_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'accepted'::text, 'declined'::text, 'cancelled'::text, 'score_submitted'::text, 'completed'::text, 'disputed'::text, 'forfeit'::text])));
alter table public.legacy_challenges add constraint challenges_pkey PRIMARY KEY (id);
alter table public.match_games add constraint game_number_check CHECK (((game_number >= 1) AND (game_number <= 3)));
alter table public.match_games add constraint game_score_check CHECK (((challenger_score >= 0) AND (challenged_score >= 0) AND (GREATEST(challenger_score, challenged_score) >= 11) AND (abs((challenger_score - challenged_score)) >= 2)));
alter table public.match_games add constraint match_games_match_id_game_number_key UNIQUE (match_id, game_number);
alter table public.match_games add constraint match_games_pkey PRIMARY KEY (id);
alter table public.matches add constraint match_status_check CHECK ((status = ANY (ARRAY['submitted'::text, 'confirmed'::text, 'disputed'::text, 'forfeit'::text, 'cancelled'::text])));
alter table public.matches add constraint match_winner_loser_check CHECK (((winner_team_id IS NULL) OR (loser_team_id IS NULL) OR (winner_team_id <> loser_team_id)));
alter table public.matches add constraint matches_challenge_id_key UNIQUE (challenge_id);
alter table public.matches add constraint matches_pkey PRIMARY KEY (id);
alter table public.partner_invites add constraint partner_invites_ladder_check CHECK ((ladder = ANY (ARRAY['mens'::text, 'womens'::text, 'mixed'::text])));
alter table public.partner_invites add constraint partner_invites_pkey PRIMARY KEY (id);
alter table public.partner_invites add constraint partner_invites_recipient_gender_check CHECK ((recipient_gender = ANY (ARRAY['Male'::text, 'Female'::text])));
alter table public.partner_invites add constraint partner_invites_sender_gender_check CHECK ((sender_gender = ANY (ARRAY['Male'::text, 'Female'::text])));
alter table public.partner_invites add constraint partner_invites_status_check CHECK ((status = ANY (ARRAY['Pending'::text, 'Accepted'::text, 'Declined'::text, 'Cancelled'::text])));
alter table public.partner_listings add constraint partner_listings_gender_check CHECK ((gender = ANY (ARRAY['Male'::text, 'Female'::text])));
alter table public.partner_listings add constraint partner_listings_ladder_check CHECK ((ladder = ANY (ARRAY['mens'::text, 'womens'::text, 'mixed'::text])));
alter table public.partner_listings add constraint partner_listings_pkey PRIMARY KEY (id);
alter table public.partner_listings add constraint partner_listings_status_check CHECK ((status = ANY (ARRAY['Active'::text, 'Removed'::text])));
alter table public.profiles add constraint profiles_dupr_check CHECK (((dupr IS NULL) OR ((dupr >= (0)::numeric) AND (dupr <= (10)::numeric))));
alter table public.profiles add constraint profiles_pkey PRIMARY KEY (id);
alter table public.ranking_history add constraint ranking_history_pkey PRIMARY KEY (id);
alter table public.team_members add constraint team_member_dupr_check CHECK (((dupr_at_entry IS NULL) OR ((dupr_at_entry >= (0)::numeric) AND (dupr_at_entry <= (10)::numeric))));
alter table public.team_members add constraint team_member_slot_check CHECK ((slot = ANY (ARRAY[1, 2])));
alter table public.team_members add constraint team_members_pkey PRIMARY KEY (team_id, user_id);
alter table public.team_members add constraint team_members_team_id_slot_key UNIQUE (team_id, slot);
alter table public.teams add constraint team_rank_check CHECK ((rank > 0));
alter table public.teams add constraint team_record_check CHECK (((wins >= 0) AND (losses >= 0)));
alter table public.teams add constraint team_status_check CHECK ((status = ANY (ARRAY['available'::text, 'challenge_pending'::text, 'match_scheduled'::text, 'inactive'::text, 'forfeit_review'::text, 'removed'::text])));
alter table public.teams add constraint team_strikes_check CHECK (((challenge_strikes >= 0) AND (challenge_strikes <= 4)));
alter table public.teams add constraint teams_ladder_id_name_key UNIQUE (ladder_id, name);
alter table public.teams add constraint teams_ladder_rank_unique UNIQUE (ladder_id, rank) DEFERRABLE INITIALLY DEFERRED;
alter table public.teams add constraint teams_pkey PRIMARY KEY (id);

-- Add foreign keys after all referenced tables exist.
alter table private.app_admins add constraint app_admins_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
alter table private.team_members add constraint team_members_club_id_fkey FOREIGN KEY (club_id) REFERENCES clubs(id) ON DELETE RESTRICT;
alter table private.team_members add constraint team_members_team_id_fkey FOREIGN KEY (team_id) REFERENCES ladder_teams(id) ON DELETE CASCADE;
alter table private.team_members add constraint team_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
alter table public.audit_log add constraint audit_log_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
alter table public.audit_log add constraint audit_log_club_id_fkey FOREIGN KEY (club_id) REFERENCES clubs(id) ON DELETE CASCADE;
alter table public.challenges add constraint challenges_challenged_team_id_fkey1 FOREIGN KEY (challenged_team_id) REFERENCES ladder_teams(id) ON DELETE SET NULL;
alter table public.challenges add constraint challenges_challenger_team_id_fkey1 FOREIGN KEY (challenger_team_id) REFERENCES ladder_teams(id) ON DELETE SET NULL;
alter table public.challenges add constraint challenges_club_id_fkey FOREIGN KEY (club_id) REFERENCES clubs(id);
alter table public.challenges add constraint challenges_forfeited_by_team_id_fkey FOREIGN KEY (forfeited_by_team_id) REFERENCES ladder_teams(id) ON DELETE SET NULL;
alter table public.challenges add constraint challenges_submitted_by_team_id_fkey FOREIGN KEY (submitted_by_team_id) REFERENCES ladder_teams(id) ON DELETE SET NULL;
alter table public.challenges add constraint challenges_winner_team_id_fkey FOREIGN KEY (winner_team_id) REFERENCES ladder_teams(id) ON DELETE SET NULL;
alter table public.club_memberships add constraint club_memberships_club_id_fkey FOREIGN KEY (club_id) REFERENCES clubs(id) ON DELETE CASCADE;
alter table public.club_memberships add constraint club_memberships_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
alter table public.ladder_movements add constraint ladder_movements_club_id_fkey FOREIGN KEY (club_id) REFERENCES clubs(id);
alter table public.ladder_movements add constraint ladder_movements_team_id_fkey FOREIGN KEY (team_id) REFERENCES ladder_teams(id) ON DELETE SET NULL;
alter table public.ladder_teams add constraint ladder_teams_club_id_fkey FOREIGN KEY (club_id) REFERENCES clubs(id) ON DELETE RESTRICT;
alter table public.ladders add constraint ladders_club_id_fkey FOREIGN KEY (club_id) REFERENCES clubs(id) ON DELETE CASCADE;
alter table public.legacy_challenges add constraint challenges_challenged_team_id_fkey FOREIGN KEY (challenged_team_id) REFERENCES teams(id);
alter table public.legacy_challenges add constraint challenges_challenger_team_id_fkey FOREIGN KEY (challenger_team_id) REFERENCES teams(id);
alter table public.legacy_challenges add constraint challenges_issued_by_fkey FOREIGN KEY (issued_by) REFERENCES auth.users(id) ON DELETE SET NULL;
alter table public.legacy_challenges add constraint challenges_ladder_id_fkey FOREIGN KEY (ladder_id) REFERENCES ladders(id) ON DELETE CASCADE;
alter table public.match_games add constraint match_games_match_id_fkey FOREIGN KEY (match_id) REFERENCES matches(id) ON DELETE CASCADE;
alter table public.matches add constraint matches_challenge_id_fkey FOREIGN KEY (challenge_id) REFERENCES legacy_challenges(id) ON DELETE CASCADE;
alter table public.matches add constraint matches_confirmed_by_fkey FOREIGN KEY (confirmed_by) REFERENCES auth.users(id) ON DELETE SET NULL;
alter table public.matches add constraint matches_ladder_id_fkey FOREIGN KEY (ladder_id) REFERENCES ladders(id);
alter table public.matches add constraint matches_loser_team_id_fkey FOREIGN KEY (loser_team_id) REFERENCES teams(id);
alter table public.matches add constraint matches_submitted_by_fkey FOREIGN KEY (submitted_by) REFERENCES auth.users(id) ON DELETE SET NULL;
alter table public.matches add constraint matches_winner_team_id_fkey FOREIGN KEY (winner_team_id) REFERENCES teams(id);
alter table public.partner_invites add constraint partner_invites_club_id_fkey FOREIGN KEY (club_id) REFERENCES clubs(id);
alter table public.partner_invites add constraint partner_invites_listing_id_fkey FOREIGN KEY (listing_id) REFERENCES partner_listings(id) ON DELETE SET NULL;
alter table public.partner_invites add constraint partner_invites_recipient_user_id_fkey FOREIGN KEY (recipient_user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
alter table public.partner_invites add constraint partner_invites_sender_user_id_fkey FOREIGN KEY (sender_user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
alter table public.partner_listings add constraint partner_listings_club_id_fkey FOREIGN KEY (club_id) REFERENCES clubs(id);
alter table public.partner_listings add constraint partner_listings_owner_user_id_fkey FOREIGN KEY (owner_user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
alter table public.profiles add constraint profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;
alter table public.ranking_history add constraint ranking_history_changed_by_fkey FOREIGN KEY (changed_by) REFERENCES auth.users(id) ON DELETE SET NULL;
alter table public.ranking_history add constraint ranking_history_ladder_id_fkey FOREIGN KEY (ladder_id) REFERENCES ladders(id);
alter table public.ranking_history add constraint ranking_history_related_challenge_id_fkey FOREIGN KEY (related_challenge_id) REFERENCES legacy_challenges(id);
alter table public.ranking_history add constraint ranking_history_related_match_id_fkey FOREIGN KEY (related_match_id) REFERENCES matches(id);
alter table public.ranking_history add constraint ranking_history_team_id_fkey FOREIGN KEY (team_id) REFERENCES teams(id);
alter table public.team_members add constraint team_members_team_id_fkey FOREIGN KEY (team_id) REFERENCES teams(id) ON DELETE CASCADE;
alter table public.team_members add constraint team_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
alter table public.teams add constraint teams_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;
alter table public.teams add constraint teams_ladder_id_fkey FOREIGN KEY (ladder_id) REFERENCES ladders(id) ON DELETE CASCADE;

CREATE INDEX team_members_club_ladder_email_idx ON private.team_members USING btree (club_id, ladder, lower(email));
CREATE UNIQUE INDEX team_members_email_ladder_unique ON private.team_members USING btree (ladder, lower(email));
CREATE UNIQUE INDEX team_members_user_ladder_unique ON private.team_members USING btree (ladder, user_id) WHERE (user_id IS NOT NULL);
CREATE INDEX challenges_challenged_index ON public.challenges USING btree (challenged_team_id, status);
CREATE INDEX challenges_challenger_index ON public.challenges USING btree (challenger_team_id, status);
CREATE INDEX challenges_club_id_idx ON public.challenges USING btree (club_id);
CREATE INDEX challenges_ladder_index ON public.challenges USING btree (ladder, created_at);
CREATE INDEX ladder_movements_club_id_idx ON public.ladder_movements USING btree (club_id);
CREATE INDEX ladder_movements_team_index ON public.ladder_movements USING btree (team_id, created_at);
CREATE INDEX ladder_teams_club_ladder_rank_idx ON public.ladder_teams USING btree (club_id, ladder, rank_position);
CREATE UNIQUE INDEX ladder_teams_name_unique ON public.ladder_teams USING btree (ladder, lower(name));
CREATE INDEX ladder_teams_rank_index ON public.ladder_teams USING btree (ladder, rank_position);
CREATE INDEX partner_invites_club_id_idx ON public.partner_invites USING btree (club_id);
CREATE UNIQUE INDEX partner_invites_one_pending_per_sender_listing ON public.partner_invites USING btree (listing_id, sender_user_id) WHERE (status = 'Pending'::text);
CREATE INDEX partner_invites_participants_index ON public.partner_invites USING btree (sender_user_id, recipient_user_id, status);
CREATE INDEX partner_listings_club_id_idx ON public.partner_listings USING btree (club_id);
CREATE INDEX partner_listings_ladder_index ON public.partner_listings USING btree (ladder, status);
CREATE UNIQUE INDEX partner_listings_one_active_per_user_ladder ON public.partner_listings USING btree (owner_user_id, ladder) WHERE (status = 'Active'::text);

-- Preserve the production RLS setting. Policies are installed separately.
alter table private.app_admins enable row level security;
alter table private.ladder_state_backup_20260922 enable row level security;
alter table private.team_members enable row level security;
alter table public.audit_log enable row level security;
alter table public.challenges enable row level security;
alter table public.club_memberships enable row level security;
alter table public.clubs enable row level security;
alter table public.ladder_movements enable row level security;
alter table public.ladder_state enable row level security;
alter table public.ladder_teams enable row level security;
alter table public.ladders enable row level security;
alter table public.legacy_challenges enable row level security;
alter table public.match_games enable row level security;
alter table public.matches enable row level security;
alter table public.partner_invites enable row level security;
alter table public.partner_listings enable row level security;
alter table public.profiles enable row level security;
alter table public.ranking_history enable row level security;
alter table public.team_members enable row level security;
alter table public.teams enable row level security;
commit;
