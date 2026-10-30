// An original the device decodes, chosen over a copy it cannot decode, that a server without Range cannot stream (the
// MP4 index at the end): the in-app player downloads it with a progress line, then plays the file (lot
// fix-decoder-limit, the rule of the immersive viewer too).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/providers/asset_viewer/original_download.provider.dart';

const _server = 'https://immich.example/api';

void main() {
  final file = Uint8List.fromList(List.generate(300000, (i) => i % 251));
  late Directory dir;
  late List<http.BaseRequest> requests;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('original_download_test');
    requests = [];
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  OriginalDownloads downloads({bool ranges = true, int? failAt}) => OriginalDownloads(
    client: () => MockClient.streaming((request, _) async {
      requests.add(request);
      final range = request.headers['range'];
      if (ranges && range != null) {
        return http.StreamedResponse(Stream.value(file.sublist(1, 2)), 206, contentLength: 1);
      }
      final chunks = [
        for (var i = 0; i < file.length; i += 65536) file.sublist(i, i + 65536 > file.length ? file.length : i + 65536),
      ];
      Stream<List<int>> body() async* {
        var sent = 0;
        for (final chunk in chunks) {
          if (failAt != null && sent >= failAt) {
            throw const SocketException('connection reset');
          }
          sent += chunk.length;
          yield chunk;
        }
      }

      return http.StreamedResponse(body(), 200, contentLength: file.length);
    }),
    serverEndpoint: () => _server,
    headers: () => {'x-custom': 'yes'},
    directory: () async => dir,
  );

  test('a server that answers Range streams the original, wherever its index lies', () async {
    expect(await downloads().streams('video-1', headRead: false), isTrue);
    expect(requests.single.headers['range'], 'bytes=1-1');
    expect(requests.single.url.toString(), '$_server/assets/video-1/original');
  });

  test('a server without Range streams it only when its index is at the head', () async {
    expect(await downloads(ranges: false).streams('video-1', headRead: true), isTrue);
    expect(await downloads(ranges: false).streams('video-1', headRead: false), isFalse);
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

  test('keeps one original only: the one of the video before goes', () async {
    final loader = downloads(ranges: false);
    final first = await loader.download('video-1');
    final second = await loader.download('video-2');

    expect(first?.existsSync(), isFalse);
    expect(second?.existsSync(), isTrue);
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

  test('clear removes the downloaded original', () async {
    final loader = downloads(ranges: false);
    await loader.download('video-1');

    await loader.clear();

    expect(dir.listSync(), isEmpty);
  });
}
