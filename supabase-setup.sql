-- ============================================================
-- BiyaHERO — Supabase setup
-- Run this once in your project's SQL Editor (Supabase Dashboard
-- -> SQL Editor -> New query -> paste this whole file -> Run).
-- ============================================================

-- Real, persistent user data table (separate from Supabase's own
-- internal auth.users table, which is managed for you and stores
-- the securely-hashed password — BiyaHERO's own code never sees or
-- handles a plaintext or hashed password directly).
create table if not exists public.profiles (
  id uuid references auth.users on delete cascade primary key,
  name text not null,
  email text not null,
  -- 'user' is the default and only role a signup can ever get itself —
  -- see the role-escalation trigger below. Promoting someone to 'admin'
  -- is a deliberate, separate step (see the ADMIN BOOTSTRAPPING note
  -- near the bottom of this file), never something the app itself can
  -- do to its own account.
  role text not null default 'user' check (role in ('user','admin')),
  -- Account status, separate from role. 'disabled' is how an Admin
  -- deactivates an account (their own or another Admin's — see the
  -- self-disable guard on the trigger below) without deleting it.
  -- BiyaHERO.js checks this immediately after every login/session
  -- restore and signs the account back out if disabled — see
  -- attemptLogin() and the getSession() restore block.
  status text not null default 'active' check (status in ('active','disabled')),
  created_at timestamptz not null default now()
);

-- Columns added after the table already existed in earlier deployments —
-- "create table if not exists" above won't retrofit them, so this handles
-- upgrading an existing database. No-op on a fresh install. Without this,
-- a profiles table created before 'role' existed would make is_admin()
-- below fail with "column role does not exist".
alter table public.profiles add column if not exists role text not null default 'user';
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('user','admin'));

alter table public.profiles add column if not exists status text not null default 'active';
alter table public.profiles drop constraint if exists profiles_status_check;
alter table public.profiles add constraint profiles_status_check check (status in ('active','disabled'));

-- Username uniqueness. BiyaHERO's signup form calls this field "Username"
-- now (previously "Full Name") — this is the same `name` column, not a
-- new one; the signup form, handle_new_user() below, and every existing
-- reader of profiles.name (the admin dashboard, "Welcome back" greetings,
-- etc.) all keep working exactly as before. What's new is that it must
-- now be unique, case-insensitively — "JuanDC" and "juandc" are the same
-- username, so the index is on lower(name), not name itself. A
-- genuinely blank name (shouldn't happen — the signup form requires one
-- — but handle_new_user() itself falls back to '' if metadata is ever
-- missing) is excluded, so that fallback case can never collide with
-- itself across multiple accounts.
-- If this fails because duplicate usernames already exist in your data,
-- resolve those manually first (e.g. rename all-but-one of each
-- duplicate), then re-run this statement.
drop index if exists profiles_username_unique;
create unique index profiles_username_unique on public.profiles (lower(name)) where name <> '';

-- Lets the signup form ask "is this username taken?" BEFORE calling
-- auth.signUp() — profiles' own RLS (just above) only allows reading
-- your OWN row, so a not-yet-signed-up visitor can't query it directly,
-- and shouldn't be able to see anything else about other accounts
-- either. This function deliberately returns nothing but a yes/no —
-- security definer so it can see across all rows to answer that,
-- without granting the anon caller any broader read access. Revealing
-- username existence this way is standard and expected for a username
-- (unlike the deliberate anti-enumeration behavior for EMAIL elsewhere
-- in this file) — every major sign-up form does the same "that username
-- is taken" check.
create or replace function public.is_username_taken(check_name text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles where lower(name) = lower(check_name)
  );
$$;

grant execute on function public.is_username_taken(text) to anon, authenticated;

-- Belt-and-suspenders for "one account per email": auth.users.email is
-- already unique inside Supabase's own managed auth schema (that's what
-- actually stops signUp() from creating a second auth account for an
-- email already in use — see attemptSignup() in BiyaHERO.js, which
-- already handles both the ordinary "already registered" error AND the
-- quieter case where Supabase returns a fake success with an empty
-- identities array for an existing, confirmed email, specifically to
-- avoid leaking which emails are registered). This constraint mirrors
-- that same rule onto profiles.email too, so the two tables can never
-- drift into showing two different "accounts" for what should be one
-- unique address, even via a direct write to this table.
alter table public.profiles drop constraint if exists profiles_email_unique;
alter table public.profiles add constraint profiles_email_unique unique (email);

alter table public.profiles enable row level security;

-- Row Level Security: every user can only read/edit their own row.
drop policy if exists "Users can view own profile" on public.profiles;
create policy "Users can view own profile"
  on public.profiles for select
  using ( auth.uid() = id );

drop policy if exists "Users can update own profile" on public.profiles;
create policy "Users can update own profile"
  on public.profiles for update
  using ( auth.uid() = id );

drop policy if exists "Users can insert own profile" on public.profiles;
create policy "Users can insert own profile"
  on public.profiles for insert
  with check ( auth.uid() = id );

-- ============================================================
-- ROLE-BASED ACCESS CONTROL (admin system)
-- ============================================================
-- is_admin() is what every admin-only RLS policy below actually checks —
-- never the frontend. Even if someone bypasses BiyaHERO.js entirely and
-- calls the Supabase REST API directly with their own anon-key session,
-- these policies still apply; there is no frontend-only gate anywhere in
-- this system. security definer + a fixed search_path so it can read
-- profiles.role regardless of the calling user's own row-level access.
create or replace function public.is_admin(uid uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select coalesce((select role = 'admin' from public.profiles where id = uid), false);
$$;

-- Mirrors is_admin() for account status. Used both by the trigger below
-- and, optionally, by any table that wants defense-in-depth against a
-- disabled account still writing data even if BiyaHERO.js's post-login
-- check were somehow skipped (see hazard_reports/pois insert policies
-- further down, which now check this too).
create or replace function public.is_active(uid uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select coalesce((select status = 'active' from public.profiles where id = uid), false);
$$;

-- Without this, "Users can update own profile" above (using auth.uid() =
-- id, with no column restriction) would let anyone grant themselves the
-- admin role with a single authenticated update() call — the classic way
-- a "hide the admin button in the UI" scheme actually gets bypassed. This
-- trigger makes that impossible at the database level: a role OR status
-- change is only allowed when it's being made BY an admin — with two
-- narrow exceptions:
--   1. The service_role key (used only by the create-admin Edge Function,
--      never shipped to the browser) bypasses this, because that's the
--      one legitimate path that promotes a brand-new signup to 'admin'
--      before any admin session is "changing" it — the function has
--      already independently verified the caller is an admin before it
--      gets this far.
--   2. An admin can never flip their OWN status to 'disabled' — otherwise
--      the "don't let someone lock themselves out" requirement would have
--      no enforcement below the UI layer, same as role changes.
-- Also guards `email`, for the same "not through the UI layer" reason as
-- the one-account-per-email requirement above: a real email change
-- belongs to Supabase Auth's own updateUser({email}) flow (which
-- re-verifies the new address and keeps auth.users and profiles in sync),
-- not a silent write to this table's email column, which could otherwise
-- point a profile at an address its account was never actually verified
-- against.
create or replace function public.prevent_role_self_escalation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.role is distinct from old.role
     and not public.is_admin(auth.uid())
     and auth.role() <> 'service_role' then
    raise exception 'Only an existing admin can change a profile''s role.';
  end if;

  if new.status is distinct from old.status
     and not public.is_admin(auth.uid())
     and auth.role() <> 'service_role' then
    raise exception 'Only an existing admin can change a profile''s status.';
  end if;

  if new.status is distinct from old.status
     and new.id = auth.uid()
     and new.status = 'disabled' then
    raise exception 'An admin cannot disable their own account.';
  end if;

  if new.email is distinct from old.email
     and auth.role() <> 'service_role' then
    raise exception 'Email can only be changed through account settings, not a profile update.';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_prevent_role_self_escalation on public.profiles;
create trigger trg_prevent_role_self_escalation
  before update on public.profiles
  for each row execute procedure public.prevent_role_self_escalation();

-- Lets an admin update/promote *other* users' profiles (e.g. from the
-- in-app Admin Dashboard) — separate from "Users can update own profile"
-- above, which only ever covers a user's own row.
drop policy if exists "Admins can update any profile" on public.profiles;
create policy "Admins can update any profile"
  on public.profiles for update
  using ( public.is_admin(auth.uid()) and public.is_active(auth.uid()) );

drop policy if exists "Admins can view all profiles" on public.profiles;
create policy "Admins can view all profiles"
  on public.profiles for select
  using ( public.is_admin(auth.uid()) );

-- Automatically create a profiles row whenever someone signs up via
-- supabase.auth.signUp(...) in BiyaHERO.js. `raw_user_meta_data->>'name'`
-- reads the { data: { name } } option passed at signup time.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, name, email)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', ''), new.email);
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();


-- ============================================================
-- HAZARD REPORTS (shared, backend-moderated — replaces the old
-- "prototype sync" that only ever marked local reports as uploaded
-- without actually sending them anywhere)
-- ============================================================
-- One real, shared table other commuters' apps and the Admin Dashboard
-- both read from. BiyaHERO.js still queues a report in localStorage
-- first (so reporting still works offline) and inserts it here the next
-- time syncNow() runs with a connection — see fetchRoadRoute-style
-- comments in BiyaHERO.js for the offline-first reasoning.
create table if not exists public.hazard_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid references auth.users on delete set null,
  label text not null,
  category text,
  lat double precision not null,
  lng double precision not null,
  note text,
  status text not null default 'active' check (status in ('active','resolved','dismissed')),
  created_at timestamptz not null default now(),
  moderated_at timestamptz,
  moderated_by uuid references auth.users on delete set null
);

alter table public.hazard_reports enable row level security;

-- Any signed-in commuter can see the shared hazard feed (that's the
-- whole point of a community reports feature) and can file their own
-- report, but reporter_id must match their own auth.uid() — nobody can
-- submit a report under someone else's name.
drop policy if exists "Authenticated users can view hazard reports" on public.hazard_reports;
create policy "Authenticated users can view hazard reports"
  on public.hazard_reports for select
  using ( auth.role() = 'authenticated' );

drop policy if exists "Users can insert their own hazard reports" on public.hazard_reports;
create policy "Users can insert their own hazard reports"
  on public.hazard_reports for insert
  -- is_active() here is defense-in-depth: BiyaHERO.js already signs a
  -- disabled account back out at login/session-restore (see
  -- BiyaHERO.js's attemptLogin and getSession() restore block), but a
  -- lingering client-side token from before a disable shouldn't be able
  -- to write here regardless.
  with check ( auth.uid() = reporter_id and public.is_active(auth.uid()) );

-- Moderation (marking resolved/dismissed, or deleting a bad report) is
-- admin-only, enforced here — NOT by hiding the moderation buttons in
-- the frontend. A non-admin user's own Supabase session, if pointed
-- directly at this table's update/delete endpoint, is rejected by
-- Postgres itself, regardless of what BiyaHERO.js's UI does or doesn't
-- show them.
drop policy if exists "Admins can moderate hazard reports" on public.hazard_reports;
create policy "Admins can moderate hazard reports"
  on public.hazard_reports for update
  using ( public.is_admin(auth.uid()) and public.is_active(auth.uid()) );

drop policy if exists "Admins can delete hazard reports" on public.hazard_reports;
create policy "Admins can delete hazard reports"
  on public.hazard_reports for delete
  using ( public.is_admin(auth.uid()) and public.is_active(auth.uid()) );

-- Running totals for the community feed's Confirm/Dispute reactions (see
-- hazard_reactions below, which is what actually maintains these two
-- counts — nothing writes to them directly). BiyaHERO.js's own
-- getConfidenceStatus()/updateHazardConfidence() already know how to
-- turn a confirmations/disputes pair into a displayed confidence score
-- and badge, so that formula stays client-side and isn't duplicated
-- here — this table just needs to hold the two real numbers it's based
-- on.
alter table public.hazard_reports add column if not exists confirmations integer not null default 0;
alter table public.hazard_reports add column if not exists disputes integer not null default 0;

-- The Community page shows exactly what is in this table (status =
-- 'active') and nothing else — no bundled sample cards. An earlier
-- revision of this file seeded 4 fake demo reports here so the feed
-- would look populated; they're fake data nobody ever reported, so any
-- database that already ran that version has them removed below (their
-- reactions go with them via on delete cascade). Deleting by the fixed
-- ids only touches those 4 rows, never a real commuter's report.
delete from public.hazard_reports
 where id in (
   'a1b2c3d4-0001-4000-8000-000000000001',
   'a1b2c3d4-0002-4000-8000-000000000002',
   'a1b2c3d4-0003-4000-8000-000000000003',
   'a1b2c3d4-0004-4000-8000-000000000004'
 );

-- The starting confidence a report is created with (BiyaHERO.js's
-- calculateInitialConfidence(): 40 base, up to +30 for GPS/accuracy/
-- note). Stored so every device shows the same confidence for the same
-- report instead of each recomputing it differently.
alter table public.hazard_reports add column if not exists initial_confidence integer not null default 40;

-- Nothing a client sends on insert may pre-load its own credibility:
-- counts always start at zero (only hazard_reactions moves them) and the
-- starting confidence is held to the range the app itself can produce.
create or replace function public.guard_hazard_report_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.confirmations := 0;
  new.disputes := 0;
  new.initial_confidence := least(70, greatest(40, coalesce(new.initial_confidence, 40)));
  return new;
end;
$$;

drop trigger if exists trg_guard_hazard_report_insert on public.hazard_reports;
create trigger trg_guard_hazard_report_insert
  before insert on public.hazard_reports
  for each row execute procedure public.guard_hazard_report_insert();

-- ============================================================
-- HAZARD REACTIONS (Confirm / Dispute — role-based, backend-enforced)
-- ============================================================
-- One row per person's reaction to one report. What actually enforces
-- "a regular user gets one reaction per report, ever; an admin can react
-- any number of times" is enforce_reaction_limit() below — NOT the
-- BiyaHERO.js UI, which only disables the buttons as a convenience once
-- it already knows a reaction went through. Someone calling this table's
-- insert endpoint directly, bypassing the UI entirely, hits the exact
-- same rule.
create table if not exists public.hazard_reactions (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.hazard_reports on delete cascade,
  user_id uuid not null references auth.users on delete cascade,
  reaction text not null check (reaction in ('up','down')),
  created_at timestamptz not null default now()
);

create index if not exists idx_hazard_reactions_report on public.hazard_reactions (report_id);

alter table public.hazard_reactions enable row level security;

-- Anyone signed in can see reaction rows (needed so BiyaHERO.js can, if
-- it ever wants to, ask "did I already react to this?" directly rather
-- than relying only on its own local votedReports_<uid> cache) — but
-- the reaction itself must be the caller's own, checked below by
-- enforce_reaction_limit(), not just by this policy alone.
drop policy if exists "Authenticated users can view hazard reactions" on public.hazard_reactions;
create policy "Authenticated users can view hazard reactions"
  on public.hazard_reactions for select
  using ( auth.role() = 'authenticated' );

drop policy if exists "Users can insert their own hazard reactions" on public.hazard_reactions;
create policy "Users can insert their own hazard reactions"
  on public.hazard_reactions for insert
  with check ( auth.uid() = user_id and public.is_active(auth.uid()) );

-- No update/delete policy for anyone but admins — a reaction, once
-- cast, is a fact about what someone voted at that moment; letting a
-- regular user edit or remove their own would just be a roundabout way
-- to react again, defeating the one-reaction rule below.
drop policy if exists "Admins can delete hazard reactions" on public.hazard_reactions;
create policy "Admins can delete hazard reactions"
  on public.hazard_reactions for delete
  using ( public.is_admin(auth.uid()) );

-- The actual rule: a non-admin who already has a row for this report
-- gets rejected outright; an admin never hits this check at all, so
-- their reactions are never limited to one per report — but each row
-- they insert is still exactly one reaction (this table has no way to
-- represent "both up and down at once" for a single row in the first
-- place, so that half of the requirement is just the table shape).
create or replace function public.enforce_reaction_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin(new.user_id) and exists (
    select 1 from public.hazard_reactions
    where report_id = new.report_id and user_id = new.user_id
  ) then
    raise exception 'You have already reacted to this report.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enforce_reaction_limit on public.hazard_reactions;
create trigger trg_enforce_reaction_limit
  before insert on public.hazard_reactions
  for each row execute procedure public.enforce_reaction_limit();

-- Keeps hazard_reports.confirmations/disputes as a running total, so
-- BiyaHERO.js can display the count and compute a confidence score
-- straight from that one row without summing hazard_reactions itself
-- every time the feed renders.
create or replace function public.apply_reaction_to_report()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.reaction = 'up' then
    update public.hazard_reports set confirmations = confirmations + 1 where id = new.report_id;
  else
    update public.hazard_reports set disputes = disputes + 1 where id = new.report_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_apply_reaction_to_report on public.hazard_reactions;
create trigger trg_apply_reaction_to_report
  after insert on public.hazard_reactions
  for each row execute procedure public.apply_reaction_to_report();


-- ============================================================
-- MAP POIs (admin-managed, backend-enforced)
-- ============================================================
-- This table now holds BOTH the app's original bundled destinations
-- (seeded below, migrated from the lagunaDestinations array that used
-- to be the only copy of this data, hardcoded in BiyaHERO.js) and any
-- new POIs an admin adds later — one real, shared source of truth
-- instead of two. BiyaHERO.js still ships lagunaDestinations as an
-- offline fallback (so the map has real places on it before the first
-- successful sync, or with no connection at all) but treats this table
-- as authoritative once it's reachable — see loadLivePois() in
-- BiyaHERO.js. Editing/deleting a seed POI works exactly like any
-- other row here once it's been seeded; there's no special case.
create table if not exists public.pois (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  sub text,
  category text not null,
  lat double precision not null,
  lng double precision not null,
  created_by uuid references auth.users on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.pois enable row level security;

-- Read access matches hazard_reports: any signed-in commuter sees the
-- shared POI set (that's the point — an admin adding a POI should show
-- up on everyone's map), but only admins can write.
drop policy if exists "Authenticated users can view POIs" on public.pois;
create policy "Authenticated users can view POIs"
  on public.pois for select
  using ( auth.role() = 'authenticated' );

-- is_active() here is defense-in-depth, same rationale as the
-- hazard_reports insert policy above: BiyaHERO.js already signs a
-- disabled admin back out at login/session-restore, but a lingering
-- client-side token from before a disable shouldn't be able to write
-- here regardless.
drop policy if exists "Admins can insert POIs" on public.pois;
create policy "Admins can insert POIs"
  on public.pois for insert
  with check ( public.is_admin(auth.uid()) and public.is_active(auth.uid()) );

drop policy if exists "Admins can update POIs" on public.pois;
create policy "Admins can update POIs"
  on public.pois for update
  using ( public.is_admin(auth.uid()) and public.is_active(auth.uid()) );

drop policy if exists "Admins can delete POIs" on public.pois;
create policy "Admins can delete POIs"
  on public.pois for delete
  using ( public.is_admin(auth.uid()) and public.is_active(auth.uid()) );

create or replace function public.set_poi_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_pois_updated_at on public.pois;
create trigger trg_pois_updated_at
  before update on public.pois
  for each row execute procedure public.set_poi_updated_at();

-- Seed data — migrates the app's original bundled destinations list
-- (the lagunaDestinations array already baked into BiyaHERO.js) into
-- this table too, so an admin opening the Dashboard for the first time
-- sees the full real POI set rather than an empty table, and can add to
-- or build on what's already there. Safe to re-run: the WHERE NOT
-- EXISTS guard skips a row if a POI with that exact name already
-- exists, so running this file twice won't create duplicates.
insert into public.pois (name, sub, category, lat, lng)
select * from (values
  ('Santa Cruz Public Market', 'Santa Cruz, Laguna (provincial capital)', 'City Center', 14.2814, 121.4157),
  ('SM City Santa Rosa', 'Santa Rosa City, Laguna', 'Mall', 14.3123, 121.0947),
  ('Calamba City Hall', 'Calamba City, Laguna', 'City Center', 14.2117, 121.1653),
  ('San Pablo City Plaza', 'San Pablo City, Laguna', 'City Center', 14.0703, 121.3256),
  ('Biñan City Hall', 'Biñan City, Laguna', 'City Center', 14.3426, 121.0839),
  ('Cabuyao City Hall', 'Cabuyao City, Laguna', 'City Center', 14.2776, 121.125),
  ('Los Baños Municipal Hall', 'Los Baños, Laguna', 'City Center', 14.17, 121.2237),
  ('Sta. Rosa Tagaytay Road', 'Santa Rosa City, Laguna', 'Road', 14.287, 121.089),
  ('Enchanted Kingdom', 'San Lorenzo, Santa Rosa City, Laguna', 'Theme Park', 14.2819473, 121.0953936),
  ('University of the Philippines Los Baños (UPLB)', 'Los Baños, Laguna', 'University', 14.1651, 121.2415),
  ('Pagsanjan Falls', 'Pagsanjan, Laguna', 'Landmark', 14.2697, 121.4527),
  ('Rizal Shrine, Calamba', 'Calamba City, Laguna', 'Landmark', 14.2138, 121.1652),
  ('Nagcarlan Underground Cemetery', 'Brgy. Bambang, Nagcarlan, Laguna', 'Landmark', 14.13135, 121.41482),
  ('Paete Church', 'Paete, Laguna', 'Landmark', 14.3667, 121.48),
  ('Lake Caliraya', 'Lumban / Cavinti / Kalayaan, Laguna', 'Landmark', 14.29583, 121.53194),
  ('Mount Makiling', 'Los Baños / Bay, Laguna', 'Landmark', 14.1367, 121.205),
  ('Seven Lakes, San Pablo', 'San Pablo City, Laguna', 'Landmark', 14.0781, 121.3272),
  ('Pila Heritage Town Plaza', 'Pila, Laguna', 'Landmark', 14.2333, 121.3667),
  ('Majayjay Church (Taytay Falls area)', 'Majayjay, Laguna', 'Landmark', 14.1444, 121.4736),
  ('San Pablo Cathedral', 'Cathedral-Parish of St. Paul the First Hermit, San Pablo City', 'Church', 14.069725, 121.326575),
  ('San Pablo City Hall', 'San Pablo City, Laguna', 'Government', 14.070007, 121.325681),
  ('SM City San Pablo', 'Maharlika Highway, Brgy. San Rafael, San Pablo City', 'Mall', 14.07145, 121.30177),
  ('San Pablo City Science Integrated High School', 'San Pablo City, Laguna', 'School', 14.06452, 121.34254),
  ('San Pablo City National High School', 'Brgy. VI-D, San Pablo City, Laguna', 'School', 14.07673, 121.32092),
  ('San Pablo District Hospital', 'San Pablo City, Laguna (approx. — near Sampaloc Lake)', 'Hospital', 14.0775, 121.326),
  ('San Pedro City Hall', 'San Pedro City, Laguna', 'City Center', 14.3583, 121.0583),
  ('Saint Peter of Alcantara Parish Church (Pakil)', 'Pakil, Laguna — Diocesan Shrine of Our Lady of Turumba', 'Church', 14.380826, 121.478914),
  ('Siniloan Church (Sts. Peter and Paul Parish)', 'Siniloan, Laguna', 'Church', 14.421999, 121.446129),
  ('San Agustin Parish Church, Bay', 'Bay, Laguna — the old Laguna provincial capital', 'Church', 14.180369, 121.284315),
  ('Saint John the Baptist Parish Church (Liliw)', 'Liliw, Laguna — the "Flip-flops Capital of the Philippines"', 'Church', 14.12982, 121.43581),
  ('Mercury Drug – Sta. Rosa Poblacion', 'Gomez St / Tatlong Hari St, Market Area, Santa Rosa City', 'Pharmacy', 14.313827, 121.112702),
  ('Petron – Bypass Road', 'Barangay Bucal, Calamba City', 'Gas Station', 14.181185, 121.15913),
  ('Shell – San Rafael', 'Brgy. San Rafael, San Pablo City', 'Gas Station', 14.07119, 121.304877),
  ('Caltex – Balibago / RSBS Blvd', 'Balibago, Santa Rosa City', 'Gas Station', 14.288834, 121.094695),
  ('Security Bank – Biñan', 'National Highway, Biñan City', 'Bank', 14.333108, 121.08152),
  ('BDO – Biñan Central Mall', 'Malvar St. cor. Old National Hwy, Biñan City', 'Bank', 14.332739, 121.082215),
  ('BPI ATM – Waltermart Cabuyao', 'KM 47 National Hwy, Brgy. Banlic, Cabuyao City', 'Bank', 14.232896, 121.134128),
  ('SM Supermarket – SM City San Pablo', 'National Highway, San Pablo City', 'Supermarket', 14.071201, 121.302592),
  ('South Supermarket', 'National Highway, Los Baños', 'Supermarket', 14.176812, 121.262219),
  ('Los Baños Public Market', '149 Villegas St., Los Baños', 'Wet Market', 14.181555, 121.224374),
  ('Pamilihang Bayan ng Batong Malake', 'National Highway, Los Baños', 'Wet Market', 14.179636, 121.24054),
  ('Cabuyao City Police Station', 'Manila South Rd, Cabuyao City', 'Police', 14.271199, 121.124208),
  ('Santa Cruz Municipal Police Station', 'A. Mabini St., Santa Cruz', 'Police', 14.282458, 121.416004),
  ('Santa Rosa City Fire Station', 'Rizal Ave, Santa Rosa City', 'Fire Station', 14.31575, 121.110555),
  ('Laguna Technopark Fire Station', 'Science Ave, Don Jose, Santa Rosa City', 'Fire Station', 14.26136, 121.057583),
  ('San Pedro Doctors Hospital', 'National Highway, San Pedro City', 'Hospital', 14.348863, 121.064919),
  ('LPH – San Pedro District Hospital', 'Puerto Azul St., San Pedro City', 'Hospital', 14.362976, 121.042297),
  ('Calamba Medical Center', 'Crossing, Asian Hwy, Calamba City', 'Hospital', 14.206167, 121.152387),
  ('Calamba Doctors Hospital', 'KM 49, San Cristobal Bridge, Calamba City', 'Hospital', 14.217319, 121.141912),
  ('Dr. Jose P. Rizal Memorial Provincial Hospital', 'Manila South Rd, Calamba City', 'Hospital', 14.191669, 121.167549),
  ('Robinsons Place Santa Rosa', 'Manila South Rd, Santa Rosa City', 'Mall', 14.319167, 121.096667),
  ('Central Mall Biñan', 'Manila South Rd, Biñan City', 'Mall', 14.332788, 121.082296),
  ('SM City Calamba', 'National Road, Brgy. Real, Calamba City', 'Mall', 14.204185, 121.154586),
  ('Jollibee Pacita', 'Pacita Complex, National Hwy, San Pedro City', 'Fast Food', 14.346811, 121.06565),
  ('Bertie''s Artisan Bakeshop', 'Bucal Bypass Rd, Calamba City', 'Bakery', 14.17885, 121.155876),
  ('Pidol''s Bakeshop – Calamba', 'San Jose Rd, Calamba City', 'Bakery', 14.213768, 121.169877),
  ('Calle Arco Restaurant', 'Pagsanjan (riverside dining)', 'Restaurant', 14.273165, 121.453248),
  ('SM Calamba Parking Area', 'Real Rd, Brgy. Real, Calamba City', 'Parking', 14.202951, 121.154139),
  ('Bacay''s Water Refilling Station', 'Marcos Paulino St., San Pablo City', 'Water Station', 14.064392, 121.325789),
  ('LLi Bus Terminal', 'Pagsanjan', 'Terminal', 14.264924, 121.430832),
  ('SLEX Santa Rosa Exit', 'South Luzon Expressway, Santa Rosa City', 'Highway', 14.301, 121.085),
  ('SLEX Calamba Exit', 'South Luzon Expressway, Calamba City', 'Highway', 14.225, 121.14),
  ('Manila South Road, San Pablo', 'National Highway, San Pablo City', 'Highway', 14.085, 121.31)
) as v(name, sub, category, lat, lng)
where not exists (select 1 from public.pois p where p.name = v.name);

-- ============================================================
-- SEPT 2026 PASS — provinces, Laguna cities/municipalities/barangays,
-- and the Tripadvisor landmark/farm/church additions
-- ============================================================
-- Everything below brings this table up to parity with the current
-- lagunaDestinations array in BiyaHERO.js (876 entries total): all 82
-- Philippine provinces, all 30 Laguna cities/municipalities, all 681
-- Laguna barangays, and every landmark/church/farm added since the
-- original 63-row seed above. Uses the same idempotent pattern as that
-- seed, safe to re-run — EXCEPT the uniqueness check below is on
-- (name, sub) together, not name alone. Name alone isn't a safe
-- uniqueness key here: many different real Laguna barangays legitimately
-- share the same name across different towns ("San Isidro", "Poblacion",
-- "Santo Nino" etc. each appear a dozen-plus times province-wide) --
-- checking name alone would make this script think the second
-- "San Isidro" already exists (because a DIFFERENT San Isidro, in a
-- different town, does) and silently skip inserting it.
--
-- Run this once in the Supabase SQL Editor (same place you ran the
-- rest of this file). It only writes to public.pois — no schema, RLS,
-- or trigger changes, and nothing here touches auth/profiles.

-- Fix the 7 pre-existing city/municipality rows seeded above: they
-- still carry the old, single 'City Center' category and lack barangay
-- counts in "sub" — bring them in line with BiyaHERO.js's current
-- City vs Municipality split (see lagunaDestinations) so the admin
-- dashboard shows the same categorization the map/search use.
update public.pois set category = 'Municipality', sub = 'Santa Cruz, Laguna (provincial capital) — 26 barangays' where name = 'Santa Cruz Public Market';
update public.pois set category = 'City', sub = 'Calamba City, Laguna — 54 barangays' where name = 'Calamba City Hall';
update public.pois set category = 'City', sub = 'San Pablo City, Laguna — 80 barangays' where name = 'San Pablo City Plaza';
update public.pois set category = 'City', sub = 'Biñan City, Laguna — 24 barangays' where name = 'Biñan City Hall';
update public.pois set category = 'City', sub = 'Cabuyao City, Laguna — 18 barangays' where name = 'Cabuyao City Hall';
update public.pois set category = 'Municipality', sub = 'Los Baños, Laguna — 14 barangays' where name = 'Los Baños Municipal Hall';
update public.pois set category = 'City', sub = 'San Pedro City, Laguna — 27 barangays' where name = 'San Pedro City Hall';

insert into public.pois (name, sub, category, lat, lng)
select * from (values
  ('Santa Rosa City Hall', 'Rizal Blvd, Santa Rosa City, Laguna — 18 barangays', 'City', 14.3119, 121.1055),
  ('San Pablo City Hall', 'San Pablo City, Laguna — 80 barangays', 'Government', 14.070007, 121.325681),
  ('Fun Farm at Sta. Elena', 'Brgy. Malitlit, Santa Rosa City, Laguna (approx.)', 'Farm', 14.2583, 121.0969),
  ('Forest Wood Garden', 'San Pablo City, Laguna (approx.)', 'Farm', 14.065, 121.31),
  ('Costales Nature Farms', 'Majayjay, Laguna — foot of Mt. Banahaw (approx.)', 'Farm', 14.1463, 121.4729),
  ('Sta. Maria Magdalena Church', 'Magdalena, Laguna', 'Church', 14.198907, 121.429145),
  ('Ylaya At Santa Elena', 'San Pablo City, Laguna (approx.)', 'Farm', 14.06, 121.305),
  ('Shrine of Our Lady of Guadalupe', 'Pagsanjan, Laguna — Diocesan Shrine and Parish', 'Church', 14.272819, 121.456174),
  ('Lukong Valley Farm', 'Dolores, Quezon — just across the San Pablo border (approx.)', 'Farm', 14.0157, 121.4011),
  ('San Gregorio Magno Church', 'Majayjay, Laguna — Minor Basilica, National Cultural Treasure', 'Church', 14.14621, 121.47141),
  ('Alcasid Aviary and Farm', 'Calamba City, Laguna (approx.)', 'Farm', 14.205, 121.155),
  ('Saint James the Apostle Church', 'Paete, Laguna — National Historical Landmark', 'Church', 14.364557, 121.481638),
  ('Joni and Susan Agroshop and Integrated Farms', 'San Pablo City, Laguna (approx.)', 'Farm', 14.065, 121.31),
  ('National Shrine of San Antonio De Padua', 'Pila, Laguna — Pila Church, National Shrine', 'Church', 14.233958, 121.364398),
  ('San Juan Bautista Church', 'Brgy. Longos, Kalayaan, Laguna', 'Church', 14.34045, 121.481431),
  ('San Bartolome Apostol Parish Church', 'Nagcarlan, Laguna — Nagcarlan Church', 'Church', 14.13629, 121.4174),
  ('Graco Farms & Leisure', 'Pila, Laguna (approx.)', 'Farm', 14.2333, 121.3667),
  ('National Shrine of Our Lady of Sorrows', 'Dolores, Quezon — just across the San Pablo border (approx.)', 'Church', 14.0157, 121.4011),
  ('UPLB Fertility Tree', 'Freedom Park, UPLB, Los Baños, Laguna (approx.)', 'Landmark', 14.1663, 121.2423),
  ('Saint John the Baptist Parish Church, Calamba', 'Calamba City, Laguna — christening site of José Rizal', 'Church', 14.213477, 121.167528),
  ('Tatlong Krus', 'Paete, Laguna — hillside "Three Crosses" viewpoint (approx.)', 'Landmark', 14.3667, 121.48),
  ('Holy Carabao', 'Santa Rosa City, Laguna (approx.)', 'Landmark', 14.2819, 121.0954),
  ('Fule-Malvar Mansion', 'Jose Rizal Ave, San Pablo City, Laguna — heritage house', 'Landmark', 14.0716, 121.3225),
  ('Farmshare Agri Tourism Park', 'Cavinti, Laguna (approx.)', 'Farm', 14.2451, 121.5074),
  ('Museo ng San Pablo', 'Capitol Compound, San Pablo City, Laguna — city museum', 'Landmark', 14.070007, 121.325681),
  ('Roman Catholic Parish of San Antonio de Padua', 'Lopez Ave, Batong Malake, Los Baños, Laguna (approx.)', 'Church', 14.166, 121.241),
  ('Shrine of St. Therese of the Child Jesus', 'UPLB campus, Los Baños, Laguna — Diocesan Shrine / "UPLB Chapel"', 'Church', 14.16472, 121.245),
  ('Rodrigo''s Greenhouse Cafe', 'Cabuyao City, Laguna (approx.)', 'Restaurant', 14.2776, 121.125),
  ('Immaculate Conception Parish Church', 'Poblacion, Los Baños, Laguna — oldest church in the town', 'Church', 14.178733, 121.221912),
  ('Alaminos Municipal Hall', 'Alaminos, Laguna — 15 barangays', 'Municipality', 14.063469, 121.245128),
  ('Bay Municipal Hall', 'Bay, Laguna — old Laguna provincial capital — 15 barangays', 'Municipality', 14.18, 121.28),
  ('Calauan Municipal Hall', 'Calauan, Laguna — 17 barangays', 'Municipality', 14.15, 121.32),
  ('Cavinti Municipal Hall', 'Cavinti, Laguna — 19 barangays', 'Municipality', 14.245128, 121.507419),
  ('Famy Municipal Hall', 'Famy, Laguna — 20 barangays', 'Municipality', 14.43, 121.45),
  ('Kalayaan Municipal Hall', 'Kalayaan, Laguna — 3 barangays', 'Municipality', 14.328, 121.48),
  ('Liliw Municipal Hall', 'Liliw, Laguna — "Flip-flops Capital of the Philippines" — 33 barangays', 'Municipality', 14.13, 121.436),
  ('Luisiana Municipal Hall', 'Luisiana, Laguna — "Little Baguio of Laguna" — 23 barangays', 'Municipality', 14.185, 121.5109),
  ('Lumban Municipal Hall', 'Lumban, Laguna — Embroidery Capital of the Philippines — 16 barangays', 'Municipality', 14.297, 121.459),
  ('Mabitac Municipal Hall', 'Mabitac, Laguna — 15 barangays', 'Municipality', 14.43, 121.42),
  ('Magdalena Municipal Hall', 'Magdalena, Laguna — Bamboo Capital of Laguna — 24 barangays', 'Municipality', 14.198907, 121.429145),
  ('Majayjay Municipal Hall', 'Majayjay, Laguna — foot of Mt. Banahaw — 40 barangays', 'Municipality', 14.1463, 121.4729),
  ('Nagcarlan Municipal Hall', 'Nagcarlan, Laguna — 52 barangays (most of any Laguna town)', 'Municipality', 14.1364, 121.4165),
  ('Paete Municipal Hall', 'Paete, Laguna — 9 barangays', 'Municipality', 14.364557, 121.481638),
  ('Pagsanjan Municipal Hall', 'Pagsanjan, Laguna — "Tourist Capital of Laguna" — 16 barangays', 'Municipality', 14.273283, 121.44906),
  ('Pakil Municipal Hall', 'Pakil, Laguna — Pilgrimage Capital of Laguna — 13 barangays', 'Municipality', 14.380826, 121.478914),
  ('Pangil Municipal Hall', 'Pangil, Laguna — 8 barangays', 'Municipality', 14.4, 121.47),
  ('Pila Municipal Hall', 'Pila, Laguna — heritage town — 17 barangays', 'Municipality', 14.233958, 121.364398),
  ('Rizal Municipal Hall', 'Rizal, Laguna — 11 barangays', 'Municipality', 14.1083, 121.3917),
  ('Santa Maria Municipal Hall', 'Santa Maria, Laguna — 25 barangays', 'Municipality', 14.475, 121.425),
  ('Siniloan Municipal Hall', 'Siniloan, Laguna — "A Waterfall Sanctuary" — 20 barangays', 'Municipality', 14.421999, 121.446129),
  ('Victoria Municipal Hall', 'Victoria, Laguna — Duck Raising Capital of the Philippines — 9 barangays', 'Municipality', 14.225, 121.325),
  ('Abra', 'Province, Cordillera Administrative Region (CAR)', 'Province', 17.578121, 120.803199),
  ('Agusan del Norte', 'Province, Region XIII (Caraga)', 'Province', 9.072133, 125.522395),
  ('Agusan del Sur', 'Province, Region XIII (Caraga)', 'Province', 8.421401, 125.729015),
  ('Aklan', 'Province, Region VI (Western Visayas)', 'Province', 11.609532, 122.248059),
  ('Albay', 'Province, Region V (Bicol Region)', 'Province', 13.209668, 123.615739),
  ('Antique', 'Province, Region VI (Western Visayas)', 'Province', 11.126288, 122.068083),
  ('Apayao', 'Province, Cordillera Administrative Region (CAR)', 'Province', 18.105488, 121.187563),
  ('Aurora', 'Province, Region III (Central Luzon)', 'Province', 15.922707, 121.699847),
  ('Basilan', 'Province, Bangsamoro Autonomous Region In Muslim Mindanao (BARMM)', 'Province', 6.565435, 122.029096),
  ('Bataan', 'Province, Region III (Central Luzon)', 'Province', 14.66041, 120.454415),
  ('Batanes', 'Province, Region II (Cagayan Valley)', 'Province', 20.552162, 121.888002),
  ('Batangas', 'Province, Region IV-A (CALABARZON)', 'Province', 13.891818, 121.031451),
  ('Benguet', 'Province, Cordillera Administrative Region (CAR)', 'Province', 16.545486, 120.701055),
  ('Biliran', 'Province, Region VIII (Eastern Visayas)', 'Province', 11.596696, 124.473256),
  ('Bohol', 'Province, Region VII (Central Visayas)', 'Province', 9.853804, 124.197553),
  ('Bukidnon', 'Province, Region X (Northern Mindanao)', 'Province', 8.01854, 125.006949),
  ('Bulacan', 'Province, Region III (Central Luzon)', 'Province', 14.978688, 121.057836),
  ('Cagayan', 'Province, Region II (Cagayan Valley)', 'Province', 18.093278, 121.76074),
  ('Camarines Norte', 'Province, Region V (Bicol Region)', 'Province', 14.143134, 122.727661),
  ('Camarines Sur', 'Province, Region V (Bicol Region)', 'Province', 13.705255, 123.262336),
  ('Camiguin', 'Province, Region X (Northern Mindanao)', 'Province', 9.171987, 124.717747),
  ('Capiz', 'Province, Region VI (Western Visayas)', 'Province', 11.369865, 122.632904),
  ('Catanduanes', 'Province, Region V (Bicol Region)', 'Province', 13.783156, 124.236448),
  ('Cavite', 'Province, Region IV-A (CALABARZON)', 'Province', 14.254732, 120.86847),
  ('Cebu', 'Province, Region VII (Central Visayas)', 'Province', 10.353874, 123.742713),
  ('Cotabato', 'Province, Region XII (SOCCSKSARGEN)', 'Province', 7.209991, 124.867332),
  ('Davao Occidental', 'Province, Region XI (Davao Region)', 'Province', 6.097965, 125.54057),
  ('Davao Oriental', 'Province, Region XI (Davao Region)', 'Province', 7.251011, 126.298164),
  ('Davao de Oro', 'Province, Region XI (Davao Region)', 'Province', 7.573118, 126.022949),
  ('Davao del Norte', 'Province, Region XI (Davao Region)', 'Province', 7.585181, 125.642247),
  ('Davao del Sur', 'Province, Region XI (Davao Region)', 'Province', 6.713291, 125.255652),
  ('Dinagat Islands', 'Province, Region XIII (Caraga)', 'Province', 10.170899, 125.602437),
  ('Eastern Samar', 'Province, Region VIII (Eastern Visayas)', 'Province', 11.646915, 125.381263),
  ('Guimaras', 'Province, Region VI (Western Visayas)', 'Province', 10.568766, 122.61408),
  ('Ifugao', 'Province, Cordillera Administrative Region (CAR)', 'Province', 16.848396, 121.207174),
  ('Ilocos Norte', 'Province, Region I (Ilocos Region)', 'Province', 18.204654, 120.730253),
  ('Ilocos Sur', 'Province, Region I (Ilocos Region)', 'Province', 17.24703, 120.547087),
  ('Iloilo', 'Province, Region VI (Western Visayas)', 'Province', 11.012157, 122.606616),
  ('Isabela', 'Province, Region II (Cagayan Valley)', 'Province', 16.986911, 121.961202),
  ('Kalinga', 'Province, Cordillera Administrative Region (CAR)', 'Province', 17.430898, 121.279474),
  ('La Union', 'Province, Region I (Ilocos Region)', 'Province', 16.580352, 120.424518),
  ('Laguna', 'Province, Region IV-A (CALABARZON)', 'Province', 14.23767, 121.360491),
  ('Lanao del Norte', 'Province, Region X (Northern Mindanao)', 'Province', 7.974764, 123.95288),
  ('Lanao del Sur', 'Province, Bangsamoro Autonomous Region In Muslim Mindanao (BARMM)', 'Province', 7.789228, 124.34456),
  ('Leyte', 'Province, Region VIII (Eastern Visayas)', 'Province', 10.968554, 124.752083),
  ('Maguindanao del Norte', 'Province, Bangsamoro Autonomous Region In Muslim Mindanao (BARMM)', 'Province', 7.178263, 124.237571),
  ('Maguindanao del Sur', 'Province, Bangsamoro Autonomous Region In Muslim Mindanao (BARMM)', 'Province', 6.88872, 124.57461),
  ('Marinduque', 'Province, MIMAROPA Region', 'Province', 13.391267, 121.971921),
  ('Masbate', 'Province, Region V (Bicol Region)', 'Province', 12.29426, 123.552538),
  ('Misamis Occidental', 'Province, Region X (Northern Mindanao)', 'Province', 8.32726, 123.690967),
  ('Misamis Oriental', 'Province, Region X (Northern Mindanao)', 'Province', 8.678292, 124.82484),
  ('Mountain Province', 'Province, Cordillera Administrative Region (CAR)', 'Province', 17.10125, 121.129204),
  ('Negros Occidental', 'Province, Negros Island Region (NIR)', 'Province', 10.30318, 122.986685),
  ('Negros Oriental', 'Province, Negros Island Region (NIR)', 'Province', 9.606563, 123.033454),
  ('Northern Samar', 'Province, Region VIII (Eastern Visayas)', 'Province', 12.41107, 124.791738),
  ('Nueva Ecija', 'Province, Region III (Central Luzon)', 'Province', 15.617572, 121.02059),
  ('Nueva Vizcaya', 'Province, Region II (Cagayan Valley)', 'Province', 16.3052, 121.171813),
  ('Occidental Mindoro', 'Province, MIMAROPA Region', 'Province', 12.971404, 120.892966),
  ('Oriental Mindoro', 'Province, MIMAROPA Region', 'Province', 12.923174, 121.299296),
  ('Palawan', 'Province, MIMAROPA Region', 'Province', 9.98578, 118.73455),
  ('Pampanga', 'Province, Region III (Central Luzon)', 'Province', 15.051978, 120.653156),
  ('Pangasinan', 'Province, Region I (Ilocos Region)', 'Province', 15.999397, 120.31266),
  ('Quezon', 'Province, Region IV-A (CALABARZON)', 'Province', 14.167753, 121.966136),
  ('Quirino', 'Province, Region II (Cagayan Valley)', 'Province', 16.294404, 121.5955),
  ('Rizal', 'Province, Region IV-A (CALABARZON)', 'Province', 14.617328, 121.262537),
  ('Romblon', 'Province, MIMAROPA Region', 'Province', 12.435564, 122.234537),
  ('Samar', 'Province, Region VIII (Eastern Visayas)', 'Province', 11.846163, 124.940475),
  ('Sarangani', 'Province, Region XII (SOCCSKSARGEN)', 'Province', 6.059589, 125.158327),
  ('Siquijor', 'Province, Negros Island Region (NIR)', 'Province', 9.185199, 123.588667),
  ('Sorsogon', 'Province, Region V (Bicol Region)', 'Province', 12.85425, 123.928586),
  ('South Cotabato', 'Province, Region XII (SOCCSKSARGEN)', 'Province', 6.306775, 124.813002),
  ('Southern Leyte', 'Province, Region VIII (Eastern Visayas)', 'Province', 10.291159, 125.051949),
  ('Sultan Kudarat', 'Province, Region XII (SOCCSKSARGEN)', 'Province', 6.534934, 124.431255),
  ('Sulu', 'Province, Region IX (Zamboanga Peninsula)', 'Province', 5.954663, 121.056167),
  ('Surigao del Norte', 'Province, Region XIII (Caraga)', 'Province', 9.670654, 125.737504),
  ('Surigao del Sur', 'Province, Region XIII (Caraga)', 'Province', 8.7759, 126.113138),
  ('Tarlac', 'Province, Region III (Central Luzon)', 'Province', 15.478243, 120.476199),
  ('Tawi-Tawi', 'Province, Bangsamoro Autonomous Region In Muslim Mindanao (BARMM)', 'Province', 5.238896, 119.900726),
  ('Zambales', 'Province, Region III (Central Luzon)', 'Province', 15.304493, 120.137358),
  ('Zamboanga Sibugay', 'Province, Region IX (Zamboanga Peninsula)', 'Province', 7.69468, 122.725437),
  ('Zamboanga del Norte', 'Province, Region IX (Zamboanga Peninsula)', 'Province', 8.048888, 122.806957),
  ('Zamboanga del Sur', 'Province, Region IX (Zamboanga Peninsula)', 'Province', 7.881254, 123.322396),
  ('Del Carmen', 'Barangay, Alaminos, Laguna', 'Barangay', 14.079527, 121.265654),
  ('Palma', 'Barangay, Alaminos, Laguna', 'Barangay', 14.025383, 121.231826),
  ('Barangay I', 'Barangay, Alaminos, Laguna', 'Barangay', 14.061689, 121.250574),
  ('Barangay II', 'Barangay, Alaminos, Laguna', 'Barangay', 14.06666, 121.23896),
  ('Barangay III', 'Barangay, Alaminos, Laguna', 'Barangay', 14.069351, 121.248467),
  ('Barangay IV', 'Barangay, Alaminos, Laguna', 'Barangay', 14.060995, 121.244406),
  ('San Agustin', 'Barangay, Alaminos, Laguna', 'Barangay', 14.05943, 121.264452),
  ('San Andres', 'Barangay, Alaminos, Laguna', 'Barangay', 14.07, 121.219237),
  ('San Benito', 'Barangay, Alaminos, Laguna', 'Barangay', 14.057026, 121.279929),
  ('San Gregorio', 'Barangay, Alaminos, Laguna', 'Barangay', 14.019298, 121.255905),
  ('San Ildefonso', 'Barangay, Alaminos, Laguna', 'Barangay', 14.044385, 121.220001),
  ('San Juan', 'Barangay, Alaminos, Laguna', 'Barangay', 14.06039, 121.231909),
  ('San Miguel', 'Barangay, Alaminos, Laguna', 'Barangay', 14.049058, 121.25607),
  ('San Roque', 'Barangay, Alaminos, Laguna', 'Barangay', 14.043475, 121.271562),
  ('Santa Rosa', 'Barangay, Alaminos, Laguna', 'Barangay', 14.041835, 121.242391),
  ('Bitin', 'Barangay, Bay, Laguna', 'Barangay', 14.100876, 121.2193),
  ('Calo', 'Barangay, Bay, Laguna', 'Barangay', 14.18358, 121.280488),
  ('Dila', 'Barangay, Bay, Laguna', 'Barangay', 14.176535, 121.292889),
  ('Maitim', 'Barangay, Bay, Laguna', 'Barangay', 14.185556, 121.273794),
  ('Masaya', 'Barangay, Bay, Laguna', 'Barangay', 14.144823, 121.277186),
  ('Paciano Rizal', 'Barangay, Bay, Laguna', 'Barangay', 14.150678, 121.266856),
  ('Puypuy', 'Barangay, Bay, Laguna', 'Barangay', 14.162397, 121.282924),
  ('San Antonio', 'Barangay, Bay, Laguna', 'Barangay', 14.191574, 121.281879),
  ('San Isidro', 'Barangay, Bay, Laguna', 'Barangay', 14.187914, 121.28595),
  ('Santa Cruz', 'Barangay, Bay, Laguna', 'Barangay', 14.121155, 121.245911),
  ('Santo Domingo', 'Barangay, Bay, Laguna', 'Barangay', 14.176936, 121.267725),
  ('Tagumpay', 'Barangay, Bay, Laguna', 'Barangay', 14.19387, 121.290499),
  ('Tranca', 'Barangay, Bay, Laguna', 'Barangay', 14.132901, 121.261523),
  ('San Agustin', 'Barangay, Bay, Laguna', 'Barangay', 14.180566, 121.283608),
  ('San Nicolas', 'Barangay, Bay, Laguna', 'Barangay', 14.182563, 121.284149),
  ('Biñan', 'Barangay, Biñan City, Laguna', 'Barangay', 14.264777, 121.049983),
  ('Bungahan', 'Barangay, Biñan City, Laguna', 'Barangay', 14.302339, 121.075179),
  ('Santo Tomas', 'Barangay, Biñan City, Laguna', 'Barangay', 14.313643, 121.072186),
  ('Canlalay', 'Barangay, Biñan City, Laguna', 'Barangay', 14.341781, 121.074062),
  ('Casile', 'Barangay, Biñan City, Laguna', 'Barangay', 14.343767, 121.08845),
  ('De La Paz', 'Barangay, Biñan City, Laguna', 'Barangay', 14.352475, 121.081871),
  ('Ganado', 'Barangay, Biñan City, Laguna', 'Barangay', 14.286363, 121.08311),
  ('San Francisco', 'Barangay, Biñan City, Laguna', 'Barangay', 14.333305, 121.054902),
  ('Langkiwa', 'Barangay, Biñan City, Laguna', 'Barangay', 14.296001, 121.059193),
  ('Loma', 'Barangay, Biñan City, Laguna', 'Barangay', 14.284607, 121.069082),
  ('Malaban', 'Barangay, Biñan City, Laguna', 'Barangay', 14.346418, 121.091204),
  ('Malamig', 'Barangay, Biñan City, Laguna', 'Barangay', 14.275609, 121.048062),
  ('Mampalasan', 'Barangay, Biñan City, Laguna', 'Barangay', 14.295678, 121.08112),
  ('Platero', 'Barangay, Biñan City, Laguna', 'Barangay', 14.32244, 121.09167),
  ('Poblacion', 'Barangay, Biñan City, Laguna', 'Barangay', 14.338126, 121.084286),
  ('Santo Niño', 'Barangay, Biñan City, Laguna', 'Barangay', 14.327366, 121.084382),
  ('San Antonio', 'Barangay, Biñan City, Laguna', 'Barangay', 14.333886, 121.090655),
  ('San Jose', 'Barangay, Biñan City, Laguna', 'Barangay', 14.342448, 121.082163),
  ('San Vicente', 'Barangay, Biñan City, Laguna', 'Barangay', 14.33232, 121.080236),
  ('Soro-soro', 'Barangay, Biñan City, Laguna', 'Barangay', 14.327116, 121.060316),
  ('Santo Domingo', 'Barangay, Biñan City, Laguna', 'Barangay', 14.337983, 121.081406),
  ('Timbao', 'Barangay, Biñan City, Laguna', 'Barangay', 14.283506, 121.054392),
  ('Tubigan', 'Barangay, Biñan City, Laguna', 'Barangay', 14.331018, 121.070829),
  ('Zapote', 'Barangay, Biñan City, Laguna', 'Barangay', 14.314199, 121.084122),
  ('Baclaran', 'Barangay, Cabuyao City, Laguna', 'Barangay', 14.24579, 121.163384),
  ('Banaybanay', 'Barangay, Cabuyao City, Laguna', 'Barangay', 14.254149, 121.13148),
  ('Banlic', 'Barangay, Cabuyao City, Laguna', 'Barangay', 14.23249, 121.138744),
  ('Butong', 'Barangay, Cabuyao City, Laguna', 'Barangay', 14.286226, 121.137568),
  ('Bigaa', 'Barangay, Cabuyao City, Laguna', 'Barangay', 14.284896, 121.130525),
  ('Casile', 'Barangay, Cabuyao City, Laguna', 'Barangay', 14.185821, 121.03248),
  ('Gulod', 'Barangay, Cabuyao City, Laguna', 'Barangay', 14.257096, 121.160113),
  ('Mamatid', 'Barangay, Cabuyao City, Laguna', 'Barangay', 14.238286, 121.156838),
  ('Marinig', 'Barangay, Cabuyao City, Laguna', 'Barangay', 14.272306, 121.149787),
  ('Niugan', 'Barangay, Cabuyao City, Laguna', 'Barangay', 14.262077, 121.130654),
  ('Pittland', 'Barangay, Cabuyao City, Laguna', 'Barangay', 14.219227, 121.067628),
  ('Pulo', 'Barangay, Cabuyao City, Laguna', 'Barangay', 14.245273, 121.129711),
  ('Sala', 'Barangay, Cabuyao City, Laguna', 'Barangay', 14.268562, 121.124428),
  ('San Isidro', 'Barangay, Cabuyao City, Laguna', 'Barangay', 14.243292, 121.140406),
  ('Diezmo', 'Barangay, Cabuyao City, Laguna', 'Barangay', 14.23399, 121.101138),
  ('Barangay Uno', 'Barangay, Cabuyao City, Laguna', 'Barangay', 14.279925, 121.123878),
  ('Barangay Dos', 'Barangay, Cabuyao City, Laguna', 'Barangay', 14.277041, 121.125021),
  ('Barangay Tres', 'Barangay, Cabuyao City, Laguna', 'Barangay', 14.27537, 121.122847),
  ('Bagong Kalsada', 'Barangay, Calamba City, Laguna', 'Barangay', 14.170713, 121.194811),
  ('Banadero', 'Barangay, Calamba City, Laguna', 'Barangay', 14.219661, 121.163288),
  ('Banlic', 'Barangay, Calamba City, Laguna', 'Barangay', 14.227816, 121.158329),
  ('Barandal', 'Barangay, Calamba City, Laguna', 'Barangay', 14.193213, 121.127659),
  ('Bubuyan', 'Barangay, Calamba City, Laguna', 'Barangay', 14.172781, 121.106304),
  ('Bucal', 'Barangay, Calamba City, Laguna', 'Barangay', 14.18561, 121.172527),
  ('Bunggo', 'Barangay, Calamba City, Laguna', 'Barangay', 14.158956, 121.068477),
  ('Burol', 'Barangay, Calamba City, Laguna', 'Barangay', 14.164036, 121.094329),
  ('Camaligan', 'Barangay, Calamba City, Laguna', 'Barangay', 14.158151, 121.150747),
  ('Canlubang', 'Barangay, Calamba City, Laguna', 'Barangay', 14.198273, 121.077121),
  ('Halang', 'Barangay, Calamba City, Laguna', 'Barangay', 14.195769, 121.169008),
  ('Hornalan', 'Barangay, Calamba City, Laguna', 'Barangay', 14.167287, 121.064781),
  ('Kay-Anlog', 'Barangay, Calamba City, Laguna', 'Barangay', 14.162435, 121.115133),
  ('Laguerta', 'Barangay, Calamba City, Laguna', 'Barangay', 14.173751, 121.087746),
  ('La Mesa', 'Barangay, Calamba City, Laguna', 'Barangay', 14.18446, 121.151815),
  ('Lawa', 'Barangay, Calamba City, Laguna', 'Barangay', 14.205608, 121.14493),
  ('Lecheria', 'Barangay, Calamba City, Laguna', 'Barangay', 14.202025, 121.171094),
  ('Lingga', 'Barangay, Calamba City, Laguna', 'Barangay', 14.209658, 121.180906),
  ('Looc', 'Barangay, Calamba City, Laguna', 'Barangay', 14.227241, 121.178263),
  ('Mabato', 'Barangay, Calamba City, Laguna', 'Barangay', 14.161241, 121.034787),
  ('Makiling', 'Barangay, Calamba City, Laguna', 'Barangay', 14.1529, 121.138787),
  ('Mapagong', 'Barangay, Calamba City, Laguna', 'Barangay', 14.225997, 121.128501),
  ('Masili', 'Barangay, Calamba City, Laguna', 'Barangay', 14.181689, 121.202373),
  ('Maunong', 'Barangay, Calamba City, Laguna', 'Barangay', 14.169361, 121.161019),
  ('Mayapa', 'Barangay, Calamba City, Laguna', 'Barangay', 14.211259, 121.123053),
  ('Paciano Rizal', 'Barangay, Calamba City, Laguna', 'Barangay', 14.214568, 121.134913),
  ('Palingon', 'Barangay, Calamba City, Laguna', 'Barangay', 14.215608, 121.189135),
  ('Palo-Alto', 'Barangay, Calamba City, Laguna', 'Barangay', 14.189151, 121.111233),
  ('Pansol', 'Barangay, Calamba City, Laguna', 'Barangay', 14.177183, 121.185453),
  ('Parian', 'Barangay, Calamba City, Laguna', 'Barangay', 14.213836, 121.148447),
  ('Barangay 1', 'Barangay, Calamba City, Laguna', 'Barangay', 14.205103, 121.157305),
  ('Barangay 2', 'Barangay, Calamba City, Laguna', 'Barangay', 14.21274, 121.160117),
  ('Barangay 3', 'Barangay, Calamba City, Laguna', 'Barangay', 14.208154, 121.161536),
  ('Barangay 4', 'Barangay, Calamba City, Laguna', 'Barangay', 14.21501, 121.166126),
  ('Barangay 5', 'Barangay, Calamba City, Laguna', 'Barangay', 14.209253, 121.166674),
  ('Barangay 6', 'Barangay, Calamba City, Laguna', 'Barangay', 14.213361, 121.164891),
  ('Barangay 7', 'Barangay, Calamba City, Laguna', 'Barangay', 14.20996, 121.171093),
  ('Prinza', 'Barangay, Calamba City, Laguna', 'Barangay', 14.197775, 121.139),
  ('Punta', 'Barangay, Calamba City, Laguna', 'Barangay', 14.178167, 121.12025),
  ('Puting Lupa', 'Barangay, Calamba City, Laguna', 'Barangay', 14.152536, 121.169065),
  ('Real', 'Barangay, Calamba City, Laguna', 'Barangay', 14.197706, 121.151114),
  ('Sucol', 'Barangay, Calamba City, Laguna', 'Barangay', 14.179719, 121.197453),
  ('Saimsim', 'Barangay, Calamba City, Laguna', 'Barangay', 14.163313, 121.147575),
  ('Sampiruhan', 'Barangay, Calamba City, Laguna', 'Barangay', 14.219893, 121.183898),
  ('San Cristobal', 'Barangay, Calamba City, Laguna', 'Barangay', 14.223576, 121.143428),
  ('San Jose', 'Barangay, Calamba City, Laguna', 'Barangay', 14.212838, 121.175083),
  ('San Juan', 'Barangay, Calamba City, Laguna', 'Barangay', 14.216506, 121.173753),
  ('Sirang Lupa', 'Barangay, Calamba City, Laguna', 'Barangay', 14.201253, 121.104238),
  ('Milagrosa', 'Barangay, Calamba City, Laguna', 'Barangay', 14.17389, 121.134908),
  ('Turbina', 'Barangay, Calamba City, Laguna', 'Barangay', 14.188508, 121.138278),
  ('Ulango', 'Barangay, Calamba City, Laguna', 'Barangay', 14.154479, 121.123086),
  ('Uwisan', 'Barangay, Calamba City, Laguna', 'Barangay', 14.234425, 121.173641),
  ('Batino', 'Barangay, Calamba City, Laguna', 'Barangay', 14.20218, 121.13286),
  ('Majada Labas', 'Barangay, Calamba City, Laguna', 'Barangay', 14.195632, 121.105326),
  ('Balayhangin', 'Barangay, Calauan, Laguna', 'Barangay', 14.130179, 121.312296),
  ('Bangyas', 'Barangay, Calauan, Laguna', 'Barangay', 14.178791, 121.315467),
  ('Dayap', 'Barangay, Calauan, Laguna', 'Barangay', 14.176995, 121.338504),
  ('Hanggan', 'Barangay, Calauan, Laguna', 'Barangay', 14.187858, 121.301409),
  ('Imok', 'Barangay, Calauan, Laguna', 'Barangay', 14.108703, 121.292535),
  ('Lamot 1', 'Barangay, Calauan, Laguna', 'Barangay', 14.140028, 121.326827),
  ('Lamot 2', 'Barangay, Calauan, Laguna', 'Barangay', 14.15324, 121.333298),
  ('Limao', 'Barangay, Calauan, Laguna', 'Barangay', 14.090285, 121.244062),
  ('Mabacan', 'Barangay, Calauan, Laguna', 'Barangay', 14.135753, 121.288634),
  ('Masiit', 'Barangay, Calauan, Laguna', 'Barangay', 14.157967, 121.304293),
  ('Paliparan', 'Barangay, Calauan, Laguna', 'Barangay', 14.122298, 121.286739),
  ('Perez', 'Barangay, Calauan, Laguna', 'Barangay', 14.111965, 121.268031),
  ('Kanluran', 'Barangay, Calauan, Laguna', 'Barangay', 14.145149, 121.312606),
  ('Silangan', 'Barangay, Calauan, Laguna', 'Barangay', 14.147412, 121.315544),
  ('Prinza', 'Barangay, Calauan, Laguna', 'Barangay', 14.134702, 121.322919),
  ('San Isidro', 'Barangay, Calauan, Laguna', 'Barangay', 14.161753, 121.317021),
  ('Santo Tomas', 'Barangay, Calauan, Laguna', 'Barangay', 14.158744, 121.349019),
  ('Anglas', 'Barangay, Cavinti, Laguna', 'Barangay', 14.258699, 121.484803),
  ('Bangco', 'Barangay, Cavinti, Laguna', 'Barangay', 14.241429, 121.480282),
  ('Bukal', 'Barangay, Cavinti, Laguna', 'Barangay', 14.233526, 121.549627),
  ('Bulajo', 'Barangay, Cavinti, Laguna', 'Barangay', 14.225025, 121.491443),
  ('Cansuso', 'Barangay, Cavinti, Laguna', 'Barangay', 14.253342, 121.60079),
  ('Duhat', 'Barangay, Cavinti, Laguna', 'Barangay', 14.246527, 121.496039),
  ('Inao-Awan', 'Barangay, Cavinti, Laguna', 'Barangay', 14.2569, 121.532068),
  ('Kanluran Talaongan', 'Barangay, Cavinti, Laguna', 'Barangay', 14.276797, 121.514114),
  ('Labayo', 'Barangay, Cavinti, Laguna', 'Barangay', 14.227659, 121.508061),
  ('Layasin', 'Barangay, Cavinti, Laguna', 'Barangay', 14.233621, 121.489685),
  ('Layug', 'Barangay, Cavinti, Laguna', 'Barangay', 14.229121, 121.538565),
  ('Mahipon', 'Barangay, Cavinti, Laguna', 'Barangay', 14.26848, 121.551546),
  ('Paowin', 'Barangay, Cavinti, Laguna', 'Barangay', 14.257845, 121.569372),
  ('Poblacion', 'Barangay, Cavinti, Laguna', 'Barangay', 14.245669, 121.510347),
  ('Sisilmin', 'Barangay, Cavinti, Laguna', 'Barangay', 14.244454, 121.529081),
  ('Silangan Talaongan', 'Barangay, Cavinti, Laguna', 'Barangay', 14.277944, 121.536513),
  ('Sumucab', 'Barangay, Cavinti, Laguna', 'Barangay', 14.215136, 121.576321),
  ('Tibatib', 'Barangay, Cavinti, Laguna', 'Barangay', 14.257233, 121.512687),
  ('Udia', 'Barangay, Cavinti, Laguna', 'Barangay', 14.223006, 121.531351),
  ('Asana', 'Barangay, Famy, Laguna', 'Barangay', 14.438517, 121.448947),
  ('Bacong-Sigsigan', 'Barangay, Famy, Laguna', 'Barangay', 14.510281, 121.481069),
  ('Bagong Pag-Asa', 'Barangay, Famy, Laguna', 'Barangay', 14.436856, 121.448753),
  ('Balitoc', 'Barangay, Famy, Laguna', 'Barangay', 14.447315, 121.438511),
  ('Banaba', 'Barangay, Famy, Laguna', 'Barangay', 14.437847, 121.44955),
  ('Batuhan', 'Barangay, Famy, Laguna', 'Barangay', 14.433926, 121.442257),
  ('Bulihan', 'Barangay, Famy, Laguna', 'Barangay', 14.447713, 121.447863),
  ('Caballero', 'Barangay, Famy, Laguna', 'Barangay', 14.440198, 121.448867),
  ('Calumpang', 'Barangay, Famy, Laguna', 'Barangay', 14.43681, 121.447703),
  ('Kapatalan', 'Barangay, Famy, Laguna', 'Barangay', 14.48248, 121.501473),
  ('Cuebang Bato', 'Barangay, Famy, Laguna', 'Barangay', 14.496721, 121.467502),
  ('Damayan', 'Barangay, Famy, Laguna', 'Barangay', 14.440397, 121.45035),
  ('Kataypuanan', 'Barangay, Famy, Laguna', 'Barangay', 14.491245, 121.482504),
  ('Liyang', 'Barangay, Famy, Laguna', 'Barangay', 14.483634, 121.471104),
  ('Maate', 'Barangay, Famy, Laguna', 'Barangay', 14.476326, 121.463607),
  ('Magdalo', 'Barangay, Famy, Laguna', 'Barangay', 14.438458, 121.447946),
  ('Mayatba', 'Barangay, Famy, Laguna', 'Barangay', 14.474827, 121.473468),
  ('Minayutan', 'Barangay, Famy, Laguna', 'Barangay', 14.4819, 121.482616),
  ('Salangbato', 'Barangay, Famy, Laguna', 'Barangay', 14.462842, 121.457132),
  ('Tunhac', 'Barangay, Famy, Laguna', 'Barangay', 14.443376, 121.452602),
  ('Longos', 'Barangay, Kalayaan, Laguna', 'Barangay', 14.340756, 121.489364),
  ('San Antonio', 'Barangay, Kalayaan, Laguna', 'Barangay', 14.334226, 121.548987),
  ('San Juan', 'Barangay, Kalayaan, Laguna', 'Barangay', 14.324071, 121.501115),
  ('Bagong Anyo', 'Barangay, Liliw, Laguna', 'Barangay', 14.131348, 121.436458),
  ('Bayate', 'Barangay, Liliw, Laguna', 'Barangay', 14.180005, 121.418035),
  ('Bubukal', 'Barangay, Liliw, Laguna', 'Barangay', 14.155078, 121.433976),
  ('Bongkol', 'Barangay, Liliw, Laguna', 'Barangay', 14.14713, 121.440125),
  ('Cabuyew', 'Barangay, Liliw, Laguna', 'Barangay', 14.167554, 121.423316),
  ('Calumpang', 'Barangay, Liliw, Laguna', 'Barangay', 14.197525, 121.403984),
  ('Culoy', 'Barangay, Liliw, Laguna', 'Barangay', 14.155536, 121.428426),
  ('Dagatan', 'Barangay, Liliw, Laguna', 'Barangay', 14.189604, 121.374489),
  ('Daniw', 'Barangay, Liliw, Laguna', 'Barangay', 14.193835, 121.382392),
  ('Dita', 'Barangay, Liliw, Laguna', 'Barangay', 14.20398, 121.388723),
  ('Ibabang Palina', 'Barangay, Liliw, Laguna', 'Barangay', 14.152133, 121.422209),
  ('Ibabang San Roque', 'Barangay, Liliw, Laguna', 'Barangay', 14.131591, 121.447872),
  ('Ibabang Sungi', 'Barangay, Liliw, Laguna', 'Barangay', 14.117363, 121.439684),
  ('Ibabang Taykin', 'Barangay, Liliw, Laguna', 'Barangay', 14.14036, 121.442218),
  ('Ilayang Palina', 'Barangay, Liliw, Laguna', 'Barangay', 14.139833, 121.427534),
  ('Ilayang San Roque', 'Barangay, Liliw, Laguna', 'Barangay', 14.122637, 121.45399),
  ('Ilayang Sungi', 'Barangay, Liliw, Laguna', 'Barangay', 14.092262, 121.461471),
  ('Ilayang Taykin', 'Barangay, Liliw, Laguna', 'Barangay', 14.136493, 121.445656),
  ('Kanlurang Bukal', 'Barangay, Liliw, Laguna', 'Barangay', 14.123676, 121.443755),
  ('Laguan', 'Barangay, Liliw, Laguna', 'Barangay', 14.129948, 121.430816),
  ('Rizal', 'Barangay, Liliw, Laguna', 'Barangay', 14.131477, 121.435862),
  ('Luquin', 'Barangay, Liliw, Laguna', 'Barangay', 14.089501, 121.477001),
  ('Malabo-Kalantukan', 'Barangay, Liliw, Laguna', 'Barangay', 14.20478, 121.406815),
  ('Masikap', 'Barangay, Liliw, Laguna', 'Barangay', 14.130622, 121.434361),
  ('Maslun', 'Barangay, Liliw, Laguna', 'Barangay', 14.131591, 121.437049),
  ('Mojon', 'Barangay, Liliw, Laguna', 'Barangay', 14.212973, 121.397921),
  ('Novaliches', 'Barangay, Liliw, Laguna', 'Barangay', 14.110515, 121.458643),
  ('Oples', 'Barangay, Liliw, Laguna', 'Barangay', 14.123181, 121.436574),
  ('Pag-Asa', 'Barangay, Liliw, Laguna', 'Barangay', 14.131182, 121.435293),
  ('Palayan', 'Barangay, Liliw, Laguna', 'Barangay', 14.142655, 121.432613),
  ('San Isidro', 'Barangay, Liliw, Laguna', 'Barangay', 14.196078, 121.39232),
  ('Silangang Bukal', 'Barangay, Liliw, Laguna', 'Barangay', 14.128208, 121.452239),
  ('Tuy-Baanan', 'Barangay, Liliw, Laguna', 'Barangay', 14.157784, 121.439009),
  ('Anos', 'Barangay, Los Baños, Laguna', 'Barangay', 14.173639, 121.231819),
  ('Bagong Silang', 'Barangay, Los Baños, Laguna', 'Barangay', 14.125093, 121.227536),
  ('Bambang', 'Barangay, Los Baños, Laguna', 'Barangay', 14.15286, 121.205641),
  ('Batong Malake', 'Barangay, Los Baños, Laguna', 'Barangay', 14.147736, 121.22781),
  ('Baybayin', 'Barangay, Los Baños, Laguna', 'Barangay', 14.181377, 121.223778),
  ('Bayog', 'Barangay, Los Baños, Laguna', 'Barangay', 14.188231, 121.249354),
  ('Lalakay', 'Barangay, Los Baños, Laguna', 'Barangay', 14.155834, 121.194475),
  ('Maahas', 'Barangay, Los Baños, Laguna', 'Barangay', 14.173082, 121.25902),
  ('Mayondon', 'Barangay, Los Baños, Laguna', 'Barangay', 14.188445, 121.238479),
  ('Putho Tuntungin', 'Barangay, Los Baños, Laguna', 'Barangay', 14.152299, 121.252944),
  ('San Antonio', 'Barangay, Los Baños, Laguna', 'Barangay', 14.172036, 121.248706),
  ('Tadlak', 'Barangay, Los Baños, Laguna', 'Barangay', 14.179756, 121.2071),
  ('Timugan', 'Barangay, Los Baños, Laguna', 'Barangay', 14.149451, 121.212748),
  ('Malinta', 'Barangay, Los Baños, Laguna', 'Barangay', 14.184127, 121.231592),
  ('De La Paz', 'Barangay, Luisiana, Laguna', 'Barangay', 14.185642, 121.540245),
  ('Barangay Zone I', 'Barangay, Luisiana, Laguna', 'Barangay', 14.184764, 121.508919),
  ('Barangay Zone II', 'Barangay, Luisiana, Laguna', 'Barangay', 14.184051, 121.51036),
  ('Barangay Zone III', 'Barangay, Luisiana, Laguna', 'Barangay', 14.184033, 121.511261),
  ('Barangay Zone IV', 'Barangay, Luisiana, Laguna', 'Barangay', 14.184187, 121.513808),
  ('Barangay Zone V', 'Barangay, Luisiana, Laguna', 'Barangay', 14.185581, 121.513636),
  ('Barangay Zone VI', 'Barangay, Luisiana, Laguna', 'Barangay', 14.185511, 121.512108),
  ('Barangay Zone VII', 'Barangay, Luisiana, Laguna', 'Barangay', 14.185452, 121.511182),
  ('Barangay Zone VIII', 'Barangay, Luisiana, Laguna', 'Barangay', 14.185318, 121.510061),
  ('San Antonio', 'Barangay, Luisiana, Laguna', 'Barangay', 14.19886, 121.497704),
  ('San Buenaventura', 'Barangay, Luisiana, Laguna', 'Barangay', 14.182159, 121.573338),
  ('San Diego', 'Barangay, Luisiana, Laguna', 'Barangay', 14.186896, 121.486559),
  ('San Isidro', 'Barangay, Luisiana, Laguna', 'Barangay', 14.178607, 121.514748),
  ('San Jose', 'Barangay, Luisiana, Laguna', 'Barangay', 14.203847, 121.51015),
  ('San Juan', 'Barangay, Luisiana, Laguna', 'Barangay', 14.203721, 121.521086),
  ('San Luis', 'Barangay, Luisiana, Laguna', 'Barangay', 14.170753, 121.501749),
  ('San Pablo', 'Barangay, Luisiana, Laguna', 'Barangay', 14.200415, 121.53005),
  ('San Pedro', 'Barangay, Luisiana, Laguna', 'Barangay', 14.172991, 121.5301),
  ('San Rafael', 'Barangay, Luisiana, Laguna', 'Barangay', 14.158196, 121.520416),
  ('San Roque', 'Barangay, Luisiana, Laguna', 'Barangay', 14.159744, 121.507592),
  ('San Salvador', 'Barangay, Luisiana, Laguna', 'Barangay', 14.211599, 121.477459),
  ('Santo Domingo', 'Barangay, Luisiana, Laguna', 'Barangay', 14.201844, 121.542968),
  ('Santo Tomas', 'Barangay, Luisiana, Laguna', 'Barangay', 14.187536, 121.516985),
  ('Bagong Silang', 'Barangay, Lumban, Laguna', 'Barangay', 14.296051, 121.466143),
  ('Balimbingan', 'Barangay, Lumban, Laguna', 'Barangay', 14.300092, 121.460812),
  ('Balubad', 'Barangay, Lumban, Laguna', 'Barangay', 14.277577, 121.480827),
  ('Caliraya', 'Barangay, Lumban, Laguna', 'Barangay', 14.294834, 121.578341),
  ('Concepcion', 'Barangay, Lumban, Laguna', 'Barangay', 14.299534, 121.452356),
  ('Lewin', 'Barangay, Lumban, Laguna', 'Barangay', 14.30495, 121.496776),
  ('Maracta', 'Barangay, Lumban, Laguna', 'Barangay', 14.298709, 121.459419),
  ('Maytalang I', 'Barangay, Lumban, Laguna', 'Barangay', 14.287812, 121.45656),
  ('Maytalang II', 'Barangay, Lumban, Laguna', 'Barangay', 14.290178, 121.438122),
  ('Primera Parang', 'Barangay, Lumban, Laguna', 'Barangay', 14.292511, 121.460847),
  ('Primera Pulo', 'Barangay, Lumban, Laguna', 'Barangay', 14.301438, 121.461306),
  ('Salac', 'Barangay, Lumban, Laguna', 'Barangay', 14.295358, 121.460576),
  ('Segunda Parang', 'Barangay, Lumban, Laguna', 'Barangay', 14.294115, 121.460343),
  ('Segunda Pulo', 'Barangay, Lumban, Laguna', 'Barangay', 14.303485, 121.462167),
  ('Santo Niño', 'Barangay, Lumban, Laguna', 'Barangay', 14.296985, 121.459659),
  ('Wawa', 'Barangay, Lumban, Laguna', 'Barangay', 14.321828, 121.44773),
  ('Amuyong', 'Barangay, Mabitac, Laguna', 'Barangay', 14.42934, 121.377527),
  ('Lambac', 'Barangay, Mabitac, Laguna', 'Barangay', 14.410488, 121.43125),
  ('Lucong', 'Barangay, Mabitac, Laguna', 'Barangay', 14.423968, 121.43281),
  ('Matalatala', 'Barangay, Mabitac, Laguna', 'Barangay', 14.413409, 121.415714),
  ('Nanguma', 'Barangay, Mabitac, Laguna', 'Barangay', 14.440777, 121.42332),
  ('Numero', 'Barangay, Mabitac, Laguna', 'Barangay', 14.415822, 121.391697),
  ('Paagahan', 'Barangay, Mabitac, Laguna', 'Barangay', 14.444274, 121.4004),
  ('Bayanihan', 'Barangay, Mabitac, Laguna', 'Barangay', 14.424813, 121.428061),
  ('Libis ng Nayon', 'Barangay, Mabitac, Laguna', 'Barangay', 14.43257, 121.432641),
  ('Maligaya', 'Barangay, Mabitac, Laguna', 'Barangay', 14.427013, 121.432706),
  ('Masikap', 'Barangay, Mabitac, Laguna', 'Barangay', 14.423144, 121.430278),
  ('Pag-Asa', 'Barangay, Mabitac, Laguna', 'Barangay', 14.42361, 121.428352),
  ('Sinagtala', 'Barangay, Mabitac, Laguna', 'Barangay', 14.431297, 121.423934),
  ('San Antonio', 'Barangay, Mabitac, Laguna', 'Barangay', 14.451088, 121.420089),
  ('San Miguel', 'Barangay, Mabitac, Laguna', 'Barangay', 14.450851, 121.376437),
  ('Alipit', 'Barangay, Magdalena, Laguna', 'Barangay', 14.221624, 121.412879),
  ('Malaking Ambling', 'Barangay, Magdalena, Laguna', 'Barangay', 14.191745, 121.433016),
  ('Munting Ambling', 'Barangay, Magdalena, Laguna', 'Barangay', 14.200438, 121.436888),
  ('Baanan', 'Barangay, Magdalena, Laguna', 'Barangay', 14.169282, 121.433926),
  ('Balanac', 'Barangay, Magdalena, Laguna', 'Barangay', 14.218376, 121.454115),
  ('Bucal', 'Barangay, Magdalena, Laguna', 'Barangay', 14.208328, 121.439886),
  ('Buenavista', 'Barangay, Magdalena, Laguna', 'Barangay', 14.222683, 121.424501),
  ('Bungkol', 'Barangay, Magdalena, Laguna', 'Barangay', 14.177486, 121.430602),
  ('Buo', 'Barangay, Magdalena, Laguna', 'Barangay', 14.203826, 121.457424),
  ('Burlungan', 'Barangay, Magdalena, Laguna', 'Barangay', 14.181909, 121.435875),
  ('Cigaras', 'Barangay, Magdalena, Laguna', 'Barangay', 14.225676, 121.435025),
  ('Ibabang Atingay', 'Barangay, Magdalena, Laguna', 'Barangay', 14.204983, 121.446403),
  ('Ibabang Butnong', 'Barangay, Magdalena, Laguna', 'Barangay', 14.208635, 121.424418),
  ('Ilayang Atingay', 'Barangay, Magdalena, Laguna', 'Barangay', 14.192176, 121.444415),
  ('Ilayang Butnong', 'Barangay, Magdalena, Laguna', 'Barangay', 14.200674, 121.423441),
  ('Ilog', 'Barangay, Magdalena, Laguna', 'Barangay', 14.217946, 121.442196),
  ('Malinao', 'Barangay, Magdalena, Laguna', 'Barangay', 14.203448, 121.413877),
  ('Maravilla', 'Barangay, Magdalena, Laguna', 'Barangay', 14.211205, 121.414608),
  ('Poblacion', 'Barangay, Magdalena, Laguna', 'Barangay', 14.200066, 121.429136),
  ('Sabang', 'Barangay, Magdalena, Laguna', 'Barangay', 14.230959, 121.451004),
  ('Salasad', 'Barangay, Magdalena, Laguna', 'Barangay', 14.211652, 121.432525),
  ('Tanawan', 'Barangay, Magdalena, Laguna', 'Barangay', 14.194358, 121.456611),
  ('Tipunan', 'Barangay, Magdalena, Laguna', 'Barangay', 14.193214, 121.427338),
  ('Halayhayin', 'Barangay, Magdalena, Laguna', 'Barangay', 14.191846, 121.418074),
  ('Amonoy', 'Barangay, Majayjay, Laguna', 'Barangay', 14.104667, 121.496258),
  ('Bakia', 'Barangay, Majayjay, Laguna', 'Barangay', 14.157723, 121.489195),
  ('Bukal', 'Barangay, Majayjay, Laguna', 'Barangay', 14.113426, 121.472997),
  ('Balanac', 'Barangay, Majayjay, Laguna', 'Barangay', 14.177063, 121.456049),
  ('Balayong', 'Barangay, Majayjay, Laguna', 'Barangay', 14.12904, 121.485772),
  ('Banilad', 'Barangay, Majayjay, Laguna', 'Barangay', 14.188619, 121.464965),
  ('Banti', 'Barangay, Majayjay, Laguna', 'Barangay', 14.180473, 121.464533),
  ('Bitaoy', 'Barangay, Majayjay, Laguna', 'Barangay', 14.137686, 121.511878),
  ('Botocan', 'Barangay, Majayjay, Laguna', 'Barangay', 14.15365, 121.50008),
  ('Burgos', 'Barangay, Majayjay, Laguna', 'Barangay', 14.126925, 121.499956),
  ('Burol', 'Barangay, Majayjay, Laguna', 'Barangay', 14.169561, 121.478699),
  ('Coralao', 'Barangay, Majayjay, Laguna', 'Barangay', 14.141041, 121.461893),
  ('Gagalot', 'Barangay, Majayjay, Laguna', 'Barangay', 14.120005, 121.509619),
  ('Ibabang Banga', 'Barangay, Majayjay, Laguna', 'Barangay', 14.152937, 121.477426),
  ('Ibabang Bayucain', 'Barangay, Majayjay, Laguna', 'Barangay', 14.166461, 121.443126),
  ('Ilayang Banga', 'Barangay, Majayjay, Laguna', 'Barangay', 14.145448, 121.484416),
  ('Ilayang Bayucain', 'Barangay, Majayjay, Laguna', 'Barangay', 14.156609, 121.446237),
  ('Isabang', 'Barangay, Majayjay, Laguna', 'Barangay', 14.146828, 121.508771),
  ('Malinao', 'Barangay, Majayjay, Laguna', 'Barangay', 14.105074, 121.48448),
  ('May-It', 'Barangay, Majayjay, Laguna', 'Barangay', 14.139033, 121.487611),
  ('Munting Kawayan', 'Barangay, Majayjay, Laguna', 'Barangay', 14.158296, 121.465192),
  ('Oobi', 'Barangay, Majayjay, Laguna', 'Barangay', 14.121558, 121.484272),
  ('Olla', 'Barangay, Majayjay, Laguna', 'Barangay', 14.160154, 121.454984),
  ('Origuel', 'Barangay, Majayjay, Laguna', 'Barangay', 14.14305, 121.473282),
  ('Panalaban', 'Barangay, Majayjay, Laguna', 'Barangay', 14.124963, 121.494006),
  ('Panglan', 'Barangay, Majayjay, Laguna', 'Barangay', 14.142071, 121.452861),
  ('Pangil', 'Barangay, Majayjay, Laguna', 'Barangay', 14.133035, 121.465527),
  ('Piit', 'Barangay, Majayjay, Laguna', 'Barangay', 14.142023, 121.499914),
  ('Pook', 'Barangay, Majayjay, Laguna', 'Barangay', 14.171314, 121.465056),
  ('Rizal', 'Barangay, Majayjay, Laguna', 'Barangay', 14.127069, 121.514322),
  ('San Francisco', 'Barangay, Majayjay, Laguna', 'Barangay', 14.146393, 121.47346),
  ('San Isidro', 'Barangay, Majayjay, Laguna', 'Barangay', 14.176288, 121.441851),
  ('San Miguel', 'Barangay, Majayjay, Laguna', 'Barangay', 14.144018, 121.469855),
  ('San Roque', 'Barangay, Majayjay, Laguna', 'Barangay', 14.125732, 121.460965),
  ('Santa Catalina', 'Barangay, Majayjay, Laguna', 'Barangay', 14.150331, 121.468432),
  ('Suba', 'Barangay, Majayjay, Laguna', 'Barangay', 14.170929, 121.451796),
  ('Tanawan', 'Barangay, Majayjay, Laguna', 'Barangay', 14.184334, 121.453958),
  ('Taytay', 'Barangay, Majayjay, Laguna', 'Barangay', 14.102293, 121.503841),
  ('Talortor', 'Barangay, Majayjay, Laguna', 'Barangay', 14.149673, 121.458709),
  ('Villa Nogales', 'Barangay, Majayjay, Laguna', 'Barangay', 14.140652, 121.470272),
  ('Abo', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.098868, 121.435404),
  ('Alibungbungan', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.147232, 121.416399),
  ('Alumbrado', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.1371, 121.387538),
  ('Balayong', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.151685, 121.388962),
  ('Balimbing', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.117412, 121.432074),
  ('Balinacon', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.125195, 121.42323),
  ('Bambang', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.128318, 121.411412),
  ('Banago', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.113394, 121.418009),
  ('Banca-banca', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.185206, 121.3837),
  ('Bangcuro', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.172658, 121.407884),
  ('Banilad', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.123479, 121.403123),
  ('Bayaquitos', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.159723, 121.392137),
  ('Buboy', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.120411, 121.413856),
  ('Buenavista', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.170159, 121.381679),
  ('Buhanginan', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.191008, 121.393924),
  ('Bukal', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.075467, 121.447655),
  ('Bunga', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.147957, 121.399886)
) as v(name, sub, category, lat, lng)
where not exists (
  select 1 from public.pois p where p.name = v.name and p.sub = v.sub
);

insert into public.pois (name, sub, category, lat, lng)
select * from (values
  ('Cabuyew', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.163254, 121.407044),
  ('Calumpang', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.195975, 121.400248),
  ('Kanluran Kabubuhayan', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.185563, 121.396995),
  ('Silangan Kabubuhayan', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.189812, 121.403701),
  ('Labangan', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.169762, 121.396633),
  ('Lawaguin', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.158806, 121.371113),
  ('Kanluran Lazaan', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.079627, 121.459148),
  ('Silangan Lazaan', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.09898, 121.446498),
  ('Lagulo', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.177688, 121.395916),
  ('Maiit', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.131761, 121.393068),
  ('Malaya', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.111885, 121.409173),
  ('Malinao', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.109238, 121.438168),
  ('Manaol', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.18444, 121.365804),
  ('Maravilla', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.177816, 121.374627),
  ('Nagcalbang', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.180241, 121.403728),
  ('Poblacion I', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.138253, 121.41732),
  ('Poblacion II', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.135782, 121.414724),
  ('Poblacion III', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.134874, 121.418271),
  ('Oples', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.126324, 121.427387),
  ('Palayan', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.13706, 121.402105),
  ('Palina', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.14025, 121.420786),
  ('Sabang', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.145943, 121.388253),
  ('San Francisco', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.08581, 121.432215),
  ('Sibulan', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.178188, 121.386069),
  ('Silangan Napapatid', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.112268, 121.426533),
  ('Silangan Ilaya', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.125847, 121.419271),
  ('Sinipian', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.11687, 121.428122),
  ('Santa Lucia', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.178023, 121.410706),
  ('Sulsuguin', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.125875, 121.373152),
  ('Talahib', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.137568, 121.365795),
  ('Talangan', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.153406, 121.413286),
  ('Taytay', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.108999, 121.414759),
  ('Tipacan', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.153926, 121.405701),
  ('Wakat', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.175653, 121.358401),
  ('Yukos', 'Barangay, Nagcarlan, Laguna', 'Barangay', 14.140013, 121.409864),
  ('Bagumbayan', 'Barangay, Paete, Laguna', 'Barangay', 14.36868, 121.479289),
  ('Bangkusay', 'Barangay, Paete, Laguna', 'Barangay', 14.364837, 121.482785),
  ('Ermita', 'Barangay, Paete, Laguna', 'Barangay', 14.363372, 121.483499),
  ('Ibaba del Norte', 'Barangay, Paete, Laguna', 'Barangay', 14.364705, 121.477606),
  ('Ibaba del Sur', 'Barangay, Paete, Laguna', 'Barangay', 14.362204, 121.478192),
  ('Ilaya del Norte', 'Barangay, Paete, Laguna', 'Barangay', 14.364916, 121.484886),
  ('Ilaya del Sur', 'Barangay, Paete, Laguna', 'Barangay', 14.363595, 121.484778),
  ('Maytoong', 'Barangay, Paete, Laguna', 'Barangay', 14.363071, 121.482495),
  ('Quinale', 'Barangay, Paete, Laguna', 'Barangay', 14.356664, 121.482136),
  ('Anibong', 'Barangay, Pagsanjan, Laguna', 'Barangay', 14.230887, 121.46825),
  ('Biñan', 'Barangay, Pagsanjan, Laguna', 'Barangay', 14.266885, 121.434169),
  ('Buboy', 'Barangay, Pagsanjan, Laguna', 'Barangay', 14.233631, 121.4241),
  ('Cabanbanan', 'Barangay, Pagsanjan, Laguna', 'Barangay', 14.243592, 121.429066),
  ('Calusiche', 'Barangay, Pagsanjan, Laguna', 'Barangay', 14.255564, 121.445907),
  ('Dingin', 'Barangay, Pagsanjan, Laguna', 'Barangay', 14.244081, 121.449992),
  ('Lambac', 'Barangay, Pagsanjan, Laguna', 'Barangay', 14.250512, 121.463788),
  ('Layugan', 'Barangay, Pagsanjan, Laguna', 'Barangay', 14.239686, 121.439983),
  ('Magdapio', 'Barangay, Pagsanjan, Laguna', 'Barangay', 14.271333, 121.464132),
  ('Maulawin', 'Barangay, Pagsanjan, Laguna', 'Barangay', 14.266041, 121.451124),
  ('Pinagsanjan', 'Barangay, Pagsanjan, Laguna', 'Barangay', 14.263445, 121.462467),
  ('Barangay I', 'Barangay, Pagsanjan, Laguna', 'Barangay', 14.274332, 121.455936),
  ('Barangay II', 'Barangay, Pagsanjan, Laguna', 'Barangay', 14.275181, 121.450874),
  ('Sabang', 'Barangay, Pagsanjan, Laguna', 'Barangay', 14.253891, 121.433558),
  ('Sampaloc', 'Barangay, Pagsanjan, Laguna', 'Barangay', 14.270559, 121.444326),
  ('San Isidro', 'Barangay, Pagsanjan, Laguna', 'Barangay', 14.279777, 121.455201),
  ('Baño', 'Barangay, Pakil, Laguna', 'Barangay', 14.378857, 121.484584),
  ('Banilan', 'Barangay, Pakil, Laguna', 'Barangay', 14.382104, 121.396923),
  ('Burgos', 'Barangay, Pakil, Laguna', 'Barangay', 14.375892, 121.474831),
  ('Casa Real', 'Barangay, Pakil, Laguna', 'Barangay', 14.366528, 121.386634),
  ('Casinsin', 'Barangay, Pakil, Laguna', 'Barangay', 14.352365, 121.375729),
  ('Dorado', 'Barangay, Pakil, Laguna', 'Barangay', 14.395312, 121.37788),
  ('Gonzales', 'Barangay, Pakil, Laguna', 'Barangay', 14.381697, 121.472335),
  ('Kabulusan', 'Barangay, Pakil, Laguna', 'Barangay', 14.373369, 121.39499),
  ('Matikiw', 'Barangay, Pakil, Laguna', 'Barangay', 14.359655, 121.379931),
  ('Rizal', 'Barangay, Pakil, Laguna', 'Barangay', 14.389035, 121.496191),
  ('Saray', 'Barangay, Pakil, Laguna', 'Barangay', 14.409383, 121.525229),
  ('Taft', 'Barangay, Pakil, Laguna', 'Barangay', 14.37618, 121.481914),
  ('Tavera', 'Barangay, Pakil, Laguna', 'Barangay', 14.386834, 121.472548),
  ('Balian', 'Barangay, Pangil, Laguna', 'Barangay', 14.402273, 121.483495),
  ('Dambo', 'Barangay, Pangil, Laguna', 'Barangay', 14.400627, 121.402231),
  ('Galalan', 'Barangay, Pangil, Laguna', 'Barangay', 14.438379, 121.516357),
  ('Isla', 'Barangay, Pangil, Laguna', 'Barangay', 14.396483, 121.465225),
  ('Mabato-Azufre', 'Barangay, Pangil, Laguna', 'Barangay', 14.387749, 121.399208),
  ('Natividad', 'Barangay, Pangil, Laguna', 'Barangay', 14.410229, 121.475694),
  ('San Jose', 'Barangay, Pangil, Laguna', 'Barangay', 14.3973, 121.460002),
  ('Sulib', 'Barangay, Pangil, Laguna', 'Barangay', 14.418789, 121.471663),
  ('Aplaya', 'Barangay, Pila, Laguna', 'Barangay', 14.257964, 121.353891),
  ('Bagong Pook', 'Barangay, Pila, Laguna', 'Barangay', 14.257745, 121.366652),
  ('Bukal', 'Barangay, Pila, Laguna', 'Barangay', 14.209109, 121.365735),
  ('Bulilan Norte', 'Barangay, Pila, Laguna', 'Barangay', 14.238464, 121.365899),
  ('Bulilan Sur', 'Barangay, Pila, Laguna', 'Barangay', 14.229986, 121.368493),
  ('Concepcion', 'Barangay, Pila, Laguna', 'Barangay', 14.232615, 121.379107),
  ('Labuin', 'Barangay, Pila, Laguna', 'Barangay', 14.244345, 121.368501),
  ('Linga', 'Barangay, Pila, Laguna', 'Barangay', 14.25551, 121.360665),
  ('Masico', 'Barangay, Pila, Laguna', 'Barangay', 14.206581, 121.380326),
  ('Mojon', 'Barangay, Pila, Laguna', 'Barangay', 14.219569, 121.381983),
  ('Pansol', 'Barangay, Pila, Laguna', 'Barangay', 14.217478, 121.372682),
  ('Pinagbayanan', 'Barangay, Pila, Laguna', 'Barangay', 14.249337, 121.353073),
  ('San Antonio', 'Barangay, Pila, Laguna', 'Barangay', 14.218019, 121.358097),
  ('San Miguel', 'Barangay, Pila, Laguna', 'Barangay', 14.200848, 121.373616),
  ('Santa Clara Norte', 'Barangay, Pila, Laguna', 'Barangay', 14.23424, 121.35796),
  ('Santa Clara Sur', 'Barangay, Pila, Laguna', 'Barangay', 14.228021, 121.360241),
  ('Tubuan', 'Barangay, Pila, Laguna', 'Barangay', 14.235606, 121.34839),
  ('Antipolo', 'Barangay, Rizal, Laguna', 'Barangay', 14.1153, 121.378047),
  ('Entablado', 'Barangay, Rizal, Laguna', 'Barangay', 14.122035, 121.386401),
  ('Laguan', 'Barangay, Rizal, Laguna', 'Barangay', 14.118045, 121.399126),
  ('Paule 1', 'Barangay, Rizal, Laguna', 'Barangay', 14.109442, 121.397652),
  ('Paule 2', 'Barangay, Rizal, Laguna', 'Barangay', 14.114295, 121.392526),
  ('East Poblacion', 'Barangay, Rizal, Laguna', 'Barangay', 14.109778, 121.395079),
  ('West Poblacion', 'Barangay, Rizal, Laguna', 'Barangay', 14.110359, 121.392888),
  ('Pook', 'Barangay, Rizal, Laguna', 'Barangay', 14.103824, 121.411283),
  ('Tala', 'Barangay, Rizal, Laguna', 'Barangay', 14.085094, 121.409012),
  ('Talaga', 'Barangay, Rizal, Laguna', 'Barangay', 14.111479, 121.387728),
  ('Tuy', 'Barangay, Rizal, Laguna', 'Barangay', 14.106278, 121.401878),
  ('Bagong Bayan II-A', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.066616, 121.317562),
  ('Bagong Pook VI-C', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.074885, 121.320606),
  ('Barangay I-A', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.073107, 121.316647),
  ('Barangay I-B', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.069381, 121.31589),
  ('Barangay II-A', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.063099, 121.319434),
  ('Barangay II-B', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.06333, 121.321532),
  ('Barangay II-C', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.065908, 121.322625),
  ('Barangay II-D', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.067432, 121.323201),
  ('Barangay II-E', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.06509, 121.325206),
  ('Barangay II-F', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.061182, 121.322875),
  ('Barangay III-A', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.067084, 121.326748),
  ('Barangay III-B', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.069554, 121.327653),
  ('Barangay III-C', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.06745, 121.329599),
  ('Barangay III-D', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.070384, 121.330853),
  ('Barangay III-E', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.071016, 121.333504),
  ('Barangay III-F', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.068383, 121.328403),
  ('Barangay IV-A', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.072544, 121.330992),
  ('Barangay IV-B', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.071962, 121.327496),
  ('Barangay IV-C', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.072111, 121.326363),
  ('Barangay V-A', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.076753, 121.324647),
  ('Barangay V-B', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.072694, 121.324519),
  ('Barangay V-C', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.072429, 121.325067),
  ('Barangay V-D', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.072301, 121.325575),
  ('Barangay VI-A', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.073295, 121.322929),
  ('Barangay VI-B', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.07772, 121.323135),
  ('Barangay VI-D', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.077845, 121.320668),
  ('Barangay VI-E', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.074785, 121.317906),
  ('Barangay VII-A', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.070356, 121.321849),
  ('Barangay VII-B', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.069584, 121.32368),
  ('Barangay VII-C', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.06925, 121.325041),
  ('Barangay VII-D', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.068772, 121.325643),
  ('Barangay VII-E', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.068044, 121.324068),
  ('Bautista', 'Barangay, San Pablo City, Laguna', 'Barangay', 13.988888, 121.271493),
  ('Concepcion', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.080894, 121.341765),
  ('Del Remedio', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.083482, 121.311658),
  ('Dolores', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.10446, 121.336591),
  ('San Antonio 1', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.008621, 121.338289),
  ('San Antonio 2', 'Barangay, San Pablo City, Laguna', 'Barangay', 13.996083, 121.328985),
  ('San Bartolome', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.024542, 121.289051),
  ('San Buenaventura', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.116271, 121.329571),
  ('San Crispin', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.077876, 121.283295),
  ('San Cristobal', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.045313, 121.399091),
  ('San Diego', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.087876, 121.373562),
  ('San Francisco', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.056005, 121.33069),
  ('San Gabriel', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.055422, 121.313236),
  ('San Gregorio', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.044423, 121.327619),
  ('San Ignacio', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.049679, 121.345792),
  ('San Isidro', 'Barangay, San Pablo City, Laguna', 'Barangay', 13.982391, 121.305953),
  ('San Joaquin', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.028332, 121.328001),
  ('San Jose', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.067408, 121.367452),
  ('San Juan', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.094947, 121.296079),
  ('San Lorenzo', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.113344, 121.353231),
  ('San Lucas 1', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.083284, 121.326526),
  ('San Lucas 2', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.089432, 121.325883),
  ('San Marcos', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.103198, 121.304368),
  ('San Mateo', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.109384, 121.30445),
  ('San Miguel', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.0345, 121.301493),
  ('San Nicolas', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.065436, 121.291058),
  ('San Pedro', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.095518, 121.331456),
  ('San Rafael', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.072471, 121.301474),
  ('San Roque', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.069531, 121.311674),
  ('San Vicente', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.0245, 121.340164),
  ('Santa Ana', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.013987, 121.326132),
  ('Santa Catalina', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.126449, 121.347433),
  ('Santa Cruz', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.023959, 121.352575),
  ('Santa Felomina', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.089468, 121.285087),
  ('Santa Isabel', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.081957, 121.366702),
  ('Santa Maria Magdalena', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.096726, 121.31228),
  ('Santa Veronica', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.043959, 121.287522),
  ('Santiago I', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.019498, 121.282057),
  ('Santiago II', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.00188, 121.265282),
  ('Santisimo Rosario', 'Barangay, San Pablo City, Laguna', 'Barangay', 13.998517, 121.305846),
  ('Santo Angel', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.10284, 121.36756),
  ('Santo Cristo', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.064504, 121.330512),
  ('Santo Niño', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.048832, 121.362339),
  ('Soledad', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.040466, 121.316821),
  ('Atisan', 'Barangay, San Pablo City, Laguna', 'Barangay', 13.977747, 121.277804),
  ('Santa Elena', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.044759, 121.375578),
  ('Santa Maria', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.022704, 121.311854),
  ('Santa Monica', 'Barangay, San Pablo City, Laguna', 'Barangay', 14.055275, 121.300331),
  ('Bagong Silang', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.335365, 121.025275),
  ('Cuyab', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.37254, 121.058576),
  ('Estrella', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.33464, 121.019791),
  ('G.S.I.S.', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.350257, 121.038761),
  ('Landayan', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.355449, 121.06858),
  ('Langgam', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.326886, 121.014598),
  ('Laram', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.329344, 121.022947),
  ('Magsaysay', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.337802, 121.033541),
  ('Nueva', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.355093, 121.060216),
  ('Poblacion', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.363738, 121.059286),
  ('Riverside', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.332836, 121.027591),
  ('San Antonio', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.353449, 121.030685),
  ('San Roque', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.365445, 121.063662),
  ('San Vicente', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.345876, 121.033988),
  ('Santo Niño', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.367249, 121.057909),
  ('United Bayanihan', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.335388, 121.029813),
  ('United Better Living', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.337992, 121.022547),
  ('Sampaguita Village', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.344424, 121.034516),
  ('Calendola', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.341214, 121.034037),
  ('Narra', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.330941, 121.025588),
  ('Chrysanthemum', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.341115, 121.045094),
  ('Fatima', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.355443, 121.05514),
  ('Maharlika', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.347898, 121.044949),
  ('Pacita 1', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.34363, 121.056908),
  ('Pacita 2', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.349544, 121.053219),
  ('Rosario', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.336149, 121.043597),
  ('San Lorenzo Ruiz', 'Barangay, San Pedro City, Laguna', 'Barangay', 14.352156, 121.052025),
  ('Alipit', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.230782, 121.41051),
  ('Bagumbayan', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.272561, 121.39379),
  ('Bubukal', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.260549, 121.403548),
  ('Calios', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.279072, 121.404089),
  ('Duhat', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.256203, 121.376395),
  ('Gatid', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.265019, 121.383541),
  ('Jasaan', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.223624, 121.392128),
  ('Labuin', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.246117, 121.394137),
  ('Malinao', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.233323, 121.393471),
  ('Oogong', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.225698, 121.401624),
  ('Pagsawitan', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.271367, 121.424332),
  ('Palasan', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.251838, 121.418912),
  ('Patimbao', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.267358, 121.414891),
  ('Barangay I', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.276956, 121.417885),
  ('Barangay II', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.279804, 121.416192),
  ('Barangay III', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.282097, 121.415277),
  ('Barangay IV', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.283826, 121.414554),
  ('Barangay V', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.28546, 121.412829),
  ('San Jose', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.237885, 121.408836),
  ('San Juan', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.248622, 121.408574),
  ('San Pablo Norte', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.288951, 121.41902),
  ('San Pablo Sur', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.283394, 121.424615),
  ('Santisima Cruz', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.295465, 121.410367),
  ('Santo Angel Central', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.285175, 121.407534),
  ('Santo Angel Norte', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.293403, 121.403404),
  ('Santo Angel Sur', 'Barangay, Santa Cruz, Laguna', 'Barangay', 14.28041, 121.412187),
  ('Adia', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.484325, 121.434795),
  ('Bagong Pook', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.472251, 121.429085),
  ('Bagumbayan', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.511023, 121.434948),
  ('Bubukal', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.47925, 121.411494),
  ('Cabooan', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.459952, 121.434087),
  ('Calangay', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.508, 121.394585),
  ('Cambuja', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.472575, 121.391408),
  ('Coralan', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.494744, 121.422494),
  ('Cueva', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.517983, 121.459901),
  ('Inayapan', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.491851, 121.414603),
  ('Jose Laurel, Sr.', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.541334, 121.459955),
  ('Kayhakat', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.463769, 121.417016),
  ('Macasipac', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.499649, 121.439076),
  ('Masinao', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.494194, 121.430727),
  ('Mataling-Ting', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.531968, 121.396172),
  ('Pao-o', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.529933, 121.417425),
  ('Parang Ng Buho', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.530729, 121.434853),
  ('Barangay I', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.470054, 121.421999),
  ('Barangay II', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.469408, 121.423287),
  ('Barangay III', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.471382, 121.425689),
  ('Barangay IV', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.469411, 121.425717),
  ('Jose Rizal', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.463584, 121.423258),
  ('Santiago', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.568506, 121.456884),
  ('Talangka', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.478484, 121.446925),
  ('Tungkod', 'Barangay, Santa Maria, Laguna', 'Barangay', 14.488576, 121.383884),
  ('Aplaya', 'Barangay, Santa Rosa City, Laguna', 'Barangay', 14.316863, 121.121578),
  ('Balibago', 'Barangay, Santa Rosa City, Laguna', 'Barangay', 14.28792, 121.09907),
  ('Caingin', 'Barangay, Santa Rosa City, Laguna', 'Barangay', 14.302154, 121.125144),
  ('Dila', 'Barangay, Santa Rosa City, Laguna', 'Barangay', 14.291245, 121.114761),
  ('Dita', 'Barangay, Santa Rosa City, Laguna', 'Barangay', 14.280187, 121.11038),
  ('Don Jose', 'Barangay, Santa Rosa City, Laguna', 'Barangay', 14.250889, 121.079116),
  ('Ibaba', 'Barangay, Santa Rosa City, Laguna', 'Barangay', 14.313516, 121.118206),
  ('Labas', 'Barangay, Santa Rosa City, Laguna', 'Barangay', 14.307163, 121.109701),
  ('Macabling', 'Barangay, Santa Rosa City, Laguna', 'Barangay', 14.299619, 121.096047),
  ('Malitlit', 'Barangay, Santa Rosa City, Laguna', 'Barangay', 14.261892, 121.104998),
  ('Malusak', 'Barangay, Santa Rosa City, Laguna', 'Barangay', 14.310901, 121.11647),
  ('Market Area', 'Barangay, Santa Rosa City, Laguna', 'Barangay', 14.319706, 121.114407),
  ('Kanluran', 'Barangay, Santa Rosa City, Laguna', 'Barangay', 14.312208, 121.110065),
  ('Pooc', 'Barangay, Santa Rosa City, Laguna', 'Barangay', 14.301511, 121.115623),
  ('Pulong Santa Cruz', 'Barangay, Santa Rosa City, Laguna', 'Barangay', 14.274131, 121.084169),
  ('Santo Domingo', 'Barangay, Santa Rosa City, Laguna', 'Barangay', 14.229528, 121.062907),
  ('Sinalhan', 'Barangay, Santa Rosa City, Laguna', 'Barangay', 14.330088, 121.105755),
  ('Tagapo', 'Barangay, Santa Rosa City, Laguna', 'Barangay', 14.316894, 121.099829),
  ('Acevida', 'Barangay, Siniloan, Laguna', 'Barangay', 14.414444, 121.450518),
  ('Bagong Pag-Asa', 'Barangay, Siniloan, Laguna', 'Barangay', 14.418909, 121.445517),
  ('Bagumbarangay', 'Barangay, Siniloan, Laguna', 'Barangay', 14.421636, 121.446127),
  ('Buhay', 'Barangay, Siniloan, Laguna', 'Barangay', 14.43019, 121.44903),
  ('Gen. Luna', 'Barangay, Siniloan, Laguna', 'Barangay', 14.418903, 121.445039),
  ('Halayhayin', 'Barangay, Siniloan, Laguna', 'Barangay', 14.419675, 121.45321),
  ('Mendiola', 'Barangay, Siniloan, Laguna', 'Barangay', 14.425771, 121.456859),
  ('Kapatalan', 'Barangay, Siniloan, Laguna', 'Barangay', 14.469484, 121.510362),
  ('Laguio', 'Barangay, Siniloan, Laguna', 'Barangay', 14.461141, 121.483615),
  ('Liyang', 'Barangay, Siniloan, Laguna', 'Barangay', 14.463684, 121.493368),
  ('Llavac', 'Barangay, Siniloan, Laguna', 'Barangay', 14.511599, 121.525887),
  ('Pandeno', 'Barangay, Siniloan, Laguna', 'Barangay', 14.420587, 121.440694),
  ('Magsaysay', 'Barangay, Siniloan, Laguna', 'Barangay', 14.505885, 121.507882),
  ('Macatad', 'Barangay, Siniloan, Laguna', 'Barangay', 14.439967, 121.463682),
  ('Mayatba', 'Barangay, Siniloan, Laguna', 'Barangay', 14.450428, 121.476333),
  ('P. Burgos', 'Barangay, Siniloan, Laguna', 'Barangay', 14.426415, 121.442589),
  ('G. Redor', 'Barangay, Siniloan, Laguna', 'Barangay', 14.423101, 121.444556),
  ('Salubungan', 'Barangay, Siniloan, Laguna', 'Barangay', 14.421776, 121.447562),
  ('Wawa', 'Barangay, Siniloan, Laguna', 'Barangay', 14.406398, 121.444765),
  ('J. Rizal', 'Barangay, Siniloan, Laguna', 'Barangay', 14.419084, 121.445959),
  ('Banca-banca', 'Barangay, Victoria, Laguna', 'Barangay', 14.205348, 121.347218),
  ('Daniw', 'Barangay, Victoria, Laguna', 'Barangay', 14.198311, 121.360222),
  ('Masapang', 'Barangay, Victoria, Laguna', 'Barangay', 14.191154, 121.343898),
  ('Nanhaya', 'Barangay, Victoria, Laguna', 'Barangay', 14.227353, 121.332236),
  ('Pagalangan', 'Barangay, Victoria, Laguna', 'Barangay', 14.230058, 121.338481),
  ('San Benito', 'Barangay, Victoria, Laguna', 'Barangay', 14.194133, 121.316635),
  ('San Felix', 'Barangay, Victoria, Laguna', 'Barangay', 14.209208, 121.322776),
  ('San Francisco', 'Barangay, Victoria, Laguna', 'Barangay', 14.213915, 121.342042),
  ('San Roque', 'Barangay, Victoria, Laguna', 'Barangay', 14.22284, 121.326195)
) as v(name, sub, category, lat, lng)
where not exists (
  select 1 from public.pois p where p.name = v.name and p.sub = v.sub
);



-- ============================================================
-- ADMIN BOOTSTRAPPING — read this before expecting the Admin Dashboard
-- to show up for anyone
-- ============================================================
-- Every new signup gets role = 'user' (the column default above), and
-- the trigger above means NOTHING in the app itself — not the API, not
-- a modified request, not admin-looking UI someone reveals in devtools —
-- can promote an account to 'admin'. The very FIRST admin has to be
-- created once, deliberately, outside the app: in the Supabase
-- Dashboard's SQL Editor, run
--
--   update public.profiles set role = 'admin' where email = 'you@gmail.com';
--
-- for whichever account should be the first admin. (This direct SQL
-- Editor update runs as the Postgres owner role, not through
-- PostgREST/RLS, so the self-escalation trigger's "not admin yet" check
-- doesn't block it — that trigger only stops it from happening through
-- the app's own authenticated API calls.) After that, BiyaHERO.js's
-- post-login role fetch will pick it up and reveal the Admin Dashboard
-- for that account — and from then on, that first admin can create every
-- other admin from inside the app itself (Admin Dashboard -> Admin
-- Management -> Create Admin Account), which calls the create-admin
-- Edge Function in supabase/functions/create-admin/index.ts. See that
-- file's header comment for deployment steps
-- (supabase functions deploy create-admin). This one-time manual SQL
-- step is only ever needed for account #1.

-- ============================================================
-- OPTIONAL, RECOMMENDED HARDENING: server-side @gmail.com enforcement
-- ============================================================
-- BiyaHERO.js already rejects non-Gmail addresses in the browser before
-- ever calling signUp(). That's enough to satisfy normal use, but a
-- browser check alone can always be bypassed by someone calling the
-- Supabase API directly. For true backend enforcement, wire this
-- function up as a "Before User Created" Auth Hook:
--
--   Dashboard -> Authentication -> Hooks (Beta) -> Before User Created
--   -> Postgres function -> select "public.validate_gmail_domain"
--
-- (Hook availability can vary by Supabase plan/version — if you don't
-- see "Hooks" in your dashboard, the frontend check above is your
-- current safeguard; this is an extra layer, not a required step.)

create or replace function public.validate_gmail_domain(event jsonb)
returns jsonb
language plpgsql
as $$
declare
  user_email text := event->'user'->>'email';
begin
  if user_email is null or user_email !~* '^[A-Za-z0-9._%+-]+@gmail\.com$' then
    return jsonb_build_object(
      'error', jsonb_build_object(
        'message', 'Only @gmail.com email addresses are allowed to register.'
      )
    );
  end if;
  return jsonb_build_object();
end;
$$;


-- ============================================================
-- AUTH HARDENING — Gmail-only, one account per mailbox, unique and
-- appropriate usernames. ALL of this is enforced by the database itself,
-- so it still applies if someone bypasses BiyaHERO.js and calls the
-- Supabase Auth / REST API directly. Idempotent: safe to re-run.
-- ============================================================
--
-- DASHBOARD SETTINGS THAT SQL CANNOT SET (required, do these once):
--   Authentication -> Providers -> Email:
--     * "Confirm email" = ON. This is what actually stops an unverified
--       address from ever getting a session. With it OFF, Supabase marks
--       every new address confirmed immediately and no client or database
--       code can tell a verified mailbox from an unverified one.
--     * "Minimum password length" = 8 (BiyaHERO.js's own rule; the note at
--       the top of supabase-config.js still says 6).
--   Authentication -> URL Configuration: set the Site URL / Redirect URLs
--   the confirmation e-mail link should land on.

-- ---- 1. @gmail.com only ----------------------------------------------------
-- Replaces the old "optional Before User Created hook" for good: a trigger
-- on auth.users needs no dashboard step and covers every signup path,
-- including the create-admin Edge Function. (validate_gmail_domain() above
-- is left in place in case you already wired it up as a hook; it is now
-- redundant but harmless.) Runs on INSERT, and on an email CHANGE so a
-- verified Gmail user can't swap to another provider later. Existing
-- non-Gmail rows are not touched unless their email changes.
create or replace function public.enforce_gmail_only()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.email is null or lower(new.email) !~ '^[a-z0-9._%+-]+@gmail\.com$' then
    raise exception 'Only @gmail.com email addresses are allowed to register.'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enforce_gmail_only_insert on auth.users;
create trigger trg_enforce_gmail_only_insert
  before insert on auth.users
  for each row execute procedure public.enforce_gmail_only();

drop trigger if exists trg_enforce_gmail_only_update on auth.users;
create trigger trg_enforce_gmail_only_update
  before update of email on auth.users
  for each row
  when (new.email is distinct from old.email)
  execute procedure public.enforce_gmail_only();

-- ---- 2. One account per MAILBOX --------------------------------------------
-- auth.users.email and profiles.email are already unique, but Gmail ignores
-- dots and "+tags": juan.dc@gmail.com, juandc@gmail.com and juandc+x@gmail.com
-- are ONE inbox. Without this, one person could register unlimited accounts
-- with trivially different spellings of the same address. email_canonical is
-- a generated column (kept in sync automatically, no app code involved).
create or replace function public.canonical_email(e text)
returns text
language sql
immutable
as $$
  select case
    when e is null then null
    when lower(e) ~ '@(gmail|googlemail)\.com$' then
      regexp_replace(split_part(split_part(lower(e), '@', 1), '+', 1), '\.', '', 'g') || '@gmail.com'
    else lower(e)
  end;
$$;

alter table public.profiles
  add column if not exists email_canonical text
  generated always as (public.canonical_email(email)) stored;

-- If two EXISTING accounts already collapse to the same mailbox the unique
-- index can't be built; this reports it instead of failing the whole script.
-- Resolve those accounts manually, then re-run this file.
do $$
begin
  if exists (
    select 1 from public.profiles group by email_canonical having count(*) > 1
  ) then
    raise notice 'profiles_email_canonical_unique NOT created: existing accounts share a mailbox (same Gmail ignoring dots/+tags). Find them with: select email_canonical, array_agg(email) from public.profiles group by 1 having count(*) > 1;';
  else
    create unique index if not exists profiles_email_canonical_unique
      on public.profiles (email_canonical);
  end if;
end;
$$;

-- ---- 3. Prohibited usernames -------------------------------------------------
-- One editable table is the single source of truth (no app release needed to
-- change it). RLS is on with NO policies, so it can't be read or written
-- through the API at all — only from the SQL Editor / service role:
--     insert into public.blocked_username_terms (term, match_type, note)
--     values ('someterm', 'exact', 'why') on conflict (term) do nothing;
--     delete from public.blocked_username_terms where term = 'someterm';
--
-- match_type:
--   'substring' — blocked if the term appears ANYWHERE in the username.
--                 Only for long, unambiguous terms.
--   'exact'     — blocked only if the whole username equals the term. Used for
--                 short/ambiguous terms so legitimate names aren't rejected
--                 (the "Scunthorpe problem": 'ass' in "Cassandra", 'cunt' in
--                 "Scunthorpe", 'rapist' in "Therapist", 'cock' in "Peacock").
-- Add reserved/impersonation names the same way if you want them, e.g.
--     ('admin','exact'), ('moderator','exact'), ('biyahero','substring').
-- (Left out by default: an 'admin' entry would also stop an admin from
-- creating an account literally named "admin" from the Admin Dashboard.)
create table if not exists public.blocked_username_terms (
  term       text primary key check (term = lower(term) and term ~ '^[a-z]+$'),
  match_type text not null default 'exact' check (match_type in ('exact', 'substring')),
  note       text
);

alter table public.blocked_username_terms enable row level security;

insert into public.blocked_username_terms (term, match_type, note) values
  -- English profanity / slurs — long & unambiguous => substring
  ('fuck',       'substring', null), ('shit',       'substring', null),
  ('bitch',      'substring', null), ('nigger',     'substring', 'slur'),
  ('nigga',      'substring', 'slur'), ('faggot',   'substring', 'slur'),
  ('whore',      'substring', null), ('slut',       'substring', null),
  ('pussy',      'substring', null), ('asshole',    'substring', null),
  ('dickhead',   'substring', null), ('bastard',    'substring', null),
  ('cocksucker', 'substring', null), ('blowjob',    'substring', null),
  ('retarded',   'substring', 'slur'), ('hitler',   'substring', 'hate'),
  ('pornhub',    'substring', null), ('pornstar',   'substring', null),
  -- English — short / collides with real words or names => exact only
  ('ass',    'exact', null), ('cock',   'exact', null), ('cum',    'exact', null),
  ('cunt',   'exact', 'in "Scunthorpe"'), ('cunts',  'exact', null),
  ('rape',   'exact', 'in "drape", "grape"'), ('rapist', 'exact', 'in "therapist"'),
  ('rapists','exact', null), ('retard', 'exact', 'in "fire retardant"'),
  ('fag',    'exact', 'slur'), ('nazi',   'exact', 'in the name "Nazir"'),
  ('kkk',    'exact', 'hate'), ('sex',    'exact', null), ('sexy',   'exact', null),
  ('xxx',    'exact', null), ('porn',   'exact', 'Thai name "Pornthip"'),
  ('penis',  'exact', null), ('vagina', 'exact', null), ('tits',   'exact', null),
  -- Filipino / Tagalog
  ('putangina', 'substring', null), ('tangina',  'substring', null),
  ('tarantado', 'substring', null), ('pakyu',    'substring', null),
  ('kantot',    'substring', null), ('pekpek',   'substring', null),
  ('puta',  'exact', 'in "reputation"'), ('gago', 'exact', null),
  ('ulol',  'exact', null), ('burat', 'exact', null), ('jakol', 'exact', null)
on conflict (term) do nothing;

-- Normalises a username into the strings the filter compares, so trivial
-- disguises don't get through: case; common digit/symbol swaps (0->o 1->i
-- 3->e 4->a 5->s 7->t 8->b 9->g @->a $->s !->i); every separator (_ digits
-- left over, spaces) stripped, so "f_u_c_k" == "fuck"; and stretched letters
-- ("fuuuck", "assss") collapsed two different ways, because collapsing every
-- double letter would turn "nigger" into "niger" and wrongly block "Nigeria".
create or replace function public.username_filter_forms(n text)
returns text[]
language sql
immutable
as $$
  with base as (
    select regexp_replace(
             translate(lower(coalesce(n, '')), '01345789@$!', 'oieastbgasi'),
             '[^a-z]', '', 'g') as s
  )
  select array[
    s,
    regexp_replace(s, '(.)\1+',   '\1',   'g'),
    regexp_replace(s, '(.)\1{2,}', '\1\1', 'g')
  ] from base;
$$;

-- The one rule set. Returns NULL when the username is acceptable, otherwise
-- 'format' | 'blocked' | 'taken'. ignore_id lets a user keep their own name.
-- Deliberately not callable by clients directly (see check_username below).
create or replace function public.username_problem(check_name text, ignore_id uuid default null)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  forms text[];
begin
  if check_name is null or check_name !~ '^[A-Za-z0-9_]{3,20}$' then
    return 'format';
  end if;

  forms := public.username_filter_forms(check_name);

  if exists (
    select 1
      from public.blocked_username_terms t
      cross join lateral (select (public.username_filter_forms(t.term))[1] as a) term
      cross join unnest(forms) as f
     where length(term.a) > 0
       and ( (t.match_type = 'exact'     and f = term.a)
          or (t.match_type = 'substring' and position(term.a in f) > 0) )
  ) then
    return 'blocked';
  end if;

  if exists (
    select 1 from public.profiles p
     where lower(p.name) = lower(check_name)
       and (ignore_id is null or p.id <> ignore_id)
  ) then
    return 'taken';
  end if;

  return null;
end;
$$;

revoke execute on function public.username_problem(text, uuid) from public, anon, authenticated;

-- What BiyaHERO.js calls (signup form, offline-signup sync, Admin Dashboard
-- "Create Admin"): a yes/no style answer — 'ok' | 'format' | 'blocked' |
-- 'taken'. It reveals nothing beyond that, same trade-off as the username
-- availability check on any sign-up form. Supersedes is_username_taken()
-- (kept above so builds already in the field that still call it keep working).
create or replace function public.check_username(check_name text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.username_problem(check_name), 'ok');
$$;

grant execute on function public.check_username(text) to anon, authenticated;

-- The enforcement. Runs when a profile is CREATED (every signup, including the
-- create-admin Edge Function, goes through handle_new_user()) and whenever its
-- name is CHANGED — including a direct profiles update from a signed-in user,
-- which the "Users can update own profile" RLS policy otherwise allows with no
-- column restriction. A row only gets checked when the name is new or changed,
-- so existing accounts (some predate the 3-20 char rule, e.g. "Juan Dela
-- Cruz") keep working untouched until they rename. The unique index on
-- lower(name) stays the final, race-proof guard for two simultaneous signups
-- that both pass the check below.
create or replace function public.enforce_username_rules()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  problem text;
begin
  if tg_op = 'INSERT' or new.name is distinct from old.name then
    problem := public.username_problem(new.name, new.id);

    if problem = 'format' then
      raise exception 'Username must be 3-20 characters, using only letters, numbers, and underscores.'
        using errcode = '23514';
    elsif problem = 'blocked' then
      raise exception 'That username is not allowed.'
        using errcode = '23514';
    elsif problem = 'taken' then
      raise exception 'That username is already taken.'
        using errcode = '23505';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enforce_username_rules on public.profiles;
create trigger trg_enforce_username_rules
  before insert or update of name on public.profiles
  for each row execute procedure public.enforce_username_rules();
