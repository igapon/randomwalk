import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'account_state.dart';
import 'backend.dart';
import 'config.dart';

/// The app's single [SyncBackend] instance.
///
/// Returns [UnconfiguredBackend] whenever [SupabaseConfig.fromEnvironment]
/// is `null` — every build without `--dart-define=SUPABASE_URL=...
/// --dart-define=SUPABASE_ANON_KEY=...`, which is the default and the case
/// this task's identity test pins down.
///
/// Task 3 adds the real branch: when a [SupabaseConfig] is present, this
/// will construct and return a `SupabaseBackend` instead. Until then, a
/// configured build still gets [UnconfiguredBackend] here — there is no
/// `SupabaseBackend` yet — so setting the dart-defines alone does not turn
/// on networking; it only starts a build that is ready for Task 3 to wire
/// up.
final syncBackendProvider = Provider<SyncBackend>((ref) {
  final config = SupabaseConfig.fromEnvironment();
  if (config == null) return const UnconfiguredBackend();
  // TODO(Task 3): return SupabaseBackend(config) once that thin
  // supabase_flutter adapter exists.
  return const UnconfiguredBackend();
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
