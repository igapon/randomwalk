import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/trip/gated_ticker.dart';

void main() {
  test('does not tick while inactive', () async {
    var ticks = 0;
    final ticker = GatedTicker(
      onTick: () => ticks++,
      interval: const Duration(milliseconds: 20),
    );

    ticker.sync(false); // idle: never started
    await Future.delayed(const Duration(milliseconds: 80));

    expect(ticks, 0);
    expect(ticker.isActive, false);
    ticker.dispose();
  });

  test('ticks periodically once active', () async {
    var ticks = 0;
    final ticker = GatedTicker(
      onTick: () => ticks++,
      interval: const Duration(milliseconds: 20),
    );

    ticker.sync(true);
    expect(ticker.isActive, true);
    await Future.delayed(const Duration(milliseconds: 90));

    expect(ticks, greaterThanOrEqualTo(3));
    ticker.dispose();
  });

  test('stops ticking once deactivated', () async {
    var ticks = 0;
    final ticker = GatedTicker(
      onTick: () => ticks++,
      interval: const Duration(milliseconds: 20),
    );

    ticker.sync(true);
    await Future.delayed(const Duration(milliseconds: 50));
    final ticksAtStop = ticks;
    ticker.sync(false);
    expect(ticker.isActive, false);

    await Future.delayed(const Duration(milliseconds: 80));
    expect(ticks, ticksAtStop); // no further ticks after stopping
    ticker.dispose();
  });

  test(
    'sync(true) called repeatedly does not create duplicate timers',
    () async {
      var ticks = 0;
      final ticker = GatedTicker(
        onTick: () => ticks++,
        interval: const Duration(milliseconds: 30),
      );

      ticker.sync(true);
      ticker.sync(true); // idempotent — must not double the tick rate
      ticker.sync(true);
      await Future.delayed(const Duration(milliseconds: 100));

      // ~3 ticks expected at a 30ms interval over 100ms; a doubled timer
      // would produce roughly twice that.
      expect(ticks, lessThan(6));
      ticker.dispose();
    },
  );

  test('dispose stops a running ticker', () async {
    var ticks = 0;
    final ticker = GatedTicker(
      onTick: () => ticks++,
      interval: const Duration(milliseconds: 20),
    );

    ticker.sync(true);
    await Future.delayed(const Duration(milliseconds: 30));
    ticker.dispose();
    final ticksAtDispose = ticks;

    await Future.delayed(const Duration(milliseconds: 80));
    expect(ticks, ticksAtDispose);
  });
}
