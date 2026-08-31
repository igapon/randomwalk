// Task-7 item 3: the TTS availability probe SettingsScreen fires in
// initState (`NativeTtsSpeaker().init()`) builds a real `TextToSpeech`
// engine on the native side purely to answer "is French TTS usable here?" —
// see TtsChannel.kt. Nothing ever released it: the engine sat allocated for
// as long as the settings screen (or, since the probe is fire-and-forget,
// even longer) stayed alive, wasting a real OS resource for a one-shot
// question. The fix asks the same channel's `shutdown()` right after `init`
// answers.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/nav/tts.dart';
import 'package:randomwalk/settings/settings_screen.dart';
import 'package:randomwalk/tracking/device_channel.dart';
import 'package:randomwalk/tracking/permissions.dart';
import 'package:randomwalk/tracking/steps.dart';
import 'package:randomwalk/trip/trip_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/trip_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ttsCalls = <String>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ttsCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeTtsSpeaker.channel, (call) async {
      ttsCalls.add(call.method);
      if (call.method == 'init') return true;
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DeviceChannel.channel, (call) async {
      if (call.method == 'manufacturer') return null;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeTtsSpeaker.channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DeviceChannel.channel, null);
  });

  TripController buildTrip() => TripController(
        tracker: FakeTripTracker(),
        routeStore: MemoryRouteStore(),
        totalStore: FakeTotalDistanceStore(),
        finalisedTrips: MemoryFinalisedTripMemory(),
        ensurePermissions: () async => const TripPermissions(
            outcome: TripPermissionOutcome.ready,
            mode: TrackingMode.background),
        createStepCounter: (seed) =>
            SessionStepCounter(FakeStepSensor(), seed: seed),
        persistProfile: (_) async {},
        loadProfile: () async => null,
      );

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tripControllerProvider.overrideWith((ref) => buildTrip())],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
  }

  testWidgets(
      'the TTS probe shuts its engine down once init has answered',
      (tester) async {
    await pumpSettings(tester);
    await tester.pumpAndSettle();

    expect(ttsCalls, ['init', 'shutdown'],
        reason: 'init answers the availability question; shutdown must '
            'follow right after, releasing the native engine rather than '
            'leaking it for the rest of the screen\'s lifetime');
  });

  testWidgets(
      '"Guidage vocal" still reflects the probed availability after shutdown',
      (tester) async {
    await pumpSettings(tester);
    await tester.pumpAndSettle();

    expect(find.text('Guidage vocal'), findsOneWidget);
    expect(find.text('Instructions de navigation lues à voix haute'),
        findsOneWidget);
  });
}
