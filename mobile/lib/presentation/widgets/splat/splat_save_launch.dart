// Save to Immich of a splat scene (plan of 3 November 2026, section 6): in the splat viewer's page of the computers,
// phones and tablets (the view on screen becomes the poster), and in a sheet with a drawn poster for the Quest's splat
// page and a single splat selected in a share or a folder. Both start the same SplatSaveJob through
// splatSaveJobsProvider, which keeps running when the page or the sheet is gone; the main window then tells its end.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_save_job.dart';
import 'package:immich_mobile/domain/services/splat_viewer_files.dart';
import 'package:immich_mobile/domain/services/splat_viewer_service.dart';
import 'package:immich_mobile/domain/services/splat_viewer_session.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/presentation/widgets/splat/splat_tile.widget.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/splat/splat_save.provider.dart';
import 'package:immich_mobile/providers/splat/splat_viewer.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:logging/logging.dart';

final _log = Logger('SplatSaveLaunch');

/// The key of the Save button of the sheet
const splatSaveSheetSaveKey = Key('splat_save_sheet_save');

/// The key of the album switch of the sheet
const splatSaveSheetAlbumKey = Key('splat_save_sheet_album');

/// The key of "Show it" of the sheet
const splatSaveSheetShowKey = Key('splat_save_sheet_show');

/// Opens the splat photo [assetId] in the asset viewer once the sync brought it to this device; until then, says
/// where it will show ("In your timeline on {date}")
Future<void> showSplatPhotoAsset(
  BuildContext context,
  WidgetRef ref,
  String assetId, {
  required DateTime sceneDate,
}) async {
  final t = context.t;
  final locale = Localizations.localeOf(context).toLanguageTag();
  final messenger = ScaffoldMessenger.maybeOf(context);
  RemoteAsset? asset;
  try {
    asset = await ref.read(assetServiceProvider).getRemoteAsset(assetId);
  } catch (error) {
    _log.fine('The splat photo $assetId is not on this device yet: $error');
  }
  if (!context.mounted) {
    return;
  }
  if (asset == null) {
    messenger?.showSnackBar(SnackBar(content: Text(t.splat_save_date(date: splatSaveDateText(sceneDate, locale)))));
    return;
  }
  Navigator.of(context).maybePop();
  AssetViewer.setAsset(ref, asset);
  await context.pushRoute(
    AssetViewerRoute(
      initialIndex: 0,
      timelineService: ref.read(timelineFactoryProvider).fromAssets([asset], TimelineOrigin.deepLink),
    ),
  );
}

/// Where a scene to save is: a file of this device, or of a share (copied into the cache before the save)
final class SplatSaveScene {
  const SplatSaveScene({required this.path, required this.length, this.sourceId, this.modified});

  final String? sourceId;
  final String path;
  final int length;

  /// When the file last changed: the scene's date in the timeline
  final DateTime? modified;

  String get name => path.split(RegExp(r'[/\\]')).where((part) => part.isNotEmpty).lastOrNull ?? path;

  String get key => splatSaveKeyOf(sourceId: sourceId, path: path);

  bool get isPly => name.toLowerCase().endsWith('.ply');

  DateTime get date {
    final known = modified;
    if (known != null) {
      return known;
    }
    if (sourceId == null) {
      try {
        return File(path).lastModifiedSync();
      } catch (_) {
        // Gone: now
      }
    }
    return DateTime.now();
  }
}

/// The file of [scene] on this device: itself, or a copy of the share's file in the splat viewer's cache (deleted by
/// [release])
Future<File> splatSaveFileOf(ProviderContainer container, SplatSaveScene scene) async {
  final sourceId = scene.sourceId;
  if (sourceId == null) {
    return File(scene.path);
  }
  final cache = container.read(splatViewerCacheProvider);
  final out = await cache.fileFor('splat-save-copy-${DateTime.now().microsecondsSinceEpoch}-${scene.name}');
  final fileSystem = await container.read(networkConnectionsProvider).fileSystem(sourceId);
  await copySplatFromShare(
    readRange: (offset, length) => fileSystem.readRange(scene.path, offset, length),
    length: scene.length,
    out: out,
  );
  return out;
}

/// Deletes the copy [file] of [scene] once saved
void releaseSplatSaveFile(SplatSaveScene scene, File file) {
  if (scene.sourceId == null) {
    return;
  }
  try {
    file.deleteSync();
  } catch (_) {
    // The cache's prune takes it later
  }
}

/// Runs the save of [scene] with [poster] (null to draw one) in the jobs of the app; the last status, or null without
/// a server or when one of this scene runs
Future<SplatSaveStatus?> runSplatSave(
  ProviderContainer container,
  Translations t,
  String locale, {
  required SplatSaveScene scene,
  Uint8List? poster,
  SplatPosterKind posterKind = SplatPosterKind.view,
  String? up,
  required bool album,
  bool force = false,
  File? copied,
}) async {
  final jobs = container.read(splatSaveJobsProvider.notifier);
  if (jobs.isRunning(scene.key)) {
    return null;
  }
  // Before anything is awaited: see forget
  jobs.forget(scene.key);
  final software = await container.read(splatSaveSoftwareProvider.future).catchError((_) => ('Immuch360', 'Immuch360'));
  File? file;
  try {
    // The copy of a share's file the caller made already (the sheet, for its poster) is the caller's to delete
    file = copied ?? await splatSaveFileOf(container, scene);
    return await jobs.save(
      scene.key,
      splatSaveRequestOf(
        t,
        locale,
        scene: file,
        sceneName: scene.name,
        sceneDate: scene.date,
        poster: poster,
        posterKind: posterKind,
        up: up,
        album: album,
        mark: container.read(appConfigProvider).viewer.markSplatPhotos,
        force: force,
        software: software,
      ),
    );
  } catch (error) {
    _log.warning('${scene.name} could not be saved: $error');
    return SplatSaveStatus(SplatSaveState.failed, problem: SplatSaveProblem.other, detail: '$error');
  } finally {
    if (file != null && copied == null) {
      releaseSplatSaveFile(scene, file);
    }
  }
}

/// Save to Immich in the splat viewer's page for one viewing (see SplatViewerSaving)
class SplatViewerSaveSession implements SplatViewerSaving {
  SplatViewerSaveSession({
    required this._container,
    required this.t,
    required this.locale,
    required this.scene,
    required this.head,
    required this.onServer,
    required this.connected,
    required this.albumOn,
    required this._up,
  });

  final ProviderContainer _container;
  final Translations t;
  final String locale;
  final SplatSaveScene scene;
  final SplatHead head;

  /// The scene of a splat photo: "On your Immich server", nothing to save
  final bool onServer;
  final bool connected;

  /// The album switch of the panel, as the user left it last time
  bool albumOn;
  String? _up;
  var _turned = false;
  Uint8List? _poster;
  var _viewerOpen = true;
  SplatSaveStatus? _last;

  /// The viewer closed: the end of a save that still runs is told by the main window
  void viewerClosed() => _viewerOpen = false;

  @override
  Map<String, Object?> get session => {
    'offered': !onServer,
    'onServer': onServer,
    'connected': connected,
    'mark': _container.read(appConfigProvider).viewer.markSplatPhotos,
    'album': albumOn,
    'poster': 'poster',
    'state': 'save',
    'name': scene.name,
    'details': t.splat_photo_details(count: splatCountText(head.gaussians, locale), size: formatBytes(scene.length)),
    'date': t.splat_save_date(date: splatSaveDateText(scene.date, locale)),
    'warning': splatSaveSizeWarning(t, scene.length),
    'texts': {
      'save': t.splat_save,
      'title': t.splat_save_title,
      'explain': '${t.splat_save_explain} ${t.splat_save_view}',
      'album': t.splat_save_album(name: t.splat_save_album_name),
      'cancel': t.cancel,
      'close': t.close,
      'again': t.splat_save_again,
      'notConnected': t.network_upload_needs_server,
      'noCapture': t.splat_save_no_capture,
      'onServer': t.splat_photo_on_server,
    },
  };

  @override
  bool takePoster(Uint8List jpeg) {
    if (onServer) {
      return false;
    }
    _poster = jpeg;
    return true;
  }

  @override
  void upright(String value) {
    _turned = true;
    _up = value;
  }

  /// The orientation the user chose for this scene on this device before this viewing, unless turned since
  void rememberedUp(String? value) {
    if (!_turned && value != null) {
      _up = value;
    }
  }

  @override
  void onEvent(SplatViewerEvent event) {
    switch (event) {
      case SplatViewerSave(:final album, :final again):
        unawaited(_save(album: album, force: again));
      case SplatViewerCancelSave():
        _container.read(splatSaveJobsProvider.notifier).cancel(scene.key);
      default:
        break;
    }
  }

  Future<void> _save({required bool album, required bool force}) async {
    final poster = _poster;
    if (poster == null || onServer) {
      return;
    }
    // What the page reads until the job tells more, never the end of a save before ("Save another copy")
    _last = const SplatSaveStatus(SplatSaveState.checking);
    unawaited(_container.read(splatSaveRecordsProvider).setAlbumOn(album).catchError((_) {}));
    final status = await runSplatSave(
      _container,
      t,
      locale,
      scene: scene,
      poster: poster,
      up: _up,
      album: album,
      force: force,
    );
    _last = status;
    if (status != null && !_viewerOpen) {
      splatSaveTellEnd(
        t,
        locale,
        status,
        name: scene.name,
        sceneDate: scene.date,
        plyBytes: scene.isPly ? scene.length : null,
      );
    }
  }

  @override
  Map<String, Object?> state() {
    final status =
        _container.read(splatSaveJobsProvider)[scene.key] ?? _last ?? const SplatSaveStatus(SplatSaveState.idle);
    return {
      'state': status.state.name,
      'percent': (status.share * 100).round(),
      'text': splatSaveLine(
        t,
        locale,
        status,
        name: scene.name,
        sceneDate: scene.date,
        plyBytes: scene.isPly ? scene.length : null,
      ),
      'assetId': status.assetId,
    };
  }
}

/// Save to Immich for the viewing of [source] in the splat viewer: null where the splats are off
SplatViewerSaveSession? splatViewerSavingFor(
  BuildContext context,
  WidgetRef ref, {
  required SplatViewerSource source,
  required SplatHead head,
  required int fileBytes,
  required bool onServer,
}) {
  if (!ref.read(appConfigProvider).viewer.gaussianSplats) {
    return null;
  }
  final saving = SplatViewerSaveSession(
    container: ProviderScope.containerOf(context, listen: false),
    t: context.t,
    locale: Localizations.localeOf(context).toLanguageTag(),
    scene: SplatSaveScene(path: source.path, length: fileBytes, sourceId: source.sourceId, modified: source.modified),
    head: head,
    onServer: onServer,
    connected: ref.read(splatSaveServerProvider)() != null,
    albumOn: true,
    up: source.up,
  );
  // Read while the viewer opens, nothing awaited before it: the album switch remembered, the orientation chosen
  unawaited(
    ref.read(splatSaveRecordsProvider).albumOn().then((on) => saving.albumOn = on, onError: (Object _) => null),
  );
  unawaited(
    ref
        .read(splatUprightStoreProvider)
        .read(source.name, fileBytes)
        .then((up) => saving.rememberedUp(up), onError: (Object _) => null),
  );
  return saving;
}

/// What the sheet shows before Save: the scene on this device, its head, and its poster drawn as the job would draw
/// it (or its card); a problem when the scene could not be read
final class _SplatSavePrepared {
  const _SplatSavePrepared({this.file, this.head, this.poster, this.posterKind = SplatPosterKind.render, this.problem});

  final File? file;
  final SplatHead? head;
  final Uint8List? poster;
  final SplatPosterKind posterKind;
  final String? problem;
}

Future<String?> _rememberedUpOf(ProviderContainer container, SplatSaveScene scene) async {
  try {
    return await container.read(splatUprightStoreProvider).read(scene.name, scene.length);
  } catch (_) {
    return null;
  }
}

Future<_SplatSavePrepared> _prepareSplatSave(
  ProviderContainer container,
  Translations t,
  String locale,
  SplatSaveScene scene,
) async {
  final mark = container.read(appConfigProvider).viewer.markSplatPhotos;
  try {
    final file = await splatSaveFileOf(container, scene);
    // A PLY is drawn from the PLY itself: its SPZ is made by the save
    final head = await splatSaveHeadOf(file);
    final posters = container.read(splatSavePostersProvider);
    try {
      if (head == null || head.isZstd) {
        throw const FormatException('no drawing for this scene');
      }
      final poster = await posters.poster(file, head, await _rememberedUpOf(container, scene), mark);
      return _SplatSavePrepared(file: file, head: head, poster: poster);
    } catch (error) {
      _log.fine('The card for ${scene.name}: $error');
      final card = await posters.card(
        scene.name,
        t.splat_count(count: splatCountText(head?.gaussians ?? 0, locale)),
        mark,
      );
      return _SplatSavePrepared(file: file, head: head, poster: card, posterKind: SplatPosterKind.card);
    }
  } catch (error) {
    _log.warning('The sheet of ${scene.name}: $error');
    return _SplatSavePrepared(problem: t.splat_save_failed(reason: '$error'));
  }
}

/// The sheet of Save to Immich for [scene]: the poster drawn from its first view (or its card), the name, the size and
/// the gaussians, the date, the album switch, Cancel and Save; then the progress and the result
Future<void> showSplatSaveSheet(BuildContext context, WidgetRef ref, SplatSaveScene scene) async {
  final t = context.t;
  final locale = Localizations.localeOf(context).toLanguageTag();
  if (ref.read(splatSaveServerProvider)() == null) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(t.network_upload_needs_server)));
    return;
  }
  final container = ProviderScope.containerOf(context, listen: false);
  // Drawn while the sheet opens
  final prepared = _prepareSplatSave(container, t, locale, scene);
  final albumOn = await ref.read(splatSaveRecordsProvider).albumOn().catchError((_) => true);
  if (!context.mounted) {
    unawaited(prepared.then((ready) => ready.file == null ? null : releaseSplatSaveFile(scene, ready.file!)));
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _SplatSaveSheet(scene: scene, albumOn: albumOn, prepared: prepared),
  );
}

class _SplatSaveSheet extends ConsumerStatefulWidget {
  const _SplatSaveSheet({required this.scene, required this.albumOn, required this.prepared});

  final SplatSaveScene scene;
  final bool albumOn;
  final Future<_SplatSavePrepared> prepared;

  @override
  ConsumerState<_SplatSaveSheet> createState() => _SplatSaveSheetState();
}

class _SplatSaveSheetState extends ConsumerState<_SplatSaveSheet> {
  late bool _album = widget.albumOn;
  Uint8List? _poster;
  var _posterKind = SplatPosterKind.render;
  SplatHead? _head;
  File? _file;
  var _preparing = true;
  var _saving = false;
  var _gone = false;
  SplatSaveStatus? _result;
  String? _problem;

  SplatSaveScene get scene => widget.scene;

  @override
  void initState() {
    super.initState();
    unawaited(
      widget.prepared.then((ready) {
        _file = ready.file;
        if (_gone) {
          // Closed before the poster was ready
          final file = ready.file;
          if (file != null) {
            releaseSplatSaveFile(scene, file);
          }
          return;
        }
        setState(() {
          _head = ready.head;
          _poster = ready.poster;
          _posterKind = ready.posterKind;
          _problem = ready.problem;
          _preparing = false;
        });
      }),
    );
  }

  @override
  void dispose() {
    _gone = true;
    final file = _file;
    if (file != null && !_saving) {
      releaseSplatSaveFile(scene, file);
    }
    super.dispose();
  }

  Future<String?> _upOf() => _rememberedUpOf(ProviderScope.containerOf(context, listen: false), scene);

  Future<void> _save({bool force = false}) async {
    final t = context.t;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() {
      _saving = true;
      _result = null;
    });
    unawaited(ref.read(splatSaveRecordsProvider).setAlbumOn(_album).catchError((_) {}));
    final status = await runSplatSave(
      container,
      t,
      locale,
      scene: scene,
      poster: _poster,
      posterKind: _posterKind,
      up: await _upOf(),
      album: _album,
      force: force,
      copied: scene.sourceId == null ? null : _file,
    );
    if (!mounted) {
      // The sheet went while it saved: the copy is deleted here, the end told by the main window
      final file = _file;
      if (file != null) {
        releaseSplatSaveFile(scene, file);
      }
      if (status != null) {
        splatSaveTellEnd(
          t,
          locale,
          status,
          name: scene.name,
          sceneDate: scene.date,
          plyBytes: scene.isPly ? scene.length : null,
        );
      }
      return;
    }
    setState(() {
      _saving = false;
      _result = status;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final theme = Theme.of(context);
    final status = ref.watch(splatSaveJobsProvider)[scene.key];
    final shown = _saving ? status : _result;
    final line = shown == null
        ? null
        : splatSaveLine(
            t,
            locale,
            shown,
            name: scene.name,
            sceneDate: scene.date,
            plyBytes: scene.isPly ? scene.length : null,
          );
    final head = _head;
    final warning = splatSaveSizeWarning(t, scene.length);
    final ended = _result != null && _result!.state.isFinal;
    final again =
        ended && (_result!.state == SplatSaveState.alreadyThere || _result!.state == SplatSaveState.duplicate);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.splat_save_title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            if (_preparing)
              const AspectRatio(aspectRatio: 1.5, child: Center(child: CircularProgressIndicator()))
            else if (_poster != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(_poster!, fit: BoxFit.contain),
              ),
            const SizedBox(height: 10),
            Text(scene.name, style: theme.textTheme.titleMedium),
            if (head != null)
              Text(
                t.splat_photo_details(count: splatCountText(head.gaussians, locale), size: formatBytes(scene.length)),
              ),
            Text(t.splat_save_date(date: splatSaveDateText(scene.date, locale))),
            if (warning != null) Text(warning, style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: 6),
            Text('${t.splat_save_explain} ${t.splat_save_drawn}', style: theme.textTheme.bodySmall),
            SwitchListTile(
              key: splatSaveSheetAlbumKey,
              contentPadding: EdgeInsets.zero,
              value: _album,
              onChanged: _saving ? null : (value) => setState(() => _album = value),
              title: Text(t.splat_save_album(name: t.splat_save_album_name)),
            ),
            if (_problem != null) Text(_problem!, style: TextStyle(color: theme.colorScheme.error)),
            if (line != null) Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(line)),
            if (_saving && status != null && status.state == SplatSaveState.uploading)
              LinearProgressIndicator(value: status.share),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (_saving)
                  TextButton(
                    onPressed: () => ref.read(splatSaveJobsProvider.notifier).cancel(scene.key),
                    child: Text(t.cancel),
                  )
                else ...[
                  TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(ended ? t.close : t.cancel)),
                  if (again) TextButton(onPressed: () => _save(force: true), child: Text(t.splat_save_again)),
                  if (ended && _result!.assetId != null && _result!.state != SplatSaveState.inTrash)
                    TextButton(
                      key: splatSaveSheetShowKey,
                      onPressed: () => showSplatPhotoAsset(context, ref, _result!.assetId!, sceneDate: scene.date),
                      child: Text(t.splat_save_show),
                    ),
                  if (!ended)
                    FilledButton(
                      key: splatSaveSheetSaveKey,
                      onPressed: _preparing || _problem != null ? null : _save,
                      child: Text(t.splat_save),
                    ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
