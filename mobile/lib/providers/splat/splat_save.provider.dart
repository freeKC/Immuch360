// "Save to Immich" of the splat scenes (plan of 3 November 2026, section 6): the jobs that run, by the key of their
// scene, so that closing the viewer does not stop one; the server, the records and the drawing of the posters they
// use; the words of each state in the app's language, for the page of the splat viewer, the sheet of the Quest's
// splat page and the snack bars.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/domain/models/splat/splat_reducer.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_poster_card.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_poster_draw.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_save_job.dart';
import 'package:immich_mobile/domain/services/splat_viewer_files.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/splat/splat_tile.widget.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/splat/splat_viewer.provider.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/services/splat_save_server.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:immich_ui/immich_ui.dart' show scaffoldMessengerKey;
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('SplatSave');

/// The scenes saved from this device, in the support folder
final splatSaveRecordsProvider = Provider<SplatSaveRecords>(
  (ref) =>
      SplatSaveRecords(() async => File(p.join((await getApplicationSupportDirectory()).path, 'splat_saves.json'))),
);

/// The server of the session now; null when none is logged in. Tests replace it.
final splatSaveServerProvider = Provider<SplatSaveServer? Function()>((ref) {
  return () {
    String? endpoint;
    try {
      endpoint = Store.tryGet(StoreKey.serverEndpoint);
    } catch (_) {
      // No store yet: no server
    }
    if (endpoint == null || endpoint.isEmpty) {
      return null;
    }
    return ImmichSplatSaveServer(
      url: endpoint,
      api: ref.read(apiServiceProvider),
      uploads: ref.read(foregroundUploadServiceProvider),
    );
  };
});

/// The largest PLY this device converts: a quarter of its memory, the PLY taking about three times its size while it
/// is read and packed; 512 MiB when the memory is not known
final splatSavePlyLimitProvider = Provider<Future<int> Function()>((ref) {
  return () async {
    int? memory;
    try {
      memory = await readTotalMemoryBytes();
      if (memory == null && CurrentPlatform.isDesktop) {
        memory = (await ref.read(splatComputerNowProvider)())?.physicalMemory;
      }
    } catch (error) {
      _log.fine('The memory of this device could not be read: $error');
    }
    return memory == null ? 512 << 20 : memory ~/ 12;
  };
});

/// The posters drawn and the cards made for the saves. Tests replace them.
final splatSavePostersProvider = Provider<({SplatPosterDrawer poster, SplatCardDrawer card})>(
  (ref) => (
    poster: (spz, head, up, mark) async =>
        (await drawSplatPosterInIsolate(path: spz.path, head: head, up: up, mark: mark)).jpeg,
    card: (name, line, mark) => drawSplatPosterCard(name: name, countLine: line, mark: mark),
  ),
);

/// "Immuch360 3.3.0" and "Immuch360 3.3.0 (windows)", the Software of the EXIF and the CreatorTool of the packet
final splatSaveSoftwareProvider = FutureProvider<(String, String)>((ref) async {
  var version = '';
  try {
    version = (await PackageInfo.fromPlatform().timeout(const Duration(seconds: 2))).version;
  } catch (_) {
    // The name alone
  }
  final software = version.isEmpty ? 'Immuch360' : 'Immuch360 $version';
  return (software, '$software (${Platform.operatingSystem})');
});

/// The key of the save of a scene: its place on this device or on its share
String splatSaveKeyOf({String? sourceId, required String path}) =>
    sourceId == null ? 'file:$path' : 'share:$sourceId:$path';

/// The jobs that run or ran this session, by the key of their scene (see [splatSaveKeyOf])
final splatSaveJobsProvider = NotifierProvider<SplatSaveJobs, Map<String, SplatSaveStatus>>(SplatSaveJobs.new);

class SplatSaveJobs extends Notifier<Map<String, SplatSaveStatus>> {
  final _jobs = <String, SplatSaveJob>{};

  @override
  Map<String, SplatSaveStatus> build() => const {};

  /// Whether a job of [key] runs now
  bool isRunning(String key) => _jobs.containsKey(key);

  /// Saves [request] under [key]: the job's last status, or null without a server or when one of [key] runs already
  Future<SplatSaveStatus?> save(
    String key,
    SplatSaveRequest request, {
    void Function(SplatSaveStatus status)? onStatus,
  }) async {
    if (_jobs.containsKey(key)) {
      return null;
    }
    final server = ref.read(splatSaveServerProvider)();
    if (server == null) {
      return null;
    }
    final posters = ref.read(splatSavePostersProvider);
    final job = SplatSaveJob(
      request: request,
      server: server,
      records: ref.read(splatSaveRecordsProvider),
      workFolder: () => ref.read(splatViewerCacheProvider).folder(),
      drawPoster: posters.poster,
      drawCard: posters.card,
      maxPlyBytes: await ref.read(splatSavePlyLimitProvider)(),
    );
    _jobs[key] = job;
    state = {...state, key: job.status};
    final listening = job.changes.listen((status) {
      state = {...state, key: status};
      onStatus?.call(status);
    });
    try {
      final status = await job.run();
      state = {...state, key: status};
      _log.info('${request.sceneName}: $status');
      return status;
    } finally {
      await listening.cancel();
      _jobs.remove(key);
    }
  }

  void cancel(String key) => _jobs[key]?.cancel();
}

/// [request] with the words of the app's language: the caption of the packet, the line of the card, the album's name
SplatSaveRequest splatSaveRequestOf(
  Translations t,
  String locale, {
  required File scene,
  required String sceneName,
  required DateTime sceneDate,
  Uint8List? poster,
  SplatPosterKind posterKind = SplatPosterKind.view,
  String? up,
  bool album = true,
  bool mark = true,
  bool force = false,
  (String, String)? software,
}) => SplatSaveRequest(
  scene: scene,
  sceneName: sceneName,
  sceneDate: sceneDate,
  caption: (count) => t.splat_photo_description(count: splatCountText(count, locale)),
  cardLine: (count) => t.splat_count(count: splatCountText(count, locale)),
  poster: poster,
  posterKind: posterKind,
  up: up,
  album: album,
  albumName: t.splat_save_album_name,
  mark: mark,
  force: force,
  software: software?.$1 ?? 'Immuch360',
  creatorTool: software?.$2 ?? 'Immuch360',
);

/// The day of [date] in [locale], "3 Nov 2026"
String splatSaveDateText(DateTime date, String locale) {
  try {
    return DateFormat.yMMMd(locale).format(date.toLocal());
  } catch (_) {
    return DateFormat.yMMMd('en').format(date.toLocal());
  }
}

/// What to say of [status] for the scene [name] ("room.spz") whose date is [sceneDate]; null for nothing (idle, a
/// cancel)
String? splatSaveLine(
  Translations t,
  String locale,
  SplatSaveStatus status, {
  required String name,
  required DateTime sceneDate,
  int? plyBytes,
}) {
  final percent = '${(status.share * 100).round()} %';
  return switch (status.state) {
    SplatSaveState.idle || SplatSaveState.cancelled => null,
    SplatSaveState.converting ||
    SplatSaveState.checking ||
    SplatSaveState.drawing => t.splat_save_preparing(name: name),
    SplatSaveState.writing => '${t.splat_save_preparing(name: name)}: $percent',
    SplatSaveState.uploading => '${t.network_upload_sending_file(name: splatPhotoNameFor(name))}: $percent',
    SplatSaveState.done when plyBytes != null && status.sceneBytes != null =>
      '${t.splat_save_done(date: splatSaveDateText(status.savedAt ?? sceneDate, locale))}. '
          '${t.splat_save_ply(size: formatBytes(status.sceneBytes!), plySize: formatBytes(plyBytes))}',
    SplatSaveState.done => t.splat_save_done(date: splatSaveDateText(status.savedAt ?? sceneDate, locale)),
    SplatSaveState.duplicate || SplatSaveState.alreadyThere => t.splat_save_already(
      name: name,
      date: splatSaveDateText(status.savedAt ?? DateTime.now(), locale),
    ),
    SplatSaveState.inTrash => t.network_upload_in_trash_mark,
    SplatSaveState.failed => switch (status.problem) {
      SplatSaveProblem.plyTooLarge => t.splat_save_ply_too_large,
      SplatSaveProblem.refusedSize => t.splat_save_refused_size(size: formatBytes(status.carrierBytes ?? 0)),
      _ => t.splat_save_failed(reason: status.detail ?? status.problem?.name ?? ''),
    },
  };
}

/// The warning of a large scene, before it is saved: null below 95 MB
String? splatSaveSizeWarning(Translations t, int bytes) =>
    bytes > splatPhotoWarnLength ? t.splat_save_large(size: formatBytes(bytes)) : null;

/// The head of [file], the splat this reads, or null
Future<SplatHead?> splatSaveHeadOf(File file) async {
  final length = await file.length();
  final raf = await file.open();
  try {
    final head = await raf.read(length < splatHeadBytes ? length : splatHeadBytes);
    final probe = probeSplatHead(head, length);
    return probe is SplatHead ? probe : null;
  } finally {
    await raf.close();
  }
}

/// Tells the end of a save whose page or sheet is gone, in a snack bar of the main window
void splatSaveTellEnd(
  Translations t,
  String locale,
  SplatSaveStatus status, {
  required String name,
  required DateTime sceneDate,
  int? plyBytes,
}) {
  final line = splatSaveLine(t, locale, status, name: name, sceneDate: sceneDate, plyBytes: plyBytes);
  if (line == null || !status.state.isFinal) {
    return;
  }
  scaffoldMessengerKey.currentState?.showSnackBar(SnackBar(content: Text(line)));
}

/// Saves the splat [entry] of the share [fileSystem] as a splat photo with a drawn poster, for "Upload to Immich" of the
/// shares and folders (plan of 3 November 2026, section 6.2): copied into the cache, then the job, in the app's
/// language; the album switch as the user left it. [cancel] stops it; [onProgress] the part sent.
Future<SplatSaveStatus> saveSplatFromShare(
  Ref ref,
  NetworkFileSystem fileSystem,
  NetworkEntry entry, {
  required Completer<void> cancel,
  void Function(double share)? onProgress,
}) async {
  final key = splatSaveKeyOf(sourceId: entry.sourceId, path: entry.path);
  final jobs = ref.read(splatSaveJobsProvider.notifier);
  final cache = ref.read(splatViewerCacheProvider);
  final t = StaticTranslations.instance;
  final locale = Intl.getCurrentLocale();
  final size = entry.size ?? (await fileSystem.stat(entry.path)).size;
  if (size == null) {
    return const SplatSaveStatus(SplatSaveState.failed, problem: SplatSaveProblem.unreadable, detail: 'no size');
  }
  final copy = await cache.fileFor('splat-save-copy-${DateTime.now().microsecondsSinceEpoch}-${entry.name}');
  try {
    final copyCancel = SplatPrepareCancel();
    final stop = cancel.future.then((_) {
      copyCancel.cancel();
      jobs.cancel(key);
    });
    unawaited(stop);
    await copySplatFromShare(
      readRange: (offset, length) => fileSystem.readRange(entry.path, offset, length),
      length: size,
      out: copy,
      cancel: copyCancel,
    );
    if (cancel.isCompleted) {
      return const SplatSaveStatus(SplatSaveState.cancelled);
    }
    final software = await ref.read(splatSaveSoftwareProvider.future).catchError((_) => ('Immuch360', 'Immuch360'));
    final status = await jobs.save(
      key,
      splatSaveRequestOf(
        t,
        locale,
        scene: copy,
        sceneName: entry.name,
        sceneDate: entry.modified ?? DateTime.now(),
        album: await ref.read(splatSaveRecordsProvider).albumOn().catchError((_) => true),
        mark: ref.read(appConfigProvider).viewer.markSplatPhotos,
        software: software,
      ),
      onStatus: (status) {
        if (status.state == SplatSaveState.uploading) {
          onProgress?.call(status.share);
        }
      },
    );
    return status ?? const SplatSaveStatus(SplatSaveState.failed, problem: SplatSaveProblem.other, detail: 'busy');
  } on SplatReduceCancelled {
    return const SplatSaveStatus(SplatSaveState.cancelled);
  } finally {
    try {
      if (copy.existsSync()) {
        copy.deleteSync();
      }
    } catch (_) {
      // The cache's prune takes it later
    }
  }
}
