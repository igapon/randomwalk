import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../map/route_controller.dart' show coverageRepositoryProvider;
import 'pois.dart';

/// Loads [gz] off the UI isolate.
///
/// `PoiStore.load` parses up to ~140k landmarks out of a multi-megabyte
/// gzip (see task-4-report.md: 141,892 POIs, ~3.5 MB compressed / ~14 MB
/// raw JSON) — cheap for a background isolate, but enough JSON decoding to
/// visibly jank a frame if it ever ran on the UI thread.
///
/// `TripTaskHandler` (`tracking/tracking_service.dart`) does NOT use this
/// helper: it already runs inside the foreground-service isolate, which is
/// not the UI isolate to begin with, so a direct `await PoiStore.load(...)`
/// there costs the UI nothing regardless of how long it takes (see that
/// class's own doc comment on `_initPoiStore`). This function exists for
/// UI-isolate call sites — e.g. a future Aventure-tab screen reading
/// [poisStoreProvider] below — where `compute()` is the seam that actually
/// matters.
Future<PoiStore> loadPoiStoreOffUiIsolate(File gz) =>
    compute(_loadPoiStoreSync, gz.path);

/// Top-level (not a closure) so `compute` can hand it to a fresh isolate
/// without capturing any UI-isolate state.
Future<PoiStore> _loadPoiStoreSync(String path) => PoiStore.load(File(path));

/// The `pois.json.gz` file for whatever dataset version is currently
/// cached, or `null` when none has been downloaded — adapts
/// `CoverageRepository.poisFile` (disk-only, no network/validation) to
/// Riverpod.
final poisFileProvider = FutureProvider<File?>((ref) async {
  final coverage = await ref.watch(coverageRepositoryProvider.future);
  try {
    return await coverage.poisFile();
  } catch (_) {
    // "Game never blocks the tool": no usable POI file just means no
    // landmarks to show, never a reason to surface an error here.
    return null;
  }
});

/// The current [PoiStore] for the UI isolate — a future Aventure-tab screen
/// (Task 6) is the intended consumer, so it never has to parse
/// `pois.json.gz` itself on every rebuild.
///
/// Cached per exact file path via [_poiStoreByPathProvider]: since that path
/// embeds the dataset version (`<root>/<version>/pois.json.gz`, see
/// `CoverageRepository.poisFile`), a coverage update that downloads a new
/// `pois.json.gz` under a new version directory changes the path, and
/// Riverpod's own family caching loads a fresh store for it rather than
/// serving a stale one — nothing here needs to invalidate anything by hand.
final poisStoreProvider = FutureProvider<PoiStore>((ref) async {
  final file = await ref.watch(poisFileProvider.future);
  if (file == null) return PoiStore.empty;
  return ref.watch(_poiStoreByPathProvider(file.path).future);
});

final _poiStoreByPathProvider =
    FutureProvider.family<PoiStore, String>((ref, path) {
  return loadPoiStoreOffUiIsolate(File(path));
});
