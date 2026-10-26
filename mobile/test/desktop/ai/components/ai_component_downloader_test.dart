// The download of an AI component against a local HTTPS server (component_test_server.dart): the sum, a cut then the
// resume by Range, 404 then the next address, a redirect, http:// refused, no header of the app, a full disk,
// cancelling, gzip, and the mirror whose sums stay required. The downloader is shared with the Quest; its tests live
// under test/desktop so that the Windows job runs them on a real Windows too (paths, file:// folders, renames).

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_downloader.dart';
import 'package:path/path.dart' as p;

import 'component_test_server.dart';

Uint8List _bytes(int length, int seed) {
  final random = Random(seed);
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

Matcher _fails(AiDownloadFailure failure) =>
    throwsA(isA<AiDownloadException>().having((error) => error.failure, 'failure', failure));

/// What the app's own HttpOverrides would do to a client it makes: its User-Agent; the downloader must never ask it
class _AppOverrides extends HttpOverrides {
  var asked = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    asked++;
    return super.createHttpClient(context)..userAgent = 'Immuch360-app-agent';
  }
}

/// A sink that fills the disk after [room] bytes
class _FullDisk implements AiFileSink {
  _FullDisk(this._inner, this.room);

  final AiFileSink _inner;
  int room;

  @override
  Future<void> add(List<int> bytes) async {
    if (bytes.length > room) {
      // ERROR_DISK_FULL on Windows, ENOSPC elsewhere
      throw FileSystemException(
        'write failed',
        'test',
        OSError('No space left on device', Platform.isWindows ? 112 : 28),
      );
    }
    room -= bytes.length;
    await _inner.add(bytes);
  }

  @override
  Future<void> close() => _inner.close();
}

void main() {
  late Directory temp;
  late Directory certificatesFolder;
  TestCertificates? certificates;
  late ComponentTestServer server;

  setUpAll(() async {
    certificatesFolder = await Directory.systemTemp.createTemp('ai-components-certs');
    certificates = await TestCertificates.make(certificatesFolder);
  });

  // The keys of the test authority go with the run
  tearDownAll(() => certificatesFolder.delete(recursive: true));

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ai-components');
    if (certificates != null) {
      server = await ComponentTestServer.start(certificates!);
    }
  });

  tearDown(() async {
    if (certificates != null) {
      await server.close();
    }
    HttpOverrides.global = null;
    await temp.delete(recursive: true);
  });

  File target() => File(p.join(temp.path, 'models', 'test', 'test.bin'));
  File part() => File(p.join(temp.path, 'tmp', 'test.bin.part'));

  /// A downloader of the tests: the test authority, no mirror unless given, the release at [release] of the server
  AiComponentDownloader downloader({
    String? mirror,
    String folder = 'files',
    AiFileSinkOpener? openSink,
    Duration idleTimeout = const Duration(seconds: 60),
  }) => AiComponentDownloader(
    createClient: certificates!.bareClient,
    mirror: () => mirror,
    release: server.url(folder, ''),
    retryDelay: Duration.zero,
    idleTimeout: idleTimeout,
    openSink: openSink,
  );

  /// A test against the HTTPS server, skipped with its reason when openssl could not make the certificates
  void httpsTest(String description, Future<void> Function() body) => test(description, () async {
    if (certificates == null) {
      markTestSkipped('openssl is needed to make the certificates of the test server');
      return;
    }
    await body();
  });

  group('the download of a component', () {
    httpsTest('with the right sum, the file is installed under its final name and nothing is left in tmp', () async {
      final bytes = _bytes(300 * 1024, 1);
      server.files['test.bin'] = ServedFile(bytes);
      final component = testComponent('test.bin', bytes, sha256: _sha(bytes));
      final progress = <int>[];

      final source = await downloader().download(
        component,
        target: target(),
        part: part(),
        onProgress: (received, total) {
          progress.add(received);
          expect(total, bytes.length);
        },
      );

      expect(source.toString(), server.url('files', 'test.bin'));
      expect(target().readAsBytesSync(), bytes);
      expect(part().existsSync(), isFalse);
      expect(Directory(p.join(temp.path, 'tmp')).listSync(), isEmpty);
      expect(progress.last, bytes.length);
    });

    httpsTest('a wrong sum deletes what was received and says the file is damaged', () async {
      final bytes = _bytes(100 * 1024, 2);
      server.files['test.bin'] = ServedFile(bytes);
      final component = testComponent('test.bin', bytes, sha256: _sha(_bytes(100 * 1024, 3)));

      final error = await downloader()
          .download(component, target: target(), part: part())
          .then<AiDownloadException?>((_) => null, onError: (Object error) => error as AiDownloadException);

      expect(error?.failure, AiDownloadFailure.damaged);
      expect(error?.messageKey, 'ai_immersive_download_damaged');
      expect(target().existsSync(), isFalse);
      expect(part().existsSync(), isFalse);
    });

    httpsTest('a server that announces another size is left before the body, as a damaged file', () async {
      final bytes = _bytes(64 * 1024, 4);
      server.files['test.bin'] = ServedFile(bytes, contentLength: bytes.length);
      final component = testComponent('test.bin', _bytes(80 * 1024, 4), sha256: _sha(_bytes(80 * 1024, 4)));

      await expectLater(
        downloader().download(component, target: target(), part: part()),
        _fails(AiDownloadFailure.damaged),
      );
      expect(part().existsSync(), isFalse);
    });

    httpsTest('a connection cut in the middle resumes with Range where it stopped', () async {
      final bytes = _bytes(512 * 1024, 5);
      server.files['test.bin'] = ServedFile(bytes, cutFirstAfter: 200 * 1024);
      final component = testComponent('test.bin', bytes, sha256: _sha(bytes));

      await downloader().download(component, target: target(), part: part());

      expect(target().readAsBytesSync(), bytes);
      expect(server.requests.map((request) => request.range), [null, 'bytes=${200 * 1024}-']);
    });

    httpsTest('a .part left by an earlier download is resumed, its bytes counted in the sum', () async {
      final bytes = _bytes(256 * 1024, 6);
      server.files['test.bin'] = ServedFile(bytes);
      final component = testComponent('test.bin', bytes, sha256: _sha(bytes));
      part()
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes.sublist(0, 1000));

      await downloader().download(component, target: target(), part: part());

      expect(target().readAsBytesSync(), bytes);
      expect(server.requests.single.range, 'bytes=1000-');
    });

    httpsTest('404 at the release, then the official source', () async {
      final bytes = _bytes(50 * 1024, 7);
      server.files['test.bin'] = ServedFile(bytes);
      final component = testComponent(
        'test.bin',
        bytes,
        sha256: _sha(bytes),
        officialUrls: [server.url('files', 'test.bin')],
      );

      final source = await downloader(folder: 'missing').download(component, target: target(), part: part());

      expect(source.toString(), server.url('files', 'test.bin'));
      expect(server.requests.map((request) => request.path), ['/missing/test.bin', '/files/test.bin']);
      expect(target().readAsBytesSync(), bytes);
    });

    httpsTest('a damaged file at the release, then the official source', () async {
      final bytes = _bytes(60 * 1024, 30);
      server.files['test.bin'] = ServedFile(_bytes(60 * 1024, 31));
      server.files['official.bin'] = ServedFile(bytes);
      final component = testComponent(
        'test.bin',
        bytes,
        sha256: _sha(bytes),
        officialUrls: [server.url('files', 'official.bin')],
      );

      final source = await downloader().download(component, target: target(), part: part());

      expect(source.toString(), server.url('files', 'official.bin'));
      expect(server.requests.map((request) => request.path), ['/files/test.bin', '/files/official.bin']);
      expect(server.requests.last.range, isNull, reason: 'the damaged bytes are not resumed');
      expect(target().readAsBytesSync(), bytes);
      expect(Directory(p.join(temp.path, 'tmp')).listSync(), isEmpty);
    });

    httpsTest('a server that takes the request and never answers is left after the silence allowed', () async {
      final bytes = _bytes(1024, 32);
      final component = testComponent('test.bin', bytes, sha256: _sha(bytes));

      await expectLater(
        downloader(
          folder: 'silent',
          idleTimeout: const Duration(milliseconds: 300),
        ).download(component, target: target(), part: part()),
        _fails(AiDownloadFailure.network),
      );
      expect(server.requests.map((request) => request.path), ['/silent/test.bin']);
    });

    httpsTest('404 everywhere says not found', () async {
      final bytes = _bytes(1024, 8);
      final component = testComponent('test.bin', bytes, sha256: _sha(bytes));

      await expectLater(
        downloader(folder: 'missing').download(component, target: target(), part: part()),
        _fails(AiDownloadFailure.notFound),
      );
    });

    httpsTest('a redirect is followed, as GitHub sends its files from its storage', () async {
      final bytes = _bytes(70 * 1024, 9);
      server.files['test.bin'] = ServedFile(bytes);
      final component = testComponent('test.bin', bytes, sha256: _sha(bytes));

      await downloader(folder: 'redirect').download(component, target: target(), part: part());

      expect(server.requests.map((request) => request.path), ['/redirect/test.bin', '/files/test.bin']);
      expect(target().readAsBytesSync(), bytes);
    });

    httpsTest('http:// is refused, as a mirror or behind a redirect, and the plain server is never reached', () async {
      final bytes = _bytes(1024, 10);
      final component = testComponent('test.bin', bytes, sha256: _sha(bytes));

      await expectLater(
        downloader(mirror: '${server.plainBase}/files/').download(component, target: target(), part: part()),
        _fails(AiDownloadFailure.insecureAddress),
      );
      await expectLater(
        downloader(folder: 'to-http').download(component, target: target(), part: part()),
        _fails(AiDownloadFailure.insecureAddress),
      );
      expect(server.plainRequests, isEmpty);
      expect(server.requests.map((request) => request.path), ['/to-http/test.bin']);
    });

    httpsTest('no header of the app reaches the server: the client is made outside the overrides of the app', () async {
      final bytes = _bytes(10 * 1024, 11);
      server.files['test.bin'] = ServedFile(bytes);
      final overrides = _AppOverrides();
      HttpOverrides.global = overrides;
      final component = testComponent('test.bin', bytes, sha256: _sha(bytes));

      await downloader().download(component, target: target(), part: part());

      expect(overrides.asked, 0);
      final headers = server.requests.single.headers;
      expect(headers['user-agent'], isNot(contains('Immuch360')));
      expect(headers.keys.toSet().difference({'user-agent', 'accept-encoding', 'host', 'content-length'}), isEmpty);
      expect(headers['accept-encoding'], 'identity');
    });

    httpsTest('a full disk stops the download, deletes what was received and says so', () async {
      final bytes = _bytes(400 * 1024, 12);
      server.files['test.bin'] = ServedFile(bytes);
      final component = testComponent('test.bin', bytes, sha256: _sha(bytes));
      final full = downloader(
        openSink: (file, {required append}) async => _FullDisk(await AiFileSink.open(file, append: append), 100 * 1024),
      );

      final error = await full
          .download(component, target: target(), part: part())
          .then<AiDownloadException?>((_) => null, onError: (Object error) => error as AiDownloadException);

      expect(error?.failure, AiDownloadFailure.diskFull);
      expect(error?.messageKey, 'ai_immersive_failed_disk_full');
      expect(part().existsSync(), isFalse);
      expect(target().existsSync(), isFalse);
    });

    httpsTest('cancelled, it stops at once and keeps its .part, which the next download resumes', () async {
      final bytes = _bytes(1024 * 1024, 13);
      server.files['test.bin'] = ServedFile(bytes, chunk: 16 * 1024, pause: const Duration(milliseconds: 20));
      final component = testComponent('test.bin', bytes, sha256: _sha(bytes));
      final cancel = AiDownloadCancel();

      await expectLater(
        downloader().download(
          component,
          target: target(),
          part: part(),
          cancel: cancel,
          onProgress: (received, _) {
            if (received >= 64 * 1024) {
              cancel.cancel();
            }
          },
        ),
        _fails(AiDownloadFailure.cancelled),
      );
      expect(target().existsSync(), isFalse);
      final kept = part().lengthSync();
      expect(kept, inInclusiveRange(64 * 1024, bytes.length - 1));

      server.files['test.bin'] = ServedFile(bytes);
      await downloader().download(component, target: target(), part: part());

      expect(target().readAsBytesSync(), bytes);
      expect(server.requests.last.range, 'bytes=$kept-');
    });

    httpsTest('a cancel asked before the start downloads nothing', () async {
      final bytes = _bytes(1024, 14);
      server.files['test.bin'] = ServedFile(bytes);
      final component = testComponent('test.bin', bytes, sha256: _sha(bytes));

      await expectLater(
        downloader().download(component, target: target(), part: part(), cancel: AiDownloadCancel()..cancel()),
        _fails(AiDownloadFailure.cancelled),
      );
      expect(server.requests, isEmpty);
    });

    httpsTest('a gzip component is unpacked while it downloads; size and sum are those of the unpacked file', () async {
      final installed = Uint8List.fromList(List.generate(600 * 1024, (index) => index % 251 < 200 ? 7 : index % 13));
      final packed = Uint8List.fromList(gzip.encode(installed));
      server.files['lib.so.gz'] = ServedFile(packed, cutFirstAfter: packed.length ~/ 2);
      final component = testComponent(
        'lib.so.gz',
        installed,
        sha256: _sha(installed),
        compression: AiCompression.gzip,
        downloadSize: packed.length,
      );
      final totals = <int?>{};

      await downloader().download(
        component,
        target: target(),
        part: File(p.join(temp.path, 'tmp', 'lib.so.gz.part')),
        onProgress: (_, total) => totals.add(total),
      );

      expect(target().readAsBytesSync(), installed);
      expect(totals, {packed.length});
      expect(Directory(p.join(temp.path, 'tmp')).listSync(), isEmpty);
    });

    httpsTest('a gzip file whose content is not the catalogue one is damaged', () async {
      final installed = _bytes(10 * 1024, 15);
      final packed = Uint8List.fromList(gzip.encode(_bytes(10 * 1024, 16)));
      server.files['lib.so.gz'] = ServedFile(packed);
      final component = testComponent(
        'lib.so.gz',
        installed,
        sha256: _sha(installed),
        compression: AiCompression.gzip,
        downloadSize: packed.length,
      );

      await expectLater(
        downloader().download(component, target: target(), part: File(p.join(temp.path, 'tmp', 'lib.so.gz.part'))),
        _fails(AiDownloadFailure.damaged),
      );
      expect(target().existsSync(), isFalse);
      expect(Directory(p.join(temp.path, 'tmp')).listSync(), isEmpty);
    });

    httpsTest(
      'an incomplete component of the catalogue (an ONNX Runtime before lot A3b) is never downloaded',
      () async {
        await expectLater(
          downloader().download(onnxRuntimeLinuxComponent, target: target(), part: part()),
          _fails(AiDownloadFailure.incomplete),
        );
        expect(server.requests, isEmpty);
      },
    );
  });

  group('the mirror', () {
    late Directory mirror;

    setUp(() {
      mirror = Directory(p.join(temp.path, 'mirror'))..createSync();
    });

    AiComponentDownloader offline(String mirrorValue) => AiComponentDownloader(mirror: () => mirrorValue);

    test('a file:// folder replaces every address', () async {
      final bytes = _bytes(90 * 1024, 20);
      File(p.join(mirror.path, 'test.bin')).writeAsBytesSync(bytes);
      final component = testComponent(
        'test.bin',
        bytes,
        sha256: _sha(bytes),
        officialUrls: ['https://127.0.0.1:9/never'],
      );

      final source = await offline(
        Uri.directory(mirror.path).toString(),
      ).download(component, target: target(), part: part());

      expect(source, Uri.file(p.join(mirror.path, 'test.bin')));
      expect(target().readAsBytesSync(), bytes);
    });

    test('a plain folder path is taken as the same file:// folder', () async {
      final bytes = _bytes(20 * 1024, 21);
      File(p.join(mirror.path, 'test.bin')).writeAsBytesSync(bytes);
      final component = testComponent('test.bin', bytes, sha256: _sha(bytes));

      await offline(mirror.path).download(component, target: target(), part: part());

      expect(target().readAsBytesSync(), bytes);
    });

    test('its sums stay required: another file in the mirror is damaged and deleted', () async {
      final bytes = _bytes(30 * 1024, 22);
      File(p.join(mirror.path, 'test.bin')).writeAsBytesSync(_bytes(30 * 1024, 23));
      final component = testComponent('test.bin', bytes, sha256: _sha(bytes));

      await expectLater(
        offline(Uri.directory(mirror.path).toString()).download(component, target: target(), part: part()),
        _fails(AiDownloadFailure.damaged),
      );
      expect(target().existsSync(), isFalse);
      expect(part().existsSync(), isFalse);
      expect(File(p.join(mirror.path, 'test.bin')).existsSync(), isTrue);
    });

    test('a file missing from the mirror is not found', () async {
      final bytes = _bytes(1024, 24);
      final component = testComponent('test.bin', bytes, sha256: _sha(bytes));

      await expectLater(
        offline(Uri.directory(mirror.path).toString()).download(component, target: target(), part: part()),
        _fails(AiDownloadFailure.notFound),
      );
    });

    test('the variable is read from the environment by default', () {
      expect(aiComponentsMirrorVariable, 'IMMUCH360_AI_COMPONENTS_MIRROR');
      expect(
        AiComponentDownloader.mirrorAddress(Platform.environment[aiComponentsMirrorVariable]),
        AiComponentDownloader().mirrorBase,
      );
    });
  });

  group('the failures', () {
    test('each one has its text in en.json', () {
      final texts = File('../i18n/en.json').readAsStringSync();
      for (final failure in AiDownloadFailure.values) {
        final key = AiDownloadException(failure).messageKey;
        expect(texts, contains('"$key"'), reason: failure.name);
      }
    });

    test('a full disk is told apart from the other write errors, with the codes of each system', () {
      FileSystemException error(int code) => FileSystemException('x', 'y', OSError('error', code));
      for (final code in [112, 39]) {
        expect(isDiskFull(error(code), windows: true), isTrue, reason: 'Windows $code');
        expect(isDiskFull(error(code), windows: false), isFalse, reason: 'EHOSTDOWN and ENOTEMPTY elsewhere: $code');
      }
      expect(isDiskFull(error(28), windows: false), isTrue);
      expect(isDiskFull(error(28), windows: true), isFalse, reason: 'ERROR_OUT_OF_PAPER on Windows');
      expect(isDiskFull(error(13), windows: false), isFalse);
      expect(isDiskFull(error(Platform.isWindows ? 112 : 28)), isTrue, reason: 'this system by default');
      expect(isDiskFull(const FileSystemException('x')), isFalse);
    });
  });
}
