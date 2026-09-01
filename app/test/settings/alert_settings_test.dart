import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:randomwalk/settings/alert_settings.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('both toggles default to on', () async {
    final store = AlertSettingsStore();
    expect(await store.ttsEnabled(), isTrue);
    expect(await store.hapticsEnabled(), isTrue);
  });

  test('setTtsEnabled persists independently of haptics', () async {
    final store = AlertSettingsStore();
    await store.setTtsEnabled(false);
    expect(await store.ttsEnabled(), isFalse);
    expect(await store.hapticsEnabled(), isTrue);
  });

  test('setHapticsEnabled persists independently of tts', () async {
    final store = AlertSettingsStore();
    await store.setHapticsEnabled(false);
    expect(await store.hapticsEnabled(), isFalse);
    expect(await store.ttsEnabled(), isTrue);
  });

  test(
    'a later read sees the persisted value, not a memoized default',
    () async {
      await AlertSettingsStore().setTtsEnabled(false);
      final reread = AlertSettingsStore();
      expect(await reread.ttsEnabled(), isFalse);
    },
  );
}
