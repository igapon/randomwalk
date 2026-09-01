import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/map/latest_only.dart';

void main() {
  test('a token is current until a newer start() is called', () {
    final g = LatestOnly();
    final t1 = g.start();
    expect(g.isCurrent(t1), isTrue);

    final t2 = g.start();
    expect(g.isCurrent(t1), isFalse, reason: 'superseded by t2');
    expect(g.isCurrent(t2), isTrue);
  });

  test('models the debounced-search race: a slow call that resolves after '
      'a newer one is dropped, even though it finishes last', () async {
    final g = LatestOnly();
    final applied = <String>[];

    Future<void> search(String query, Duration delay) async {
      final token = g.start();
      await Future<void>.delayed(delay);
      if (g.isCurrent(token)) applied.add(query);
    }

    // "Lausanne" is the older, slower call; "Genève" starts right after
    // and resolves first. The stale "Lausanne" response must be dropped.
    final slow = search('Lausanne', const Duration(milliseconds: 50));
    final fast = search('Genève', const Duration(milliseconds: 5));
    await Future.wait([slow, fast]);

    expect(applied, ['Genève']);
  });
}
