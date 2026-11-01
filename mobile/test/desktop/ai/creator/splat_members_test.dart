// The sources of the queue as members of a splat scene (lot SP5, splat_members.dart): read when the engine gets to
// them, released as soon as their bytes are read. Twenty-two originals of the server, then twenty files of a share,
// prepared for a scene are copied one at a time: when each is downloaded, its own copy is the only one in the folder
// of the copies, and none is left at the end; each is counted.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/server_original_source.dart';
import 'package:immich_mobile/desktop/ai/creator/share_file_source.dart';
import 'package:immich_mobile/desktop/ai/creator/splat_members.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_inputs.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:path/path.dart' as p;

import '../splat/splat_input_support.dart';

void main() {
  late Directory root;
  late NativeCancelFlag cancel;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('immuch360_splat_members_');
    cancel = NativeCancelFlag();
  });

  tearDown(() async {
    cancel.free();
    await root.delete(recursive: true);
  });

  Directory copies() => Directory(p.join(root.path, 'immuch360-ai'));
  List<String> copiesNow() => copies().existsSync() ? [for (final entry in copies().listSync()) entry.path] : const [];

  test('a member is its source: its name, read when asked, released when told', () async {
    final file = File(p.join(root.path, 'salon 1.jpg'))..writeAsBytesSync([1, 2, 3]);
    final taken = DateTime(2026, 11, 1, 10);
    final member = SourceSplatMember(LocalFileSource(file.path), taken: taken, camera: 'Canon EOS 18 mm 4272x2848');
    expect((member.name, member.taken, member.camera), ('salon 1.jpg', taken, 'Canon EOS 18 mm 4272x2848'));
    final read = await member.load(cancel);
    expect((read.path, read.size), (file.path, 3));
    await member.release();
    expect(file.existsSync(), isTrue, reason: 'a file of this computer is read in place, never deleted');
  });

  test('the originals of the server are copied one at a time, counted, and none is left', () async {
    final photos = {
      for (var step = 0; step < 22; step++) 'asset-$step': testJpeg(texturedRgba(320, 240, shift: step * 5), 320, 240),
    };
    final seenAtFetch = <int>[];
    Future<http.StreamedResponse> fetch(Uri url) async {
      seenAtFetch.add(copiesNow().length);
      final id = url.pathSegments[url.pathSegments.length - 2];
      return http.StreamedResponse(Stream.value(photos[id]!), 200);
    }

    final members = [
      for (final (index, id) in photos.keys.indexed)
        SourceSplatMember(
          ServerOriginalSource(
            name: 'IMG_$index.jpg',
            remoteId: id,
            endpoint: 'http://server.invalid/api',
            fetch: fetch,
            copiesFolder: () async => copies(),
            hash: (path, cancel) async => base64.encode(crypto.sha1.convert(File(path).readAsBytesSync()).bytes),
          ),
          taken: DateTime(2026, 11, 1).add(Duration(seconds: index)),
        ),
    ];
    final counted = <int>[];
    final inputs = await prepareSplatPhotos(
      planSplatPhotos(members).taken,
      imagesFolder: p.join(root.path, 'work', 'images'),
      cancel: cancel,
      onProgress: (done, total) => counted.add(done),
    );
    expect(seenAtFetch, List.filled(22, 1), reason: 'its own copy only, each time');
    expect(copiesNow(), isEmpty);
    expect(counted, [for (var i = 1; i <= 22; i++) i]);
    expect(inputs.images, hasLength(22));
    expect(inputs.images.map((image) => image.source), [for (var i = 0; i < 22; i++) 'IMG_$i.jpg']);
  });

  test('the files of a share are copied one at a time too, counted, and none is left', () async {
    final photos = {
      for (var step = 0; step < 20; step++)
        '/Photos/salon/P$step.jpg': testJpeg(texturedRgba(320, 240, shift: step * 5), 320, 240),
    };
    final seenAtFetch = <int>[];
    Future<http.StreamedResponse> fetch(Uri url, {Future<void>? abort}) async {
      seenAtFetch.add(copiesNow().length);
      final path = url.path.substring('/token/nas'.length);
      return http.StreamedResponse(Stream.value(photos[path]!), 200, contentLength: photos[path]!.length);
    }

    final members = [
      for (final (index, path) in photos.keys.indexed)
        SourceSplatMember(
          ShareFileSource(
            entry: NetworkEntry(sourceId: 'nas', path: path, isDirectory: false, size: photos[path]!.length),
            url: () async => Uri.parse('http://127.0.0.1:1/token/nas$path'),
            fetch: fetch,
            copiesFolder: () async => copies(),
            hash: (path, cancel) async => 'sha1',
          ),
          taken: DateTime(2026, 11, 1).add(Duration(seconds: index)),
        ),
    ];
    final counted = <int>[];
    final inputs = await prepareSplatPhotos(
      planSplatPhotos(members).taken,
      imagesFolder: p.join(root.path, 'work', 'images'),
      cancel: cancel,
      onProgress: (done, total) => counted.add(done),
    );
    expect(seenAtFetch, List.filled(20, 1), reason: 'its own copy only, each time');
    expect(copiesNow(), isEmpty);
    expect(counted, [for (var i = 1; i <= 20; i++) i]);
    expect(inputs.images.map((image) => image.source), [for (var i = 0; i < 20; i++) 'P$i.jpg']);
  });

  test('an original the server does not give is left out as unreadable, the others go on', () async {
    final good = testJpeg(texturedRgba(320, 240), 320, 240);
    final members = [
      for (var index = 0; index < 21; index++)
        SourceSplatMember(
          ServerOriginalSource(
            name: 'IMG_$index.jpg',
            remoteId: 'asset-$index',
            endpoint: 'http://server.invalid/api',
            fetch: (url) async => index == 7
                ? http.StreamedResponse(const Stream.empty(), 404)
                : http.StreamedResponse(Stream.value(good), 200),
            copiesFolder: () async => copies(),
            hash: (path, cancel) async => 'sha1',
          ),
        ),
    ];
    final inputs = await prepareSplatPhotos(members, imagesFolder: p.join(root.path, 'images'), cancel: cancel);
    expect(inputs.leftOut.map((left) => (left.name, left.reason)), [('IMG_7.jpg', SplatLeftOutReason.unreadable)]);
    expect(inputs.leftOut.single.detail, contains('404'));
    expect(inputs.images, hasLength(20));
    expect(copiesNow(), isEmpty);
  });

  test('a disk full while an original is copied ends the preparation as a disk full', () async {
    final member = SourceSplatMember(_FullDisk());
    await expectLater(
      prepareSplatPhotos([member], imagesFolder: p.join(root.path, 'images'), cancel: cancel),
      throwsA(isA<ConversionException>().having((error) => error.code, 'code', ImmersiveErrorCode.diskFull)),
    );
  });
}

class _FullDisk implements ConversionSource {
  @override
  String get name => 'big.jpg';
  @override
  String? get folder => null;
  @override
  ImmersiveExif get exif => const ImmersiveExif();
  @override
  Future<ImmersiveSource> prepare(NativeCancelFlag cancel) async =>
      throw const ConversionException(ImmersiveErrorCode.diskFull, 'No space left on device');
  @override
  Future<void> release() async {}
}
