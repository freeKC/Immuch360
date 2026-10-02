// What the photos and videos of a network share are, read from their files: whether they are 360°, and what they
// declare about their eyes and their coverage of the sphere. The rules are the server's, as for the files of the
// device (see LocalPanoramaService): a photo is 360° when its GPano XMP declares an equirectangular projection, a video
// when it declares a spherical projection (see probeSphericalMetadata). The viewers then show a file with the rules of
// resolveSphereView, from what it declares and its name.
//
// Reading a file costs a 128 KiB window or two for a photo, a few small reads for a video, with range reads on the
// share or on the media bridge. The results are kept in memory per file, until it changes.

import 'dart:async';
import 'dart:collection';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:logging/logging.dart';

final _log = Logger('NetworkMediaService');

/// What the file of a photo or a video of a share declares
class NetworkMediaInfo {
  const NetworkMediaInfo({this.gpano, this.probe});

  /// The GPano tags of a photo, null for a video and for a photo without any
  final GPanoTags? gpano;

  /// What a video declares (see [probeSphericalMetadata]), null for a photo
  final SphericalProbe? probe;

  /// Whether the file declares a 360° projection
  bool get is360 {
    final gpano = this.gpano;
    return (gpano != null && isEquirectangularGPano(gpano)) || (probe?.hasSphericalMetadata ?? false);
  }

  /// Whether a video declares two eyes (its st3d box), which the players then read
  bool get declaresStereo {
    final stereo = probe?.stereo;
    return stereo != null && stereo != StereoLayout.mono;
  }

  /// How the 360° viewers show the file named [fileName], of [width] x [height] pixels when known: see
  /// [resolveSphereView]
  SphereView sphereView(
    String fileName, {
    int? width,
    int? height,
    StereoLayout? chosenLayout,
    SphereCoverage? chosenCoverage,
  }) => resolveSphereView(
    fileName: fileName,
    width: width,
    height: height,
    gpanoCrop: gpano?.crop,
    probe: probe,
    chosenLayout: chosenLayout,
    chosenCoverage: chosenCoverage,
  );

  @override
  String toString() => 'NetworkMediaInfo(is360: $is360, gpano: $gpano, probe: $probe)';
}

/// A file of a share as the results are kept: they hold until its size or its date changes
typedef NetworkMediaKey = ({String sourceId, String path, int? size, DateTime? modified});

NetworkMediaKey networkMediaKey(NetworkEntry entry) =>
    (sourceId: entry.sourceId, path: entry.path, size: entry.size, modified: entry.modified);

/// Reads the file at [path] of [fileSystem] by ranges, for [NetworkMediaService.detect]
ByteRangeReader networkFileReader(NetworkFileSystem fileSystem, String path) =>
    (offset, length) => fileSystem.readRange(path, offset, length);

/// A read under way, shared by the callers that asked for the same file meanwhile
class _PendingRead {
  final _wanted = <bool Function()?>[];
  late final Future<NetworkMediaInfo?> result;

  void want(bool Function()? isWanted) => _wanted.add(isWanted);

  /// Whether any of the callers still wants the result
  bool get isWanted => _wanted.any((isWanted) => isWanted == null || isWanted());
}

class _Detected {
  const _Detected(this.info, {required this.thorough});

  final NetworkMediaInfo info;

  /// Whether the whole moov box of a video was allowed, see [NetworkMediaService.detect]
  final bool thorough;
}

/// Reads what the photos and videos of the shares declare (see [NetworkMediaInfo]) and keeps it in memory, per file
/// (see [NetworkMediaKey]).
///
/// A read that fails or takes longer than [timeout] gives null, and is tried again next time.
class NetworkMediaService {
  NetworkMediaService({
    this.timeout = const Duration(seconds: 15),
    this.maxEntries = 2000,
    this.maxConcurrent = 2,
    this.quickMoovLength = 1024 * 1024,
  });

  /// Longest wait for a file
  final Duration timeout;

  /// Past this many files, the results read first are forgotten
  final int maxEntries;

  /// Most files read at once for the browser (see [detect]); the reads of a viewer do not wait for them
  final int maxConcurrent;

  /// Most bytes of the moov box of a video read for the browser (see [detect]). The first video track comes first in
  /// it, and its sample description before its large tables: the head of the box tells for nearly every file.
  final int quickMoovLength;

  // Results per file, the latest last, and the reads under way
  final _results = <NetworkMediaKey, _Detected>{};
  final _pending = <(NetworkMediaKey, bool), _PendingRead>{};
  int _running = 0;
  final _waiting = Queue<Completer<void>>();

  /// What [entry] declares as far as it was read already, null when it was not
  NetworkMediaInfo? cached(NetworkEntry entry) => _results[networkMediaKey(entry)]?.info;

  /// What [entry], a photo or a video of a share, declares, read through [read]; null for any other file, and when
  /// the read fails or times out.
  ///
  /// The browser asks for many files: at most [maxConcurrent] are read at once, the others wait, and those no longer
  /// wanted once their turn comes ([isWanted] false, a thumbnail scrolled away) are not read at all. A video is read
  /// up to [quickMoovLength] bytes of its moov box. A viewer asks with [thorough]: right away, and the whole moov box
  /// up to [sphericalProbeMaxMoovLength] bytes when a quicker read found nothing.
  Future<NetworkMediaInfo?> detect(
    NetworkEntry entry,
    ByteRangeReader read, {
    bool thorough = false,
    bool Function()? isWanted,
  }) async {
    if (!entry.isMedia) {
      return null;
    }
    final key = networkMediaKey(entry);
    final known = _results[key];
    if (known != null && (known.thorough || !thorough || !entry.isVideo || known.info.is360)) {
      return known.info;
    }
    final pendingKey = (key, thorough);
    final pending = _pending[pendingKey];
    if (pending != null) {
      pending.want(isWanted);
      return pending.result;
    }
    final request = _PendingRead()..want(isWanted);
    _pending[pendingKey] = request;
    request.result = _detectInTurn(
      entry,
      read,
      thorough: thorough,
      isWanted: () => request.isWanted,
    ).whenComplete(() => _pending.remove(pendingKey));
    return request.result;
  }

  Future<NetworkMediaInfo?> _detectInTurn(
    NetworkEntry entry,
    ByteRangeReader read, {
    required bool thorough,
    required bool Function() isWanted,
  }) async {
    if (!thorough) {
      await _takeTurn();
    }
    try {
      if (!isWanted()) {
        return null;
      }
      final info = await _read(entry, read, thorough: thorough).timeout(timeout);
      _remember(networkMediaKey(entry), _Detected(info, thorough: thorough || !entry.isVideo));
      if (info.is360) {
        _log.fine('${entry.name} is 360°: $info');
      }
      return info;
    } catch (error) {
      _log.info('Could not read what ${entry.name} declares: $error');
      return null;
    } finally {
      if (!thorough) {
        _endTurn();
      }
    }
  }

  Future<NetworkMediaInfo> _read(NetworkEntry entry, ByteRangeReader read, {required bool thorough}) async {
    if (entry.isVideo) {
      final probe = await probeSphericalMetadata(
        read,
        maxMoovLength: thorough ? sphericalProbeMaxMoovLength : quickMoovLength,
      );
      return NetworkMediaInfo(probe: probe);
    }
    // Without a size, the head of the file only, where JPEG files carry their XMP
    return NetworkMediaInfo(gpano: await readGPanoTags(read, entry.size ?? 0));
  }

  void _remember(NetworkMediaKey key, _Detected detected) {
    // Removed first, so that the file goes last, as the latest
    _results
      ..remove(key)
      ..[key] = detected;
    while (_results.length > maxEntries) {
      _results.remove(_results.keys.first);
    }
  }

  Future<void> _takeTurn() async {
    if (_running < maxConcurrent) {
      _running++;
      return;
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    // The turn is handed over by _endTurn, the count of reads under way staying the same
    await turn.future;
  }

  void _endTurn() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _running--;
    }
  }
}

/// What the files of the shares declare, kept as long as the app runs
final networkMediaServiceProvider = Provider<NetworkMediaService>((_) => NetworkMediaService());

/// The HTTP client the viewers read the media bridge with, for the GPano tags and the spherical metadata of a file
/// (range requests). A plain one: the bridge is on this device. Tests replace it.
final networkBridgeClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});
