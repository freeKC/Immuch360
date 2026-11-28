// The Share button of a computer (Windows, Linux, macOS): a small menu that names each way to share, one line each
// saying what it does, rather than a share window that leaves the user guessing (FreeKC, 27 November 2026: "on ne sait
// pas comment il va partager"). Phones, tablets, TVs and the Quest keep their Share as it is (share.action.dart).
// - Copy: the files on the clipboard, to paste in another program (lib/desktop/clipboard);
// - Save to a folder…: a copy of the files in a folder the user picks (lib/desktop/files/save_to_folder.dart);
// - Share with Windows… / Share with macOS…: the share window of the system (system_share_sheet.dart), shown only
//   where the system says it has one; Linux has none;
// - Create a share link: the link page of the Immich server, for items of the server, as its own action;
// - Select quality: original or preview for the files of Save and of the share window (the long press of the button
//   asks it too, as on a phone).
// The files fetched from the server for the share window are kept until the window and the program chosen in it are
// done with them, in the folder of the copies of the clipboard (clipboard_copies.dart), which cleans them up later.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/desktop/clipboard/clipboard_copies.dart';
import 'package:immich_mobile/desktop/clipboard/clipboard_copy.dart';
import 'package:immich_mobile/desktop/files/save_to_folder.dart';
import 'package:immich_mobile/desktop/share/system_share_sheet.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('DesktopShare');

/// The ways of the Share menu, in its order
enum DesktopShareWay { copy, saveToFolder, systemSheet, shareLink, quality }

/// The ways the Share menu of [platform] offers: Copy and Save first, the share window of the system where it has one
/// ([systemSheet], never on Linux), a share link for items of the server ([shareLink]), the quality for photos
/// ([quality])
List<DesktopShareWay> desktopShareWays({
  required TargetPlatform platform,
  required bool systemSheet,
  required bool shareLink,
  required bool quality,
}) => [
  DesktopShareWay.copy,
  DesktopShareWay.saveToFolder,
  if (systemSheet && (platform == TargetPlatform.windows || platform == TargetPlatform.macOS))
    DesktopShareWay.systemSheet,
  if (shareLink) DesktopShareWay.shareLink,
  if (quality) DesktopShareWay.quality,
];

/// The share window of this computer; the tests give theirs
final systemShareSheetProvider = Provider<SystemShareSheet?>((ref) => systemShareSheetHere());

/// Whether the system says its share window can be opened, asked once
Future<bool>? _systemSheetSupported;

@visibleForTesting
void resetDesktopShare() {
  _systemSheetSupported = null;
  _lastPointerDown = null;
}

/// Where and when the last button of the mouse went down: the menu opens there
Offset? _lastPointerDown;
DateTime? _lastPointerDownAt;
bool _tracking = false;

/// Follows the presses of the mouse, for the place of the menu; at the start of a computer
void trackDesktopSharePointer() {
  if (_tracking) {
    return;
  }
  _tracking = true;
  GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
}

void _onPointer(PointerEvent event) {
  if (event is PointerDownEvent) {
    _lastPointerDown = event.position;
    _lastPointerDownAt = DateTime.now();
  }
}

/// The point the menu opens at: the last press when it was just now, else the middle of what [context] shows
Offset _menuPoint(BuildContext context, Size screen) {
  final pressed = _lastPointerDown;
  final at = _lastPointerDownAt;
  if (pressed != null && at != null && DateTime.now().difference(at) < const Duration(seconds: 5)) {
    return pressed;
  }
  final box = context.mounted ? context.findRenderObject() : null;
  if (box is RenderBox && box.hasSize && box.attached) {
    return box.localToGlobal(box.size.center(Offset.zero));
  }
  return screen.center(Offset.zero);
}

/// The text of [way] on [platform]: its name, and the line saying what it does
({String title, String line}) desktopShareWayText(
  DesktopShareWay way,
  TargetPlatform platform,
  ShareAssetType fileType,
  Translations t,
) => switch (way) {
  DesktopShareWay.copy => (title: t.desktop_copy, line: t.desktop_share_copy_line),
  DesktopShareWay.saveToFolder => (title: t.desktop_share_save, line: t.desktop_share_save_line),
  DesktopShareWay.systemSheet when platform == TargetPlatform.macOS => (
    title: t.desktop_share_macos,
    line: t.desktop_share_macos_line,
  ),
  DesktopShareWay.systemSheet => (title: t.desktop_share_windows, line: t.desktop_share_windows_line),
  DesktopShareWay.shareLink => (title: t.desktop_share_link, line: t.desktop_share_link_line),
  DesktopShareWay.quality => (
    title: t.select_quality,
    line: fileType == ShareAssetType.preview ? t.share_preview : t.share_original,
  ),
};

IconData _iconOf(DesktopShareWay way) => switch (way) {
  DesktopShareWay.copy => Icons.content_copy_rounded,
  DesktopShareWay.saveToFolder => Icons.save_alt_rounded,
  DesktopShareWay.systemSheet => Icons.ios_share_rounded,
  DesktopShareWay.shareLink => Icons.link_rounded,
  DesktopShareWay.quality => Icons.high_quality_rounded,
};

/// What the menu works with, read from the providers when Share is pressed: the widget that showed Share may be gone
/// once the menu closes (an entry of a menu, the menu of a right click)
class DesktopShareServices {
  const DesktopShareServices({
    required this.copier,
    required this.storage,
    required this.media,
    required this.sheet,
    this.clipboardRoot = clipboardCopiesRoot,
  });

  factory DesktopShareServices.of(WidgetRef ref) => DesktopShareServices(
    copier: ref.read(desktopClipboardCopierProvider),
    storage: ref.read(storageRepositoryProvider),
    media: ref.read(assetMediaRepositoryProvider),
    sheet: ref.read(systemShareSheetProvider),
  );

  final ClipboardCopier copier;
  final StorageRepository storage;
  final AssetMediaRepository media;
  final SystemShareSheet? sheet;

  /// The folder of the copies of the clipboard, where the files of a share window are kept
  final Future<Directory> Function() clipboardRoot;
}

/// Opens the Share menu over [context] for [assets], then does what is picked. [fileType] is the quality of Save and
/// of the share window; [shareLink] opens the page of a share link of the server for them (null: no link entry).
Future<void> openDesktopShareMenu(
  BuildContext context,
  DesktopShareServices services,
  List<BaseAsset> assets, {
  required ShareAssetType fileType,
  Future<void> Function()? shareLink,
  TargetPlatform? platform,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final target = platform ?? defaultTargetPlatform;
  final screen = MediaQuery.sizeOf(context);
  final point = _menuPoint(context, screen);
  final sheet = services.sheet;
  final systemSheet = sheet != null && await (_systemSheetSupported ??= sheet.supported());
  final ways = desktopShareWays(
    platform: target,
    systemSheet: systemSheet,
    shareLink: shareLink != null,
    quality: assets.any((asset) => !asset.isVideo),
  );
  if (!navigator.mounted) {
    return;
  }
  final t = StaticTranslations.instance;
  final picked = await showMenu<DesktopShareWay>(
    context: navigator.context,
    useRootNavigator: true,
    position: RelativeRect.fromRect(Rect.fromLTWH(point.dx, point.dy, 0, 0), Offset.zero & screen),
    items: [
      for (final way in ways)
        PopupMenuItem<DesktopShareWay>(
          key: Key('desktop_share_${way.name}'),
          value: way,
          child: _DesktopShareEntry(icon: _iconOf(way), text: desktopShareWayText(way, target, fileType, t)),
        ),
    ],
  );
  if (picked == null || !navigator.mounted) {
    return;
  }
  final origin = Rect.fromLTWH(point.dx, point.dy, 1, 1);
  switch (picked) {
    case DesktopShareWay.copy:
      await copyAssetsToClipboardWith(
        navigator.context,
        services.copier,
        assets,
        localFile: services.storage.getFileForAsset,
      );
    case DesktopShareWay.saveToFolder:
      await _shareFiles(navigator, services, assets, fileType, toFolder: true, origin: origin);
    case DesktopShareWay.systemSheet:
      await _shareFiles(navigator, services, assets, fileType, toFolder: false, origin: origin);
    case DesktopShareWay.shareLink:
      await shareLink?.call();
    case DesktopShareWay.quality:
      final chosen = await askDesktopShareQuality(navigator.context, assets);
      if (chosen != null && navigator.mounted) {
        await openDesktopShareMenu(
          navigator.context,
          services,
          assets,
          fileType: chosen,
          shareLink: shareLink,
          platform: platform,
        );
      }
  }
}

/// Original or preview, as the long press of Share asks on a phone; null when the user gave up
Future<ShareAssetType?> askDesktopShareQuality(BuildContext context, List<BaseAsset> assets) {
  final t = StaticTranslations.instance;
  final showPreview = assets.any((asset) => !asset.isVideo);
  return showDialog<ShareAssetType>(
    context: context,
    useRootNavigator: true,
    builder: (dialogContext) => AlertDialog(
      title: Text(t.select_quality),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const Key('desktop_share_original'),
            leading: const Icon(Icons.high_quality_rounded),
            title: Text(t.share_original),
            onTap: () => Navigator.of(dialogContext).pop(ShareAssetType.original),
          ),
          if (showPreview)
            ListTile(
              key: const Key('desktop_share_preview'),
              leading: const Icon(Icons.photo_size_select_large_rounded),
              title: Text(t.share_preview),
              onTap: () => Navigator.of(dialogContext).pop(ShareAssetType.preview),
            ),
        ],
      ),
      actions: [TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(t.cancel))],
    ),
  );
}

/// The title the share window shows: the name of the file, or how many there are
String desktopShareTitle(List<String> paths, Translations t) =>
    paths.length == 1 ? p.basename(paths.single) : t.desktop_share_title_files(count: paths.length);

/// Fetches the files of [assets] (a progress over the app, which Cancel and Escape stop), then saves them into a folder
/// ([toFolder]) or hands them to the share window of the system
Future<void> _shareFiles(
  NavigatorState navigator,
  DesktopShareServices services,
  List<BaseAsset> assets,
  ShareAssetType fileType, {
  required bool toFolder,
  required Rect origin,
}) async {
  final t = StaticTranslations.instance;
  final cancel = Completer<void>();
  final progress = ValueNotifier<double?>(null);
  var open = true;
  final dialogClosed = showDialog<void>(
    context: navigator.context,
    useRootNavigator: true,
    barrierDismissible: false,
    builder: (_) => DesktopSharePreparingDialog(
      progress: progress,
      onCancel: () {
        if (!cancel.isCompleted) {
          cancel.complete();
        }
      },
    ),
  ).whenComplete(() => open = false);
  List<ShareFetchedFile>? fetched;
  try {
    fetched = await services.media.fetchShareFiles(
      assets,
      fileType: fileType,
      cancelCompleter: cancel,
      onAssetDownloadProgress: (value) => progress.value = value,
    );
  } catch (error) {
    _log.warning('The files to share could not be fetched: ${error.runtimeType}');
    fetched = null;
  } finally {
    if (open && navigator.mounted) {
      navigator.pop();
    }
    unawaited(dialogClosed.whenComplete(progress.dispose));
  }
  if (fetched == null) {
    // A cancel says nothing; anything else, which the repository logged, says it failed
    if (!cancel.isCompleted) {
      snackbar.error(t.scaffold_body_error_occurred);
    }
    return;
  }
  if (!cancel.isCompleted) {
    cancel.complete();
  }
  if (toFolder) {
    try {
      await saveFilesToFolder([for (final file in fetched) file.file.path]);
    } finally {
      await services.media.releaseShareFiles(fetched);
    }
    return;
  }
  final sheet = services.sheet;
  if (sheet == null) {
    await services.media.releaseShareFiles(fetched);
    return;
  }
  await shareWithSystemSheet(
    sheet,
    fetched,
    root: services.clipboardRoot,
    release: services.media.releaseShareFiles,
    origin: origin,
  );
}

/// Hands [fetched] to [sheet]: the files fetched from the server move into a folder of the copies of the clipboard
/// first, where they stay until the window and the program chosen in it let them go and an hour more
/// (clipboard_copies.dart); a failure is shown with the reason the system gave, and logged without any folder or URL;
/// a window closed without a choice says nothing. Returns once the window is done with the files.
Future<SystemShareEnd?> shareWithSystemSheet(
  SystemShareSheet sheet,
  List<ShareFetchedFile> fetched, {
  required Future<Directory> Function() root,
  required Future<void> Function(List<ShareFetchedFile> fetched) release,
  Rect? origin,
}) async {
  final t = StaticTranslations.instance;
  final temporary = [
    for (final file in fetched)
      if (file.temporary != null) file.file,
  ];
  Directory? kept;
  final paths = <String>[];
  try {
    if (temporary.isNotEmpty) {
      final copies = await keepShareCopies(temporary, await root());
      kept = copies.folder;
      var next = 0;
      for (final file in fetched) {
        paths.add(file.temporary != null ? copies.paths[next++] : file.file.path);
      }
    } else {
      paths.addAll([for (final file in fetched) file.file.path]);
    }
  } on FileSystemException catch (error) {
    _log.warning('The files to share could not be kept: ${error.message}');
    snackbar.error(t.desktop_share_failed(reason: error.message));
    return null;
  } finally {
    // The downloads' own folders, empty now, and their records
    await release(fetched);
  }

  final share = sheet.share(paths, title: desktopShareTitle(paths, t), origin: origin);
  try {
    await share.opened;
  } on SystemShareException catch (error) {
    _log.warning('The share window did not take the files: ${clipboardLogText('$error')}');
    // A window that never asked for the files says so in the language of the app; the others give the text of the system
    final reason = error.step == 'request'
        ? t.desktop_share_not_opened
        : error.reason.isEmpty
        ? (error.code ?? error.step)
        : error.reason;
    snackbar.error(t.desktop_share_failed(reason: error.file == null ? reason : '${error.file}: $reason'));
    if (kept != null) {
      await releaseShareCopies(kept);
    }
    return null;
  }
  _log.info('The share window took ${paths.length} files');
  final end = await share.finished;
  _log.info(
    end == SystemShareEnd.shared
        ? 'The share window gave the files to ${share.target ?? 'a program'}'
        : 'The share window was closed without a choice',
  );
  if (kept != null) {
    await releaseShareCopies(kept);
  }
  return end;
}

/// The progress of the files fetched for a share: Cancel, and Escape (the Back of this dialog), stop it
class DesktopSharePreparingDialog extends StatelessWidget {
  const DesktopSharePreparingDialog({super.key, required this.progress, required this.onCancel});

  final ValueListenable<double?> progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          onCancel();
        }
      },
      child: AlertDialog(
        key: const Key('desktop_share_preparing'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.share_dialog_preparing),
            const SizedBox(height: 12),
            SizedBox(
              width: 260,
              child: ValueListenableBuilder<double?>(
                valueListenable: progress,
                builder: (context, value, _) => LinearProgressIndicator(value: value),
              ),
            ),
          ],
        ),
        actions: [TextButton(key: const Key('desktop_share_cancel'), onPressed: onCancel, child: Text(t.cancel))],
      ),
    );
  }
}

class _DesktopShareEntry extends StatelessWidget {
  const _DesktopShareEntry({required this.icon, required this.text});

  final IconData icon;
  final ({String title, String line}) text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text.title, style: theme.textTheme.bodyLarge),
                Text(text.line, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
