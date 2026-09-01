import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/adventure/badge_labels.dart';
import 'package:randomwalk/game/reducers.dart';

void main() {
  test('every GameBadges id has a French label', () {
    for (final id in [
      GameBadges.firstTrip,
      GameBadges.firstLoop,
      GameBadges.km10,
      GameBadges.km50,
      GameBadges.km100,
      GameBadges.landmarks10,
      GameBadges.streak7,
      GameBadges.quartier25,
    ]) {
      expect(
        kBadgeLabels.containsKey(id),
        isTrue,
        reason: 'missing label for $id',
      );
      expect(
        badgeLabel(id),
        isNot(id),
        reason: '$id should not fall back to its raw id',
      );
    }
  });

  test('kBadgeOrder lists exactly the 8 known badge ids, no duplicates', () {
    expect(kBadgeOrder.toSet(), hasLength(8));
    expect(kBadgeOrder.toSet(), kBadgeLabels.keys.toSet());
  });

  test('an unknown badge id falls back to itself rather than throwing', () {
    expect(badgeLabel('some_future_badge'), 'some_future_badge');
  });
}
