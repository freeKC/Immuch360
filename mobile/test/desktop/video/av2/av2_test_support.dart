// What the tests of the AV2 playback share (lot AD3): the fixtures of lot AD0, a longer stream made of a fixture
// repeated (each copy a closed group of pictures that starts with its key frame and its sequence header, as the checks
// of lot AD2 repeat it for the real companion), a share over bytes, and a runner that gives the compiled fake companion
// (IMMUCH360_FAKE_AV2) the mode of a test through its environment.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:path/path.dart' as p;

/// The compiled fake companion, when the CI or the owner gave it
final fakeAv2Program = Platform.environment['IMMUCH360_FAKE_AV2'];

/// Why the tests on the compiled fake are skipped, false when they run
Object get skipWithoutFakeAv2 => fakeAv2Program == null ? 'no compiled fake companion (IMMUCH360_FAKE_AV2)' : false;

Uint8List av2Fixture(String name) => File(p.join('test', 'fixtures', 'av2', name)).readAsBytesSync();

/// [ivf] with its packets repeated [times] over, their pts moved on by the pictures of each copy, and the number of
/// pictures of the header to match: a stream of 12 x [times] pictures, a key frame every 6
Uint8List repeatAv2Ivf(Uint8List ivf, int times) {
  final data = ByteData.sublistView(ivf);
  final headerLength = data.getUint16(6, Endian.little);
  final frames = data.getUint32(24, Endian.little);
  final packets = <(int pts, Uint8List bytes)>[];
  var at = headerLength;
  while (at + 12 <= ivf.length) {
    final size = data.getUint32(at, Endian.little);
    final pts = data.getUint64(at + 4, Endian.little);
    packets.add((pts, Uint8List.sublistView(ivf, at + 12, at + 12 + size)));
    at += 12 + size;
  }
  final out = BytesBuilder()..add(Uint8List.sublistView(ivf, 0, headerLength));
  for (var copy = 0; copy < times; copy++) {
    for (final (pts, bytes) in packets) {
      final header = ByteData(12)
        ..setUint32(0, bytes.length, Endian.little)
        ..setUint64(4, pts + copy * frames, Endian.little);
      out
        ..add(header.buffer.asUint8List())
        ..add(bytes);
    }
  }
  final result = out.toBytes();
  ByteData.sublistView(result).setUint32(24, frames * times, Endian.little);
  return result;
}

/// A share of one file held in memory, as a NetworkFileSystem the bridge would read
class MemoryShare implements NetworkFileSystem {
  MemoryShare(this.bytes, {this.path = '/clips/video.ivf'});

  final Uint8List bytes;
  final String path;
  var reads = 0;

  @override
  final NetworkSource source = const NetworkSource(
    id: 'av2-share',
    type: NetworkSourceType.smb,
    name: 'av2',
    host: 'nas',
  );

  @override
  Future<List<NetworkEntry>> list(String path) async => const [];

  @override
  Future<NetworkEntry> stat(String path) async =>
      NetworkEntry(sourceId: source.id, path: path, isDirectory: false, size: bytes.length);

  @override
  Future<Uint8List> readRange(String path, int offset, int length) async {
    reads++;
    final start = math.min(offset, bytes.length);
    return Uint8List.sublistView(bytes, start, math.min(bytes.length, start + length));
  }

  @override
  Future<void> close() async {}
}

/// A runner that starts the program of each launch as [runner] does, with [environment] added: the mode of the fake
class EnvironmentRunner implements ProcessRunner {
  EnvironmentRunner(this.runner, this.environment);

  final ProcessRunner runner;
  final Map<String, String> environment;
  final launches = <ProcessLaunch>[];

  @override
  Future<RunningProcess> start(ProcessLaunch launch) {
    launches.add(launch);
    return runner.start(
      ProcessLaunch(
        executable: launch.executable,
        arguments: launch.arguments,
        workingDirectory: launch.workingDirectory,
        environment: {...launch.environment, ...environment},
        lowPriority: launch.lowPriority,
      ),
    );
  }
}

/// [length] bytes of [url] from [start] (to the end without [length]), read over HTTP as the player reads them; with
/// [cut], what came before the companion closed the connection
Future<Uint8List> readAv2Url(
  Uri url, {
  int start = 0,
  int? length,
  bool cut = false,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final client = HttpClient();
  final out = BytesBuilder(copy: false);
  try {
    final request = await client.getUrl(url);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-${length == null ? '' : start + length - 1}');
    final response = await request.close().timeout(timeout);
    await response.forEach(out.add).timeout(timeout);
    return out.toBytes();
  } on HttpException {
    if (!cut) {
      rethrow;
    }
    return out.toBytes();
  } finally {
    client.close(force: true);
  }
}
