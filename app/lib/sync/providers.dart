import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'account_state.dart';
import 'backend.dart';
import 'config.dart';
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
