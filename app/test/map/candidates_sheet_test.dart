import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/loop/loop_planner.dart';
import 'package:randomwalk/map/candidates_sheet.dart';
import 'package:randomwalk/theme/theme.dart';
import 'package:randomwalk/valhalla/models.dart';

LoopCandidate candidate({
  required double distanceKm,
  required double gapRatio,
  double repeatedRatio = 0.0,
}) =>
    LoopCandidate(
      route: RouteResult(
          shape: const [(46.52, 6.63), (46.53, 6.64)],
          distanceKm: distanceKm,
          duration: const Duration(minutes: 30),
          maneuvers: const []),
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
    ValueChanged<int>? onSelect,
    VoidCallback? onStart,
    VoidCallback? onOtherProposals,
    VoidCallback? onClose,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: CandidatesSheet(
          result: result,
          selectedIndex: selectedIndex,
          speedKmh: speedKmh,
          onSelect: onSelect ?? (_) {},
          onStart: onStart ?? () {},
          onOtherProposals: onOtherProposals ?? () {},
          onClose: onClose ?? () {},
        ),
      ),
    ));
  }

  group('CandidatesSheet — rendering', () {
    testWidgets('renders one card per candidate, distance and duration',
        (tester) async {
      final result = LoopPlanResult(
        candidates: [
          candidate(distanceKm: 5.0, gapRatio: 0.0),
          candidate(distanceKm: 5.6, gapRatio: 0.12),
        ],
        targetMet: true,
        bestGapRatio: 0.0,
      );
      await pump(tester, result: result);

      expect(find.text('5,0 km · ~67 min'), findsOneWidget);
      expect(find.text('5,6 km · ~75 min'), findsOneWidget);
    });

    testWidgets('shows a signed gap badge only for the off-target candidate',
        (tester) async {
      final result = LoopPlanResult(
        candidates: [
          candidate(distanceKm: 5.0, gapRatio: 0.0),
          candidate(distanceKm: 5.6, gapRatio: 0.12),
        ],
        targetMet: true,
        bestGapRatio: 0.0,
      );
      await pump(tester, result: result);

      expect(find.text('+12 %'), findsOneWidget);
    });

    testWidgets('shows the repeated-segment hint for each card',
        (tester) async {
      final result = LoopPlanResult(
        candidates: [
          candidate(distanceKm: 5.0, gapRatio: 0.0, repeatedRatio: 0.05),
          candidate(distanceKm: 5.6, gapRatio: 0.12, repeatedRatio: 0.4),
        ],
        targetMet: true,
        bestGapRatio: 0.0,
      );
      await pump(tester, result: result);

      expect(find.text("peu d'allers-retours"), findsOneWidget);
      expect(find.text('quelques allers-retours'), findsOneWidget);
    });

    testWidgets('tapping a card invokes onSelect with its index',
        (tester) async {
      final result = LoopPlanResult(
        candidates: [
          candidate(distanceKm: 5.0, gapRatio: 0.0),
          candidate(distanceKm: 5.6, gapRatio: 0.12),
        ],
        targetMet: true,
        bestGapRatio: 0.0,
      );
      int? selected;
      await pump(tester, result: result, onSelect: (i) => selected = i);

      await tester.tap(find.text('5,6 km · ~75 min'));
      expect(selected, 1);
    });

    testWidgets("Autres propositions and C'est parti fire their callbacks",
        (tester) async {
      final result = LoopPlanResult(
        candidates: [candidate(distanceKm: 5.0, gapRatio: 0.0)],
        targetMet: true,
        bestGapRatio: 0.0,
      );
      var otherTapped = false;
      var startTapped = false;
      await pump(
        tester,
        result: result,
        onOtherProposals: () => otherTapped = true,
        onStart: () => startTapped = true,
      );

      await tester.tap(find.text('Autres propositions'));
      await tester.tap(find.text("C'est parti"));
      expect(otherTapped, isTrue);
      expect(startTapped, isTrue);
    });

    testWidgets('close button fires onClose', (tester) async {
      final result = LoopPlanResult(
        candidates: [candidate(distanceKm: 5.0, gapRatio: 0.0)],
        targetMet: true,
        bestGapRatio: 0.0,
      );
      var closed = false;
      await pump(tester, result: result, onClose: () => closed = true);

      await tester.tap(find.byIcon(Icons.close));
      expect(closed, isTrue);
    });

    testWidgets('an out-of-range selectedIndex does not throw',
        (tester) async {
      final result = LoopPlanResult(
        candidates: [candidate(distanceKm: 5.0, gapRatio: 0.0)],
        targetMet: true,
        bestGapRatio: 0.0,
      );
      await pump(tester, result: result, selectedIndex: 99);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'does not self-pad for the bottom system inset — the single outer '
        'Positioned/Padding in map_screen.dart owns it (fix-round-1)',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final result = LoopPlanResult(
        candidates: [candidate(distanceKm: 5.0, gapRatio: 0.0)],
        targetMet: true,
        bestGapRatio: 0.0,
      );

      Future<EdgeInsets> pumpAndMeasure(double viewPaddingBottom) async {
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          home: MediaQuery(
            data: MediaQueryData(
                padding: EdgeInsets.only(bottom: viewPaddingBottom)),
            child: Scaffold(
              body: CandidatesSheet(
                result: result,
                selectedIndex: 0,
                speedKmh: 4.5,
                onSelect: (_) {},
                onStart: () {},
                onOtherProposals: () {},
                onClose: () {},
              ),
            ),
          ),
        ));
        expect(tester.takeException(), isNull);
        final padding = tester
            .widget<Padding>(find.byKey(const Key('candidatesSheetPadding')))
            .padding
            .resolve(TextDirection.ltr);
        return padding;
      }

      // A 0dp inset (gesture nav's own case, or an unrelated screen) and a
      // 48dp one (typical 3-button nav bar) must produce the *same* padding
      // out of this widget: it must never read `viewPadding.bottom` itself.
      final noInset = await pumpAndMeasure(0);
      final withInset = await pumpAndMeasure(48);
      expect(noInset, withInset);
      expect(noInset.bottom, 12);
      expect(find.byType(SafeArea), findsNothing);
    });
  });
}
