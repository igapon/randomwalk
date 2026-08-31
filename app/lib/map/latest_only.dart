/// Tracks the "generation" of the most recent asynchronous call a caller
/// started, so a slow response belonging to an older call can be told
/// apart from — and dropped in favor of — a newer one.
///
/// This is the classic debounced-search race: keystroke N's request can
/// resolve *after* keystroke N+1's, and without this guard the stale
/// response for N would overwrite state that N+1 already set. Extracted
/// out of `map_screen.dart` (rather than kept as a bare `int` field) so
/// the bump-then-compare logic itself is unit-testable without pumping a
/// Flutter widget tree.
class LatestOnly {
  int _generation = 0;

  /// Call at the start of a new asynchronous call. Returns a token to pass
  /// to [isCurrent] once that call completes.
  int start() => ++_generation;

  /// True if [token] (returned by an earlier [start]) is still the most
  /// recent call, i.e. no newer [start] has happened since.
  bool isCurrent(int token) => token == _generation;
}
