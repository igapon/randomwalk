import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

const kMapStyleUrl = 'https://tiles.openfreemap.org/styles/liberty';
const kMapAttribution = 'OpenFreeMap © OpenMapTiles, Data from OpenStreetMap';

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});
  @override
  ConsumerState<MapScreen> createState() => MapScreenState();
}

class MapScreenState extends ConsumerState<MapScreen> {
  MapLibreMapController? controller;

  Future<void> _centerOnUser() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Localisation refusée — activez-la dans les réglages.')));
      }
      return;
    }
    final pos = await Geolocator.getCurrentPosition();
    await controller?.animateCamera(CameraUpdate.newLatLngZoom(
        LatLng(pos.latitude, pos.longitude), 15));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: MapLibreMap(
          styleString: kMapStyleUrl,
          initialCameraPosition:
              const CameraPosition(target: LatLng(46.52, 6.63), zoom: 11),
          myLocationEnabled: true,
          myLocationTrackingMode: MyLocationTrackingMode.none,
          attributionButtonPosition: AttributionButtonPosition.bottomLeft,
          onMapCreated: (c) => controller = c,
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: _centerOnUser,
          child: const Icon(Icons.my_location),
        ),
      );
}
