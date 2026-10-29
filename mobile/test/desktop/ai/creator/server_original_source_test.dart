// The original of a photo of the Immich server, copied for its conversion: downloaded whole into a folder of its own
// in the temporary folder, its sum and size those of the bytes received, deleted with its folder at the end of the job
// whatever the end; a server that answers otherwise, or a cancel during the copy, said by their code; the copies an
// earlier session left deleted at the start once an hour old.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/server_original_source.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late HttpServer server;
  late Uint8List original;
  late List<String> asked;
  late int status;
  late bool slow;
  final client = http.Client();

  setUp(() async {
    root = Directory.systemTemp.createTempSync('server_original_source');
    original = Uint8List.fromList(List.generate(300000, (i) => (i * 13) & 0xff));
    asked = [];
    status = HttpStatus.ok;
    slow = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      asked.add('${request.uri.path} ${request.headers.value('x-test')}');
      request.response.statusCode = status;
      if (status == HttpStatus.ok) {
        for (var start = 0; start < original.length; start += 50000) {
          request.response.add(original.sublist(start, (start + 50000).clamp(0, original.length)));
          await request.response.flush();
          if (slow) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
        }
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    root.deleteSync(recursive: true);
  });

  tearDownAll(client.close);

  ServerOriginalSource source({String name = 'plage: été.jpg'}) => ServerOriginalSource(
    name: name,
    remoteId: 'asset-1',
    endpoint: 'http://127.0.0.1:${server.port}/api',
    fetch: (url) => client.send(http.Request('GET', url)..headers['x-test'] = 'signed in'),
    copiesFolder: () async => Directory(p.join(root.path, 'immuch360-ai')),
    hash: (path, cancel) async => base64.encode(crypto.sha1.convert(File(path).readAsBytesSync()).bytes),
  );

  List<String> copies() => Directory(p.join(root.path, 'immuch360-ai')).existsSync()
      ? [for (final entry in Directory(p.join(root.path, 'immuch360-ai')).listSync()) p.basename(entry.path)]
      : const [];

  test('the original is copied whole, with the sum and the size of its bytes, then deleted with its folder', () async {
    final photo = source();
    final flag = NativeCancelFlag();
    addTearDown(flag.free);

    final read = await photo.prepare(flag);

    expect(asked, ['/api/assets/asset-1/original signed in'], reason: 'the original, never an edit, as signed in');
    expect(read.name, 'plage: été.jpg', reason: 'the name the XMP keeps is that of the original');
    expect(read.size, original.length);
    expect(read.sha1, base64.encode(crypto.sha1.convert(original).bytes));
    expect(File(read.path!).readAsBytesSync(), original);
    expect(p.basename(read.path!), isNot(contains(':')), reason: 'a name Windows accepts for the copy');
    expect(photo.folder, isNull, reason: 'not on this computer: a chosen folder receives its 3D photo');
    expect(copies(), hasLength(1));

    await photo.release();
    expect(copies(), isEmpty);
  });

  test('a server that answers otherwise: the original cannot be reached, and no copy stays', () async {
    status = HttpStatus.notFound;
    final photo = source();
    final flag = NativeCancelFlag();
    addTearDown(flag.free);

    await expectLater(
      photo.prepare(flag),
      throwsA(isA<ConversionException>().having((error) => error.code, 'code', ImmersiveErrorCode.sourceLost)),
    );
    await photo.release();
    expect(copies(), isEmpty);
  });

  test('a cancel during the copy is told as a cancel', () async {
    slow = true;
    final photo = source();
    final flag = NativeCancelFlag();
    addTearDown(flag.free);

    final copying = photo.prepare(flag);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    flag.cancel();

    await expectLater(
      copying,
      throwsA(isA<ConversionException>().having((error) => error.code, 'code', ImmersiveErrorCode.cancelled)),
    );
    await photo.release();
    expect(copies(), isEmpty);
  });

  test('a copy that cannot be written fails the photo with that reason', () async {
    // A file where the folder of the copies would be
    File(p.join(root.path, 'immuch360-ai')).writeAsStringSync('in the way');
    final photo = source();
    final flag = NativeCancelFlag();
    addTearDown(flag.free);

    await expectLater(
      photo.prepare(flag),
      throwsA(isA<ConversionException>().having((error) => error.code, 'code', ImmersiveErrorCode.writeFailed)),
    );
  });

  test('at the start, the copies an earlier session left are deleted once an hour old', () async {
    final folder = Directory(p.join(root.path, 'immuch360-ai'));
    final now = DateTime.now();
    final old = Directory(p.join(folder.path, 'old'))..createSync(recursive: true);
    File(p.join(old.path, 'salon.jpg'))
      ..writeAsStringSync('old copy')
      ..setLastModifiedSync(now.subtract(const Duration(hours: 2)));
    final fresh = Directory(p.join(folder.path, 'fresh'))..createSync();
    File(p.join(fresh.path, 'cuisine.jpg'))
      ..writeAsStringSync('copy under way')
      ..setLastModifiedSync(now.subtract(const Duration(minutes: 50)));

    await cleanUpAiCopiesAtStart(copiesFolder: () async => folder, now: () => now);

    expect(copies(), ['fresh']);
  });
}
