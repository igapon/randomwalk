-- RandomWalk M5 — initial Supabase schema.
--
-- HOW THIS FILE IS APPLIED: pasted whole into the Supabase SQL Editor and
-- run ONCE, top to bottom, against a brand-new project (see
-- supabase/README.md for the exact click path). It is not a repeatable
-- migration in the Supabase-CLI-managed-migrations sense — there is no
-- `if not exists` hedging anywhere below — and it is not applied by CI
-- (no live Supabase project exists in this environment; see
-- supabase/notes.md for how it was validated instead: careful manual
-- read-through, not execution).
--
-- Scope: two tables (`game_events`, `profiles`) backing the M5 event-journal
-- sync described in app/lib/sync/backend.dart's CONTRACT dartdoc, plus three
-- RPCs (`push_events`, `top_profiles`, `delete_account`) that are the only
-- server-side logic this app depends on. Everything else (merge, replay,
-- checkpointing) happens client-side in Dart.

-- =============================================================================
-- game_events — append-only remote mirror of the local GameJournal
-- (app/lib/game/events.dart). One row per GameEvent ever pushed by any
-- device of any account. Never updated, never deleted (see the RLS policies
-- below, which define no UPDATE/DELETE policy at all — not "a restrictive
-- one", an ABSENT one, which is what actually enforces append-only under
-- RLS: with row level security enabled, a command with no matching policy
-- allows zero rows, full stop).
-- =============================================================================

create table public.game_events (
  id uuid primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  ts timestamptz not null,
  type text not null,
  payload jsonb not null default '{}'::jsonb,
  inserted_at timestamptz not null default now()
);

comment on table public.game_events is
  'Append-only mirror of every device''s local GameJournal (app/lib/game/events.dart). One row per GameEvent, keyed by the event''s own id so push is naturally idempotent. Never UPDATEd or DELETEd — see the RLS policies below (no UPDATE/DELETE policy is defined for this table at all).';
comment on column public.game_events.id is
  'Matches GameEvent.id (client-generated, e.g. a uuid). Primary key, so a repeat push of an already-known event is a duplicate-key no-op, not a new row.';
comment on column public.game_events.user_id is
  'The owning account. Always server-stamped from auth.uid() (by the push_events() RPC, or by the insert-own-rows RLS policy if a client ever inserts directly) — never trusted from client-supplied payload, precisely so one account can never write rows into another account''s journal.';
comment on column public.game_events.ts is
  'Matches GameEvent.ts: the client-authoritative event clock the local reducers replay by (ts, id) order. Client-controlled and NOT used for pull pagination — see inserted_at below.';
comment on column public.game_events.type is
  'Matches GameEvent.type (see GameEventTypes in app/lib/game/events.dart). Stored as unconstrained text, not an enum: the reducers already tolerate unknown event types for forward-compat with newer app versions, and the schema shouldn''t be stricter than the client that reads it.';
comment on column public.game_events.payload is
  'Matches GameEvent.payload. Defaults to ''{}'' because GameEvent''s own Dart default is the empty map (e.g. loop_completed events carry no payload).';
comment on column public.game_events.inserted_at is
  'Server-assigned row-landing time — NOT GameEvent.ts (see that column''s comment). This is the field pull pagination orders and cursors by; see the index comment immediately below for why the cursor cannot be inserted_at alone.';

-- Cursor pagination support for SyncBackend.pullEventsSince (see the
-- CONTRACT dartdoc on PullPage in app/lib/sync/backend.dart): pages are
-- ordered by inserted_at ASCENDING and the cursor returned to resume is
-- EXCLUSIVE of the last row already delivered.
--
-- IMPORTANT — this index's column order is deliberate and load-bearing:
-- (user_id, inserted_at, id), never (user_id, inserted_at) alone. inserted_at
-- by itself is NOT a total order over this table's rows: Postgres' now()
-- returns the SAME value for every call inside one transaction, and
-- push_events() inserts an entire batch of events in a single multi-row
-- INSERT (one transaction) — so ties on inserted_at are not a rare edge
-- case here, they are the NORMAL outcome of every batched push of more than
-- one event. A cursor built from inserted_at alone can only express
-- "everything after this timestamp", which either re-delivers or silently
-- skips whichever tied rows land on the boundary, depending on how the
-- untiebroken ORDER BY happens to sort them on a given call (undefined,
-- since SQL does not guarantee a stable order across ties without an
-- explicit tiebreaker column).
--
-- The fix is what this index encodes: order by (inserted_at, id) and treat
-- the pair as the cursor's total order, with id (a uuid — not sequential,
-- but a stable arbitrary tiebreaker) resolving every tie deterministically.
-- Task 3's SupabaseBackend MUST encode BOTH fields into the single opaque
-- cursor string that pullEventsSince returns/accepts (the dartdoc on
-- PullPage currently says only "a serialized Supabase inserted_at
-- timestamp" — that description is one field short; align it with this
-- comment when SupabaseBackend lands, see supabase/notes.md). A query
-- resuming from a cursor should read as:
--   where user_id = :uid
--     and (inserted_at, id) > (:cursor_inserted_at, :cursor_id)
--   order by inserted_at asc, id asc
--   limit :page_size
-- which this composite index serves directly (no sort step needed).
create index game_events_user_cursor_idx
  on public.game_events (user_id, inserted_at, id);

comment on index public.game_events_user_cursor_idx is
  'Serves cursor-paginated pulls: WHERE user_id = :uid AND (inserted_at, id) > (:cursor) ORDER BY inserted_at, id. See the inline comment above the CREATE INDEX statement for why (inserted_at, id) — not inserted_at alone — is the required total order (same-transaction batch inserts share one inserted_at value via Postgres now()).';

alter table public.game_events enable row level security;

-- Read own rows only. No USING clause is needed beyond the ownership check
-- itself — there is nothing else to filter by for SELECT.
create policy "game_events_select_own" on public.game_events
  for select
  to authenticated
  using (user_id = auth.uid());

comment on policy "game_events_select_own" on public.game_events is
  'Each account may SELECT only its own rows (user_id = auth.uid()). No policy exists for the anon role, so unauthenticated reads return zero rows.';

-- Insert own rows only. NOTE (RLS pitfall this schema deliberately avoids):
-- an INSERT policy needs WITH CHECK, not USING — USING is evaluated against
-- pre-existing rows and is not even accepted by Postgres for a bare INSERT
-- policy; WITH CHECK is evaluated against the NEW row being inserted, which
-- is the check that actually stops a client from stamping some other
-- account's user_id on a row it writes. This policy exists mainly as
-- defense in depth: push_events() below (a SECURITY INVOKER function, so
-- this same RLS still applies to it) already stamps user_id from auth.uid()
-- unconditionally, ignoring anything the client sent.
create policy "game_events_insert_own" on public.game_events
  for insert
  to authenticated
  with check (user_id = auth.uid());

comment on policy "game_events_insert_own" on public.game_events is
  'Each account may INSERT only rows stamped with its own user_id (WITH CHECK, evaluated against the new row — see the inline comment above this CREATE POLICY for why INSERT policies need WITH CHECK rather than USING).';

-- Deliberately no UPDATE or DELETE policy for game_events. With row level
-- security enabled and no policy defined for a command, that command is
-- allowed on zero rows for every role — this is what actually makes the
-- journal append-only at the database layer, not just by client
-- convention. If a future task needs to correct a bad event, it must do so
-- by appending a compensating event, never by mutating history.

-- =============================================================================
-- push_events — idempotent batch ingest for SyncBackend.pushEvents
-- =============================================================================

-- SECURITY INVOKER (the default — spelled out for clarity, since the
-- security-definer functions below make the contrast worth being explicit
-- about): this function carries none of the caller's authority beyond what
-- the caller already has, and the RLS policies on game_events still apply
-- to every row it inserts. search_path is still pinned below as routine
-- hygiene (a SECURITY INVOKER function is much lower risk than a DEFINER
-- one, since it can't do anything the caller couldn't already do directly,
-- but an unqualified reference silently resolving against an
-- attacker-writable schema earlier in a hijacked search_path is a mistake
-- worth foreclosing on regardless).
create or replace function public.push_events(events jsonb)
returns integer
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  inserted_count integer;
begin
  if auth.uid() is null then
    raise exception 'push_events: authentication required';
  end if;

  if events is null or jsonb_typeof(events) <> 'array' then
    raise exception 'push_events: events must be a JSON array';
  end if;

  -- user_id is ALWAYS auth.uid(), never read from the incoming JSON — a
  -- payload that happens to carry a "user_id" key (it shouldn't; GameEvent
  -- has no such field, see app/lib/game/events.dart) is silently ignored,
  -- not honoured and not rejected. ON CONFLICT (id) DO NOTHING is the
  -- idempotency: re-pushing an event the server already has (same id) is a
  -- silent no-op, matching pushEvents' contract in backend.dart.
  with incoming as (
    select
      (elem ->> 'id')::uuid as id,
      (elem ->> 'ts')::timestamptz as ts,
      elem ->> 'type' as type,
      coalesce(elem -> 'payload', '{}'::jsonb) as payload
    from jsonb_array_elements(events) as elem
  ),
  ins as (
    insert into public.game_events (id, user_id, ts, type, payload)
    select incoming.id, auth.uid(), incoming.ts, incoming.type, incoming.payload
    from incoming
    on conflict (id) do nothing
    returning 1
  )
  select count(*)::integer into inserted_count from ins;

  return inserted_count;
end;
$$;

comment on function public.push_events(jsonb) is
  'Idempotent batch push for SyncBackend.pushEvents (app/lib/sync/backend.dart). events is a JSON array of {id, ts, type, payload} objects matching GameEvent.toJson(); user_id is always server-stamped from auth.uid(), never trusted from the payload. Duplicate ids (already-known events) are silently skipped via ON CONFLICT (id) DO NOTHING. Returns the count of rows actually newly inserted (0..array length). NOTE: events[].ts must carry an explicit UTC/offset marker (e.g. a trailing Z) — an offset-less timestamp string is interpreted against this session''s timezone by the ::timestamptz cast, which is ambiguous; ensuring the client always serializes ts in UTC is Task 3''s (SupabaseBackend''s) responsibility, not enforced here.';

revoke all on function public.push_events(jsonb) from public;
grant execute on function public.push_events(jsonb) to authenticated;
-- Deliberately NOT granted to anon: pushing events requires a signed-in
-- account (auth.uid() is null for the anon role, which the explicit check
-- above rejects anyway — this GRANT is the first line of defense, the
-- auth.uid() check is the second).

-- =============================================================================
-- profiles — one row per account, backing the leaderboard and identity
-- =============================================================================

create table public.profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  pseudo text not null check (char_length(pseudo) between 1 and 24),
  total_km double precision not null default 0 check (total_km >= 0),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is
  'One row per account: display name and cumulative distance for the leaderboard. Populated by SyncBackend.upsertProfile after each trip, once signed in; read across ALL accounts only through the top_profiles() security-definer function below, never directly (RLS on this table restricts direct SELECT to the caller''s own row).';
comment on column public.profiles.user_id is
  'References auth.users(id); cascades on account deletion (also reachable via delete_account() below, which deletes the auth.users row directly).';
comment on column public.profiles.pseudo is
  'Display name shown on the leaderboard. 1..24 characters, matching the local PlayerIdentity pseudo the M4 leaderboard already collects (settings/identity.dart) — this is the same string pushed up, not a separate identity.';
comment on column public.profiles.total_km is
  'Cumulative distance in kilometres, as computed locally and pushed by upsertProfile; source of the leaderboard ordering in top_profiles(). Constrained non-negative as a sanity backstop, not because negative distance is otherwise reachable.';
comment on column public.profiles.updated_at is
  'Auto-maintained by the trigger below on every UPDATE (and defaults to now() on INSERT) — callers never need to set this explicitly when upserting.';

create or replace function public.set_profiles_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

comment on function public.set_profiles_updated_at() is
  'Trigger function: stamps profiles.updated_at = now() on every UPDATE, so upsertProfile callers never need to set it themselves.';

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row
  execute function public.set_profiles_updated_at();

comment on trigger profiles_set_updated_at on public.profiles is
  'Fires set_profiles_updated_at() before every UPDATE so profiles.updated_at always reflects the last write, without upsertProfile callers needing to set it.';

alter table public.profiles enable row level security;

create policy "profiles_select_own" on public.profiles
  for select
  to authenticated
  using (user_id = auth.uid());

comment on policy "profiles_select_own" on public.profiles is
  'Each account may SELECT only its own profile row directly. Cross-account leaderboard reads go through top_profiles() below, not through this policy.';

-- WITH CHECK, not USING — see the matching comment on game_events_insert_own
-- above for why an INSERT policy needs WITH CHECK specifically.
create policy "profiles_insert_own" on public.profiles
  for insert
  to authenticated
  with check (user_id = auth.uid());

comment on policy "profiles_insert_own" on public.profiles is
  'Each account may INSERT only its own profile row (WITH CHECK against the new row, not USING — see game_events_insert_own''s comment for why).';

-- UPDATE policies need BOTH clauses, which is the second RLS pitfall this
-- schema deliberately avoids: USING alone picks which EXISTING rows the
-- caller may target, but without a matching WITH CHECK a caller could
-- (since user_id is this table's primary key, not literally reassignable
-- post-hoc here, but the principle generalises to any future column added
-- to this table) update a row it owns into a state that no longer satisfies
-- the ownership predicate, and RLS alone wouldn't stop it. Belt and braces:
-- both clauses pin the row to the caller's own account, before and after.
create policy "profiles_update_own" on public.profiles
  for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

comment on policy "profiles_update_own" on public.profiles is
  'Each account may UPDATE only its own profile row, both selecting the target row (USING) and validating the resulting row (WITH CHECK) — see the inline comment above this CREATE POLICY for why UPDATE needs both clauses.';

-- No DELETE policy: an account's profile row is only ever removed via the
-- auth.users cascade inside delete_account() below, never directly by the
-- client.

-- =============================================================================
-- top_profiles — public leaderboard read, bypassing per-row RLS by design
-- =============================================================================

-- SECURITY DEFINER: this function intentionally reads every account's
-- profiles row, which the RLS policies above (by design) do not otherwise
-- allow any single caller to do directly. It runs as its owner (the role
-- that executes this migration in the SQL Editor — see supabase/README.md),
-- which owns the profiles table and therefore bypasses RLS on it the same
-- way any table owner does; no FORCE ROW LEVEL SECURITY is set on profiles,
-- so this is the intended mechanism, not a bypass of one.
--
-- search_path is pinned (SET search_path = public, pg_temp) as required
-- SECURITY DEFINER hygiene: without it, this function would resolve
-- unqualified identifiers against whatever search_path the CALLING session
-- has configured, which a malicious caller could otherwise manipulate to
-- redirect e.g. an unqualified table/operator reference to an
-- attacker-controlled object and have it execute with this function's
-- elevated (owner) privileges. Pinning removes that degree of freedom
-- entirely.
create or replace function public.top_profiles(p_limit integer default 50)
returns table (pseudo text, total_km double precision, rank bigint)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    p.pseudo,
    p.total_km,
    rank() over (order by p.total_km desc) as rank
  from public.profiles as p
  order by p.total_km desc
  limit greatest(coalesce(p_limit, 50), 0)
$$;

comment on function public.top_profiles(integer) is
  'Public leaderboard read backing SyncBackend.topProfiles (app/lib/sync/backend.dart). SECURITY DEFINER so it can read every account''s profiles row despite RLS restricting direct SELECT to one''s own row (see LeaderboardRow.rank''s dartdoc for the exact rank semantics this implements). rank is COMPETITION ranking (Postgres rank(), not dense_rank()) computed via a window function over ALL profiles BEFORE the LIMIT is applied — Postgres evaluates window functions ahead of the final ORDER BY/LIMIT, so rank always reflects a row''s standing on the full leaderboard, never its position within the returned page (ties share a rank; the rank after a tie skips ahead by the tie''s size, e.g. 1, 2, 2, 4). Callable by any authenticated user for any p_limit, not just the caller''s own data — that is the intended, sole purpose of this function.';

revoke all on function public.top_profiles(integer) from public;
grant execute on function public.top_profiles(integer) to authenticated;
-- Deliberately NOT granted to anon. The M5 plan's leaderboard is reached
-- through the app's signed-in account flow only; there is currently no
-- product requirement for a signed-out visitor to read it, so the default
-- (least-privilege) choice is authenticated-only. If a future task wants an
-- anonymous-readable leaderboard, that is a one-line
-- `grant execute on function public.top_profiles(integer) to anon;` added
-- deliberately, not an oversight to fix — do not add it without a specific
-- product decision to do so.

-- =============================================================================
-- delete_account — RGPD-driven full account erasure
-- =============================================================================

-- SECURITY DEFINER: deleting a row from auth.users requires privileges an
-- ordinary authenticated user does not and should not have directly (the
-- auth schema is owned/managed by Supabase Auth, not this project's own
-- tables) — this function runs as its owner (again, the role that executes
-- this migration; see supabase/README.md), which is presumed to already
-- have the necessary rights on auth.users in a standard Supabase project.
-- If this DELETE fails with a permissions error on some project, the guide
-- has the owner apply the migration via the SQL Editor as the project's
-- default (postgres) role, which does.
create or replace function public.delete_account()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'delete_account: authentication required';
  end if;

  -- Deletes only the CALLER's own row — auth.uid() is read once, server
  -- side, from the caller's own verified JWT, so there is no id parameter
  -- for a client to substitute someone else's account into.
  delete from auth.users where id = auth.uid();

  -- Cascades: auth.users -> public.profiles (user_id references ... on
  -- delete cascade) and auth.users -> public.game_events (user_id
  -- references ... on delete cascade) both wipe automatically as a result
  -- of the single DELETE above; no explicit cleanup of either table is
  -- needed here.
end;
$$;

comment on function public.delete_account() is
  'RGPD erasure: deletes the CALLER''S OWN auth.users row (auth.uid(), never a parameter), cascading via ON DELETE CASCADE to remove every game_events row and the profiles row belonging to that account. Irreversible. Does not touch the local on-device journal — see SyncBackend.deleteAccount''s dartdoc: any local purge is a separate, explicit client-side step (Task 6).';

revoke all on function public.delete_account() from public;
grant execute on function public.delete_account() to authenticated;
-- Deliberately NOT granted to anon: only a signed-in caller can delete
-- their own account, and the auth.uid() check above rejects an
-- unauthenticated call regardless — same belt-and-braces reasoning as
-- push_events() above.
