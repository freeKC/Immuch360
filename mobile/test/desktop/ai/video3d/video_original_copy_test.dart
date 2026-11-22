// The download of the original of a 3D video of the server or of a share (lot ai3d-remote-51): whole into a hidden
// folder beside the work folder, its bytes told as they come; a Pause keeping the part and the next run asking for the
// rest, or for the whole file again from a server that ignores ranges or refuses one; a connection lost mid-way or a
// file cut short failing with the part kept for a Retry; too little room said with both figures before a byte is
// written; a stop ending a download whose server sends nothing more; the answers of a server to a request from an
// offset; the Range request of the original of the Immich server and what video_jobs.json keeps of it.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/original_bytes.dart';
import 'package:immich_mobile/desktop/ai/creator/server_original_source.dart';
import 'package:immich_mobile/desktop/ai/creator/share_file_source.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_original_copy.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_downloadable_original.dart';

void main() {
  late Directory root;
  late String work;
  final bytes = List.generate(10000, (i) => (i * 7) % 256);

  setUp(() {
    root = Directory.systemTemp.createTempSync('video_original_copy_');
    work = p.join(root.path, '.immuch360-work-job1');
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<String> download(
    FakeDownloadableOriginal source, {
    bool Function()? isStopping,
    List<VideoDownloadProgress>? told,
    AiFreeSpaceReader? freeSpace,
  }) => downloadVideoOriginal(
    source,
    work,
    isStopping: isStopping ?? () => false,
    onProgress: told?.add,
    freeSpace: freeSpace,
  );

  Matcher failsWith(ImmersiveErrorCode code) =>
      throwsA(isA<ConversionException>().having((error) => error.code, 'code', code));

  test('the whole original goes into a hidden folder beside the work folder, its bytes told as they come', () async {
    final source = FakeDownloadableOriginal('VID: été.mp4', bytes);
    final told = <VideoDownloadProgress>[];
    final path = await download(source, told: told);

    expect(path, p.join('$work-original', 'VID_ été.mp4'), reason: 'its name made safe for Windows');
    expect(p.basename(p.dirname(path)), startsWith('.immuch360-work-'), reason: 'hidden: no scan imports it');
    expect(File(path).readAsBytesSync(), bytes);
    expect(File('$path.part').existsSync(), isFalse);
    expect(told.first, (copied: 0, total: 10000));
    expect(told.last, (copied: 10000, total: 10000));
    expect(source.offsets, [0]);

    // Once whole, a second run reads nothing more
    expect(await download(source), path);
    expect(source.offsets, [0]);
  });

  test('a Pause keeps the part, the next run asks for the rest and the copy is the same bytes', () async {
    final source = FakeDownloadableOriginal('clip.mp4', bytes);
    var chunks = 0;
    var stopping = false;
    source.beforeChunk = () async {
      if (++chunks == 4) {
        stopping = true;
      }
      // A slow server: the stop is seen between two chunks
      await Future<void>.delayed(const Duration(milliseconds: 30));
    };
    await expectLater(download(source, isStopping: () => stopping), failsWith(ImmersiveErrorCode.cancelled));
    final part = File('${videoOriginalCopyPathOf(work, 'clip.mp4')}.part');
    expect(part.existsSync(), isTrue);
    final kept = part.lengthSync();
    expect(kept, inInclusiveRange(1000, 9000));

    source.beforeChunk = null;
    final told = <VideoDownloadProgress>[];
    final path = await download(source, told: told);
    expect(source.offsets, [0, kept], reason: 'the rest asked with a Range request');
    expect(told.first, (copied: kept, total: 10000));
    expect(File(path).readAsBytesSync(), bytes);
  });

  test('a server that ignores the range, or refuses it, gives the whole file again from its first byte', () async {
    final source = FakeDownloadableOriginal('clip.mp4', bytes, honoursRange: false);
    final part = File('${videoOriginalCopyPathOf(work, 'clip.mp4')}.part');
    part.parent.createSync(recursive: true);
    part.writeAsBytesSync(bytes.sublist(0, 3000));
    final path = await download(source);
    expect(source.offsets, [3000]);
    expect(File(path).readAsBytesSync(), bytes, reason: 'not the 3000 bytes then the whole file');

    final refused = FakeDownloadableOriginal('other.mp4', bytes)..refuseRangeOnce = true;
    final otherPart = File('${videoOriginalCopyPathOf(work, 'other.mp4')}.part');
    otherPart.writeAsBytesSync(List.filled(12000, 1));
    final other = await download(refused);
    expect(refused.offsets, [12000, 0]);
    expect(File(other).readAsBytesSync(), bytes);
  });

  test('a connection lost mid-way fails as a source lost, the part kept; a Retry goes on from it', () async {
    final source = FakeDownloadableOriginal('clip.mp4', bytes)..failAfter = 4000;
    await expectLater(download(source), failsWith(ImmersiveErrorCode.sourceLost));
    final part = File('${videoOriginalCopyPathOf(work, 'clip.mp4')}.part');
    expect(part.lengthSync(), 4000);

    final path = await download(source);
    expect(source.offsets, [0, 4000]);
    expect(File(path).readAsBytesSync(), bytes);
  });

  test('a file cut short is not taken whole; one whose size is not told is taken as it comes', () async {
    final short = FakeDownloadableOriginal('clip.mp4', bytes)..shortBy = 10;
    await expectLater(
      download(short),
      throwsA(isA<ConversionException>().having((error) => error.message, 'message', 'Downloaded 9990 bytes of 10000')),
    );
    expect(File(videoOriginalCopyPathOf(work, 'clip.mp4')).existsSync(), isFalse);

    final untold = FakeDownloadableOriginal('untold.mp4', bytes, tellsSize: false);
    final told = <VideoDownloadProgress>[];
    final path = await download(untold, told: told);
    expect(File(path).lengthSync(), 10000);
    expect(told.last, (copied: 10000, total: null));
  });

  test('too little room is said with both figures before a byte is written', () async {
    final source = FakeDownloadableOriginal('clip.mp4', bytes);
    final asked = <String>[];
    Object? error;
    try {
      await download(
        source,
        freeSpace: (folder) async {
          asked.add(folder.path);
          return const AiFreeSpace(free: 5000, volume: '/');
        },
      );
    } catch (caught) {
      error = caught;
    }
    expect(error, isA<ConversionException>().having((e) => e.code, 'code', ImmersiveErrorCode.diskFull));
    final room = videoDownloadRoomOf((error! as ConversionException).message);
    expect(room, (free: 5000, need: 10000 + videoDownloadMargin));
    expect(asked, ['$work-original'], reason: 'the drive of the 3D video');
    expect(File('${videoOriginalCopyPathOf(work, 'clip.mp4')}.part').existsSync(), isFalse);
    expect(videoDownloadRoomOf('There is not enough space on the disk.'), isNull);

    // Room enough, or a drive that cannot be read: it goes on
    await download(
      source,
      freeSpace: (_) async => const AiFreeSpace(free: 1 << 40, volume: '/'),
    );
    final other = FakeDownloadableOriginal('other.mp4', bytes);
    await download(other, freeSpace: (_) async => throw const FileSystemException('no volume'));
  });

  test('a stop ends a download whose server sends nothing more, the request aborted', () async {
    final source = FakeDownloadableOriginal('clip.mp4', bytes)..stallAfter = 2000;
    var stopping = false;
    final run = download(source, isStopping: () => stopping);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final watch = Stopwatch()..start();
    stopping = true;
    await expectLater(run, failsWith(ImmersiveErrorCode.cancelled));
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    expect(source.aborted, 1);
    expect(File('${videoOriginalCopyPathOf(work, 'clip.mp4')}.part').lengthSync(), 2000);
  });

  test('deleteVideoOriginalCopy deletes the folder of the copy, part or whole, and never fails', () async {
    final source = FakeDownloadableOriginal('clip.mp4', bytes);
    await download(source);
    await deleteVideoOriginalCopy(work);
    expect(Directory('$work-original').existsSync(), isFalse);
    await deleteVideoOriginalCopy(work);
  });

  group('the answers to a request from an offset', () {
    http.StreamedResponse answer(int status, {Map<String, String> headers = const {}, int? length}) =>
        http.StreamedResponse(Stream.value([1, 2, 3]), status, headers: headers, contentLength: length);

    test('200 is the whole file, 206 the range asked with the size of the whole', () {
      final whole = originalBytesOf(answer(200, length: 3), 500, 'server');
      expect((whole.offset, whole.total), (0, 3));
      final part = originalBytesOf(answer(206, headers: {'content-range': 'bytes 500-999/1000'}), 500, 'server');
      expect((part.offset, part.total), (500, 1000));
      final untold = originalBytesOf(answer(206, headers: {'content-range': 'bytes 500-999/*'}), 500, 'share');
      expect((untold.offset, untold.total), (500, null));
    });

    test('another range, 416 and an error are told apart', () {
      expect(
        () => originalBytesOf(answer(206, headers: {'content-range': 'bytes 0-999/1000'}), 500, 'server'),
        throwsA(isA<ConversionException>().having((e) => e.code, 'code', ImmersiveErrorCode.sourceLost)),
      );
      expect(() => originalBytesOf(answer(416), 500, 'server'), throwsA(isA<OriginalRangeRefused>()));
      expect(
        () => originalBytesOf(answer(401), 0, 'server'),
        throwsA(isA<ConversionException>().having((e) => e.message, 'message', 'The server answered 401')),
      );
      expect(parseContentRange('bytes */1000'), isNull);
      expect(rangeHeadersFrom(0), isEmpty);
      expect(rangeHeadersFrom(42), {'Range': 'bytes=42-'});
    });

    test('the original of the server is asked from the offset, and video_jobs.json keeps where it is', () async {
      final asked = <(Uri, int)>[];
      final source = ServerOriginalSource(
        name: 'VID_1.mp4',
        remoteId: 'abc',
        endpoint: 'https://photos.example/api',
        fetch: (url) async => answer(200, length: 3),
        fetchRange: (url, {offset = 0, abort}) async {
          asked.add((url, offset));
          return answer(206, headers: {'content-range': 'bytes $offset-${offset + 2}/${offset + 3}'});
        },
      );
      final bytes = await source.openBytes(offset: 7);
      expect(asked, [(Uri.parse('https://photos.example/api/assets/abc/original'), 7)]);
      expect((bytes.offset, bytes.total), (7, 10));
      expect(source.descriptor, {
        'kind': serverOriginalKind,
        'name': 'VID_1.mp4',
        'remoteId': 'abc',
        'endpoint': 'https://photos.example/api',
      });

      // Without the request from an offset: the whole original, from its first byte
      final plain = ServerOriginalSource(
        name: 'VID_1.mp4',
        remoteId: 'abc',
        endpoint: 'https://photos.example/api',
        fetch: (url) async => answer(200, length: 3),
      );
      expect((await plain.openBytes(offset: 7)).offset, 0);
    });

    test('the file of a share is asked from the offset, its size the listed one when the bridge tells none', () async {
      final entry = NetworkEntry(
        sourceId: 'nas',
        path: '/Videos/clip.mp4',
        isDirectory: false,
        size: 3,
        modified: DateTime.utc(2026, 11, 20, 8),
      );
      final source = ShareFileSource(
        entry: entry,
        url: () async => Uri.parse('http://127.0.0.1:4000/media/nas/clip.mp4'),
        fetch: (url, {abort}) async => answer(200),
        fetchRange: (url, {offset = 0, abort}) async => offset == 0
            ? answer(200)
            : answer(206, headers: {'content-range': 'bytes $offset-${offset + 2}/${offset + 3}'}),
      );
      final whole = await source.openBytes();
      expect((whole.offset, whole.total), (0, 3));
      final rest = await source.openBytes(offset: 2);
      expect((rest.offset, rest.total), (2, 5));
      final kept = shareEntryOfDescriptor(source.descriptor)!;
      expect((kept.sourceId, kept.path, kept.size, kept.modified), ('nas', '/Videos/clip.mp4', 3, entry.modified));
      expect(shareEntryOfDescriptor({'kind': serverOriginalKind, 'name': 'x'}), isNull);
    });
  });
}
