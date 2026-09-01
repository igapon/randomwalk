# Design notes — supabase/migrations/0001_init.sql

Not a test (SQL correctness isn't unit-testable without a live project — see
the file header and the M5 plan's Task 2 validation note: "SQL lint par
revue... le guide testé à blanc par relecture"). This is the binding design
rationale Task 3 (`SupabaseBackend`) and Task 4 (`SyncEngine`) should read
before writing code against this schema, so decisions made here don't have
to be independently re-derived or accidentally contradicted.

## 1. The pull cursor MUST be a two-field total order — this is the one thing to get right first

`app/lib/sync/backend.dart`'s `PullPage` dartdoc (Task 1, already committed)
currently describes the cursor as "a serialized Supabase `inserted_at`
timestamp" — singular. **That's one field short of correct.**

`game_events.inserted_at` is `timestamptz not null default now()`. Postgres'
`now()` is *transaction*-timestamp, not statement- or row-timestamp: every
row written by one `INSERT` statement inside one transaction gets the exact
same `inserted_at` value. `push_events()` inserts an entire batch (however
many events one `SyncEngine.sync()` call decides to push) as a single
multi-row `INSERT ... SELECT` — one transaction — so **every event pushed in
one call shares one `inserted_at`**. Ties are not an edge case here; they're
the normal shape of the data.

An `inserted_at`-only cursor ("give me everything after timestamp T") cannot
express "I've already seen 3 of the 5 rows that share timestamp T" — the 4th
and 5th either get skipped forever or re-delivered, depending on how an
untiebroken `ORDER BY inserted_at` happens to sort same-valued rows on a
given call (undefined in SQL without an explicit tiebreaker).

**What Task 3 must do:** encode the cursor as the pair `(inserted_at, id)` of
the last row in a page, not `inserted_at` alone. The supporting index is
already in place —

```sql
create index game_events_user_cursor_idx
  on public.game_events (user_id, inserted_at, id);
```

— so the resuming query is a direct index scan, no sort step:

```sql
select * from game_events
where user_id = :uid
  and (inserted_at, id) > (:cursor_inserted_at, :cursor_id)
order by inserted_at asc, id asc
limit :page_size;
```

The cursor stays *opaque* to callers per the existing dartdoc (nobody outside
`SupabaseBackend` parses or compares it) — it just needs to carry both values
inside whatever string/JSON encoding Task 3 picks (e.g.
`"<iso8601-inserted_at>|<uuid>"` or a small base64-JSON blob). When Task 3
lands, its own PR should also correct `PullPage`'s dartcode in
`backend.dart` to say "a serialized `(inserted_at, id)` pair", not
"timestamp" — flagged here rather than fixed now because Task 2 doesn't own
that file and editing it out-of-turn risks racing Task 3/4's own edits to
the same doc comment.

`GameEvent.ts` is never part of this — it's client-authoritative and
reordered relative to `inserted_at` by design (see the `ts` column comment
in the migration); pull pagination only ever orders/cursors by
`inserted_at`.

## 2. Append-only is enforced by an *absent* policy, not a restrictive one

`game_events` has RLS `SELECT` and `INSERT` policies and **no `UPDATE` or
`DELETE` policy at all**. Under Postgres RLS, a command with zero matching
policies is allowed on zero rows for every role, full stop — that absence is
the actual enforcement mechanism, not a `USING (false)` policy someone could
mistake for a leftover. If a later task needs to "fix" a bad event, the only
legal move is appending a compensating event — never `UPDATE`/`DELETE`
against `game_events`, from the client or from a future RPC. If a future
task genuinely needs row correction, that's a deliberate schema change (a
new migration + a real design conversation), not something to route around
by loosening this file's policies.

## 3. RLS pitfalls this schema had to specifically avoid

Two documented mistakes an easy first draft could make, both prevented in
the migration itself (with inline comments at each site, so this is the
condensed version, not the only copy):

- **INSERT policies need `WITH CHECK`, not `USING`.** `USING` filters
  pre-existing rows and Postgres doesn't even accept it for a bare `INSERT`
  policy; `WITH CHECK` validates the *new* row, which is the clause that
  actually stops a client from writing a row it doesn't own. Both
  `game_events_insert_own` and `profiles_insert_own` use `WITH CHECK
  (user_id = auth.uid())`.
- **UPDATE policies need both `USING` and `WITH CHECK`.** `USING` alone
  picks which existing rows a caller may touch; without a matching `WITH
  CHECK`, nothing stops the *resulting* row from violating the ownership
  predicate (not exploitable today on `profiles` since `user_id` is the
  primary key, but the pattern generalizes to any future column, so both
  clauses are present regardless: `profiles_update_own` sets `using
  (user_id = auth.uid()) with check (user_id = auth.uid())`).

## 4. `SECURITY DEFINER` hygiene: why every definer function pins `search_path`

`top_profiles()` and `delete_account()` are both `SECURITY DEFINER` — they
run with the privileges of the role that applied this migration (the
project owner, via the SQL Editor; see `README.md`), which is what lets
`top_profiles()` read every account's `profiles` row despite RLS, and lets
`delete_account()` delete from `auth.users` (a schema an ordinary
authenticated role has no business touching directly).

Both set `SET search_path = public, pg_temp` explicitly. Without that, an
unqualified identifier inside the function body resolves against whatever
`search_path` the *calling* session has configured — which a hostile caller
can manipulate (e.g. `SET search_path` before calling the RPC, or a
schema/object crafted to shadow a public one) to redirect an unqualified
reference to an attacker-controlled object, executed with the function's
elevated privileges. Pinning `search_path` removes that degree of freedom.
`push_events()` (a plain `SECURITY INVOKER` function — no elevated
privileges to steal) pins it too, out of the same general hygiene rather
than because it's independently exploitable there.

All three functions also explicitly `REVOKE ALL ... FROM PUBLIC` before
`GRANT EXECUTE ... TO authenticated` — Postgres grants `EXECUTE` to `PUBLIC`
by default on function creation, so the revoke isn't decorative. None of the
three is granted to `anon`; that's a deliberate least-privilege default, not
an oversight (see the inline comment above `top_profiles`'s grant for what
to do if a future task wants an anonymous-readable leaderboard — it's a
one-line addition, but a deliberate product decision, not a default).

## 5. Why `top_profiles` computes rank *before* `LIMIT`

`rank() over (order by total_km desc)` is a window function; Postgres
evaluates window functions before the query's own final `ORDER BY`/`LIMIT`
are applied — so `rank` is always computed over the *entire* `profiles`
table, and `LIMIT greatest(p_limit, 0)` only trims the *returned* page
afterward. This is what makes `LeaderboardRow.rank` (see its dartdoc in
`backend.dart`) meaningful against the whole leaderboard rather than a row's
position within whatever page happened to come back — Task 4 can trust
`rank` at face value without re-deriving it client-side, for any `limit`.

`rank()` (competition ranking, ties share a rank and the rank after a tie
skips ahead — 1, 2, 2, 4) is used deliberately, not `dense_rank()` (which
would produce 1, 2, 2, 3) — this matches the dartdoc Task 1 already pinned
on `LeaderboardRow.rank`.

## 6. What Task 3 gets for free vs. what it still has to build

Free (server-side, already in this migration):
- Idempotent push (`push_events`, `ON CONFLICT (id) DO NOTHING`) — Task 3's
  `pushEvents` can call the RPC with the whole batch in one round trip and
  not worry about partial-failure bookkeeping; a re-sent event is a no-op.
- Server-computed, tie-correct leaderboard rank (`top_profiles`).
- Cascading account deletion (`delete_account`) — one RPC call, no
  multi-step client-side cleanup of `game_events`/`profiles` needed.

Still Task 3/4's responsibility:
- Encoding/decoding the two-field cursor (section 1 above).
- Serializing `GameEvent.ts` with an explicit UTC/offset marker before
  calling `push_events` — the migration's `::timestamptz` cast on an
  offset-less string is ambiguous (interpreted against the session's
  timezone), which is a client-serialization concern, not something the SQL
  layer can fix for a caller that gets it wrong.
- Mapping `SyncNetworkError`/`SyncAuthError` (per `backend.dart`'s contract)
  onto whatever PostgREST/supabase_flutter actually throws for a network
  failure vs. an RLS/auth rejection vs. a `raise exception` from inside one
  of these functions (e.g. `push_events`' "authentication required" — should
  probably surface as `SyncAuthError`, not `SyncNetworkError`, since it's
  the backend affirmatively saying no, not a connectivity problem — worth
  confirming against `SyncAuthError`'s dartdoc when Task 3 writes that
  mapping).
