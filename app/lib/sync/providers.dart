import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../game/game_state_provider.dart';
import 'account_state.dart';
import 'backend.dart';
import 'config.dart';
import 'sync_engine.dart';
import 'sync_state_store.dart';
import 'supabase_backend.dart';

/// The app's single [SyncBackend] instance.
///
/// Returns [UnconfiguredBackend] whenever [SupabaseConfig.fromEnvironment]
/// is `null` — every build without `--dart-define=SUPABASE_URL=...
/// --dart-define=SUPABASE_ANON_KEY=...`, which is the default and the case
/// this task's identity test pins down.
///
/// Otherwise constructs a [SupabaseBackend] (Task 3's thin
/// `supabase_flutter` adapter) — merely constructing it does not touch the
/// network; `supabase_flutter` itself is only initialized lazily, on that
/// backend's first real call (see [SupabaseBackend]'s dartdoc).
final syncBackendProvider = Provider<SyncBackend>((ref) {
  final config = SupabaseConfig.fromEnvironment();
  if (config == null) return const UnconfiguredBackend();
  return SupabaseBackend(config);
});

/// The account/sync flow's current [AccountState], seeded from
/// [syncBackendProvider]: [AccountPhase.unconfigured] when that provider
/// yields [UnconfiguredBackend], [AccountPhase.signedOut] otherwise (a
/// configured backend with no session restored yet — Task 4's sync engine
/// is what will drive this forward to `otpSent`/`signedIn` via the pure
/// transitions on [AccountState]).
final accountStateProvider = StateProvider<AccountState>((ref) {
  final backend = ref.watch(syncBackendProvider);
  return backend is UnconfiguredBackend
      ? const AccountState.unconfigured()
      : const AccountState.signedOut();
});

/// Persists [SyncEngine]'s push/pull checkpoint (`sync/sync_state_store.
/// dart`), scoped to the currently signed-in account's uid (fix round 1,
/// Task 4 review C2 — see [PrefsSyncStateStore]'s own dartdoc for why).
/// Watches [accountStateProvider] so signing into a *different* account
/// rebuilds this provider (and, transitively, [syncEngineProvider], which
/// watches this one) with a store scoped to the new uid — `PrefsSyncStateStore`
/// itself is cheap to construct either way (each call goes through
/// `SharedPreferences.getInstance()`, already a memoized singleton).
final syncStateStoreProvider = Provider<SyncStateStore>((ref) {
  final uid = ref.watch(accountStateProvider).uid;
  return PrefsSyncStateStore(uid ?? PrefsSyncStateStore.noAccountUid);
});

/// The app's single [SyncEngine], built from the same [gameJournalProvider]
/// `gameStateProvider` reads (`game/game_state_provider.dart`) so a merge
/// appends to the exact journal file the rest of the app replays, and wired
/// to bump [GameJournalSignal] on recompute so `gameStateProvider`
/// re-replays after a sync brings in new remote events.
///
/// Constructing this provider does no I/O by itself (no different from
/// constructing any of its three dependencies) — the M5 "unconfigured
/// stays bit-identical to M4" constraint is instead upheld by every call
/// site gating on `accountStateProvider.phase == AccountPhase.signedIn`
/// *before* ever reading this provider (see `sync/auto_sync.dart`), since
/// that phase is unreachable when [syncBackendProvider] yields
/// [UnconfiguredBackend].
final syncEngineProvider = FutureProvider<SyncEngine>((ref) async {
  final journal = await ref.watch(gameJournalProvider.future);
  final backend = ref.watch(syncBackendProvider);
  final stateStore = ref.watch(syncStateStoreProvider);
  return SyncEngine(
    journal: journal,
    backend: backend,
    stateStore: stateStore,
    onRecompute: GameJournalSignal.instance.bump,
  );
});

/// The outcome of the most recent [SyncEngine.sync] call this process has
/// run (launch auto-sync, post-trip auto-sync, or the account screen's
/// manual button — see `sync/auto_sync.dart`'s `runAutoSync`, the single
/// entry point all three go through). `null` until the first sync attempt.
///
/// Deliberately in-memory only, not persisted: it exists purely to answer
/// "how did the last sync go" for as long as this process runs, which is
/// exactly the account screen's "dernier résultat de synchronisation" —
/// nothing reads this across a restart.
final lastSyncResultProvider = StateProvider<SyncResult?>((ref) => null);

/// One [SyncEngine.sync] outcome, success or failure, with a French error
/// message ready to show on the account screen (`runAutoSync` is the only
/// place that constructs one, mapping the raw exception once so every
/// trigger — launch, post-trip, manual — shows identical copy).
class SyncResult {
  final DateTime at;
  final SyncReport? report;
  final String? errorMessage;

  const SyncResult.success(this.report, this.at) : errorMessage = null;
  const SyncResult.failure(this.errorMessage, this.at) : report = null;

  bool get isSuccess => errorMessage == null;
}
