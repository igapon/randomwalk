import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/sync/account_state.dart';
import 'package:randomwalk/sync/backend.dart';
import 'package:randomwalk/sync/providers.dart';

void main() {
  test('syncBackendProvider yields UnconfiguredBackend under the test env '
      '(no SUPABASE_URL/SUPABASE_ANON_KEY dart-define)', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(syncBackendProvider), isA<UnconfiguredBackend>());
  });

  test('accountStateProvider seeds to AccountPhase.unconfigured to match', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      container.read(accountStateProvider).phase,
      AccountPhase.unconfigured,
    );
  });
}
