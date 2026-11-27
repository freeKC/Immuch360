// What a copy puts on the clipboard (lib/desktop/clipboard/clipboard_copy.dart and desktop_clipboard.dart), with a fake
// clipboard: one photo gives its file and its picture, one video its file only, a selection its files in order and no
// picture; a remote file is fetched first and its folder marked with the token of the write; a cancel or a failure
// writes nothing and leaves no copy. The file of an asset: the one of this computer, else the original of the server.
// The picture of a photo: its file for the macOS runner, a PNG and a 24 bit bitmap from the engine elsewhere, scaled
// down past its limit, none for a file the engine cannot decode. Then the channel itself, as the runners get it.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/clipboard/clipboard_copies.dart';
import 'package:immich_mobile/desktop/clipboard/clipboard_copy.dart';
import 'package:immich_mobile/desktop/clipboard/desktop_clipboard.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:path/path.dart' as p;

import '../../fixtures/asset.stub.dart';
import 'recording_copier.dart';

void main() {
  late Directory work;
  late Directory root;
  late FakeDesktopClipboard clipboard;
  late List<String> pictured;
  late ClipboardCopier copier;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('clipboard-copy-test');
    root = Directory(p.join(work.path, 'copies'));
    clipboard = FakeDesktopClipboard();
    pictured = [];
    copier = ClipboardCopier(
      clipboard: clipboard,
      root: () async => root,
      picture: (path) async {
        pictured.add(path);
        return ClipboardPicture(png: Uint8List.fromList([1, 2, 3]));
      },
      systemTokens: true,
    );
  });
  tearDown(() async => work.delete(recursive: true));

  File file(String name) => File(p.join(work.path, name))..writeAsBytesSync([1, 2, 3, 4]);

  group('the copier', () {
    test('one photo: its file and its picture', () async {
      final photo = file('IMG_1.jpg');
      expect(await copier.copy([LocalClipboardSource(photo.path, isVideo: false)]), (files: 1, picture: true));
      expect(clipboard.writes.single.paths, [photo.path]);
      expect(clipboard.writes.single.picture?.png, [1, 2, 3]);
      expect(pictured, [photo.path]);
    });

    test('one video: its file only, no picture made', () async {
      final video = file('clip.mp4');
      expect(await copier.copy([LocalClipboardSource(video.path, isVideo: true)]), (files: 1, picture: false));
      expect(clipboard.writes.single.paths, [video.path]);
      expect(clipboard.writes.single.picture, isNull);
      expect(pictured, isEmpty);
    });

    test('a selection: its files in order, no picture', () async {
      final a = file('a.jpg');
      final b = file('b.mp4');
      final c = file('c.jpg');
      final result = await copier.copy([
        LocalClipboardSource(a.path, isVideo: false),
        LocalClipboardSource(b.path, isVideo: true),
        LocalClipboardSource(c.path, isVideo: false),
      ]);
      expect(result, (files: 3, picture: false));
      expect(clipboard.writes.single.paths, [a.path, b.path, c.path]);
      expect(pictured, isEmpty);
    });

    test('remote files fetched first among the local ones, in place, their folder marked with the token', () async {
      final local = file('here.jpg');
      final result = await copier.copy([
        RemoteClipboardSource(
          name: 'IMG_0042.HEIC',
          isVideo: false,
          fetch: (abort) async => http.StreamedResponse(Stream.value([9, 9]), HttpStatus.ok, contentLength: 2),
        ),
        LocalClipboardSource(local.path, isVideo: false),
      ]);
      expect(result.files, 2);
      final paths = clipboard.writes.single.paths;
      expect(p.basename(paths[0]), 'IMG_0042.HEIC');
      expect(p.dirname(p.dirname(paths[0])), root.path);
      expect(File(paths[0]).readAsBytesSync(), [9, 9]);
      expect(paths[1], local.path);
      final marker = jsonDecode(File(p.join(p.dirname(paths[0]), clipboardCopyMarker)).readAsStringSync());
      expect(marker['token'], clipboard.token);
      expect(marker['run'], clipboardRun);
    });

    test('a cancel during the fetch writes nothing and leaves no copy', () async {
      final cancel = Completer<void>();
      final copying = copier.copy([
        RemoteClipboardSource(
          name: 'a.jpg',
          isVideo: false,
          fetch: (abort) => Completer<http.StreamedResponse>().future,
        ),
      ], cancelled: cancel.future);
      cancel.complete();
      await expectLater(
        copying,
        throwsA(isA<ClipboardCopyException>().having((e) => e.failure, 'failure', ClipboardCopyFailure.cancelled)),
      );
      expect(clipboard.writes, isEmpty);
      expect(root.listSync(), isEmpty);
    });

    test('a fetch that fails writes nothing; a clipboard that refuses leaves no copy', () async {
      await expectLater(
        copier.copy([
          RemoteClipboardSource(
            name: 'a.jpg',
            isVideo: false,
            fetch: (abort) async => http.StreamedResponse(const Stream.empty(), HttpStatus.internalServerError),
          ),
        ]),
        throwsA(isA<ClipboardCopyException>().having((e) => e.failure, 'failure', ClipboardCopyFailure.fetchFailed)),
      );
      expect(clipboard.writes, isEmpty);
      clipboard.refuse = true;
      await expectLater(
        copier.copy([
          RemoteClipboardSource(
            name: 'b.jpg',
            isVideo: false,
            fetch: (abort) async => http.StreamedResponse(Stream.value([1]), HttpStatus.ok),
          ),
        ]),
        throwsA(
          isA<ClipboardCopyException>().having((e) => e.failure, 'failure', ClipboardCopyFailure.clipboardRefused),
        ),
      );
      expect(root.listSync(), isEmpty);
    });

    test('the copies the clipboard no longer holds go at the next copy, once an hour old', () async {
      final stale = Directory(
        p.join(root.path, '${DateTime.now().subtract(const Duration(hours: 2)).toUtc().microsecondsSinceEpoch}'),
      )..createSync(recursive: true);
      await markClipboardCopy(stale, 3);
      await copier.copy([LocalClipboardSource(file('a.jpg').path, isVideo: true)]);
      expect(stale.existsSync(), isFalse);
    });
  });

  group('the file of an asset', () {
    Future<File?> none(String id) async => null;
    ClipboardFetch server(String remoteId, {required bool edited}) =>
        (abort) async => http.StreamedResponse(Stream.value(utf8.encode('$remoteId $edited')), HttpStatus.ok);

    test('the file of this computer when it has one', () async {
      final photo = file('IMG_1.jpg');
      final source = await clipboardSourceOfAsset(
        LocalAssetStub.image1,
        localFile: (id) async => photo,
        serverFetch: server,
      );
      expect(source, isA<LocalClipboardSource>().having((s) => s.path, 'path', photo.path));
    });

    test('else the original of the server under the name of the asset, an edit as the server keeps it', () async {
      final remote = RemoteAsset(
        id: 'r1',
        checksum: 'c1',
        ownerId: 'o1',
        name: 'IMG_0042.HEIC',
        type: AssetType.image,
        createdAt: DateTime(2025),
        updatedAt: DateTime(2025),
        isEdited: true,
      );
      final source = await clipboardSourceOfAsset(remote, localFile: none, serverFetch: server);
      expect(source, isA<RemoteClipboardSource>().having((s) => s.name, 'name', remote.name));
      final response = await (source! as RemoteClipboardSource).fetch(Completer<void>().future);
      expect(await response.stream.bytesToString(), '${remote.id} ${remote.isEdited}');
    });

    test('nothing for an asset of this computer whose file is gone and that the server does not have', () async {
      expect(await clipboardSourceOfAsset(LocalAssetStub.image1, localFile: none, serverFetch: server), isNull);
    });

    test('a video is a video', () async {
      final video = file('clip.mp4');
      final asset = LocalAssetStub.image1.copyWith(type: AssetType.video);
      final source = await clipboardSourceOfAsset(asset, localFile: (id) async => video, serverFetch: server);
      expect(source?.isVideo, isTrue);
    });
  });

  group('the picture of a photo', () {
    Future<Uint8List> png(int width, int height) async {
      final recorder = ui.PictureRecorder();
      Canvas(
        recorder,
      ).drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = const Color(0xFF336699));
      final image = await recorder.endRecording().toImage(width, height);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return bytes!.buffer.asUint8List();
    }

    test('macOS: the runner reads the file itself', () async {
      final picture = await clipboardPictureOf(
        '/photos/a.heic',
        () async => Uint8List(0),
        platform: TargetPlatform.macOS,
      );
      expect(picture?.sourcePath, '/photos/a.heic');
      expect(picture?.png, isNull);
    });

    testWidgets('Windows: a PNG and a bitmap at the size of the photo; Linux: the PNG; past the limit, smaller', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final bytes = await png(30, 20);
        final windows = await clipboardPictureOf('a.png', () async => bytes, platform: TargetPlatform.windows);
        expect(windows?.png, isNotNull);
        final header = ByteData.sublistView(windows!.dib!, 0, dibHeaderSize);
        expect(header.getInt32(4, Endian.little), 30);
        expect(header.getInt32(8, Endian.little), 20);
        expect(header.getUint16(14, Endian.little), 24);
        expect(windows.dib!.length, dibHeaderSize + 92 * 20, reason: 'rows of 90 bytes padded to 92');

        final linux = await clipboardPictureOf('a.png', () async => bytes, platform: TargetPlatform.linux);
        expect(linux?.png, isNotNull);
        expect(linux?.dib, isNull);

        final small = await clipboardPictureOf(
          'a.png',
          () async => bytes,
          platform: TargetPlatform.windows,
          maxPixels: 150,
        );
        final smallHeader = ByteData.sublistView(small!.dib!, 0, dibHeaderSize);
        expect(smallHeader.getInt32(4, Endian.little) * smallHeader.getInt32(8, Endian.little), lessThanOrEqualTo(150));

        expect(
          await clipboardPictureOf(
            'a.cr3',
            () async => Uint8List.fromList(List.filled(64, 7)),
            platform: TargetPlatform.linux,
          ),
          isNull,
          reason: 'a file the engine does not decode: its file only',
        );
      });
    });

    test('the bitmap: bottom row first, blue green red, rows padded, transparency on white', () {
      // 2 by 2: top row red then half transparent black, bottom row green then blue
      final rgba = Uint8List.fromList([
        255, 0, 0, 255, 0, 0, 0, 128, //
        0, 255, 0, 255, 0, 0, 255, 255,
      ]);
      final dib = dibOfRgba(rgba, 2, 2);
      expect(dib.length, dibHeaderSize + 8 * 2);
      final bottom = dib.sublist(dibHeaderSize, dibHeaderSize + 8);
      final top = dib.sublist(dibHeaderSize + 8);
      expect(bottom, [0, 255, 0, 255, 0, 0, 0, 0], reason: 'green, blue, two bytes of padding');
      expect(top.sublist(0, 3), [0, 0, 255], reason: 'red');
      expect(top.sublist(3, 6), everyElement(inInclusiveRange(125, 129)), reason: 'black at half on white: grey');
    });
  });

  group('the channel', () {
    const channel = MethodChannel('immuch360/clipboard-test');
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'writeFiles' => 41,
          'holds' => throw PlatformException(code: 'clipboard'),
          _ => null,
        };
      });
    });
    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );

    test(
      'writeFiles gets the paths and the forms of the picture there are; holds keeps the copies when unsure',
      () async {
        const clipboard = ChannelDesktopClipboard(channel: channel);
        final token = await clipboard.writeFiles(
          ClipboardPayload(
            paths: const ['/a.jpg'],
            picture: ClipboardPicture(png: Uint8List.fromList([1]), dib: Uint8List.fromList([2])),
          ),
        );
        expect(token, 41);
        expect(calls.single.method, 'writeFiles');
        expect(calls.single.arguments, {
          'paths': ['/a.jpg'],
          'png': [1],
          'dib': [2],
        });
        await clipboard.writeFiles(const ClipboardPayload(paths: ['/b.mp4', '/c.jpg']));
        expect(calls.last.arguments, {
          'paths': ['/b.mp4', '/c.jpg'],
        });
        await clipboard.writeFiles(
          const ClipboardPayload(
            paths: ['/d.heic'],
            picture: ClipboardPicture(sourcePath: '/d.heic'),
          ),
        );
        expect(calls.last.arguments, {
          'paths': ['/d.heic'],
          'imagePath': '/d.heic',
        });
        expect(await clipboard.holds(41), isTrue, reason: 'a runner that cannot tell keeps the copies');
      },
    );
  });
}
