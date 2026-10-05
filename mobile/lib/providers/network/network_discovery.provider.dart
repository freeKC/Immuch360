// What the form that adds a share uses to find the servers of the network and the shares of an SMB server, and what
// the browser uses to find a share again after its address changed. Providers so that tests can replace the network.

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/domain/services/network_source_relocator.dart';
import 'package:immich_mobile/infrastructure/network/network_discovery_probes.dart';
import 'package:immich_mobile/infrastructure/network/smb_file_system.dart';

/// mDNS, the scan of the local subnet and SSDP, see [createNetworkDiscoveryService]
final networkDiscoveryServiceProvider = Provider<NetworkDiscoveryService>((ref) => createNetworkDiscoveryService());

/// The share names of the SMB server of a source, with its password (see [SmbFileSystem.listShares])
typedef NetworkShareLister = Future<List<String>> Function(NetworkSource source, String? password);

final networkShareListerProvider = Provider<NetworkShareLister>((ref) => SmbFileSystem.listShares);

/// Finds a share found on the network again at its new address, through the discovery of
/// [networkDiscoveryServiceProvider] (see [NetworkSourceRelocator.relocate])
final networkSourceRelocatorProvider = Provider<NetworkSourceRelocator>(
  (ref) => NetworkSourceRelocator(ref.watch(networkDiscoveryServiceProvider)),
);
