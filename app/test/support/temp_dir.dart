import 'dart:io';

/// Deletes [dir] recursively, retrying briefly on a Windows "file/directory
/// in use" race.
///
/// Some tests exercise code that fires off a genuinely-unawaited background
/// disk write — e.g. `game/state_checkpoint.dart`'s checkpoint writes,
/// deliberately never awaited by production code (see its own dartdoc on
/// "checkpoint writes never block gameplay", and `game_state_provider.dart`
/// wiring `gameStateProvider` through it). If such a write is still
/// in-flight when a test's `tearDown` deletes its temp directory, Windows
/// can report the directory as in-use/non-empty even though `delete` is
/// itself `recursive: true` — a benign, purely test-infrastructure race
/// (the write's own target directory is about to be deleted anyway either
/// way), not a correctness issue. Retrying a few times with a short
/// backoff resolves it without slowing down the common case, where nothing
/// is in flight and the very first attempt succeeds.
Future<void> deleteTempDirRetrying(
  Directory dir, {
  int maxAttempts = 6,
  Duration retryDelay = const Duration(milliseconds: 50),
}) async {
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == maxAttempts) rethrow;
      await Future<void>.delayed(retryDelay);
    }
  }
}
