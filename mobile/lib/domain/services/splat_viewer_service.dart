// One viewing in the splat viewer of the computers, phones and tablets, from the button to the close (plan of 2
// November 2026): the splat made ready (copied from its share and reduced when it holds more than this device shows),
// the session registered on the media bridge, the host opened on its page, the page's events followed (the
// orientation chosen kept for the file, ready and the frame rates logged under SplatViewer), and everything taken
// down once the host says the viewer closed.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/splat/splat_reducer.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/splat_viewer_files.dart';
import 'package:immich_mobile/domain/services/splat_viewer_host.dart';
import 'package:immich_mobile/domain/services/splat_viewer_session.dart';
import 'package:logging/logging.dart';

final _log = Logger('SplatViewer');

/// A splat to show: a file of the share [sourceId] at [path], or a file of this device at [path]
class SplatViewerSource {
  const SplatViewerSource.share(String this.sourceId, this.path, {this.modified});

  const SplatViewerSource.local(this.path) : sourceId = null, modified = null;

  final String? sourceId;
  final String path;

  /// When the share last changed the file, for the key of its reduced copy
  final DateTime? modified;

  String get name => path.split(RegExp(r'[/\\]')).where((part) => part.isNotEmpty).lastOrNull ?? path;

  /// The source in the key of its reduced copy
  String get key => sourceId == null ? 'file:$path' : 'share:$sourceId:$path';
}

/// What the page needs from the app beyond the scene: the texts in the app's language, its colours, the device class
/// ("phone" or "computer"), whether the gyroscope button shows, the limits of the drawing
class SplatViewerLook {
  const SplatViewerLook({
    required this.texts,
    required this.locale,
    required this.dark,
    required this.primary,
    required this.device,
    required this.gyroscope,
    required this.maxStdDev,
    required this.pixelRatioMax,
  });

  final Map<String, String> texts;
  final String locale;
  final bool dark;

  /// "#4250af"
  final String primary;
  final String device;
  final bool gyroscope;
  final double maxStdDev;

  /// The most pixels drawn per CSS pixel: 1 on phones and tablets until a real phone was measured, 2 on computers
  /// (a panel at 200 % was drawn at a quarter of its pixels); the page's quality steps go down from there
  final double pixelRatioMax;
}

/// How a viewing ended
enum SplatViewerEnd {
  /// The user went back
  closed,

  /// The web view's process died: "This splat needed more memory than this device gives it"
  rendererGone,

  /// The page stopped answering or its graphics process ended: "The graphics of this device stopped drawing the splat"
  stalled,

  /// No web view that can show the page
  noWebView,

  /// The web view lacks WebGL 2 or WebAssembly SIMD ([SplatViewerOutcome.unsupported] says which)
  unsupported,

  /// Not enough free space for the copy or the reduction
  noSpace,

  /// The file could not be read or reduced
  failed,

  /// The user cancelled the preparation
  cancelled,
}

class SplatViewerOutcome {
  const SplatViewerOutcome(this.end, {this.unsupported, this.detail, this.noPicture = false});

  final SplatViewerEnd end;

  /// The page never said it showed the scene, though its window stayed open longer than a scene takes to show
  /// (SplatViewerService.noPictureAfter): on Linux, WebKitGTK's DMABUF renderer with some NVIDIA drivers
  final bool noPicture;

  /// 'webgl2' or 'simd'
  final String? unsupported;

  /// For the log
  final String? detail;

  @override
  String toString() =>
      'SplatViewerOutcome($end${unsupported == null ? '' : ', $unsupported'}${noPicture ? ', no picture' : ''})';
}

/// See the top of this file
class SplatViewerService {
  SplatViewerService({
    required this._bridge,
    required this._host,
    required this._loadPage,
    required this._uprights,
    required this._cache,
    required this._fileSystem,
    required this._shareUrl,
    Future<int> Function({
      required File source,
      required SplatHead head,
      required int keep,
      required File out,
      void Function(double done)? progress,
      SplatPrepareCancel? cancel,
    })?
    reduce,
    this._freeBytes,
    this.noPictureAfter = const Duration(seconds: 10),
  }) : _reduce = reduce ?? reduceSplatInIsolate;

  final MediaBridge _bridge;
  final SplatViewerHost _host;
  final Future<Map<String, Uint8List>> Function() _loadPage;
  final SplatUprightStore _uprights;
  final SplatViewerCache _cache;
  final Future<NetworkFileSystem> Function(String sourceId) _fileSystem;

  /// The bridge URL of a file of a share, the share registered on the bridge first (NetworkConnections.mediaUrl)
  final Future<Uri> Function(String sourceId, String path) _shareUrl;
  final Future<int> Function({
    required File source,
    required SplatHead head,
    required int keep,
    required File out,
    void Function(double done)? progress,
    SplatPrepareCancel? cancel,
  })
  _reduce;

  /// The free bytes of the drive of a folder, null when they cannot be read (no check then)
  final Future<int?> Function(Directory folder)? _freeBytes;

  /// A page that has not said ready this long after its window opened is logged, and said after it closed
  final Duration noPictureAfter;

  /// Shows [source] (whose head is [head], [fileBytes] long) with at most [cap] gaussians, the page in the words and
  /// colours of [look]; [progress] is told the steps of a preparation (the copy from a share, the reduction),
  /// [cancel] stops one, and [onOpening] is told when the viewer opens. Completes once the viewer closed.
  Future<SplatViewerOutcome> show({
    required SplatViewerSource source,
    required SplatHead head,
    required int fileBytes,
    required int cap,
    required SplatViewerLook look,
    void Function(SplatPrepareStep step, double done)? progress,
    SplatPrepareCancel? cancel,
    void Function()? onOpening,
  }) async {
    final name = source.name;
    final ext = head.format.json;
    final sceneName = 'scene.$ext';
    File? sceneFile;
    String sceneUrl;
    var shown = head.gaussians;
    final reduced = head.gaussians > cap;
    await _bridge.start();
    if (reduced) {
      final File prepared;
      try {
        prepared = await _prepare(source, head, fileBytes, cap, progress, cancel);
      } on SplatReduceCancelled {
        return const SplatViewerOutcome(SplatViewerEnd.cancelled);
      } on _NoSpace catch (error) {
        _log.warning('The splat $name could not be prepared: $error');
        return SplatViewerOutcome(SplatViewerEnd.noSpace, detail: '$error');
      } on FileSystemException catch (error) {
        final noSpace = _isNoSpace(error);
        _log.warning('The splat $name could not be prepared: $error');
        return SplatViewerOutcome(noSpace ? SplatViewerEnd.noSpace : SplatViewerEnd.failed, detail: '$error');
      } catch (error) {
        _log.warning('The splat $name could not be prepared: $error');
        return SplatViewerOutcome(SplatViewerEnd.failed, detail: '$error');
      }
      // A Cancel or a Back that came as the preparation ended: the reduced copy is kept, nothing opens
      if (cancel?.isCancelled ?? false) {
        return const SplatViewerOutcome(SplatViewerEnd.cancelled);
      }
      sceneFile = prepared;
      sceneUrl = sceneName;
      shown = cap;
    } else if (source.sourceId == null) {
      sceneFile = File(source.path);
      sceneUrl = sceneName;
    } else {
      // A file of a share keeps its own URL on the bridge, the same origin as the page
      sceneUrl = (await _shareUrl(source.sourceId!, source.path)).path;
    }

    final id = newSplatViewerSessionId();
    final upright = await _uprights.read(name, fileBytes);
    final session = {
      'v': 1,
      'scene': {
        'url': sceneUrl,
        'type': ext,
        'name': name,
        'bytes': fileBytes,
        'gaussians': head.gaussians,
        'shown': shown,
        'reduced': reduced,
      },
      'upright': upright,
      'device': look.device,
      'limits': {'pixelRatioMax': look.pixelRatioMax, 'maxStdDev': look.maxStdDev},
      'gyroscope': look.gyroscope,
      'locale': look.locale,
      'texts': look.texts,
      'theme': {'dark': look.dark, 'primary': look.primary},
      'events': 'events',
    };
    String? unsupported;
    var closing = false;
    var ready = false;
    void onEvent(SplatViewerEvent event) {
      switch (event) {
        case SplatViewerReady(:final fields):
          ready = true;
          _log.info(
            'Ready: $name ${fields['loadMs']} ms, ${fields['gaussians']} gaussians, ${fields['renderer']}, '
            'non blank ${fields['nonBlank']}, ${fields['drawingBuffer']}, ${fields['placement']}',
          );
        case SplatViewerStats(:final fields):
          _log.info('Frames of $name: $fields');
        case SplatViewerUpright(:final value):
          unawaited(_uprights.write(name, fileBytes, value));
        case SplatViewerGyroscope(:final on):
          _log.fine('Gyroscope ${on ? 'on' : 'off'}');
        case SplatViewerUnsupported(:final reason):
          _log.warning('This web view cannot show splats: $reason');
          unsupported = reason;
        case SplatViewerError(:final message):
          _log.warning('The splat viewer page: $message');
        case SplatViewerClose():
          if (!closing) {
            closing = true;
            unawaited(_host.close());
          }
      }
    }

    final page = await _loadPage();
    _bridge.registerGenerated(
      id,
      SplatViewerSession(
        id: id,
        page: page,
        session: session,
        scene: sceneFile,
        sceneName: sceneFile == null ? null : sceneName,
        onEvent: onEvent,
      ),
    );
    onOpening?.call();
    final watch = Stopwatch()..start();
    final noPicture = Timer(noPictureAfter, () {
      if (!ready && !closing) {
        _log.warning('The splat viewer page of $name said nothing in ${noPictureAfter.inSeconds} s');
      }
    });
    try {
      _log.info('Opening $name: ${head.gaussians} gaussians, ${reduced ? 'reduced to $cap' : 'whole'}');
      final how = await _host.open(_bridge.urlFor(id, 'index.html'), title: name);
      _log.info('The splat viewer closed: $how');
      if (unsupported != null) {
        return SplatViewerOutcome(SplatViewerEnd.unsupported, unsupported: unsupported);
      }
      return SplatViewerOutcome(switch (how) {
        SplatHostClosed.user => SplatViewerEnd.closed,
        SplatHostClosed.rendererGone => SplatViewerEnd.rendererGone,
        SplatHostClosed.stalled => SplatViewerEnd.stalled,
        SplatHostClosed.noWebView => SplatViewerEnd.noWebView,
        SplatHostClosed.error => SplatViewerEnd.failed,
      }, noPicture: !ready && how == SplatHostClosed.user && watch.elapsed >= noPictureAfter);
    } finally {
      noPicture.cancel();
      _bridge.unregisterGenerated(id);
      if (reduced) {
        unawaited(_cache.prune().catchError((Object error) => _log.fine('Prune: $error')));
      }
    }
  }

  /// The date and the fingerprint of [source] for the key of its reduced copy: the date of a file of this device, or
  /// the one its share gives (null when it gives none), and splatFingerprint of its content. A file in the app's own
  /// cache folder is a copy the app made (a splat picked on Android is copied again at each pick): its date is the
  /// time of that copy, not a change of the splat, so it is left out and the fingerprint and the size tell the
  /// versions apart (second review of 3 November 2026)
  Future<(DateTime?, String)> _identityOf(SplatViewerSource source, int fileBytes) async {
    final sourceId = source.sourceId;
    if (sourceId == null) {
      final file = File(source.path);
      final modified = await _cache.isAppCopy(source.path) ? null : file.statSync().modified;
      final handle = await file.open();
      try {
        final fingerprint = await splatFingerprint((offset, length) async {
          await handle.setPosition(offset);
          return handle.read(length);
        }, await handle.length());
        return (modified, fingerprint);
      } finally {
        await handle.close();
      }
    }
    final fileSystem = await _fileSystem(sourceId);
    var modified = source.modified;
    if (modified == null) {
      try {
        modified = (await fileSystem.stat(source.path)).modified;
      } catch (error) {
        _log.fine('No date for ${source.name}: $error');
      }
    }
    final fingerprint = await splatFingerprint(
      (offset, length) => fileSystem.readRange(source.path, offset, length),
      fileBytes,
    );
    return (modified, fingerprint);
  }

  /// The reduced copy of [source]: the one kept when there is one, else made now (copied from its share first)
  Future<File> _prepare(
    SplatViewerSource source,
    SplatHead head,
    int fileBytes,
    int cap,
    void Function(SplatPrepareStep step, double done)? progress,
    SplatPrepareCancel? cancel,
  ) async {
    final (modified, fingerprint) = await _identityOf(source, fileBytes);
    final name = SplatViewerCache.nameOf(source.key, fileBytes, modified, cap, head.format, fingerprint: fingerprint);
    final kept = await _cache.find(name);
    if (kept != null) {
      _log.info('The reduced copy of ${source.name} is kept: no preparation');
      return kept;
    }
    if (cancel?.isCancelled ?? false) {
      throw const SplatReduceCancelled();
    }
    final sourceId = source.sourceId;
    // Room for the copy and the reduced file before the first byte (plan section 6)
    final needed = splatPrepareBytes(head, fileBytes: fileBytes, cap: cap, copied: sourceId != null);
    final free = await _freeBytesOf(await _cache.folder());
    if (free != null && free < needed) {
      throw _NoSpace(needed, free);
    }
    var input = File(source.path);
    File? copy;
    if (sourceId != null) {
      final fileSystem = await _fileSystem(sourceId);
      copy = await _cache.fileFor('copy-$name');
      progress?.call(SplatPrepareStep.copy, 0);
      await copySplatFromShare(
        readRange: (offset, length) => fileSystem.readRange(source.path, offset, length),
        length: fileBytes,
        out: copy,
        progress: (done) => progress?.call(SplatPrepareStep.copy, done),
        cancel: cancel,
      );
      input = copy;
    }
    try {
      final out = await _cache.fileFor(name);
      progress?.call(SplatPrepareStep.reduce, 0);
      final watch = Stopwatch()..start();
      final kept = await _reduce(
        source: input,
        head: head,
        keep: cap,
        out: out,
        progress: (done) => progress?.call(SplatPrepareStep.reduce, done),
        cancel: cancel,
      );
      _log.info('Reduced ${source.name} from ${head.gaussians} to $kept gaussians in ${watch.elapsedMilliseconds} ms');
      return out;
    } finally {
      if (copy != null) {
        try {
          await copy.delete();
        } on FileSystemException {
          // Pruned later
        }
      }
    }
  }

  Future<int?> _freeBytesOf(Directory folder) async {
    final read = _freeBytes;
    if (read == null) {
      return null;
    }
    try {
      return await read(folder);
    } catch (error) {
      _log.fine('The free space of ${folder.path} could not be read: $error');
      return null;
    }
  }

  static bool _isNoSpace(FileSystemException error) {
    final code = error.osError?.errorCode;
    // ENOSPC on Linux and Android (28), macOS (28), ERROR_DISK_FULL (112) and ERROR_HANDLE_DISK_FULL (39) on Windows
    return code == 28 || code == 112 || code == 39;
  }
}

/// Not enough free space for a preparation, found before it started
class _NoSpace implements Exception {
  const _NoSpace(this.needed, this.free);

  final int needed;
  final int free;

  @override
  String toString() => 'not enough free space: $needed bytes needed, $free free';
}
