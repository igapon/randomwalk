import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/tracking/device_channel.dart';

// `DeviceChannel`'s methods all guard on `Platform.isAndroid` first (see
// device_channel.dart) — same as its existing sdkInt/stepCount siblings,
// none of which had channel-level tests before this file either, since
// `dart:io`'s `Platform.isAndroid` cannot be overridden from a host-run
// `flutter test`. What *is* verifiable here, and is exactly manufacturer()'s
// public contract, is that it degrades to null rather than throwing
// wherever a native reply cannot be obtained — this host included.
void main() {
  test('manufacturer() never throws and returns null off Android', () async {
    expect(await const DeviceChannel().manufacturer(), isNull);
  });
}
