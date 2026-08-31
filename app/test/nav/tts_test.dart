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
  test('NoopTtsSpeaker does nothing and never throws', () async {
    await const NoopTtsSpeaker().speak('Tournez à gauche');
  });

  test('a FakeTtsSpeaker records what callers ask it to say', () async {
    final fake = FakeTtsSpeaker();
    await fake.speak('Tournez à gauche');
    await fake.speak('Arrivé !');
    expect(fake.spoken, ['Tournez à gauche', 'Arrivé !']);
  });
}
