// How a computer opens the files given to the program (see opened_files.dart for how each one is read): the command
// line of the first start, the files a later start hands over and the files dropped on the window, a batch at a time,
// once a session is open. One photo or video opens in the viewer, in 360° when it is a 360° file; several files, or a
// folder, open as a page of their own, like a folder of the library, without joining it.

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/files/opened_files.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/view_intent_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/view_360.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/local_panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/providers/view_intent/view_intent_file_path.provider.dart';
import 'package:immich_mobile/providers/view_intent/view_intent_handler.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('OpenFiles');

/// The files of a command line: its arguments that are no options ("-x", "--x", among them the "-psn_..." macOS adds),
/// a file:// URI (a Linux desktop entry may give one) as its path, nothing empty
List<String> launchPathsOf(Iterable<String> arguments) => [
  for (final argument in arguments)
    if (argument.trim().isNotEmpty && !argument.startsWith('-')) _pathOf(argument),
];

String _pathOf(String argument) {
  if (!argument.startsWith('file://')) {
    return argument;
  }
  try {
    return Uri.parse(argument).toFilePath();
  } on FormatException {
    return argument;
  } on UnsupportedError {
    return argument;
  }
}

/// What the program is asked to open, a batch per request: the command line of the first start, each later start
/// (single_instance.dart) and each drop on the window. [DesktopOpenFilesHandler] opens them in turn.
abstract final class DesktopOpenRequests {
  static final _batches = Queue<List<String>>();
  static void Function()? _onRequest;

  /// Asks to open [paths] together; nothing for an empty batch
  static void add(Iterable<String> paths) {
    final batch = launchPathsOf(paths);
    if (batch.isEmpty) {
      return;
    }
    _batches.add(batch);
    _onRequest?.call();
  }

  /// The oldest batch not opened yet, null when there is none
  static List<String>? take() => _batches.isEmpty ? null : _batches.removeFirst();

  /// [onRequest] is told of each new batch
  static void listen(void Function()? onRequest) => _onRequest = onRequest;

  @visibleForTesting
  static void reset() {
    _batches.clear();
    _onRequest = null;
  }
}

/// The 360° file the viewer has just opened, to show in its 360° view at once (see DesktopOpenedFilesHost); null
/// once it is shown
class DesktopOpenIn360 extends Notifier<BaseAsset?> {
  @override
  BaseAsset? build() => null;

  void request(BaseAsset asset) => state = asset;

  BaseAsset? take() {
    final asset = state;
    state = null;
    return asset;
  }
}

final desktopOpenIn360Provider = NotifierProvider<DesktopOpenIn360, BaseAsset?>(DesktopOpenIn360.new);

/// Reads what the program was given at once, see [readOpenedPaths]
typedef OpenedPathsReader = Future<OpenedBatch> Function(List<String> paths);

/// The ViewIntentHandler of the computers. The phones get one file per view intent, the computers a batch of paths:
/// [handle] takes a payload too, for the code that calls it with one.
///
/// A batch waits until a session is open (a server, or the files of this computer without one), as on Android, and is
/// opened as soon as one is: the files need neither the server nor the local tables. Then one photo or video opens in
/// the viewer, and a 360° one in its 360° view at once, with the projection it declares; several, or a folder, open on
/// the page of opened files ([OpenedFilesRoute]).
class DesktopOpenFilesHandler implements ViewIntentHandler {
  DesktopOpenFilesHandler(this._ref, {OpenedPathsReader? read}) : _read = read ?? readOpenedPaths {
    // The session starts after the app: a server session once its token is checked, a session without a server at once
    _ref.listen(authProvider.select((state) => state.isAuthenticated), (_, isAuthenticated) {
      if (isAuthenticated) {
        unawaited(flushDeferredViewIntent());
      }
    });
    _ref.listen(localSessionProvider, (_, isLocalSession) {
      if (isLocalSession) {
        unawaited(flushDeferredViewIntent());
      }
    });
  }

  final Ref _ref;
  final OpenedPathsReader _read;

  // The latest batch given before a session was open
  List<String>? _deferred;
  bool _opening = false;

  bool get _hasSession => _ref.read(authProvider).isAuthenticated || _ref.read(localSessionProvider);

  @override
  void init() {
    DesktopOpenRequests.listen(() => unawaited(_openRequests()));
    unawaited(_openRequests());
  }

  @override
  Future<void> onAppResumed() => _openRequests();

  @override
  Future<void> flushDeferredViewIntent() async {
    final deferred = _deferred;
    if (deferred == null || !_hasSession) {
      return;
    }
    _deferred = null;
    DesktopOpenRequests.add(deferred);
    await _openRequests();
  }

  @override
  Future<void> handle(ViewIntentPayload attachment) async {
    final path = attachment.path;
    if (path != null) {
      DesktopOpenRequests.add([path]);
      await _openRequests();
    }
  }

  Future<void> _openRequests() async {
    if (_opening) {
      // The batch waits for the one being opened
      return;
    }
    _opening = true;
    try {
      for (var batch = DesktopOpenRequests.take(); batch != null; batch = DesktopOpenRequests.take()) {
        if (!_hasSession) {
          _log.info('${batch.length} paths wait for a session');
          _deferred = batch;
          continue;
        }
        try {
          await _open(batch);
        } catch (error, stackTrace) {
          _log.warning('Could not open the files given to the program', error, stackTrace);
        }
      }
    } finally {
      _opening = false;
    }
  }

  Future<void> _open(List<String> paths) async {
    final router = _ref.read(appRouterProvider);
    final opening = _read(paths).then((batch) {
      _remember(batch);
      return batch;
    });
    if (paths.length > 1 || await isFolder(paths.single)) {
      _log.info('Opening ${paths.length} paths as a page of their own');
      await router.replaceAll([
        const TabShellRoute(),
        OpenedFilesRoute(title: openedFilesTitle(paths), files: opening),
      ]);
      return;
    }
    final batch = await opening;
    final file = batch.files.firstOrNull;
    if (file == null) {
      _log.info('No photo or video to open in ${p.basename(paths.single)}');
      await _ref.read(toastServiceProvider).error(StaticTranslations.instance.no_assets_to_show);
      return;
    }
    await _openViewer(router, file);
  }

  void _remember(OpenedBatch batch) {
    OpenedFiles.remember(batch.files);
    _ref.read(openedFilePanoramasProvider.notifier).addAll({
      for (final file in batch.files) file.asset.id: file.record,
    });
    final found = batch.files.where((file) => file.is360).length;
    _log.info('Opened ${batch.files.length} files with the program, $found of them 360°');
  }

  Future<void> _openViewer(AppRouter router, OpenedFile file) async {
    final asset = file.asset;
    final viewer = _ref.read(assetViewerProvider.notifier)..reset();
    if (asset.isVideo) {
      viewer.setControls(false);
    }
    viewer.setAsset(asset);
    // Read by its id, as a file of the library: the path of a phone's view intent is a copy of its own
    _ref.read(viewIntentFilePathProvider.notifier).clear();
    await router.replaceAll([
      const TabShellRoute(),
      AssetViewerRoute(
        key: UniqueKey(),
        initialIndex: 0,
        timelineService: _ref.read(timelineFactoryProvider).fromAssets([asset], TimelineOrigin.deepLink),
      ),
    ]);
    // The 360° button of the viewer would open the same view, see the top bar of the viewer
    final has360View =
        (_ref.read(isEquirectangularProvider(asset)) || _ref.read(rawMediaKindProvider(asset)) != null) &&
        _ref.read(can360ViewProvider(asset));
    if (has360View) {
      _ref.read(desktopOpenIn360Provider.notifier).request(asset);
    }
  }
}

/// Whether [path] is a folder
// ignore: avoid_slow_async_io
Future<bool> isFolder(String path) => FileSystemEntity.isDirectory(path);

/// The title of the page of the files opened at once ([paths]): the name of the folder they are in, or of the folder
/// given; null when they come from several folders, for the page to count them
String? openedFilesTitle(List<String> paths) {
  final folders = {for (final path in paths) FileSystemEntity.isDirectorySync(path) ? path : p.dirname(path)};
  if (folders.length != 1) {
    return null;
  }
  final folder = folders.single;
  final name = p.basename(folder);
  return name.isEmpty ? folder : name;
}

/// Shows the 360° file just opened with the program in its 360° view (see [DesktopOpenIn360]), as its 360° button
/// would, once the viewer is on screen. Placed above the router of the app (desktopAppShell): the routes get the
/// context of its navigator.
class DesktopOpenedFilesHost extends ConsumerWidget {
  const DesktopOpenedFilesHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(desktopOpenIn360Provider, (_, asset) {
      if (asset == null) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final requested = ref.read(desktopOpenIn360Provider.notifier).take();
        final navigator = ref.read(appRouterProvider).navigatorKey.currentContext;
        if (requested != null && navigator != null && navigator.mounted) {
          unawaited(open360View(navigator, ref, requested));
        }
      });
    });
    return child;
  }
}
