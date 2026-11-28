// "Copy" of photos and videos on a computer, from the menu of a right click and from Control C (Command C on macOS):
// in the grids of the timeline, of the albums and of the folders of this computer, in the folders of a share or of a
// media server, and in the viewers, for one item or the whole selection. The files of this computer go on the clipboard
// as they are; the others are fetched first into the cache of the app (clipboard_copies.dart), with a short progress
// that Cancel and Escape stop. A single photo also puts its picture there (desktop_clipboard.dart); a video, and a
// selection of several items, only their files. "Copy name" puts the file name as text.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/clipboard/clipboard_copies.dart';
import 'package:immich_mobile/desktop/clipboard/desktop_clipboard.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:logging/logging.dart';

final _log = Logger('ClipboardCopy');

/// What a copy put on the clipboard
typedef ClipboardCopyResult = ({int files, bool picture});

/// Puts photos and videos on the clipboard: fetches those that are elsewhere, makes the picture of a single photo,
/// writes, then marks the copies so that they stay while the clipboard holds them
class ClipboardCopier {
  ClipboardCopier({
    this._clipboard = const ChannelDesktopClipboard(),
    this._root = clipboardCopiesRoot,
    Future<ClipboardPicture?> Function(String path)? picture,
    bool? systemTokens,
  }) : _picture = picture ?? _pictureOfFile,
       _systemTokens = systemTokens ?? !CurrentPlatform.isLinux;

  final DesktopClipboard _clipboard;
  final Future<Directory> Function() _root;
  final Future<ClipboardPicture?> Function(String path) _picture;

  /// Whether the tokens of the clipboard belong to the system (Windows, macOS) rather than to the run of the app
  final bool _systemTokens;

  DesktopClipboard get clipboard => _clipboard;

  /// The copies asked in this run, the latest last: a copy that a later one overtook (the picture of a large photo
  /// still being made, a fetch still going) writes nothing, so that the clipboard ends up with what was asked last.
  /// Shared by every copier: there is one clipboard.
  static int _generation = 0;

  static Future<ClipboardPicture?> _pictureOfFile(String path) => clipboardPictureOf(path, File(path).readAsBytes);

  /// Puts [sources] on the clipboard, in their order. [cancelled] stops the fetch of remote files; [onProgress] tells
  /// the bytes fetched. Throws a [ClipboardCopyException]; nothing changes on the clipboard then.
  Future<ClipboardCopyResult> copy(
    List<ClipboardSource> sources, {
    Future<void>? cancelled,
    ClipboardFetchProgress? onProgress,
  }) async {
    if (sources.isEmpty) {
      return (files: 0, picture: false);
    }
    final generation = ++_generation;
    final root = await _root();
    // The copies the clipboard no longer holds go before new ones come
    await cleanClipboardCopies(root, holds: _clipboard.holds, systemTokens: _systemTokens);

    final remote = sources.whereType<RemoteClipboardSource>().toList();
    Directory? folder;
    var fetched = const <String>[];
    if (remote.isNotEmpty) {
      final copies = await fetchClipboardCopies(remote, root, cancelled: cancelled, onProgress: onProgress);
      folder = copies.folder;
      fetched = copies.paths;
    }
    try {
      var next = 0;
      final paths = [
        for (final source in sources)
          switch (source) {
            LocalClipboardSource(:final path) => path,
            RemoteClipboardSource() => fetched[next++],
          },
      ];
      var cancelledNow = false;
      unawaited(cancelled?.then((_) => cancelledNow = true));
      final single = sources.length == 1 ? sources.single : null;
      final picture = single != null && !single.isVideo ? await _picture(paths.single) : null;
      if (cancelledNow) {
        throw const ClipboardCopyException(ClipboardCopyFailure.cancelled);
      }
      if (generation != _generation) {
        throw const ClipboardCopyException(ClipboardCopyFailure.superseded);
      }
      final int token;
      try {
        token = await _clipboard.writeFiles(ClipboardPayload(paths: paths, picture: picture));
      } on PlatformException catch (error) {
        // The macOS runner makes the picture off its main thread and drops a write a later one overtook
        if (error.code == clipboardSupersededCode) {
          throw const ClipboardCopyException(ClipboardCopyFailure.superseded);
        }
        throw ClipboardCopyException(ClipboardCopyFailure.clipboardRefused, error.message ?? error.code);
      } on Exception catch (error) {
        throw ClipboardCopyException(ClipboardCopyFailure.clipboardRefused, '$error');
      }
      if (folder != null) {
        try {
          await markClipboardCopy(folder, token);
        } on FileSystemException catch (error) {
          // Without its marker the folder goes at the next copy once an hour old: the files were pasted by then
          _log.warning('The copies on the clipboard have no marker: ${error.message}');
        }
      }
      return (files: paths.length, picture: picture != null);
    } catch (_) {
      if (folder != null) {
        await _deleteFolder(folder);
      }
      rethrow;
    }
  }

  /// The clean up at the start of the app, see clipboard_copies.dart
  Future<void> cleanAtStart() async {
    try {
      await cleanClipboardCopies(await _root(), holds: _clipboard.holds, systemTokens: _systemTokens);
    } catch (error) {
      _log.info('The copies of the clipboard were not cleaned up: ${error.runtimeType}');
    }
  }

  static Future<void> _deleteFolder(Directory folder) async {
    try {
      if (folder.existsSync()) {
        await folder.delete(recursive: true);
      }
    } on FileSystemException {
      // The next copy or start
    }
  }
}

/// The copier of the app; the tests give theirs
final desktopClipboardCopierProvider = Provider<ClipboardCopier>((ref) => ClipboardCopier());

/// How long after the start the copies of an earlier run are cleaned up: once the channel of the runner answers
const clipboardCleanUpAfterStart = Duration(seconds: 30);

/// The copies of an earlier run the clipboard no longer holds, deleted a while after the start
void cleanUpClipboardCopiesAtStart() {
  unawaited(Future<void>.delayed(clipboardCleanUpAfterStart, () => ClipboardCopier().cleanAtStart()));
}

/// The file of [asset] to copy: the file of this computer when it has one (an edit of the server excepted, as for a
/// share), else the original of the server, asked with the session of the app; null for neither
Future<ClipboardSource?> clipboardSourceOfAsset(
  BaseAsset asset, {
  required Future<File?> Function(String localId) localFile,
  ClipboardFetch Function(String remoteId, {required bool edited})? serverFetch,
}) async {
  final localId = asset.localId;
  if (localId != null && !asset.isEdited) {
    final file = await localFile(localId);
    if (file != null && file.existsSync()) {
      return LocalClipboardSource(file.path, isVideo: asset.isVideo);
    }
  }
  final remoteId = asset.remoteId;
  if (remoteId == null) {
    return null;
  }
  return RemoteClipboardSource(
    name: asset.name,
    isVideo: asset.isVideo,
    fetch: (serverFetch ?? serverOriginalFetch)(remoteId, edited: asset.isEdited),
  );
}

/// The original of the asset [remoteId] of the server, as the share of a photo asks for it
ClipboardFetch serverOriginalFetch(String remoteId, {required bool edited}) =>
    (abort) => NetworkRepository.client.send(
      http.AbortableRequest('GET', Uri.parse(getOriginalUrlForRemoteId(remoteId, edited: edited)), abortTrigger: abort)
        ..headers.addAll(ApiService.getRequestHeaders()),
    );

/// The file of a share or of a media server at [entry], read through the media bridge as its pages read it
ClipboardSource clipboardSourceOfEntry(NetworkEntry entry, NetworkConnections connections, http.Client client) =>
    RemoteClipboardSource(
      name: entry.name,
      isVideo: entry.isVideo,
      size: entry.size,
      fetch: (abort) async {
        final url = await connections.mediaUrl(entry.sourceId, entry.path);
        return client.send(http.AbortableRequest('GET', url, abortTrigger: abort));
      },
    );

/// Copies [assets] (the selection of a grid, the asset of the viewer)
Future<void> copyAssetsToClipboard(BuildContext context, WidgetRef ref, List<BaseAsset> assets) {
  final storage = ref.read(storageRepositoryProvider);
  final copier = ref.read(desktopClipboardCopierProvider);
  return copyToClipboard(context, copier, () async {
    final sources = <ClipboardSource>[];
    for (final asset in assets) {
      final source = await clipboardSourceOfAsset(asset, localFile: storage.getFileForAsset);
      if (source != null) {
        sources.add(source);
      }
    }
    return sources;
  });
}

/// Copies [entries], files of a share or of a media server
Future<void> copyEntriesToClipboard(BuildContext context, WidgetRef ref, List<NetworkEntry> entries) {
  final connections = ref.read(networkConnectionsProvider);
  final client = ref.read(networkBridgeClientProvider);
  final copier = ref.read(desktopClipboardCopierProvider);
  return copyToClipboard(
    context,
    copier,
    () async => [
      for (final entry in entries)
        if (!entry.isDirectory) clipboardSourceOfEntry(entry, connections, client),
    ],
  );
}

/// Puts [name], the file name of the item shown, on the clipboard as text
Future<void> copyNameToClipboard(WidgetRef ref, String name) async {
  try {
    await ref.read(desktopClipboardCopierProvider).clipboard.writeText(name);
    snackbar.success(StaticTranslations.instance.desktop_copy_name_done);
  } on Exception catch (error) {
    _log.warning('The name could not be copied: $error');
    snackbar.error(StaticTranslations.instance.desktop_copy_failed);
  }
}

/// Copies what [sources] gives with [copier]: a progress over [context] while remote files are fetched, which Cancel
/// and Escape stop, then a message. Returns once it is done, cancelled or failed.
Future<void> copyToClipboard(
  BuildContext context,
  ClipboardCopier copier,
  Future<List<ClipboardSource>> Function() sources,
) async {
  final t = StaticTranslations.instance;
  final List<ClipboardSource> items;
  try {
    items = await sources();
  } catch (error) {
    _log.warning('The items to copy could not be found: ${error.runtimeType}');
    snackbar.error(t.desktop_copy_failed);
    return;
  }
  if (items.isEmpty) {
    snackbar.error(t.desktop_copy_failed);
    return;
  }
  final cancel = Completer<void>();
  final progress = ValueNotifier<double?>(null);
  final copying = copier.copy(
    items,
    cancelled: cancel.future,
    onProgress: (fetched, total) => progress.value = clipboardFetchFraction(fetched, total),
  );
  final remote = items.any((item) => item is RemoteClipboardSource);
  Future<void> dialogClosed = Future.value();
  if (remote && context.mounted) {
    final navigator = Navigator.of(context, rootNavigator: true);
    var open = true;
    dialogClosed = showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (_) => ClipboardFetchDialog(
        progress: progress,
        onCancel: () {
          if (!cancel.isCompleted) {
            cancel.complete();
          }
        },
      ),
    ).whenComplete(() => open = false);
    await copying.then<void>((_) {}, onError: (Object _) {});
    if (open && navigator.mounted) {
      navigator.pop();
    }
  }
  try {
    final result = await copying;
    snackbar.success(t.desktop_copy_done(count: result.files));
  } on ClipboardCopyException catch (error) {
    // A cancel, and a copy a later one overtook, stay silent: the user asked for something else
    if (error.failure != ClipboardCopyFailure.cancelled && error.failure != ClipboardCopyFailure.superseded) {
      _log.warning('The copy did not reach the clipboard: ${clipboardLogText('$error')}');
      snackbar.error(t.desktop_copy_failed);
    }
  } catch (error) {
    // Anything else (the cache folder not found, a source that cannot be read): the same message, never a path
    _log.warning('The copy did not reach the clipboard: ${clipboardLogText('${error.runtimeType}')}');
    snackbar.error(t.desktop_copy_failed);
  } finally {
    if (!cancel.isCompleted) {
      cancel.complete();
    }
    unawaited(dialogClosed.whenComplete(progress.dispose));
  }
}

/// The progress of the fetch of remote files for the clipboard: Cancel, and Escape (the Back of this dialog), stop it
class ClipboardFetchDialog extends StatelessWidget {
  const ClipboardFetchDialog({super.key, required this.progress, required this.onCancel});

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
        key: const Key('desktop_copy_fetching'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.desktop_copy_fetching),
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
        actions: [TextButton(key: const Key('desktop_copy_cancel'), onPressed: onCancel, child: Text(t.cancel))],
      ),
    );
  }
}
