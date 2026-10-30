// An original that a server without Range cannot stream (the MP4 index at the end): the in-app player downloads it with
// a progress line, then plays the file (lot fix-decoder-limit, the rule of the immersive viewer too), and keeps the
// files the pages around it still have loaded.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/providers/asset_viewer/original_download.provider.dart';

const _server = 'https://immich.example/api';

/// An MP4 box of [type] with [payload] bytes of zeros
Uint8List _box(String type, int payload) {
  final box = Uint8List(8 + payload);
  ByteData.sublistView(box).setUint32(0, 8 + payload);
  box.setRange(4, 8, type.codeUnits);
  return box;
}

/// The head of an MP4: ftyp, then [boxes] in that order
Uint8List _mp4(List<Uint8List> boxes) => Uint8List.fromList([..._box('ftyp', 24), for (final box in boxes) ...box]);

void main() {
  // An Insta360 export: the media first, its index at the end
  final moovLast = _mp4([_box('mdat', 250000), _box('moov', 4000)]);
  final file = moovLast;
  late Directory dir;
  late List<http.BaseRequest> requests;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('original_download_test');
    requests = [];
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  OriginalDownloads downloads({bool ranges = true, int? failAt, Uint8List? body}) {
    final bytes = body ?? file;
    return OriginalDownloads(
      client: () => MockClient.streaming((request, _) async {
        requests.add(request);
        final range = request.headers['range'];
        if (ranges && range != null) {
          final end = int.parse(range.split('-').last) + 1;
          final part = bytes.sublist(0, end > bytes.length ? bytes.length : end);
          return http.StreamedResponse(Stream.value(part), 206, contentLength: part.length);
        }
        final chunks = [
          for (var i = 0; i < bytes.length; i += 65536)
            bytes.sublist(i, i + 65536 > bytes.length ? bytes.length : i + 65536),
        ];
        Stream<List<int>> stream() async* {
          var sent = 0;
          for (final chunk in chunks) {
            if (failAt != null && sent >= failAt) {
              throw const SocketException('connection reset');
            }
            sent += chunk.length;
            yield chunk;
          }
        }

        return http.StreamedResponse(stream(), 200, contentLength: bytes.length);
      }),
      serverEndpoint: () => _server,
      headers: () => {'x-custom': 'yes'},
      directory: () async => dir,
    );
  }

  group('mp4MoovBeforeMdat', () {
    test('tells where the index of an MP4 lies, from its first boxes', () {
      expect(mp4MoovBeforeMdat(_mp4([_box('moov', 100), _box('mdat', 1000)])), isTrue);
      expect(mp4MoovBeforeMdat(_mp4([_box('free', 8), _box('mdat', 1000), _box('moov', 100)])), isFalse);
    });

    test('tells nothing of a head that shows neither box', () {
      expect(mp4MoovBeforeMdat(_mp4([_box('free', 100000)]), 65536), isNull);
      expect(mp4MoovBeforeMdat(Uint8List.fromList(List.filled(64, 0))), isNull);
    });
  });

  test('a server that answers Range streams the original, wherever its index lies', () async {
    final loader = downloads();
    expect(await loader.streams('video-1'), isTrue);
    expect(requests.single.headers['range'], 'bytes=0-65535');
    expect(requests.single.url.toString(), '$_server/assets/video-1/original');

    expect(await loader.streams('video-1'), isTrue);
    expect(requests, hasLength(1), reason: 'asked once per video while the app runs');
  });

  test('a server without Range streams it only when its index comes first', () async {
    final moovFirst = _mp4([_box('moov', 4000), _box('mdat', 250000)]);
    expect(await downloads(ranges: false, body: moovFirst).streams('video-1'), isTrue);
    expect(await downloads(ranges: false).streams('video-1'), isFalse);
  });

  test('downloads the original with its progress, and keeps it for the next time', () async {
    final progress = <int>[];
    final loader = downloads(ranges: false);

    final downloaded = await loader.download('video-1', onProgress: progress.add);

    expect(downloaded?.readAsBytesSync(), file);
    expect(progress.first, lessThan(100));
    expect(progress.last, 100);
    expect(progress, orderedEquals([...progress]..sort()));
    expect(requests.single.headers['x-custom'], 'yes');

    requests.clear();
    final again = <int>[];
    expect((await loader.download('video-1', onProgress: again.add))?.path, downloaded?.path);
    expect(again, [100], reason: 'the file is there already: only its size is asked again');
  });

  test('keeps the original a page still has loaded, and removes the others once the next one is whole', () async {
    final loader = downloads(ranges: false);
    final first = await loader.download('video-1');
    loader.hold('video-1');
    final stale = File('${dir.path}/original-video-0.mp4')..writeAsBytesSync([1, 2, 3]);

    final second = await loader.download('video-2');

    expect(first?.existsSync(), isTrue, reason: 'the page of video-1 may seek in it again');
    expect(second?.existsSync(), isTrue);
    expect(stale.existsSync(), isFalse, reason: 'left by an earlier page or run of the app');

    await loader.release('video-1');
    expect(first?.existsSync(), isFalse);
    expect(second?.existsSync(), isTrue, reason: 'a page gives back its own file only');
  });

  test('a download that fails or is no longer wanted leaves no file, and the original streams instead', () async {
    expect(await downloads(ranges: false, failAt: 100000).download('video-1'), isNull);
    expect(dir.listSync(), isEmpty);

    var wanted = true;
    final stopped = await downloads(
      ranges: false,
    ).download('video-1', onProgress: (percent) => wanted = percent < 20, isWanted: () => wanted);
    expect(stopped, isNull);
    expect(dir.listSync(), isEmpty);
  });
}
