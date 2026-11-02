// The splat viewer of the computers, phones and tablets (plan of 2 November 2026): where it is offered, its host, its
// service. The headset keeps its immersive viewer (splatsInThisBuildProvider, splat_button.dart).

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/splat/splat_gate.dart';
import 'package:immich_mobile/domain/services/splat_viewer_files.dart';
import 'package:immich_mobile/domain/services/splat_viewer_host.dart';
import 'package:immich_mobile/domain/services/splat_viewer_service.dart';
import 'package:immich_mobile/domain/services/splat_viewer_session.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/splat/pigeon_splat_viewer_host.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/media_bridge.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The class of this device for the splats: the computers, the Android phones and tablets, the headset; null where no
/// splat viewer is offered (a TV, iOS until its lot) and while Android has not said whether this is a Meta Quest
final splatDeviceClassProvider = Provider<SplatDeviceClass?>((ref) {
  if (CurrentPlatform.isDesktop) {
    return SplatDeviceClass.computer;
  }
  if (!CurrentPlatform.isAndroid) {
    return null;
  }
  final horizonOs = ref.watch(isHorizonOsProvider);
  if (!horizonOs.hasValue) {
    return null;
  }
  if (horizonOs.value!) {
    return SplatDeviceClass.quest;
  }
  return ref.watch(tvDeviceProvider).isTelevision ? null : SplatDeviceClass.phone;
}, dependencies: [isHorizonOsProvider, tvDeviceProvider]);

/// Whether the splat viewer of the computers, phones and tablets is offered on this device (the setting aside)
final splatFlatViewerProvider = Provider<bool>((ref) {
  final device = ref.watch(splatDeviceClassProvider);
  return device == SplatDeviceClass.computer || device == SplatDeviceClass.phone;
}, dependencies: [splatDeviceClassProvider]);

/// What shows the page: SplatViewerActivity on Android; the computers put their window here (desktopOverrides);
/// null elsewhere
final splatViewerHostProvider = Provider<SplatViewerHost?>(
  (ref) => CurrentPlatform.isAndroid ? PigeonSplatViewerHost() : null,
);

/// The orientations chosen with Turn upright, in the support folder of the app
final splatUprightStoreProvider = Provider<SplatUprightStore>(
  (ref) =>
      SplatUprightStore(() async => File(p.join((await getApplicationSupportDirectory()).path, 'splat_uprights.json'))),
);

/// The reduced copies of the splats above the cap, in the temporary folder of the app
final splatViewerCacheProvider = Provider<SplatViewerCache>(
  (ref) => SplatViewerCache(() async => Directory(p.join((await getTemporaryDirectory()).path, 'splat_viewer'))),
);

/// The viewings, null where no host shows the page
final splatViewerServiceProvider = Provider<SplatViewerService?>((ref) {
  final host = ref.watch(splatViewerHostProvider);
  if (host == null) {
    return null;
  }
  final connections = ref.read(networkConnectionsProvider);
  return SplatViewerService(
    bridge: ref.read(mediaBridgeProvider),
    host: host,
    loadPage: () => loadSplatViewerPage(rootBundle),
    uprights: ref.read(splatUprightStoreProvider),
    cache: ref.read(splatViewerCacheProvider),
    fileSystem: connections.fileSystem,
    shareUrl: connections.mediaUrl,
  );
});
