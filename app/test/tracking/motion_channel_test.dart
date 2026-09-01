import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/tracking/motion_channel.dart';

// Same rationale as device_channel_test.dart: `Platform.isAndroid` cannot be
// overridden from a host-run `flutter test`, so what is actually verifiable
// here is the public contract that matters most for this channel — it
// degrades to a quiet "unavailable" (`start()` -> false) rather than
// throwing, which is exactly the signal `TripTaskHandler` reads as "fall
// back to the step/GPS detector" (see motion_policy_test.dart), and is also
// the emulator's own path in CI.
void main() {
  test('start() never throws and returns false off Android', () async {
    expect(await const MotionChannel().start(), isFalse);
  });

  test('stop() never throws off Android', () async {
    await const MotionChannel().stop();
  });

  test(
    'transitions is a broadcast stream that never emits on its own',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final events = <bool>[];
      final sub = const MotionChannel().transitions.listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(events, isEmpty);
      await sub.cancel();
    },
  );
}
