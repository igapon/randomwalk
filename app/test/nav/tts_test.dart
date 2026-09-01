import 'dart:async';

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

  group('NativeTtsSpeaker', () {
    final calls = <MethodCall>[];
    bool initResult = true;

    setUp(() {
      calls.clear();
      initResult = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeTtsSpeaker.channel, (call) async {
            calls.add(call);
            if (call.method == 'init') return initResult;
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeTtsSpeaker.channel, null);
    });

    test('available is false before init has ever been called', () {
      expect(NativeTtsSpeaker().available, isFalse);
    });

    test(
      'init true makes speak reach the native channel with the text',
      () async {
        final speaker = NativeTtsSpeaker();
        expect(await speaker.init(), isTrue);
        expect(speaker.available, isTrue);

        await speaker.speak('Tournez à gauche');

        expect(calls.map((c) => c.method), ['init', 'speak']);
        expect(calls[1].arguments, {'text': 'Tournez à gauche'});
      },
    );

    test(
      'init false makes every later speak a no-op — no channel call at all',
      () async {
        initResult = false;
        final speaker = NativeTtsSpeaker();
        expect(await speaker.init(), isFalse);
        expect(speaker.available, isFalse);
        calls.clear();

        await speaker.speak('Tournez à gauche');

        expect(calls, isEmpty);
      },
    );

    test('a speak before init is called at all is also a no-op', () async {
      final speaker = NativeTtsSpeaker();
      await speaker.speak('Tournez à gauche');
      expect(calls, isEmpty);
    });

    test('two overlapping init() calls collapse into a single platform call — '
        'the production trigger is two settings pushes before the first '
        'resolves, each building its own NativeTtsSpeaker', () async {
      final reply = Completer<bool>();
      var initCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeTtsSpeaker.channel, (call) async {
            if (call.method == 'init') {
              initCalls++;
              return reply.future;
            }
            return null;
          });

      // Two separate instances — matching TripTaskHandler's own pattern of
      // building a fresh NativeTtsSpeaker per settings push — both call
      // init() before the (still delayed) platform reply arrives.
      final first = NativeTtsSpeaker().init();
      final second = NativeTtsSpeaker().init();

      reply.complete(true);

      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(
        initCalls,
        1,
        reason:
            'the second caller must await the first call, not start '
            'its own',
      );
    });

    test('a later, non-overlapping init() reaches the channel again', () async {
      await NativeTtsSpeaker().init();
      calls.clear();

      await NativeTtsSpeaker().init();

      expect(calls.map((c) => c.method), ['init']);
    });

    test('a transient native failure is retried on the next init() and can '
        'succeed — this test only pins down the Dart-side half (a fresh '
        'call reaches the channel again after a false); the native retry '
        'budget itself is TtsChannel.kt\'s (see fix round 3)', () async {
      var initCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeTtsSpeaker.channel, (call) async {
            if (call.method != 'init') return null;
            initCalls++;
            // First attempt: a transient native failure. Second: the retry
            // succeeds, exactly as TtsChannel.kt now allows after State.FAILED.
            return initCalls > 1;
          });

      final first = NativeTtsSpeaker();
      expect(await first.init(), isFalse);
      expect(first.available, isFalse);

      final second = NativeTtsSpeaker();
      expect(await second.init(), isTrue);
      expect(second.available, isTrue);

      expect(initCalls, 2);
    });

    test(
      'a channel error during init is treated as unavailable, not thrown',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeTtsSpeaker.channel, (call) async {
              throw PlatformException(code: 'BOOM');
            });
        final speaker = NativeTtsSpeaker();
        expect(await speaker.init(), isFalse);
        expect(speaker.available, isFalse);
      },
    );

    test('a channel error during speak does not throw', () async {
      final speaker = NativeTtsSpeaker();
      await speaker.init();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeTtsSpeaker.channel, (call) async {
            if (call.method == 'speak') throw PlatformException(code: 'BOOM');
            return null;
          });

      await speaker.speak('Tournez à gauche');
    });

    test(
      'shutdown reaches the channel once initialised, and is a no-op before',
      () async {
        final speaker = NativeTtsSpeaker();
        await speaker.shutdown();
        expect(calls, isEmpty);

        await speaker.init();
        calls.clear();
        await speaker.shutdown();
        expect(calls.map((c) => c.method), ['shutdown']);
      },
    );
  });
}
