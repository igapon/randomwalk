import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:randomwalk/loop/loop_planner.dart';
import 'package:randomwalk/map/plan_mode.dart';
import 'package:randomwalk/valhalla/models.dart';

void main() {
  group('defaultLoopTargetKm', () {
    test('5 km for walk, 15 km for bike', () {
      expect(defaultLoopTargetKm(RoutingProfile.walk), 5.0);
      expect(defaultLoopTargetKm(RoutingProfile.bike), 15.0);
    });
  });

  group('clampLoopTargetKm', () {
    test('snaps to the nearest 0.5 km step', () {
      expect(clampLoopTargetKm(5.2), 5.0);
      expect(clampLoopTargetKm(5.3), 5.5);
      expect(clampLoopTargetKm(5.26), 5.5);
    });

    test('clamps below the minimum up to 1 km', () {
      expect(clampLoopTargetKm(0), 1.0);
      expect(clampLoopTargetKm(-5), 1.0);
    });

    test('clamps above the maximum down to 30 km', () {
      expect(clampLoopTargetKm(45), 30.0);
    });

    test('is always strictly positive, whatever the input', () {
      for (final input in [-100.0, -0.001, 0.0, 0.1, 30.4, 1000.0]) {
        expect(clampLoopTargetKm(input), greaterThan(0));
      }
    });
  });

  group('clampDurationTarget', () {
    test('snaps to the nearest 15-minute step', () {
      expect(clampDurationTarget(const Duration(minutes: 50)),
          const Duration(minutes: 45));
      expect(clampDurationTarget(const Duration(minutes: 52)),
          const Duration(minutes: 45));
      expect(clampDurationTarget(const Duration(minutes: 53)),
          const Duration(hours: 1));
    });

    test('clamps below 15 minutes up to the minimum', () {
      expect(clampDurationTarget(Duration.zero), const Duration(minutes: 15));
      expect(clampDurationTarget(const Duration(minutes: 5)),
          const Duration(minutes: 15));
    });

    test('clamps above 4 hours down to the maximum', () {
      expect(clampDurationTarget(const Duration(hours: 10)),
          const Duration(hours: 4));
    });
  });

  group('durationToTargetKm', () {
    test('multiplies hours by speed', () {
      expect(durationToTargetKm(const Duration(hours: 1), 4.5), 4.5);
      expect(durationToTargetKm(const Duration(minutes: 30), 4.5),
          closeTo(2.25, 1e-9));
      expect(durationToTargetKm(const Duration(minutes: 15), 4.5),
          closeTo(1.125, 1e-9));
    });

    test('is always positive for a positive speed and the minimum duration',
        () {
      expect(durationToTargetKm(kDurationTargetMin, 2.0), greaterThan(0));
    });

    group('clamped to the Boucle slider bounds (final review item 4)', () {
      test('a fast cyclist over 4 hours is capped at the maximum', () {
        // 4 h at 25 km/h is 100 km — a target the loop planner would spend
        // its whole router budget bisecting toward and never reach, and one
        // no « Boucle » slider position can even express.
        expect(durationToTargetKm(kDurationTargetMax, 25), kLoopTargetMaxKm);
        expect(durationToTargetKm(const Duration(hours: 2), 20),
            kLoopTargetMaxKm);
      });

      test('a slow walker over the minimum duration is raised to the minimum',
          () {
        // 15 min at 3 km/h is 0.75 km, below the slider's own floor.
        expect(durationToTargetKm(kDurationTargetMin, 3), kLoopTargetMinKm);
      });

      test('an in-range conversion is untouched', () {
        expect(durationToTargetKm(const Duration(hours: 1), 4.5), 4.5);
        expect(durationToTargetKm(const Duration(hours: 2), 12), 24.0);
      });

      test('the result is always a legal LoopRequest target', () {
        for (var minutes = 15; minutes <= 240; minutes += 15) {
          for (final speed in [2.0, 4.5, 6.0, 15.0, 25.0, 40.0]) {
            final km = durationToTargetKm(Duration(minutes: minutes), speed);
            expect(km, greaterThanOrEqualTo(kLoopTargetMinKm));
            expect(km, lessThanOrEqualTo(kLoopTargetMaxKm));
          }
        }
      });
    });
  });

  group('formatConversionLabel', () {
    test('one decimal, French comma', () {
      expect(formatConversionLabel(3.8), '≈ 3,8 km à votre rythme');
      expect(formatConversionLabel(12.0), '≈ 12,0 km à votre rythme');
      expect(formatConversionLabel(2.04), '≈ 2,0 km à votre rythme');
    });

    test('says so when the target is sitting on a bound (item 4)', () {
      // Otherwise the label reads as an ordinary pace conversion and the
      // walker has no way to tell why lengthening the duration stopped
      // changing the distance.
      expect(formatConversionLabel(kLoopTargetMaxKm),
          '≈ 30,0 km (maximum) à votre rythme');
      expect(formatConversionLabel(kLoopTargetMinKm),
          '≈ 1,0 km (minimum) à votre rythme');
    });

    test('reflects the clamp the conversion actually applied', () {
      expect(formatConversionLabel(durationToTargetKm(kDurationTargetMax, 25)),
          contains('(maximum)'));
      expect(formatConversionLabel(durationToTargetKm(kDurationTargetMin, 3)),
          contains('(minimum)'));
      expect(
          formatConversionLabel(
              durationToTargetKm(const Duration(hours: 1), 4.5)),
          '≈ 4,5 km à votre rythme');
    });
  });

  group('seed stepping', () {
    test('initialSeed is derived from the clock, in whole seconds', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1234567890123);
      expect(initialSeed(now), 1234567890);
    });

    test('nextSeed increments by exactly 1', () {
      expect(nextSeed(0), 1);
      expect(nextSeed(41), 42);
    });
  });

  group('buildLoopRequest', () {
    const start = (46.52, 6.63);
    const destination = (46.55, 6.70);

    test('itinerary mode never builds a request', () {
      final request = buildLoopRequest(
        mode: PlanMode.itinerary,
        loopTargetKm: 5,
        durationTarget: kDurationTargetDefault,
        speedKmh: 4.5,
        profile: RoutingProfile.walk,
        start: start,
        seed: 1,
      );
      expect(request, isNull);
    });

    test('loop mode with no destination builds a closed loop from '
        'loopTargetKm', () {
      final request = buildLoopRequest(
        mode: PlanMode.loop,
        loopTargetKm: 7.5,
        durationTarget: kDurationTargetDefault,
        speedKmh: 4.5,
        profile: RoutingProfile.walk,
        start: start,
        seed: 3,
      );
      expect(request, isNotNull);
      expect(request!.kind, PlanKind.loop);
      expect(request.targetKm, 7.5);
      expect(request.start, start);
      expect(request.end, isNull);
      expect(request.seed, 3);
      expect(request.profile, RoutingProfile.walk);
    });

    test(
        'loop mode with a destination builds a fixed-target A->B request '
        '(task-8 brief point 3: "il faut que pour A-B on puisse sélectionner '
        'une distance") with loopTargetKm as the target', () {
      final request = buildLoopRequest(
        mode: PlanMode.loop,
        loopTargetKm: 7.5,
        durationTarget: kDurationTargetDefault,
        speedKmh: 4.5,
        profile: RoutingProfile.walk,
        start: start,
        destination: destination,
        seed: 3,
      );
      expect(request, isNotNull);
      expect(request!.kind, PlanKind.toDestination);
      expect(request.end, destination);
      expect(request.targetKm, 7.5);
      expect(request.start, start);
      expect(request.seed, 3);
    });

    test('duration mode with no destination builds a loop from the '
        'duration->distance conversion', () {
      final request = buildLoopRequest(
        mode: PlanMode.duration,
        loopTargetKm: 5,
        durationTarget: const Duration(hours: 1),
        speedKmh: 4.5,
        profile: RoutingProfile.walk,
        start: start,
        seed: 9,
      );
      expect(request, isNotNull);
      expect(request!.kind, PlanKind.loop);
      expect(request.targetKm, closeTo(4.5, 1e-9));
      expect(request.end, isNull);
    });

    test(
        'duration mode with a destination builds a fixed-duration A->B '
        'request', () {
      final request = buildLoopRequest(
        mode: PlanMode.duration,
        loopTargetKm: 5,
        durationTarget: const Duration(hours: 1),
        speedKmh: 4.5,
        profile: RoutingProfile.bike,
        start: start,
        destination: destination,
        seed: 9,
      );
      expect(request, isNotNull);
      expect(request!.kind, PlanKind.toDestination);
      expect(request.end, destination);
      expect(request.targetKm, closeTo(4.5, 1e-9));
      expect(request.profile, RoutingProfile.bike);
    });

    test('never produces a non-positive targetKm from clamped inputs', () {
      for (final km in [kLoopTargetMinKm, kLoopTargetMaxKm]) {
        final request = buildLoopRequest(
          mode: PlanMode.loop,
          loopTargetKm: km,
          durationTarget: kDurationTargetDefault,
          speedKmh: 4.5,
          profile: RoutingProfile.walk,
          start: start,
          seed: 1,
        );
        expect(request!.targetKm, greaterThan(0));
      }
      for (final duration in [kDurationTargetMin, kDurationTargetMax]) {
        final request = buildLoopRequest(
          mode: PlanMode.duration,
          loopTargetKm: 5,
          durationTarget: duration,
          speedKmh: 2.0, // the slowest plausible walking speed
          profile: RoutingProfile.walk,
          start: start,
          seed: 1,
        );
        expect(request!.targetKm, greaterThan(0));
      }
    });
  });

  group('shouldClearDestinationOnModeSwitch', () {
    test('clears when leaving Itinéraire for Boucle with no route on screen',
        () {
      expect(
        shouldClearDestinationOnModeSwitch(
            from: PlanMode.itinerary, to: PlanMode.loop, hasRoute: false),
        isTrue,
      );
    });

    test('clears when leaving Itinéraire for Durée with no route on screen',
        () {
      expect(
        shouldClearDestinationOnModeSwitch(
            from: PlanMode.itinerary,
            to: PlanMode.duration,
            hasRoute: false),
        isTrue,
      );
    });

    test('never clears when a route is already on screen', () {
      // The result banner's own ✕ is the way to clear it in that case —
      // this must not race or duplicate that.
      expect(
        shouldClearDestinationOnModeSwitch(
            from: PlanMode.itinerary, to: PlanMode.loop, hasRoute: true),
        isFalse,
      );
      expect(
        shouldClearDestinationOnModeSwitch(
            from: PlanMode.itinerary,
            to: PlanMode.duration,
            hasRoute: true),
        isFalse,
      );
    });

    test('final review item 7: symmetric — Durée→Itinéraire drops the orphan '
        'pin too', () {
      // The asymmetry this replaces: a pin set in Durée that never became a
      // route survived into Itinéraire, where the Durée chip that could clear
      // it is gone and no result banner exists yet — an invisible target for
      // the next « Planifier »/long-press to plan against.
      expect(
        shouldClearDestinationOnModeSwitch(
            from: PlanMode.duration, to: PlanMode.itinerary, hasRoute: false),
        isTrue,
      );
      expect(
        shouldClearDestinationOnModeSwitch(
            from: PlanMode.loop, to: PlanMode.itinerary, hasRoute: false),
        isTrue,
      );
      expect(
        shouldClearDestinationOnModeSwitch(
            from: PlanMode.duration, to: PlanMode.loop, hasRoute: false),
        isTrue,
      );
      expect(
        shouldClearDestinationOnModeSwitch(
            from: PlanMode.loop, to: PlanMode.duration, hasRoute: false),
        isTrue,
      );
    });

    test('a route on screen protects the destination in every direction', () {
      for (final from in PlanMode.values) {
        for (final to in PlanMode.values) {
          expect(
            shouldClearDestinationOnModeSwitch(
                from: from, to: to, hasRoute: true),
            isFalse,
            reason: '$from -> $to',
          );
        }
      }
    });

    test('a no-op switch clears nothing', () {
      // `_onPlanModeChanged` returns early on this, but the rule must not
      // depend on that guard to avoid dropping a pin the user just set in
      // the mode they are already in.
      for (final mode in PlanMode.values) {
        expect(
          shouldClearDestinationOnModeSwitch(
              from: mode, to: mode, hasRoute: false),
          isFalse,
        );
      }
    });
  });

  group('formatDestinationLabel', () {
    test('four decimals, comma-separated', () {
      expect(formatDestinationLabel((46.52, 6.63)), '46.5200, 6.6300');
      expect(formatDestinationLabel((46.520001, 6.629999)),
          '46.5200, 6.6300');
    });
  });

  group('clampSelection', () {
    test('keeps a valid index unchanged', () {
      expect(clampSelection(1, 3), 1);
      expect(clampSelection(2, 3), 2);
    });

    test('falls back to 0 when the index is out of range', () {
      expect(clampSelection(3, 3), 0);
      expect(clampSelection(-1, 3), 0);
    });

    test('falls back to 0 for an empty candidate list', () {
      expect(clampSelection(0, 0), 0);
      expect(clampSelection(5, 0), 0);
    });
  });

  group('estimatedDuration', () {
    test('distance over speed, in whole seconds', () {
      expect(estimatedDuration(4.5, 4.5), const Duration(hours: 1));
      expect(estimatedDuration(2.25, 4.5), const Duration(minutes: 30));
    });

    test('is Duration.zero for a non-positive speed rather than dividing by '
        'zero', () {
      expect(estimatedDuration(5.0, 0), Duration.zero);
      expect(estimatedDuration(5.0, -1), Duration.zero);
    });
  });

  group('candidateOnTarget / gapBadgeLabel', () {
    LoopCandidate candidateWithGap(double gapRatio) => LoopCandidate(
          route: const RouteResult(
              shape: [(0, 0), (0, 1)],
              distanceKm: 1,
              duration: Duration.zero,
              maneuvers: []),
          gapRatio: gapRatio,
          repeatedRatio: 0,
          score: 0,
        );

    test('within tolerance: on target, no badge', () {
      final candidate = candidateWithGap(0.05);
      expect(candidateOnTarget(candidate), isTrue);
      expect(gapBadgeLabel(candidate), isNull);
    });

    test('exactly at the tolerance boundary counts as on target', () {
      final candidate = candidateWithGap(LoopPlanner.targetTolerance);
      expect(candidateOnTarget(candidate), isTrue);
      expect(gapBadgeLabel(candidate), isNull);
    });

    test('positive overshoot beyond tolerance shows a signed + badge', () {
      final candidate = candidateWithGap(0.12);
      expect(candidateOnTarget(candidate), isFalse);
      expect(gapBadgeLabel(candidate), '+12 %');
    });

    test('negative shortfall beyond tolerance shows a signed - badge', () {
      final candidate = candidateWithGap(-0.18);
      expect(candidateOnTarget(candidate), isFalse);
      expect(gapBadgeLabel(candidate), '-18 %');
    });
  });

  group('repeatedRatioHint', () {
    test('low repetition reads as "peu d\'allers-retours"', () {
      expect(repeatedRatioHint(0.0), "peu d'allers-retours");
      expect(repeatedRatioHint(0.14), "peu d'allers-retours");
    });

    test('at/above the threshold reads as "quelques allers-retours"', () {
      expect(repeatedRatioHint(0.15), 'quelques allers-retours');
      expect(repeatedRatioHint(0.9), 'quelques allers-retours');
    });
  });

  group('shouldShowPlanDestinationChip (task-8 point 3)', () {
    test('shown in Boucle/Distance mode with a pinned destination', () {
      expect(
        shouldShowPlanDestinationChip(
            mode: PlanMode.loop, hasDestination: true),
        isTrue,
      );
    });

    test('shown in Durée mode with a pinned destination', () {
      expect(
        shouldShowPlanDestinationChip(
            mode: PlanMode.duration, hasDestination: true),
        isTrue,
      );
    });

    test('hidden with no pinned destination, in either mode', () {
      expect(
        shouldShowPlanDestinationChip(
            mode: PlanMode.loop, hasDestination: false),
        isFalse,
      );
      expect(
        shouldShowPlanDestinationChip(
            mode: PlanMode.duration, hasDestination: false),
        isFalse,
      );
    });

    test('never shown in Itinéraire — the result banner owns that ✕', () {
      expect(
        shouldShowPlanDestinationChip(
            mode: PlanMode.itinerary, hasDestination: true),
        isFalse,
      );
    });
  });

  group('shouldShowPlanningTopOverlay (task-8 point 1: fullscreen selection)',
      () {
    test('shown with no candidates', () {
      expect(shouldShowPlanningTopOverlay(hasCandidates: false), isTrue);
    });

    test('hidden the instant candidates exist', () {
      expect(shouldShowPlanningTopOverlay(hasCandidates: true), isFalse);
    });
  });

  group('planPanelCollapsedLabel (task-8 point 2)', () {
    test('Distance mode: "Distance · X,X km ▸"', () {
      expect(
        planPanelCollapsedLabel(
            mode: PlanMode.loop,
            loopTargetKm: 5.0,
            durationTarget: kDurationTargetDefault),
        'Distance · 5,0 km ▸',
      );
      expect(
        planPanelCollapsedLabel(
            mode: PlanMode.loop,
            loopTargetKm: 12.5,
            durationTarget: kDurationTargetDefault),
        'Distance · 12,5 km ▸',
      );
    });

    test('Durée mode with hours and minutes: "Durée · H h MM ▸"', () {
      expect(
        planPanelCollapsedLabel(
            mode: PlanMode.duration,
            loopTargetKm: 5.0,
            durationTarget: const Duration(hours: 1, minutes: 30)),
        'Durée · 1 h 30 ▸',
      );
    });

    test('Durée mode on an exact hour omits the minutes', () {
      expect(
        planPanelCollapsedLabel(
            mode: PlanMode.duration,
            loopTargetKm: 5.0,
            durationTarget: const Duration(hours: 2)),
        'Durée · 2 h ▸',
      );
    });

    test('Durée mode under an hour: "Durée · MM min ▸"', () {
      expect(
        planPanelCollapsedLabel(
            mode: PlanMode.duration,
            loopTargetKm: 5.0,
            durationTarget: const Duration(minutes: 45)),
        'Durée · 45 min ▸',
      );
    });
  });

  group('formatRouteResultLabel (owner micro-feature: personal-pace A→B '
      'duration)', () {
    const route = RouteResult(
      shape: [(0, 0), (0, 1)],
      distanceKm: 4.5,
      duration: Duration(minutes: 40), // Valhalla's generic estimate
      maneuvers: [],
    );

    test('uses the walker\'s own pace when it is known', () {
      // 4.5 km at 4.5 km/h — the walker's learned pace — is exactly 1 h,
      // not Valhalla's 40-minute generic estimate.
      expect(formatRouteResultLabel(route, 4.5), '4,5 km · ~60 min');
    });

    test('matches estimatedDuration exactly — same source as the candidate '
        'cards', () {
      final expectedMinutes =
          (estimatedDuration(route.distanceKm, 6.0).inSeconds / 60).round();
      expect(formatRouteResultLabel(route, 6.0),
          '4,5 km · ~$expectedMinutes min');
    });

    test('falls back to Valhalla\'s own estimate while the pace history is '
        'still loading (speedKmh null)', () {
      expect(formatRouteResultLabel(route, null), '4,5 km · ~40 min');
    });
  });

  group('PlanModeStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('defaults to itinerary when nothing was ever saved', () async {
      final store = PlanModeStore();
      expect(await store.load(), PlanMode.itinerary);
    });

    test('round-trips a saved mode', () async {
      final store = PlanModeStore();
      await store.save(PlanMode.loop);
      expect(await store.load(), PlanMode.loop);

      await store.save(PlanMode.duration);
      expect(await store.load(), PlanMode.duration);
    });

    test('falls back to itinerary on an unrecognised stored value', () async {
      SharedPreferences.setMockInitialValues({kPlanModePrefsKey: 'bogus'});
      expect(await PlanModeStore().load(), PlanMode.itinerary);
    });
  });
}
