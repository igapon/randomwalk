// `MapScreen` itself cannot be widget-tested (see
// `map_screen_widgets_test.dart`'s own doc comment — a real `MaplibreMap`
// throws with no platform channel in tests), so the fix for review finding
// Important #1 (task 2i, fix round 1) is exercised two ways: the pure
// decision (`shouldInterceptBackForWizardExit`, `plan_mode_test.dart`), and
// here, a harness that reproduces `MapScreen.build`'s exact single-`PopScope`
// wiring (`canPop`/`onPopInvokedWithResult` built from the very same
// `shouldInterceptBackForCandidates`/`shouldInterceptBackForWizardExit` pure
// functions `map_screen.dart` calls) so the actual `PopScope` mechanics —
// not just the booleans feeding it — are proven correct: a real system-style
// pop attempt (`NavigatorState.maybePop`) either gets blocked-and-redirected
// or genuinely pops, exactly as `MapScreen`'s own `PopScope` would.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/map/plan_mode.dart';

/// Mirrors `MapScreenState.build`'s `PopScope` verbatim (same two pure
/// functions, same precedence, same three-way `onPopInvokedWithResult`
/// branch) so a test can drive it with a real `Navigator` without needing a
/// live `MaplibreMap`.
class _PopScopeHarness extends StatelessWidget {
  const _PopScopeHarness({
    required this.hasCandidates,
    required this.candidatePlanning,
    required this.isRecording,
    required this.hasWizardExit,
    required this.onCloseCandidates,
    required this.onCancelPlanning,
    required this.onExitToWizard,
  });

  final bool hasCandidates;
  final bool candidatePlanning;
  final bool isRecording;
  final bool hasWizardExit;
  final VoidCallback onCloseCandidates;
  final VoidCallback onCancelPlanning;
  final VoidCallback onExitToWizard;

  @override
  Widget build(BuildContext context) {
    final interceptForCandidates = shouldInterceptBackForCandidates(
      hasCandidates: hasCandidates,
      candidatePlanning: candidatePlanning,
      isRecording: isRecording,
    );
    final interceptForWizardExit = shouldInterceptBackForWizardExit(
      interceptedForCandidates: interceptForCandidates,
      hasWizardExit: hasWizardExit,
    );
    return PopScope(
      canPop: !interceptForCandidates && !interceptForWizardExit,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (interceptForCandidates) {
          if (candidatePlanning) {
            onCancelPlanning();
          } else {
            onCloseCandidates();
          }
        } else if (interceptForWizardExit) {
          onExitToWizard();
        }
      },
      child: const Scaffold(body: SizedBox.expand()),
    );
  }
}

void main() {
  Future<NavigatorState> pump(
    WidgetTester tester, {
    required bool hasCandidates,
    bool candidatePlanning = false,
    bool isRecording = false,
    required bool hasWizardExit,
    required VoidCallback onCloseCandidates,
    required VoidCallback onCancelPlanning,
    required VoidCallback onExitToWizard,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: _PopScopeHarness(
          hasCandidates: hasCandidates,
          candidatePlanning: candidatePlanning,
          isRecording: isRecording,
          hasWizardExit: hasWizardExit,
          onCloseCandidates: onCloseCandidates,
          onCancelPlanning: onCancelPlanning,
          onExitToWizard: onExitToWizard,
        ),
      ),
    );
    return tester.state<NavigatorState>(find.byType(Navigator));
  }

  // `NavigatorState.maybePop` (see `navigator.dart`): when a registered
  // `PopEntry`'s `canPop` is false, the route's `onPopInvokedWithResult`
  // fires with `didPop: false` and `maybePop` itself returns `true` (the
  // pop was "handled", just not by actually removing the route). When
  // nothing blocks it and this is the ONLY route in the `Navigator` (as in
  // this harness, and as `MapScreen` genuinely is — no navigator boundary
  // between it and the wizard/`CarteTabRoot`), `popDisposition` is `bubble`
  // and `maybePop` returns `false` *without* invoking
  // `onPopInvokedWithResult` at all — this is the case that, in the real
  // app (via `WidgetsApp`'s root back-button dispatcher), falls through to
  // `SystemNavigator.pop()` and exits.

  testWidgets(
    'back during candidate selection closes selection only — wizard exit '
    'is never called even though one is available',
    (tester) async {
      var closed = false;
      var wizardExited = false;
      final nav = await pump(
        tester,
        hasCandidates: true,
        hasWizardExit: true,
        onCloseCandidates: () => closed = true,
        onCancelPlanning: () => fail('must not cancel a proposal in flight'),
        onExitToWizard: () => wizardExited = true,
      );

      final popped = await nav.maybePop();
      await tester.pump();

      expect(popped, isTrue, reason: 'the blocked pop was handled in place');
      expect(closed, isTrue);
      expect(wizardExited, isFalse);
    },
  );

  testWidgets(
    'back while a proposal is still in flight cancels it, not the wizard '
    'exit',
    (tester) async {
      var cancelled = false;
      var wizardExited = false;
      final nav = await pump(
        tester,
        hasCandidates: false,
        candidatePlanning: true,
        hasWizardExit: true,
        onCloseCandidates: () => fail('nothing to close — still planning'),
        onCancelPlanning: () => cancelled = true,
        onExitToWizard: () => wizardExited = true,
      );

      final popped = await nav.maybePop();
      await tester.pump();

      expect(popped, isTrue);
      expect(cancelled, isTrue);
      expect(wizardExited, isFalse);
    },
  );

  testWidgets('back on the free map (no candidates) returns to the wizard home '
      'instead of exiting', (tester) async {
    var wizardExited = false;
    final nav = await pump(
      tester,
      hasCandidates: false,
      hasWizardExit: true,
      onCloseCandidates: () => fail('nothing to close'),
      onCancelPlanning: () => fail('nothing planning'),
      onExitToWizard: () => wizardExited = true,
    );

    final popped = await nav.maybePop();
    await tester.pump();

    expect(popped, isTrue, reason: 'blocked and redirected to the wizard');
    expect(wizardExited, isTrue);
  });

  testWidgets(
    'back on a pre-task-2i call site (no wizard exit) is left to bubble — '
    'unchanged, pre-existing "exit the app at the root" behavior',
    (tester) async {
      final nav = await pump(
        tester,
        hasCandidates: false,
        hasWizardExit: false,
        onCloseCandidates: () => fail('nothing to close'),
        onCancelPlanning: () => fail('nothing planning'),
        onExitToWizard: () => fail('no wizard to return to'),
      );

      final popped = await nav.maybePop();
      await tester.pump();

      // `false` here is the CORRECT outcome, not a bug: it is exactly what
      // tells `WidgetsApp`'s root back-button handling to call
      // `SystemNavigator.pop()` — i.e. exit the app — the pre-task-2i,
      // still-intended behavior for a `MapScreen` with no wizard to return
      // to.
      expect(popped, isFalse);
    },
  );

  testWidgets(
    'recording (CarteTabRoot never passes onExitToWizard then) — candidates '
    'are not intercepted, and there is no wizard to bounce back to either',
    (tester) async {
      final nav = await pump(
        tester,
        hasCandidates: true,
        isRecording: true,
        // Matches `CarteTabRoot.build`'s real contract: `onExitToWizard` is
        // only ever non-null while `!trip.isRecording && !trip.isInterrupted`
        // — never simultaneously with `isRecording: true`.
        hasWizardExit: false,
        onCloseCandidates: () => fail('a recording trip must not be touched'),
        onCancelPlanning: () => fail('a recording trip must not be touched'),
        onExitToWizard: () =>
            fail('CarteTabRoot never passes onExitToWizard while recording'),
      );

      final popped = await nav.maybePop();
      await tester.pump();

      expect(popped, isFalse);
    },
  );
}
