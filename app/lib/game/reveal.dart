import 'grid.dart';

/// Mutable in-memory record of which grid cells have been revealed so far.
///
/// This is *not* the durable source of truth — that is the game event
/// journal's `cell_revealed` events, replayed into `GameState.
/// revealedCellKeys` by `reducers.dart`. `RevealState` is the fast,
/// in-session working set the UI/planner consult and update between journal
/// writes (e.g. rebuilt from `GameState.revealedCellKeys` at startup, then
/// grown as new corridors/discs are revealed during a trip).
class RevealState {
  final Set<CellId> _revealed;

  RevealState(Set<CellId> revealed) : _revealed = {...revealed};

  /// A read-only snapshot of every revealed cell so far.
  Set<CellId> get revealed => Set.unmodifiable(_revealed);

  bool isRevealed(CellId cell) => _revealed.contains(cell);

  /// Marks every cell in [cells] as revealed and returns exactly the subset
  /// that was *not* already revealed before this call (i.e. the genuinely
  /// new cells) — duplicates within [cells] itself, or cells already
  /// revealed from a prior call, are excluded from the returned set even
  /// though they remain (or become) revealed in this state.
  Set<CellId> addAll(Iterable<CellId> cells) {
    final newly = <CellId>{};
    for (final cell in cells) {
      if (_revealed.add(cell)) {
        newly.add(cell);
      }
    }
    return newly;
  }
}
