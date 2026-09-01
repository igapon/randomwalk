import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:randomwalk/settings/identity.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'concurrent get() calls share one in-flight initialization (no uuid race)',
    () async {
      final store = IdentityStore();
      // Two callers racing before either has persisted anything yet.
      final results = await Future.wait([store.get(), store.get()]);
      expect(results[0].userId, results[1].userId);
      expect(results[0].pseudo, results[1].pseudo);

      // And a later call still agrees.
      final third = await store.get();
      expect(third.userId, results[0].userId);
    },
  );

  test(
    'setPseudo updates the memoized identity so a later get() reflects it',
    () async {
      final store = IdentityStore();
      final before = await store.get();
      await store.setPseudo('Nouveau Nom');
      final after = await store.get();
      expect(after.userId, before.userId);
      expect(after.pseudo, 'Nouveau Nom');
    },
  );
}
