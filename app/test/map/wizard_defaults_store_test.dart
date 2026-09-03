import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/map/plan_mode.dart';
import 'package:randomwalk/map/wizard_defaults_store.dart';
import 'package:randomwalk/valhalla/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('WizardDefaultsStore — fresh install', () {
    test('falls back to PlanMode.loop and the profile default', () async {
      final store = WizardDefaultsStore();
      final defaults = await store.load(RoutingProfile.walk);
      expect(defaults.mode, PlanMode.loop);
      expect(defaults.loopTargetKm, defaultLoopTargetKm(RoutingProfile.walk));
      expect(defaults.durationTarget, kDurationTargetDefault);
    });

    test('the loop-target default follows the profile', () async {
      final store = WizardDefaultsStore();
      final bike = await store.load(RoutingProfile.bike);
      expect(bike.loopTargetKm, defaultLoopTargetKm(RoutingProfile.bike));
    });
  });

  group('WizardDefaultsStore — round trip', () {
    test('saveMode/load remembers the last constraint kind', () async {
      final store = WizardDefaultsStore();
      await store.saveMode(PlanMode.duration);
      final defaults = await store.load(RoutingProfile.walk);
      expect(defaults.mode, PlanMode.duration);
    });

    test(
      'saveMode ignores PlanMode.itinerary (never a promenade mode)',
      () async {
        final store = WizardDefaultsStore();
        await store.saveMode(PlanMode.itinerary);
        final defaults = await store.load(RoutingProfile.walk);
        // Falls back to the untouched default rather than persisting
        // something `load` would silently reinterpret.
        expect(defaults.mode, PlanMode.loop);
      },
    );

    test('saveLoopTargetKm/load round-trips and clamps', () async {
      final store = WizardDefaultsStore();
      await store.saveLoopTargetKm(37.2); // above kLoopTargetMaxKm
      final defaults = await store.load(RoutingProfile.walk);
      expect(defaults.loopTargetKm, kLoopTargetMaxKm);
    });

    test('saveDurationTarget/load round-trips and clamps', () async {
      final store = WizardDefaultsStore();
      await store.saveDurationTarget(const Duration(minutes: 5));
      final defaults = await store.load(RoutingProfile.walk);
      expect(defaults.durationTarget, kDurationTargetMin);
    });

    test(
      'distance and duration are remembered independently of each other',
      () async {
        final store = WizardDefaultsStore();
        await store.saveLoopTargetKm(9.0);
        await store.saveDurationTarget(const Duration(minutes: 50));
        final defaults = await store.load(RoutingProfile.walk);
        expect(defaults.loopTargetKm, 9.0);
        expect(defaults.durationTarget, const Duration(minutes: 45));
      },
    );
  });
}
