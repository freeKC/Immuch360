import 'package:flutter/services.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';

/// ConnectivityApi on the computers: a computer is taken as being on an unmetered local network, so that the "only on
/// Wi-Fi" rules of the backup, written for phones, never hold its uploads back
class DesktopConnectivityApi implements ConnectivityApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  @override
  Future<List<NetworkCapability>> getCapabilities() async => const [
    NetworkCapability.wifi,
    NetworkCapability.unmetered,
  ];
}
