// The resume logic of a film download (FilmTransfer): from a partial file with a Range from its length, starting over
// when the server sends the whole file or the file changed, going on after a cut link, pause and cancel, and the
// failures the user sees. Through an in memory server, no network.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/film_download.model.dart';
import 'package:immich_mobile/domain/services/film_download/film_transfer.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';

Uint8List _bytes(int size, {int seed = 3}) => Uint8List.fromList([for (var i = 0; i < size; i++) (i * 7 + seed) % 256]);

/// What the in memory server answers
class _Server {
  _Server(this.data, {this.identity = 'part-1|1000'});

  Uint8List data;
  String identity;

  /// Sends the whole file whatever the range asked
  bool ignoresRange = false;

  /// Cuts the body of the next answers after this many bytes, once each
  final List<int> cuts = [];

  /// Throws this at the next opens, once each
  final List<Exception> failures = [];

  /// Bytes per chunk of the body
  int chunk = 100;

  /// Waits for this before the chunk at each offset, when set
  Future<void> Function(int offset)? beforeChunk;

  final List<int> asked = [];

  Future<NetworkDownloadStream> open(int from, Future<void> abort) async {
    asked.add(from);
    if (failures.isNotEmpty) {
      throw failures.removeAt(0);
    }
    final start = ignoresRange ? 0 : from;
    final cut = cuts.isEmpty ? null : cuts.removeAt(0);
    final controller = StreamController<List<int>>();
    var aborted = false;
    unawaited(abort.then((_) => aborted = true));
    unawaited(() async {
      var offset = start;
      var sent = 0;
      while (offset < data.length) {
        final wait = beforeChunk;
        if (wait != null) {
          await wait(offset);
        }
        if (aborted || controller.isClosed) {
          break;
        }
        if (cut != null && sent >= cut) {
          controller.addError(const SocketException('Connection reset by peer'));
          break;
        }
        final end = (offset + chunk).clamp(0, data.length);
        controller.add(data.sublist(offset, end));
        sent += end - offset;
        offset = end;
        await Future<void>.delayed(Duration.zero);
      }
      await controller.close();
    }());
    return NetworkDownloadStream(start: start, total: data.length, identity: identity, bytes: controller.stream);
  }
}

void main() {
  late Directory folder;
  late String target;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('film_transfer_test');
    target = '${folder.path}${Platform.pathSeparator}film.mkv';
  });
  tearDown(() => folder.delete(recursive: true));

  FilmTransfer transfer(_Server server, {String? identity, List<int>? progress}) => FilmTransfer(
    target: target,
    open: server.open,
    identity: identity,
    retryDelays: const [Duration.zero, Duration.zero, Duration.zero],
    writeChunk: 256,
    onProgress: progress == null ? null : (received, total) => progress.add(received),
  );

  test('copies the whole file into its place, through a partial file', () async {
    final server = _Server(_bytes(1000));
    final progress = <int>[];
    final result = await transfer(server, progress: progress).run();
    expect(result.end, FilmTransferEnd.completed);
    expect(result.received, 1000);
    expect(result.identity, 'part-1|1000');
    expect(await File(target).readAsBytes(), server.data);
    expect(File('$target.part').existsSync(), isFalse);
    expect(server.asked, [0]);
    expect(progress.last, 1000);
  });

  test('resumes a partial file of the same identity with a range from its length', () async {
    final server = _Server(_bytes(1000));
    await File('$target.part').writeAsBytes(server.data.sublist(0, 400));
    final result = await transfer(server, identity: 'part-1|1000').run();
    expect(result.end, FilmTransferEnd.completed);
    expect(server.asked, [400]);
    expect(await File(target).readAsBytes(), server.data);
  });

  test('starts over when the file changed on the server', () async {
    final server = _Server(_bytes(1000, seed: 9), identity: 'part-1-new|1000');
    await File('$target.part').writeAsBytes(_bytes(400));
    final seen = <String>[];
    final copy = FilmTransfer(
      target: target,
      open: server.open,
      identity: 'part-1|1000',
      retryDelays: const [Duration.zero],
      onIdentity: seen.add,
    );
    final result = await copy.run();
    expect(result.end, FilmTransferEnd.completed);
    expect(server.asked, [400, 0]);
    expect(seen, ['part-1-new|1000']);
    expect(await File(target).readAsBytes(), server.data);
  });

  test('drops bytes of an unknown version and asks from the start', () async {
    final server = _Server(_bytes(1000));
    await File('$target.part').writeAsBytes(_bytes(400, seed: 1));
    await transfer(server).run();
    expect(server.asked, [0]);
    expect(await File(target).readAsBytes(), server.data);
  });

  test('starts over when the server sends the whole file instead of the range', () async {
    final server = _Server(_bytes(1000))..ignoresRange = true;
    await File('$target.part').writeAsBytes(server.data.sublist(0, 300));
    final result = await transfer(server, identity: 'part-1|1000').run();
    expect(result.end, FilmTransferEnd.completed);
    expect(await File(target).readAsBytes(), server.data);
  });

  test('goes on from where a cut link stopped it', () async {
    final server = _Server(_bytes(1000))..cuts.addAll([300, 200]);
    final result = await transfer(server).run();
    expect(result.end, FilmTransferEnd.completed);
    expect(server.asked, hasLength(3));
    // Each new request starts at the bytes already on the disk
    expect(server.asked, [0, 300, 500]);
    expect(await File(target).readAsBytes(), server.data);
  });

  test('tries again after network failures, then gives up as unreachable', () async {
    final server = _Server(_bytes(100))
      ..failures.addAll([
        const SocketException('No route to host'),
        TimeoutException('no answer'),
        const NetworkFileSystemException('The Plex server does not answer'),
        const SocketException('No route to host'),
      ]);
    await expectLater(
      transfer(server).run(),
      throwsA(isA<FilmTransferException>().having((e) => e.failure, 'failure', FilmDownloadFailure.unreachable)),
    );
    expect(server.asked, hasLength(4));
  });

  test('a download the server owner forbids stops at once', () async {
    final server = _Server(_bytes(100))
      ..failures.add(const NetworkFileSystemException('forbidden', isAuthentication: true, isDownloadForbidden: true));
    await expectLater(
      transfer(server).run(),
      throwsA(isA<FilmTransferException>().having((e) => e.failure, 'failure', FilmDownloadFailure.forbidden)),
    );
    expect(server.asked, [0]);
  });

  test('a file gone from the server stops at once', () async {
    final server = _Server(_bytes(100))..failures.add(const NetworkFileSystemException('gone', isNotFound: true));
    await expectLater(
      transfer(server).run(),
      throwsA(isA<FilmTransferException>().having((e) => e.failure, 'failure', FilmDownloadFailure.gone)),
    );
  });

  test('a partial file as long as the file completes without a byte', () async {
    final server = _Server(_bytes(500), identity: 'part-1|500');
    await File('$target.part').writeAsBytes(server.data);
    final result = await transfer(server, identity: 'part-1|500').run();
    expect(result.end, FilmTransferEnd.completed);
    expect(await File(target).readAsBytes(), server.data);
  });

  test('pause keeps the bytes copied, and the next run goes on from them', () async {
    final hold = Completer<void>();
    final server = _Server(_bytes(1000))
      ..chunk = 50
      // The body stops at 500 bytes until the pause
      ..beforeChunk = (offset) => offset >= 500 ? hold.future : Future.value();
    final progress = <int>[];
    final copy = transfer(server, progress: progress);
    final running = copy.run();
    while (!progress.any((received) => received >= 256)) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    copy.pause();
    final paused = await running;
    expect(paused.end, FilmTransferEnd.paused);
    // What came before the pause is on the disk, the bytes gathered for the next write included; the body stopped at
    // 500 bytes at most
    expect(paused.received, inInclusiveRange(256, 500));
    expect(File('$target.part').lengthSync(), paused.received);
    expect(File(target).existsSync(), isFalse);

    server.beforeChunk = null;
    final resumed = await transfer(server, identity: paused.identity).run();
    expect(resumed.end, FilmTransferEnd.completed);
    expect(server.asked.last, paused.received);
    expect(await File(target).readAsBytes(), server.data);
  });

  test('cancel deletes the bytes copied', () async {
    final hold = Completer<void>();
    final server = _Server(_bytes(1000))
      ..chunk = 50
      ..beforeChunk = (offset) => offset >= 500 ? hold.future : Future.value();
    final progress = <int>[];
    final copy = transfer(server, progress: progress);
    final running = copy.run();
    while (!progress.any((received) => received >= 256)) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    copy.cancel();
    final result = await running;
    expect(result.end, FilmTransferEnd.cancelled);
    expect(File('$target.part').existsSync(), isFalse);
    expect(File(target).existsSync(), isFalse);
  });

  test('the failures the user sees', () {
    expect(filmDownloadFailureOf(const SocketException('x')), (failure: FilmDownloadFailure.unreachable, retry: true));
    expect(filmDownloadFailureOf(const NetworkFileSystemException('x', isAuthentication: true)), (
      failure: FilmDownloadFailure.failed,
      retry: false,
    ));
    expect(
      filmDownloadFailureOf(const FileSystemException('full', '/x', OSError('No space left on device', 28))),
      Platform.isWindows
          ? (failure: FilmDownloadFailure.failed, retry: false)
          : (failure: FilmDownloadFailure.noSpace, retry: false),
    );
    expect(filmDownloadFailureOf(StateError('x')), (failure: FilmDownloadFailure.failed, retry: false));
  });
}
