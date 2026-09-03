import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'events.dart';
import 'reducers.dart';
import 'state_checkpoint.dart';

/// Broadcasts "the game journal just changed" to whichever
/// [gameStateProvider] subscribers exist, without depending on Riverpod
/// itself.
///
/// This has to be a plain, ref-free singleton rather than a Riverpod
/// provider: its two writers — `GameVisitConsumer` (mid-trip landmark
/// visits) and `ExplorationRecorder` (post-trip km/cells/loop/energy) — are
/// both built in `main.dart`'s `_buildTripController`, which runs *before*
/// `ProviderScope` exists (see that function's own doc comment on why), so
/// no `WidgetRef`/`ProviderContainer` is reachable at the call sites that
/// need to fire this signal.
class GameJournalSignal {
  GameJournalSignal._();

  /// The one instance wired into `main.dart`'s `GameVisitConsumer`/
  /// `ExplorationRecorder` in production; tests construct their own
  /// `GameJournalSignal._()`-free... actually tests just use this same
  /// instance's [stream] via [gameJournalEpochProvider], which is what
  /// makes this fine to share as a true singleton — nothing about it is
  /// per-app-instance state, only a change notification bus.
  static final instance = GameJournalSignal._();

  final _controller = StreamController<void>.broadcast();

  /// Fires once for every call — subscribers only care that *something*
  /// changed, not what, so no payload is carried.
  Stream<void> get stream => _controller.stream;

  void bump() {
    if (!_controller.isClosed) _controller.add(null);
  }
}

/// The `game_events.jsonl` journal for the current app-support directory —
/// the exact same path `main.dart`'s `_buildTripController` builds
/// (`'${dir.path}/game'`), so this reads whatever
/// `GameVisitConsumer`/`ExplorationRecorder` have been appending to.
final gameJournalProvider = FutureProvider<GameJournal>((ref) async {
  final dir = await getApplicationSupportDirectory();
  return GameJournal(Directory('${dir.path}/game'));
});

/// The current [GameState], replayed from the journal.
///
/// **Game never blocks the tool**: any failure resolving the journal path,
/// reading it, or replaying it resolves to the zero [GameState] rather than
/// propagating an error — a missing/corrupt journal (or no game directory
/// at all, e.g. `main.dart`'s exploration layer failed to initialize) reads
/// as "nothing played yet", exactly like a brand-new install.
///
/// **Off the frame path**: being a [FutureProvider], the `readAll`/
/// `reduceAll` replay runs asynchronously (a microtask chain kicked off by
/// `ref.watch`/`ref.read`, resolved on a later frame) rather than
/// synchronously inside a widget's `build()` — so even a large journal
/// replay never blocks the frame that first reads this provider.
///
/// **Re-runs on every [GameJournalSignal.bump]**: subscribes directly to
/// [GameJournalSignal.instance.stream] and calls `ref.invalidateSelf()` on
/// every event — the standard Riverpod idiom for "a provider that must react
/// to an external change signal" (deliberately not a derived `StreamProvider`
/// dependency: watching one from inside this `FutureProvider`'s own async
/// body raced this provider's build against its own dependency's first
/// emission and produced a permanent hang — see game_state_provider_test.dart
/// for the regression coverage). Can additionally be forced with
/// `ref.invalidate` (see `HomeShell`'s "refresh on tab focus" handling in
/// main.dart).
///
/// **Task 5: replays via [loadStateFast]**, not a bare `readAll` +
/// [reduceAll] — a checkpoint-plus-tail fast path (`game/state_checkpoint
/// .dart`) that always produces the exact same [GameState] a full replay
/// would (see that file's dartdoc for the validity invariant), just without
/// re-doing the full journal's reduction work on every call once the
/// journal has grown large. The checkpoint file lives next to whichever
/// journal [gameJournalProvider] resolves to (`GameJournal.dir`), so it
/// automatically follows the same path swap tests use (overriding
/// [gameJournalProvider] with a temp-dir journal also gets a temp-dir
/// checkpoint).
final gameStateProvider = FutureProvider<GameState>((ref) async {
  final sub = GameJournalSignal.instance.stream.listen((_) {
    ref.invalidateSelf();
  });
  ref.onDispose(sub.cancel);
  try {
    final journal = await ref.watch(gameJournalProvider.future);
    return await loadStateFast(journal, GameStateCheckpointStore(journal.dir));
  } catch (_) {
    return const GameState();
  }
});
