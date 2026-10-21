import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/server_capability.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/websocket.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/error_handler.dart';

final _stateProvider = Provider.family.autoDispose<RemoteAsset?, ActionSource>((ref, source) {
  final isSupported = ref.watch(serverInfoProvider.select((state) => state.serverVersion.supports(.syncAssetEditsV1)));
  if (!isSupported) {
    return null;
  }

  final assets = ref.watch(ownedAssetsActionProvider(source));
  // Panoramas cannot be edited (the server refuses them, same rule as the web app). Raw Insta360 .insp files are not
  // panoramas for the viewer, but the web treats them as such by file name, so they are not editable either. Photos
  // the user only chose to view as 360° stay editable: the server does not know them as panoramas.
  return assets
      .where(
        (asset) =>
            asset.isEditable &&
            !asset.name.toLowerCase().endsWith('.insp') &&
            !ref.watch(hasEquirectangularExifProvider(asset)),
      )
      .singleOrNull;
}, dependencies: [ownedAssetsActionProvider]);

class EditAssetAction extends AssetActionBuilder {
  const EditAssetAction({required super.source});

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    if (!ref.watch(_stateProvider(source).select((asset) => asset != null))) {
      return null;
    }

    return .new(icon: Icons.tune, label: context.t.edit, onAction: () => _edit(context, ref));
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final asset = ref.read(_stateProvider(source));
    if (asset == null) {
      return;
    }

    try {
      // TODO(shenlong): Move all EXIF and Apply Edits logic onto the Route
      final repository = ref.read(driftProvider).remoteAssetRepository;
      final (edits, exif) = await (repository.getAssetEdits(asset.id), repository.watchExif(asset.id).first).wait;
      // The exif may still have been loading when the action was shown: panoramas cannot be edited
      if (exif == null || exif.projectionType == ProjectionType.equirectangular || !context.mounted) {
        return;
      }

      ref.read(editorStateProvider.notifier).init(edits, exif);
      unawaited(
        context.pushRoute(
          EditImageRoute(
            image: Image(image: getFullImageProvider(asset, edited: false)),
            applyEdits: (newEdits) => applyEdits(ref, asset.id, newEdits),
          ),
        ),
      );
    } catch (error, stack) {
      handleError(error, stack: stack, description: "Failed to open the editor for the asset");
    }
  }
}

@visibleForTesting
Future<Object?> applyEdits(WidgetRef ref, String remoteId, List<AssetEdit> edits) => applyAssetEdits(
  service: ref.read(assetServiceProvider),
  websocket: ref.read(websocketProvider.notifier),
  remoteId: remoteId,
  edits: edits,
);

/// Replaces the edits of the asset [remoteId] on the server with [edits] (none removes them), then waits up to 10 s for
/// the server to say the edited files are ready. Gives what the server sent then, its new thumbhash among others (see
/// [editReadyThumbhash]), or null when nothing came in time. The editor ignores it; the one-key rotation of the viewer
/// reads it (see ViewRotationController). Fails as the request fails.
Future<Object?> applyAssetEdits({
  required AssetService service,
  required WebsocketNotifier websocket,
  required String remoteId,
  required List<AssetEdit> edits,
}) async {
  bool isCurrentId(dynamic data) => data is Map && (data['asset'] as Map?)?['id'] == remoteId;
  // Listened to before the request, so that a fast server cannot answer before anyone listens
  final ready = Future.any([
    websocket.waitForEvent('AssetEditReadyV1', isCurrentId, const .new(seconds: 10)),
    websocket.waitForEvent('AssetEditReadyV2', isCurrentId, const .new(seconds: 10)),
  ]).then<Object?>((data) => data as Object?, onError: (_) => null);
  try {
    await service.applyEdits(remoteId, edits);
  } catch (_) {
    unawaited(ready);
    rethrow;
  }
  return ready;
}

/// The thumbhash of the asset in [data], what the server sends once the edited files are ready (AssetEditReadyV1 and
/// V2); null when it holds none
String? editReadyThumbhash(Object? data) {
  if (data is! Map) {
    return null;
  }
  final asset = data['asset'];
  final thumbhash = asset is Map ? asset['thumbhash'] : null;
  return thumbhash is String ? thumbhash : null;
}
