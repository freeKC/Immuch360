// Opening the scene of a splat photo of the timeline (plan of 3 November 2026, sections 5.2 to 5.4). The scene kept on
// this device opens at once, offline too; else it is taken out of the copy of the photo on the device, then of the
// original on the server, into the splat viewer's cache, with its progress and a Cancel. Above 10 MB on a metered
// network the size is asked first; without room for it nothing is downloaded. Then:
//
// * on a computer, a phone or a tablet, the splat viewer opens it, the gate asked again with the head of the SPZ itself
//   (which wins over the packet), keyed by SplatName as the .spz of a share is, SplatUp the orientation when the user
//   chose none on this device (lot L3);
// * on a Meta Quest 3 or 3S, the splat viewer of the computers and phones is not there: the immersive viewer of the
//   headset gets the scene in a next step (lot L4).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/splat/splat_gate.dart';
import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_probe.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_scenes.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_tail_fetch.dart';
import 'package:immich_mobile/domain/services/splat_viewer_files.dart';
import 'package:immich_mobile/domain/services/splat_viewer_service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/network_capability_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/presentation/widgets/splat/splat_button.dart';
import 'package:immich_mobile/presentation/widgets/splat/splat_viewer_launch.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/splat/splat_viewer.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:logging/logging.dart';

final _log = Logger('SplatPhotoLaunch');

/// Above this many bytes, a metered network asks before the scene is downloaded
const splatPhotoMeteredAskBytes = 10 * 1000 * 1000;

/// The room kept free on the drive beyond the scene
const splatPhotoSpareBytes = 64 << 20;

/// The key of "Download" of the question asked on a metered network
const splatPhotoMeteredDownloadKey = Key('splat_photo_metered_download');

/// Opens the scene of the splat photo [asset], told by [xmp], with the [request] the gate of this device gave (see the
/// top of this file). Tests replace it.
typedef SplatPhotoOpener =
    Future<void> Function(
      BuildContext context,
      WidgetRef ref,
      BaseAsset asset,
      SplatPhotoXmp xmp,
      GaussianSplatRequest request,
    );

/// See [SplatPhotoOpener]
final splatPhotoOpenerProvider = Provider<SplatPhotoOpener>((ref) => openSplatPhoto);

/// The scenes of the splat photos kept on this device, in the splat viewer's cache
final splatPhotoScenesProvider = Provider<SplatPhotoScenes>(
  (ref) => SplatPhotoScenes(ref.watch(splatViewerCacheProvider)),
);

/// The original of the asset of a remote id on the server, without the edited parameter, with the app's shared client
/// and the authentication of the server; null without a server. Tests replace it.
final splatPhotoServerSourceProvider = Provider<SplatTailSource? Function(String remoteId)>(
  (ref) => (remoteId) {
    final endpoint = Store.tryGet(StoreKey.serverEndpoint);
    return endpoint == null
        ? null
        : SplatTailFromServer(
            client: NetworkRepository.client,
            url: splatPhotoOriginalUri(endpoint, remoteId),
            headers: ApiService.getRequestHeaders(),
          );
  },
);

/// Whether this device is on a metered network now: Android's network capabilities, as the backup reads them; never
/// on the computers. Tests replace it.
final splatPhotoMeteredProvider = Provider<Future<bool> Function()>(
  (ref) => () async {
    if (!CurrentPlatform.isAndroid) {
      return false;
    }
    try {
      return !(await ref.read(connectivityApiProvider).getCapabilities()).isUnmetered;
    } catch (error) {
      _log.fine('The network capabilities could not be read: $error');
      return false;
    }
  },
);

/// Where the scene of [asset] is read from, in order: its copy on the device, then its original on the server
Future<List<SplatTailSource>> splatPhotoSourcesOf(WidgetRef ref, BaseAsset asset) async {
  final sources = <SplatTailSource>[];
  final localId = asset.localId;
  if (localId != null) {
    try {
      final file = await ref.read(storageRepositoryProvider).getFileForAsset(localId);
      if (file != null) {
        sources.add(SplatTailFromFile(file));
      }
    } catch (error) {
      _log.fine('No copy on the device of ${asset.name}: $error');
    }
  }
  final remoteId = asset.remoteId;
  final server = remoteId == null ? null : ref.read(splatPhotoServerSourceProvider)(remoteId);
  if (server != null) {
    sources.add(server);
  }
  return sources;
}

/// The key of the scene of [asset] in the cache: its id on the server, else on the device
String splatPhotoSceneKeyOf(BaseAsset asset) =>
    asset.remoteId ?? (asset.localId == null ? asset.id : 'local-${asset.localId}');

/// What to say when the scene could not be taken out of its photo
String splatPhotoFetchFailedText(Translations t, SplatTailFetchException error) => switch (error.problem) {
  SplatTailFetchProblem.lost => t.splat_photo_lost,
  SplatTailFetchProblem.damaged => t.splat_photo_damaged,
  SplatTailFetchProblem.network || SplatTailFetchProblem.cancelled => t.splat_photo_download_failed(
    reason: error.detail.isEmpty ? error.problem.name : error.detail,
  ),
};

/// The scene of [asset] on this device: kept, or taken out of its photo with a dialog of its progress and Cancel;
/// null when the user cancelled or it could not be had (said then)
Future<SplatPhotoScene?> obtainSplatPhotoScene(
  BuildContext context,
  WidgetRef ref,
  BaseAsset asset,
  SplatPhotoXmp xmp,
) async {
  final t = context.t;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final scenes = ref.read(splatPhotoScenesProvider);
  final key = splatPhotoSceneKeyOf(asset);
  final kept = await scenes.kept(key, xmp);
  if (kept != null || !context.mounted) {
    return kept;
  }
  final length = xmp.splatLength!;
  // A large scene over a metered network: the size is asked first
  if (length > splatPhotoMeteredAskBytes && await ref.read(splatPhotoMeteredProvider)()) {
    if (!context.mounted) {
      return null;
    }
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(context.t.splat_photo_mobile_data(size: formatBytes(length))),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.t.cancel)),
          TextButton(
            key: splatPhotoMeteredDownloadKey,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t.splat_photo_download),
          ),
        ],
      ),
    );
    if (yes != true) {
      return null;
    }
  }
  // Room for the scene, and some to spare
  final cache = ref.read(splatViewerCacheProvider);
  final freeBytes = ref.read(splatFreeBytesProvider);
  if (freeBytes != null) {
    try {
      final free = await freeBytes(await cache.folder());
      if (free != null && free < length + splatPhotoSpareBytes) {
        messenger?.showSnackBar(SnackBar(content: Text(t.splat_no_space_device)));
        return null;
      }
    } catch (error) {
      _log.fine('The free space could not be read: $error');
    }
  }
  final sources = await splatPhotoSourcesOf(ref, asset);
  if (!context.mounted) {
    return null;
  }
  final progress = ValueNotifier<(SplatPrepareStep, double)?>((SplatPrepareStep.download, 0));
  final cancel = SplatPrepareCancel();
  final navigator = Navigator.of(context, rootNavigator: true);
  var dialogShown = true;
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (context) => SplatPrepareDialog(progress: progress, onCancel: cancel.cancel, downloadTotal: length),
    ).whenComplete(() {
      // Gone without the close below: the routes changed under it, the download stops as on Back
      if (dialogShown) {
        dialogShown = false;
        cancel.cancel();
      }
    }),
  );
  try {
    final scene = await scenes.obtain(
      key,
      xmp,
      sources: sources,
      onProgress: (done, total) =>
          progress.value = (SplatPrepareStep.download, total > 0 ? done / total : (done / length).clamp(0.0, 1.0)),
      cancel: cancel,
    );
    unawaited(cache.prune().catchError((Object error) => _log.fine('Prune: $error')));
    return cancel.isCancelled ? null : scene;
  } on SplatTailFetchException catch (error) {
    if (error.problem != SplatTailFetchProblem.cancelled) {
      messenger?.showSnackBar(SnackBar(content: Text(splatPhotoFetchFailedText(t, error))));
    }
    return null;
  } catch (error) {
    _log.warning('The scene of ${asset.name} could not be had: $error');
    messenger?.showSnackBar(SnackBar(content: Text(t.splat_photo_download_failed(reason: '$error'))));
    return null;
  } finally {
    if (dialogShown) {
      dialogShown = false;
      navigator.pop();
    }
    progress.dispose();
  }
}

/// See [SplatPhotoOpener] and the top of this file
Future<void> openSplatPhoto(
  BuildContext context,
  WidgetRef ref,
  BaseAsset asset,
  SplatPhotoXmp xmp,
  GaussianSplatRequest request,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final t = context.t;
  final locale = Localizations.localeOf(context).toLanguageTag();
  final device = ref.read(splatDeviceClassProvider);
  final scene = await obtainSplatPhotoScene(context, ref, asset, xmp);
  if (scene == null || !context.mounted) {
    return;
  }
  final name = xmp.splatName!;
  final fileBytes = xmp.splatLength!;
  // The gate again with the head of the SPZ itself
  final verdict = await splatViewerVerdictNow(ref, scene.head, name: name, fileBytes: fileBytes);
  final open = verdict?.request;
  if (verdict != null && open == null) {
    messenger?.showSnackBar(SnackBar(content: Text(splatRefusalText(t, verdict, locale, onHeadset: false))));
  }
  if (device == null || open == null) {
    return;
  }
  final answer = device == SplatDeviceClass.computer
      ? await ref.read(splatAnswerStoreProvider).answer(name, fileBytes)
      : null;
  if (!context.mounted) {
    return;
  }
  await showSplatViewer(
    context,
    ref,
    source: SplatViewerSource.local(scene.file.path, name: name, up: xmp.splatUp),
    head: scene.head,
    fileBytes: fileBytes,
    cap: open.maxGaussians,
    watchFrames: splatWatchesFrames(device: device, head: scene.head, cap: open.maxGaussians, answer: answer),
  );
}

/// Whether [file] is a scene of the splat photos kept on this device
bool isSplatPhotoSceneFile(File file) =>
    file.uri.pathSegments.last.startsWith(SplatViewerCache.serverPrefix) && file.path.endsWith('.spz');
