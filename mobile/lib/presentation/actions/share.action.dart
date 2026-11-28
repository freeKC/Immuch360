import 'dart:async';

import 'package:auto_route/auto_route.dart' show StackRouter, StackRouterScope;
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/desktop/share/desktop_share.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/providers/routes.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/routing/router.dart';

final _stateProvider = Provider.family.autoDispose<List<BaseAsset>?, ActionSource>((ref, source) {
  final assets = ref.watch(assetsActionProvider(source));
  final shareable = assets.toList(growable: false);
  return shareable.isEmpty ? null : shareable;
}, dependencies: [assetsActionProvider]);

class ShareAction extends AssetActionBuilder {
  const ShareAction({required super.source});

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final assets = ref.watch(_stateProvider(source));
    if (assets == null) {
      return null;
    }

    // A computer: a menu naming each way to share (lib/desktop/share/desktop_share.dart)
    if (CurrentPlatform.isDesktop) {
      return _desktop(context, ref, assets);
    }

    return .new(
      icon: CurrentPlatform.isAndroid ? Icons.share_rounded : Icons.ios_share_rounded,
      label: context.t.share,
      onAction: () => _share(context, ref, assets, ref.read(appConfigProvider).share.fileType),
      onSecondaryAction: () => _promptQualityAndShare(context, ref, assets),
    );
  }

  ActionItem _desktop(BuildContext context, WidgetRef ref, List<BaseAsset> assets) {
    // The items of the server a share link can be made of, as the Share link action offers it (never in the locked folder)
    final remoteIds = ref.watch(inLockedViewProvider)
        ? const <String>[]
        : [
            for (final asset in assets)
              if (asset is RemoteAsset) asset.id,
          ];
    // The router of the page that pressed Share, read then: that button may be gone once the menu closes
    Future<void> Function()? shareLink(StackRouter? router) => remoteIds.isEmpty || router == null
        ? null
        : () async => unawaited(router.push(SharedLinkEditRoute(assetsList: remoteIds)));
    Future<void> open(ShareAssetType fileType) => openDesktopShareMenu(
      context,
      DesktopShareServices.of(ref),
      assets,
      fileType: fileType,
      shareLink: shareLink(StackRouterScope.of(context)?.controller),
    );
    return .new(
      icon: Icons.ios_share_rounded,
      label: context.t.share,
      onAction: () => open(ref.read(appConfigProvider).share.fileType),
      onSecondaryAction: () async {
        final services = DesktopShareServices.of(ref);
        final link = shareLink(StackRouterScope.of(context)?.controller);
        final fileType = await askDesktopShareQuality(context, assets);
        if (fileType != null && context.mounted) {
          await openDesktopShareMenu(context, services, assets, fileType: fileType, shareLink: link);
        }
      },
    );
  }

  Future<void> _promptQualityAndShare(BuildContext context, WidgetRef ref, List<BaseAsset> assets) async {
    // Only show preview option when at least one of the assets is not a video
    final showPreview = assets.any((asset) => !asset.isVideo);

    final fileType = await showDialog<ShareAssetType>(
      context: context,
      builder: (_) => _ShareFileTypeDialog(showPreview: showPreview),
      useRootNavigator: false,
    );
    if (fileType == null || !context.mounted) {
      return;
    }

    await _share(context, ref, assets, fileType);
  }

  Future<void> _share(BuildContext context, WidgetRef ref, List<BaseAsset> assets, ShareAssetType fileType) async {
    final cancelCompleter = Completer<void>();
    final progress = ValueNotifier<double?>(null);
    final mediaRepository = ref.read(assetMediaRepositoryProvider);
    final toastService = ref.read(toastServiceProvider);
    final errorMessage = context.t.scaffold_body_error_occurred;

    await showDialog(
      context: context,
      barrierDismissible: false,
      useRootNavigator: false,
      builder: (dialogContext) {
        void finish({required bool failed}) {
          if (cancelCompleter.isCompleted || !dialogContext.mounted) {
            return;
          }
          if (failed) {
            unawaited(.value(toastService.error(errorMessage)));
          }
          dialogContext.pop();
        }

        unawaited(
          mediaRepository
              .shareAssets(
                assets,
                context,
                fileType: fileType,
                cancelCompleter: cancelCompleter,
                onAssetDownloadProgress: (value) => progress.value = value,
              )
              .then<void>((count) => finish(failed: count == 0), onError: (_) => finish(failed: true)),
        );

        return _SharePreparingDialog(progress: progress);
      },
    ).then((_) {
      if (!cancelCompleter.isCompleted) {
        cancelCompleter.complete();
      }
      progress.dispose();
    });
  }
}

class _SharePreparingDialog extends StatelessWidget {
  final ValueNotifier<double?> progress;

  const _SharePreparingDialog({required this.progress});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Column(
        mainAxisSize: .min,
        children: [
          Container(margin: const .only(bottom: 12), child: Text(context.t.share_dialog_preparing)),
          SizedBox(
            width: 240,
            child: ValueListenableBuilder<double?>(
              valueListenable: progress,
              builder: (context, value, _) {
                final percent = value == null ? null : (value * 100).clamp(0, 100);
                return Column(
                  mainAxisSize: .min,
                  children: [
                    LinearProgressIndicator(value: value, minHeight: 8.0),
                    if (percent != null)
                      Container(margin: const .only(top: 8), child: Text('${percent.toStringAsFixed(0)}%')),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ShareFileTypeDialog extends StatelessWidget {
  final bool showPreview;

  const _ShareFileTypeDialog({this.showPreview = true});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.t.select_quality),
      contentPadding: const .symmetric(vertical: 8),
      content: Column(
        mainAxisSize: .min,
        children: [
          ListTile(
            leading: const Icon(Icons.high_quality_rounded),
            title: Text(context.t.share_original),
            onTap: () => context.pop(ShareAssetType.original),
          ),
          if (showPreview)
            ListTile(
              leading: const Icon(Icons.photo_size_select_large_rounded),
              title: Text(context.t.share_preview),
              onTap: () => context.pop(ShareAssetType.preview),
            ),
        ],
      ),
      actions: [TextButton(onPressed: () => context.pop(), child: Text(context.t.cancel))],
    );
  }
}
