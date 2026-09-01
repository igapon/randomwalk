import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/loop/loop_planner.dart';
import 'package:randomwalk/map/candidate_chips_bar.dart';
import 'package:randomwalk/theme/theme.dart';
import 'package:randomwalk/valhalla/models.dart';

LoopCandidate candidate({
  required double distanceKm,
  required double gapRatio,
  double repeatedRatio = 0.0,
}) => LoopCandidate(
  route: RouteResult(
    shape: const [(46.52, 6.63), (46.53, 6.64)],
    distanceKm: distanceKm,
    duration: const Duration(minutes: 30),
    maneuvers: const [],
  ),
  gapRatio: gapRatio,
  repeatedRatio: repeatedRatio,
  score: gapRatio.abs(),
);

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required LoopPlanResult result,
    int selectedIndex = 0,
    double speedKmh = 4.5,
    PlanKind? kind,
    ValueChanged<int>? onSelect,
    VoidCallback? onStart,
    VoidCallback? onOtherProposals,
    VoidCallback? onClose,
    double viewPaddingBottom = 0,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: MediaQuery(
          data: MediaQueryData(
            padding: EdgeInsets.only(bottom: viewPaddingBottom),
          ),
          child: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: CandidateChipsBar(
                result: result,
                selectedIndex: selectedIndex,
                speedKmh: speedKmh,
                kind: kind,
                onSelect: onSelect ?? (_) {},
                onStart: onStart ?? () {},
                onOtherProposals: onOtherProposals ?? () {},
                onClose: onClose ?? () {},
              ),
            ),
          ),
        ),
      ),
    );
  }

  LoopPlanResult resultWith(List<LoopCandidate> candidates) => LoopPlanResult(
    candidates: candidates,
    targetMet: true,
    bestGapRatio: 0.0,
  );

  group('CandidateChipsBar — compact row (task-8 point 1)', () {
    testWidgets('the chip row stays within the ~96 px height budget', (
      tester,
    ) async {
      await pump(
        tester,
        result: resultWith([
          candidate(distanceKm: 5.0, gapRatio: 0.0),
          candidate(distanceKm: 5.6, gapRatio: 0.12),
          candidate(distanceKm: 4.2, gapRatio: -0.08),
        ]),
      );

      final size = tester.getSize(find.byKey(const Key('candidateChipsRow')));
      expect(size.height, lessThanOrEqualTo(96));
    });

    testWidgets('renders distance and personal-pace duration per candidate', (
      tester,
    ) async {
      await pump(
        tester,
        result: resultWith([
          candidate(distanceKm: 5.0, gapRatio: 0.0),
          candidate(distanceKm: 5.6, gapRatio: 0.0),
        ]),
      );

      expect(find.textContaining('5,0 km · ~67 min'), findsOneWidget);
      expect(find.textContaining('5,6 km · ~75 min'), findsOneWidget);
    });

    testWidgets('shows a signed gap badge only for the off-target candidate', (
      tester,
    ) async {
      await pump(
        tester,
        result: resultWith([
          candidate(distanceKm: 5.0, gapRatio: 0.0),
          candidate(distanceKm: 5.6, gapRatio: 0.12),
        ]),
      );

      expect(find.text('+12 %'), findsOneWidget);
    });

    testWidgets('tapping a chip invokes onSelect with its index', (
      tester,
    ) async {
      int? selected;
      await pump(
        tester,
        result: resultWith([
          candidate(distanceKm: 5.0, gapRatio: 0.0),
          candidate(distanceKm: 5.6, gapRatio: 0.12),
        ]),
        onSelect: (i) => selected = i,
      );

      await tester.tap(find.textContaining('5,6 km · ~75 min'));
      expect(selected, 1);
    });

    testWidgets(
      "Autres propositions lives inside the row and fires its callback",
      (tester) async {
        var otherTapped = false;
        await pump(
          tester,
          result: resultWith([candidate(distanceKm: 5.0, gapRatio: 0.0)]),
          onOtherProposals: () => otherTapped = true,
        );

        expect(
          find.descendant(
            of: find.byKey(const Key('candidateChipsRow')),
            matching: find.text('Autres propositions'),
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Autres propositions'));
        expect(otherTapped, isTrue);
      },
    );

    testWidgets('hides "Autres propositions" for a single direct-route '
        'toDestination candidate (fix-round-1, point 3: deterministic '
        'no-op)', (tester) async {
      await pump(
        tester,
        result: resultWith([candidate(distanceKm: 12.0, gapRatio: 1.4)]),
        kind: PlanKind.toDestination,
      );

      expect(
        find.descendant(
          of: find.byKey(const Key('candidateChipsRow')),
          matching: find.text('Autres propositions'),
        ),
        findsNothing,
      );
    });

    testWidgets('still shows "Autres propositions" for multiple toDestination '
        'candidates', (tester) async {
      await pump(
        tester,
        result: resultWith([
          candidate(distanceKm: 12.0, gapRatio: 0.0),
          candidate(distanceKm: 13.0, gapRatio: 0.08),
        ]),
        kind: PlanKind.toDestination,
      );

      expect(find.text('Autres propositions'), findsOneWidget);
    });

    testWidgets(
      'still shows "Autres propositions" for a single loop candidate — '
      'loops vary with seed, never a deterministic no-op',
      (tester) async {
        await pump(
          tester,
          result: resultWith([candidate(distanceKm: 5.0, gapRatio: 0.0)]),
          kind: PlanKind.loop,
        );

        expect(find.text('Autres propositions'), findsOneWidget);
      },
    );

    testWidgets("C'est parti and the close ✕ sit outside the compact row", (
      tester,
    ) async {
      var startTapped = false;
      var closed = false;
      await pump(
        tester,
        result: resultWith([candidate(distanceKm: 5.0, gapRatio: 0.0)]),
        onStart: () => startTapped = true,
        onClose: () => closed = true,
      );

      await tester.tap(find.text("C'est parti"));
      await tester.tap(find.byIcon(Icons.close));
      expect(startTapped, isTrue);
      expect(closed, isTrue);
    });

    testWidgets('an out-of-range selectedIndex does not throw', (tester) async {
      await pump(
        tester,
        result: resultWith([candidate(distanceKm: 5.0, gapRatio: 0.0)]),
        selectedIndex: 99,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'does not self-pad for the bottom system inset — the single outer '
      'Positioned/Padding in map_screen.dart owns it',
      (tester) async {
        final result = resultWith([candidate(distanceKm: 5.0, gapRatio: 0.0)]);

        Future<EdgeInsets> pumpAndMeasurePadding(
          double viewPaddingBottom,
        ) async {
          await pump(
            tester,
            result: result,
            viewPaddingBottom: viewPaddingBottom,
          );
          expect(tester.takeException(), isNull);
          return tester
              .widget<Padding>(
                find.byKey(const Key('candidateChipsBarPadding')),
              )
              .padding
              .resolve(TextDirection.ltr);
        }

        // A 0dp inset (gesture nav, or an unrelated screen) and a 48dp one
        // (typical 3-button nav bar) must produce the *exact same*, and
        // exactly zero, padding out of this widget: it must never read
        // `viewPadding.bottom` itself — asserting the literal value (not just
        // equality between the two configs) is what actually catches a future
        // edit that reaches for padding here and reintroduces the
        // double-counted inset fix-round-1 fixed for the old CandidatesSheet.
        final noInset = await pumpAndMeasurePadding(0);
        final withInset = await pumpAndMeasurePadding(48);
        expect(noInset, EdgeInsets.zero);
        expect(withInset, EdgeInsets.zero);
        expect(find.byType(SafeArea), findsNothing);
      },
    );

    testWidgets('scrolls horizontally with more candidates than fit on a '
        'narrow phone width, with no overflow', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await pump(
        tester,
        result: resultWith([
          candidate(distanceKm: 5.0, gapRatio: 0.0),
          candidate(distanceKm: 5.6, gapRatio: 0.12),
          candidate(distanceKm: 4.2, gapRatio: -0.08),
        ]),
      );

      expect(tester.takeException(), isNull);
      final listView = tester.widget<ListView>(find.byType(ListView));
      expect(listView.scrollDirection, Axis.horizontal);

      // The last item ("Autres propositions") is off-screen at this width;
      // scrolling it into view must work with no overflow error.
      await tester.drag(find.byType(ListView), const Offset(-1000, 0));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Autres propositions'), findsOneWidget);
    });
  });
}
