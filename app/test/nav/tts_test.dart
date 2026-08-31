import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/nav/tts.dart';

/// A fake [TtsSpeaker], for tests of anything that merely *uses* the façade
/// (e.g. the tracking handler's alert wiring) without needing a real TTS
/// engine.
class FakeTtsSpeaker implements TtsSpeaker {
  final spoken = <String>[];

  @override
  Future<void> speak(String text) async => spoken.add(text);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('NoopTtsSpeaker does nothing and never throws', () async {
    await const NoopTtsSpeaker().speak('Tournez à gauche');
  });

  test('a FakeTtsSpeaker records what callers ask it to say', () async {
    final fake = FakeTtsSpeaker();
    await fake.speak('Tournez à gauche');
    await fake.speak('Arrivé !');
    expect(fake.spoken, ['Tournez à gauche', 'Arrivé !']);
  });

  group('FlutterTtsSpeaker', () {
    const channel = MethodChannel('flutter_tts');
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return 1;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('configures fr-FR once, lazily, before the first speak', () async {
      final speaker = FlutterTtsSpeaker();
      await speaker.speak('Tournez à gauche');

      expect(calls.map((c) => c.method),
          ['setLanguage', 'setSpeechRate', 'speak']);
      expect(calls[0].arguments, 'fr-FR');
    });

    test('does not repeat setup on a later speak', () async {
      final speaker = FlutterTtsSpeaker();
      await speaker.speak('Tournez à gauche');
      calls.clear();

      await speaker.speak('Arrivé !');

      expect(calls.map((c) => c.method), ['speak']);
    });
  });
}
