// Desktop builds (Linux) have no geolocator implementation. The mapper must
// still get a status it can act on (manual coordinate entry), not an exception.

import 'package:dispatcher/core/gps_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('no location plugin reads as services off, not a crash', () async {
    // The test host registers no geolocator plugin, exactly like Linux.
    expect(await ensureGpsPermission(), GpsStatus.servicesOff);
  });
}
