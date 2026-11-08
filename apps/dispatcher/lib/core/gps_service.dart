/// Device GPS for breadcrumb walks.
///
/// Uses the platform location services via geolocator. Permission is
/// requested on demand; denial is a normal state the UI handles by falling
/// back to manual coordinate entry — capture never depends on a fix (C4).
library;

import 'dart:async';

import 'package:geolocator/geolocator.dart';

class GpsFix {
  const GpsFix({required this.lat, required this.lon, this.accuracyM});
  final double lat;
  final double lon;
  final double? accuracyM;
}

enum GpsStatus { unknown, granted, denied, deniedForever, servicesOff }

Future<GpsStatus> ensureGpsPermission() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    return GpsStatus.servicesOff;
  }
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  return switch (permission) {
    LocationPermission.always || LocationPermission.whileInUse => GpsStatus.granted,
    LocationPermission.denied => GpsStatus.denied,
    LocationPermission.deniedForever => GpsStatus.deniedForever,
    LocationPermission.unableToDetermine => GpsStatus.unknown,
  };
}

Future<GpsFix?> currentFix() async {
  try {
    final pos = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.bestForNavigation,
    );
    return GpsFix(lat: pos.latitude, lon: pos.longitude, accuracyM: pos.accuracy);
  } catch (_) {
    return null;
  }
}

/// Continuous fixes while walking. The caller persists each fix locally;
/// nothing here touches the network.
Stream<GpsFix> walkFixStream() {
  return Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 3, // metres — a breadcrumb every ~3 m walked
    ),
  ).map((p) => GpsFix(lat: p.latitude, lon: p.longitude, accuracyM: p.accuracy));
}
