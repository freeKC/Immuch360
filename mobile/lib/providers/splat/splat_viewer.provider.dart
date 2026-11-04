// The splat viewer of the computers, phones and tablets (plan of 2 November 2026): where it is offered, its host, its
// service. The headset keeps its immersive viewer (splatsInThisBuildProvider, splat_button.dart).

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/splat/splat_computer.dart';
import 'package:immich_mobile/domain/models/splat/splat_gate.dart';
import 'package:immich_mobile/domain/services/splat_viewer_files.dart';
import 'package:immich_mobile/domain/services/splat_viewer_host.dart';
import 'package:immich_mobile/domain/services/splat_viewer_service.dart';
import 'package:immich_mobile/domain/services/splat_viewer_session.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/splat/pigeon_splat_viewer_host.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/media_bridge.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
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

/// The answers to the page's offer of a reduced copy per file, and the renderer the page last drew with, in the
/// support folder of the app (lot SVC)
final splatAnswerStoreProvider = Provider<SplatAnswerStore>(
  (ref) =>
      SplatAnswerStore(() async => File(p.join((await getApplicationSupportDirectory()).path, 'splat_answers.json'))),
);

/// What this computer gives the splat viewer, the setting aside: the chip that draws its page and its memory (lot SVC);
/// the computers' reader (desktopOverrides), null on phones and tablets
final splatComputerReaderProvider = Provider<Future<SplatComputer> Function()?>((ref) => null);

/// How long the splat viewer waits for the computer's graphics chips before it keeps the cap of the chips that share
/// the computer's memory (the probe of the cards ends itself after 10 s)
const splatComputerReadTimeout = Duration(seconds: 12);

/// What this computer gives the splat viewer now, with the setting "Keep every gaussian"; null on phones and tablets.
/// A reader that fails or takes too long gives a computer of unknown chip, which keeps the cap of 1,000,000
final splatComputerNowProvider = Provider<Future<SplatComputer?> Function()>(
  (ref) => () async {
    final read = ref.read(splatComputerReaderProvider);
    if (read == null) {
      return null;
    }
    final keep = ref.read(appConfigProvider).viewer.keepAllGaussians;
    try {
      return (await read().timeout(splatComputerReadTimeout)).copyWith(keepEveryGaussian: keep);
    } catch (error) {
      return SplatComputer(keepEveryGaussian: keep);
    }
  },
);

/// [splatComputerNowProvider] for the pages, read again each time a page that shows a splat is built
final splatComputerProvider = FutureProvider.autoDispose<SplatComputer?>((ref) {
  ref.watch(appConfigProvider.select((config) => config.viewer.keepAllGaussians));
  return ref.watch(splatComputerNowProvider)();
});

/// The answer kept for the file of a name and a size (computers), read again each time one is written: the answer
/// given in the viewer counts at the next Explore of the same page (review of 4 November 2026)
final splatAnswerProvider = FutureProvider.autoDispose.family<SplatFrameAnswer?, (String, int)>((ref, file) {
  final store = ref.watch(splatAnswerStoreProvider);
  final answered = store.answered.listen((_) => ref.invalidateSelf());
  ref.onDispose(answered.cancel);
  return store.answer(file.$1, file.$2);
});

/// The reduced copies of the splats above the cap, in the cache folder of the app: %LOCALAPPDATA% of this copy of the
/// app on Windows, ~/.cache of the app on Linux, the cache of the app on Android and macOS; never the system's
/// temporary folder, which every copy of the app and every user share (review of 2 November 2026)
final splatViewerCacheProvider = Provider<SplatViewerCache>(
  (ref) => SplatViewerCache(
    () async => Directory(p.join((await getApplicationCacheDirectory()).path, 'splat_viewer')),
    // The scenes of the splat photos of the server: 1 GiB on phones, tablets and the headset, 4 GiB on a computer
    serverMaxBytes: CurrentPlatform.isDesktop ? 4 << 30 : 1 << 30,
  ),
);

/// The bytes free on the drive of a folder, for the room a preparation needs: the computers' reader of the AI
/// components (GetDiskFreeSpaceExW, statvfs; desktopOverrides), StatFs through the splat viewer's API on Android;
/// null elsewhere, and the preparation then finds a full drive only when a write fails
final splatFreeBytesProvider = Provider<Future<int?> Function(Directory folder)?>((ref) {
  final computers = ref.watch(aiFreeSpaceProvider);
  if (computers != null) {
    return (folder) async => (await computers(folder))?.free;
  }
  final host = ref.watch(splatViewerHostProvider);
  if (host is PigeonSplatViewerHost) {
    return (folder) => host.freeBytes(folder.path);
  }
  return null;
});

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
    freeBytes: ref.read(splatFreeBytesProvider),
    answers: ref.read(splatAnswerStoreProvider),
    // A computer keeps the chip its page drew with, per set of the web view's arguments, to know it next time
    onRenderer: CurrentPlatform.isDesktop
        ? (renderer) => unawaited(
            ref
                .read(splatAnswerStoreProvider)
                .writeRenderer(renderer, highPerformance: ref.read(appConfigProvider).viewer.highPerformanceGpu),
          )
        : null,
  );
});
