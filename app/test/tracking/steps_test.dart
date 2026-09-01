import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/tracking/steps.dart';

/// Stands in for the hardware TYPE_STEP_COUNTER: a monotonic since-boot
/// counter that can be unavailable, can fail, and resets on reboot.
class FakeStepSensor implements StepSensor {
  FakeStepSensor({this.available = true, this.value});

  bool available;
  int? value;
  bool failReads = false;
  int starts = 0;
  int stops = 0;

  @override
  Future<bool> start() async {
    starts++;
    return available;
  }

  @override
  Future<int?> read() async {
    if (failReads) throw StateError('sensor gone');
    return available ? value : null;
  }

  @override
  Future<void> stop() async => stops++;
}

void main() {
  group('StepTally', () {
    test('starts at zero before any reading', () {
      expect(StepTally().steps, 0);
    });

    test('the first reading only anchors the baseline', () {
      final tally = StepTally()..record(12345);
      expect(tally.steps, 0);
    });

    test('later readings count the delta since the baseline', () {
      final tally = StepTally()
        ..record(12345)
        ..record(12400);
      expect(tally.steps, 55);
      tally.record(12500);
      expect(tally.steps, 155);
    });

    test('a device reboot (counter reset to 0) keeps what was counted', () {
      // TYPE_STEP_COUNTER is cumulative since boot: a reboot mid-trip
      // restarts it near zero, which would otherwise read as a huge
      // negative delta.
      final tally = StepTally()
        ..record(12345)
        ..record(12400) // +55
        ..record(3); // reboot: re-anchor, keep the 55
      expect(tally.steps, 55);
      tally.record(20);
      expect(tally.steps, 72);
    });

    test('a repeated reading does not double count', () {
      final tally = StepTally()
        ..record(100)
        ..record(150)
        ..record(150);
      expect(tally.steps, 50);
    });

    test('resuming an interrupted trip seeds the already-counted steps', () {
      final tally = StepTally(seed: 1600)
        ..record(50000) // baseline re-anchored in a brand new process
        ..record(50100);
      expect(tally.steps, 1700);
    });

    test('a seeded tally reports its seed before any reading', () {
      expect(StepTally(seed: 1600).steps, 1600);
    });
  });

  group('SessionStepCounter', () {
    test('is unavailable when the sensor refuses to start', () async {
      final sensor = FakeStepSensor(available: false);
      final counter = SessionStepCounter(sensor);
      expect(await counter.start(), isFalse);
      expect(counter.isAvailable, isFalse);
    });

    test('counts the delta across samples', () async {
      final sensor = FakeStepSensor(value: 1000);
      final counter = SessionStepCounter(sensor);
      await counter.start();
      expect(counter.steps, 0);

      sensor.value = 1010;
      await counter.sample();
      expect(counter.steps, 10);

      sensor.value = 1025;
      await counter.sample();
      expect(counter.steps, 25);
    });

    test('start anchors the baseline immediately', () async {
      final sensor = FakeStepSensor(value: 8000);
      final counter = SessionStepCounter(sensor);
      await counter.start();
      sensor.value = 8003;
      await counter.sample();
      expect(counter.steps, 3);
    });

    test('a sample that throws freezes the count instead of failing', () async {
      final sensor = FakeStepSensor(value: 1000);
      final counter = SessionStepCounter(sensor);
      await counter.start();
      sensor.value = 1010;
      await counter.sample();

      sensor.failReads = true;
      await counter.sample();
      expect(counter.steps, 10);

      sensor.failReads = false;
      sensor.value = 1015;
      await counter.sample();
      expect(counter.steps, 15);
    });

    test(
      'a null reading (no permission, no sensor) leaves the count alone',
      () async {
        final sensor = FakeStepSensor(value: null);
        final counter = SessionStepCounter(sensor);
        await counter.start();
        await counter.sample();
        expect(counter.steps, 0);
      },
    );

    test('resuming seeds the count and only adds new steps', () async {
      final sensor = FakeStepSensor(value: 50000);
      final counter = SessionStepCounter(sensor, seed: 1600);
      await counter.start();
      expect(counter.steps, 1600);
      sensor.value = 50100;
      await counter.sample();
      expect(counter.steps, 1700);
    });

    test('stop releases the sensor', () async {
      final sensor = FakeStepSensor(value: 1);
      final counter = SessionStepCounter(sensor);
      await counter.start();
      await counter.stop();
      expect(sensor.stops, 1);
    });

    test('an unavailable sensor still samples without throwing', () async {
      final counter = SessionStepCounter(FakeStepSensor(available: false));
      await counter.start();
      await counter.sample();
      expect(counter.steps, 0);
    });
  });
}
