import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/sync/config.dart';

void main() {
  test(
    'fromEnvironment is null with no --dart-define (default test/build env)',
    () {
      // This pins the M5 global constraint at the config layer: a plain
      // `flutter test`/`flutter run`/`flutter build` (no SUPABASE_URL /
      // SUPABASE_ANON_KEY dart-defines) must read back as unconfigured.
      expect(SupabaseConfig.fromEnvironment(), isNull);
    },
  );
}
