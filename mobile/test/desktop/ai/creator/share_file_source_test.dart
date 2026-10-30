// A photo of a share opened in the app, copied for its conversion through the media bridge: once, into a folder of its
// own among the copies of the AI, with the bytes copied and their total told as it goes; read by the job from that same
// copy (no second download), with the sum and the size of its bytes; copied again only once released; a cancel during
// the copy told as a cancel, at once even when the share sends nothing more; a bridge that answers otherwise, or gives
// fewer bytes than it announced, or than the share listed when it announces none, as a source that cannot be reached;
// the size the bridge announces taken over the one listed (a photo edited since); no copy left behind in any case.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/share_file_source.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late HttpServer server;
  late Uint8List bytes;
  late List<String> asked;
  late int status;
  late bool slow;
  late int? sent;
  // The length the bridge announces: that of the bytes sent by default, none (chunked) when null
  late int? Function(int sending)? announced;
  // The bridge stops sending after its first chunk, or before any answer, until the test ends
  late bool stallAfterFirst;
  late bool stallBeforeAnswer;
  late Completer<void> stalled;
  late List<Object> serverErrors;
  final client = http.Client();

  setUp(() async {
    root = Directory.systemTemp.createTempSync('share_file_source');
    bytes = Uint8List.fromList(List.generate(300000, (i) => (i * 7) & 0xff));
    asked = [];
    status = HttpStatus.ok;
    slow = false;
    sent = null;
    announced = (sending) => sending;
    stallAfterFirst = false;
    stallBeforeAnswer = false;
    stalled = Completer<void>();
    serverErrors = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      asked.add(Uri.decodeFull(request.uri.path));
      try {
        if (stallBeforeAnswer) {
          await stalled.future;
          return;
        }
        request.response.statusCode = status;
        if (status == HttpStatus.ok) {
          final body = sent == null ? bytes : bytes.sublist(0, sent);
          final length = announced?.call(body.length);
          if (length == null) {
            request.response.headers.chunkedTransferEncoding = true;
          } else {
            request.response.contentLength = length;
          }
          for (var start = 0; start < body.length; start += 50000) {
            request.response.add(body.sublist(start, (start + 50000).clamp(0, body.length)));
            await request.response.flush();
            if (stallAfterFirst) {
              await stalled.future;
              return;
            }
            if (slow) {
              await Future<void>.delayed(const Duration(milliseconds: 30));
            }
          }
        }
        await request.response.close();
      } catch (error) {
        // A bridge that cuts its answer short, or a client gone: the connection is dropped
        serverErrors.add(error);
      }
    });
  });

  tearDown(() async {
    if (!stalled.isCompleted) {
      stalled.complete();
    }
    await server.close(force: true);
    root.deleteSync(recursive: true);
  });

  tearDownAll(client.close);

  NetworkEntry entry({String path = '/2024/salon.jpg', int? size}) => NetworkEntry(
    sourceId: 'nas',
    path: path,
    isDirectory: false,
    size: size ?? bytes.length,
    modified: DateTime.utc(2026, 10, 1, 12),
  );

  ShareFileSource source(NetworkEntry entry) => ShareFileSource(
    entry: entry,
    url: () async => Uri.parse('http://127.0.0.1:${server.port}/token/nas${entry.path}'),
    fetch: (url, {abort}) => client.send(http.AbortableRequest('GET', url, abortTrigger: abort)),
    copiesFolder: () async => Directory(p.join(root.path, 'immuch360-ai')),
    hash: (path, cancel) async => base64.encode(crypto.sha1.convert(File(path).readAsBytesSync()).bytes),
  );

  List<String> copies() {
    final folder = Directory(p.join(root.path, 'immuch360-ai'));
    return folder.existsSync() ? [for (final entry in folder.listSync()) p.basename(entry.path)] : const [];
  }

  Matcher failsWith(ImmersiveErrorCode code) =>
      throwsA(isA<ConversionException>().having((error) => error.code, 'code', code));

  test('copied once through the bridge, its progress told, then read by its job from that copy', () async {
    final photo = source(entry());
    final progress = <(int, int?)>[];

    final path = await photo.copy(onProgress: (copied, total) => progress.add((copied, total)));

    expect(asked, ['/token/nas/2024/salon.jpg'], reason: 'the file of the share, through the media bridge');
    expect(File(path).readAsBytesSync(), bytes);
    expect(p.basename(path), 'salon.jpg');
    expect(photo.copyPath, path);
    expect(copies(), hasLength(1), reason: 'a folder of its own among the copies of the AI');
    expect(progress.last, (bytes.length, bytes.length));
    expect([for (final (copied, _) in progress) copied], orderedEquals([...progress.map((each) => each.$1)]..sort()));
    expect(photo.folder, isNull, reason: 'not on this computer');
    expect(photo.name, 'salon.jpg');

    final flag = NativeCancelFlag();
    addTearDown(flag.free);
    final read = await photo.prepare(flag);
    expect(asked, hasLength(1), reason: 'the job reads the copy the dialog made, never a second download');
    expect(read.path, path);
    expect(read.name, 'salon.jpg');
    expect(read.size, bytes.length);
    expect(read.sha1, base64.encode(crypto.sha1.convert(bytes).bytes));

    await photo.release();
    expect(copies(), isEmpty);
    expect(photo.copyPath, isNull);
  });

  test('copied again by its job once released (Retry), and by a job whose copy was not made first', () async {
    final photo = source(entry());
    await photo.copy();
    await photo.release();
    final flag = NativeCancelFlag();
    addTearDown(flag.free);

    final read = await photo.prepare(flag);

    expect(asked, hasLength(2));
    expect(File(read.path!).readAsBytesSync(), bytes);
    await photo.release();

    final other = source(entry(path: '/2024/cuisine.jpg'));
    final first = await other.prepare(flag);
    expect(asked.last, '/token/nas/2024/cuisine.jpg');
    expect(File(first.path!).existsSync(), isTrue);
    await other.release();
    expect(copies(), isEmpty);
  });

  test('a copy deleted meanwhile is made again', () async {
    final photo = source(entry());
    final path = await photo.copy();
    File(path).deleteSync();
    final flag = NativeCancelFlag();
    addTearDown(flag.free);

    final read = await photo.prepare(flag);

    expect(asked, hasLength(2));
    expect(File(read.path!).readAsBytesSync(), bytes);
    await photo.release();
  });

  test('a cancel during the copy is told as a cancel, and no copy stays', () async {
    slow = true;
    final photo = source(entry());
    var cancelled = false;

    final copying = photo.copy(isCancelled: () => cancelled);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    cancelled = true;

    await expectLater(copying, failsWith(ImmersiveErrorCode.cancelled));
    expect(copies(), isEmpty);
    expect(photo.copyPath, isNull);

    final flag = NativeCancelFlag();
    addTearDown(flag.free);
    final job = photo.prepare(flag);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    flag.cancel();
    await expectLater(job, failsWith(ImmersiveErrorCode.cancelled));
    await photo.release();
    expect(copies(), isEmpty);
  });

  test('a cancel while the share sends nothing more stops the copy at once, and no copy stays', () async {
    // The bridge gives its first bytes of the photo, then the NAS stops answering
    stallAfterFirst = true;
    final photo = source(entry());
    var cancelled = false;
    final progress = <int>[];

    final copying = photo.copy(isCancelled: () => cancelled, onProgress: (copied, _) => progress.add(copied));
    while (progress.lastOrNull != 50000) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final at = DateTime.now();
    cancelled = true;

    await expectLater(copying.timeout(const Duration(seconds: 2)), failsWith(ImmersiveErrorCode.cancelled));
    expect(DateTime.now().difference(at), lessThan(const Duration(seconds: 1)), reason: 'not the timeout of the share');
    expect(copies(), isEmpty, reason: 'the partial copy deleted');
    expect(photo.copyPath, isNull);
  });

  test('a cancel before the bridge answers at all, as a job of the queue cancels it', () async {
    stallBeforeAnswer = true;
    final photo = source(entry());
    final flag = NativeCancelFlag();
    addTearDown(flag.free);

    final job = photo.prepare(flag);
    while (asked.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    flag.cancel();

    await expectLater(job.timeout(const Duration(seconds: 2)), failsWith(ImmersiveErrorCode.cancelled));
    expect(copies(), isEmpty);
  });

  test('a bridge that answers otherwise, or gives fewer bytes than it said: the source cannot be reached', () async {
    status = HttpStatus.notFound;
    final missing = source(entry());
    await expectLater(missing.copy(), failsWith(ImmersiveErrorCode.sourceLost));
    expect(copies(), isEmpty);

    // The whole photo announced, the answer cut short
    status = HttpStatus.ok;
    sent = 1000;
    announced = (_) => bytes.length;
    final cut = source(entry());
    await expectLater(cut.copy(), failsWith(ImmersiveErrorCode.sourceLost));
    expect(copies(), isEmpty);

    // No length announced: the size the share listed
    announced = null;
    final unsized = source(entry());
    await expectLater(unsized.copy(), failsWith(ImmersiveErrorCode.sourceLost));
    expect(copies(), isEmpty);
  });

  test('a photo edited on the NAS since its folder was listed: copied at the size the bridge reads now', () async {
    final photo = source(entry(size: 1000));
    sent = 1200;
    final totals = <int?>{};

    final path = await photo.copy(onProgress: (_, total) => totals.add(total));

    expect(File(path).readAsBytesSync(), bytes.sublist(0, 1200));
    expect(totals, {1200});
    await photo.release();
  });

  test('a name Windows refuses gets a safe name for its copy, the original name kept for its versions', () async {
    final photo = source(entry(path: '/2024/plage: été.jpg'));
    final flag = NativeCancelFlag();
    addTearDown(flag.free);

    final read = await photo.prepare(flag);

    expect(p.basename(read.path!), isNot(contains(':')));
    expect(read.name, 'plage: été.jpg');
    await photo.release();
  });

  test('a copy that cannot be written fails with that reason', () async {
    File(p.join(root.path, 'immuch360-ai')).writeAsStringSync('in the way');
    final photo = source(entry());

    await expectLater(photo.copy(), failsWith(ImmersiveErrorCode.writeFailed));
  });
}
