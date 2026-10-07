// A share whose server makes the pictures of its media (a Plex server) shows those in the tiles of the browser, read
// through the open connection of the share, never from a URL holding a credential. Without one, or when it fails, the
// tile shows its own picture; the URL a DLNA media server gives keeps its way.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_server_thumbnail_image.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';

import '../../../providers/network/fakes.dart';
import '../../../unit/presentation/presentation_context.dart';

/// No upload under way
class _IdleUpload extends NetworkUploadNotifier {
  @override
  NetworkUploadState build() => const NetworkUploadState();
}

/// No file of the share sent to the server yet
class _NoRecords extends NetworkUploadRecordsNotifier {
  @override
  Map<String, UploadRecord> build() => const {};
}

const _source = NetworkSource(id: 'plex', type: NetworkSourceType.plex, name: 'Test Plex', host: '192.0.2.20');

/// A share whose server makes pictures: [answer] for each, or [error] thrown
class _PictureShare extends FakeFileSystem implements NetworkThumbnailSource {
  _PictureShare() : super(_source);

  Uint8List? answer;
  Exception? error;
  final List<(String, int)> asked = [];

  @override
  Future<Uint8List?> thumbnail(NetworkEntry entry, int size) async {
    asked.add((entry.path, size));
    final error = this.error;
    if (error != null) {
      throw error;
    }
    return answer;
  }
}

/// The connections of the app with [share] open
class _Connections extends NetworkConnections {
  _Connections(Ref ref, this.share) : super(ref, FakeMediaBridge());

  final NetworkFileSystem share;

  @override
  NetworkFileSystem? opened(String sourceId) => sourceId == share.source.id ? share : null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PresentationContext context;
  late _PictureShare share;

  setUp(() async {
    context = await PresentationContext.create();
    share = _PictureShare();
  });

  tearDown(() async {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await context.dispose();
  });

  final serverPicture = find.byKey(const Key('network_media_server_thumbnail'));

  NetworkEntry entry(String path, {String? thumbnailUrl}) => NetworkEntry(
    sourceId: _source.id,
    path: path,
    isDirectory: false,
    size: 1000,
    modified: DateTime.utc(2026, 10, 1),
    thumbnailUrl: thumbnailUrl,
  );

  Future<void> pumpTile(WidgetTester tester, NetworkEntry file, {NetworkFileSystem? open, bool picture = false}) async {
    final png = (await tester.runAsync(() async {
      final image = await createTestImage(width: 8, height: 4);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return bytes!.buffer.asUint8List();
    }))!;
    if (picture) {
      share.answer = png;
    }
    await tester.pumpTestWidget(
      context,
      SizedBox(
        width: 120,
        height: 120,
        child: NetworkMediaTile(entry: file, url: null, onTap: () {}),
      ),
      overrides: [
        networkMediaInfoProvider(networkMediaKey(file)).overrideWith((ref) async => null),
        networkUploadRecordsProvider.overrideWith(_NoRecords.new),
        networkUploadProvider.overrideWith(_IdleUpload.new),
        networkConnectionsProvider.overrideWith((ref) => _Connections(ref, open ?? share)),
      ],
    );
  }

  /// Lets the picture load or fail outside the fake time of the test
  Future<void> settlePicture(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
  }

  testWidgets('shows the picture the server makes, asked through the connection of the share', (tester) async {
    await pumpTile(tester, entry('/Photos/pano.jpg'), picture: true);
    await settlePicture(tester);

    expect(serverPicture, findsOneWidget);
    final image = tester.widget<Image>(serverPicture).image;
    expect(image, isA<NetworkServerThumbnailImage>());
    expect((image as NetworkServerThumbnailImage).size, 256);
    expect(share.asked, [('/Photos/pano.jpg', 256)]);
    expect(
      tester.widget<RawImage>(find.descendant(of: serverPicture, matching: find.byType(RawImage))).image,
      isNotNull,
    );
  });

  testWidgets('shows the picture of the tile when the server has none', (tester) async {
    await pumpTile(tester, entry('/Photos/flat.jpg'));
    await settlePicture(tester);

    expect(share.asked, hasLength(1));
    expect(find.descendant(of: serverPicture, matching: find.byIcon(Icons.image_outlined)), findsOneWidget);
  });

  testWidgets('shows the picture of the tile when the server fails', (tester) async {
    share.error = const NetworkFileSystemException('The server is busy');
    await pumpTile(tester, entry('/Videos/clip.mp4'));
    await settlePicture(tester);

    expect(find.descendant(of: serverPicture, matching: find.byIcon(Icons.movie_outlined)), findsOneWidget);
  });

  testWidgets('a share whose server makes no picture shows the picture of the tile alone', (tester) async {
    await pumpTile(tester, entry('/Photos/flat.jpg'), open: FakeFileSystem(_source));

    expect(serverPicture, findsNothing);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
  });

  testWidgets('the URL of a DLNA picture keeps its way, whatever the connection makes', (tester) async {
    await pumpTile(tester, entry('/Photos/flat.jpg', thumbnailUrl: 'http://192.0.2.10:8200/AlbumArt/22-1.jpg'));

    final image = tester.widget<Image>(serverPicture).image as ResizeImage;
    expect(image.width, 256);
    expect((image.imageProvider as NetworkImage).url, 'http://192.0.2.10:8200/AlbumArt/22-1.jpg');
    expect(share.asked, isEmpty);
  });

  test('a server picture is known to the image cache by its file and size, not by its connection', () {
    final file = entry('/a.jpg');
    expect(NetworkServerThumbnailImage(share, file), NetworkServerThumbnailImage(_PictureShare(), file));
    expect(
      NetworkServerThumbnailImage(share, file).hashCode,
      NetworkServerThumbnailImage(_PictureShare(), file).hashCode,
    );
    expect(NetworkServerThumbnailImage(share, file), isNot(NetworkServerThumbnailImage(share, file, size: 512)));
    expect(NetworkServerThumbnailImage(share, file), isNot(NetworkServerThumbnailImage(share, entry('/b.jpg'))));
  });
}
