// The name of a file on its tile in the browser of a share stays readable once its picture has come: the placeholder
// writes it under its icon before, then the picture covers the placeholder and the name is written over the picture on
// the scrim of the labels over a picture (white text, at least 4.5:1 on a white, a black and a busy picture), in the
// light and the dark themes. A video keeps its name above the row of marks along the bottom; the films of a Plex
// server, whose caption writes the title under the tile, get no second one; a picked file keeps its name above the
// tint of the selection.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/presentation/widgets/images/picture_label.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';

import '../../../providers/network/fakes.dart';
import '../../../test_utils/picture_label_contrast.dart';
import '../../../unit/presentation/presentation_context.dart';

class _IdleUpload extends NetworkUploadNotifier {
  @override
  NetworkUploadState build() => const NetworkUploadState();
}

class _NoRecords extends NetworkUploadRecordsNotifier {
  @override
  Map<String, UploadRecord> build() => const {};
}

const _source = NetworkSource(id: 'plex', type: NetworkSourceType.plex, name: 'Test Plex', host: '192.0.2.20');

/// A share whose server gives [answer] as the picture of each file, or none
class _PictureShare extends FakeFileSystem implements NetworkThumbnailSource {
  _PictureShare() : super(_source);

  Uint8List? answer;

  @override
  Future<Uint8List?> thumbnail(NetworkEntry entry, int size) async => answer;
}

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

  final label = find.byKey(const Key('network_media_name'));

  NetworkEntry entry(String path, {String? title}) => NetworkEntry(
    sourceId: _source.id,
    path: path,
    isDirectory: false,
    size: 1000,
    modified: DateTime.utc(2026, 10, 1),
    title: title,
  );

  Future<void> pumpTile(
    WidgetTester tester,
    NetworkEntry file, {
    Color? picture,
    Brightness brightness = Brightness.light,
    bool showName = true,
    bool? isSelected,
  }) async {
    if (picture != null) {
      share.answer = await tester.runAsync(() => solidPng(picture));
    }
    await tester.pumpTestWidget(
      context,
      Theme(
        data: ThemeData(brightness: brightness),
        child: SizedBox(
          width: 120,
          height: 120,
          child: NetworkMediaTile(entry: file, url: null, onTap: () {}, showName: showName, isSelected: isSelected),
        ),
      ),
      overrides: [
        networkMediaInfoProvider(networkMediaKey(file)).overrideWith((ref) async => null),
        networkUploadRecordsProvider.overrideWith(_NoRecords.new),
        networkUploadProvider.overrideWith(_IdleUpload.new),
        networkConnectionsProvider.overrideWith((ref) => _Connections(ref, share)),
      ],
    );
  }

  Future<void> settlePicture(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
  }

  for (final brightness in Brightness.values) {
    for (final (picture, what) in [(Colors.white, 'white'), (Colors.black, 'black')]) {
      testWidgets('the name over a $what picture, ${brightness.name} theme: white on the scrim, 4.5:1 at least', (
        tester,
      ) async {
        await pumpTile(tester, entry('/Photos/IMG_1.jpg'), picture: picture, brightness: brightness);
        await settlePicture(tester);

        expect(find.byKey(const Key('network_media_server_thumbnail')), findsOneWidget);
        expect(label, findsOneWidget);
        expect(find.descendant(of: label, matching: find.text('IMG_1.jpg')), findsOneWidget);
        expect(textColorsIn(tester, label), everyElement(Colors.white));
        // On the pixel of this picture, then on any pixel of a busy one
        expect(lowestContrast(tester, label, picture: [picture]), greaterThanOrEqualTo(smallTextContrast));
        expect(lowestContrast(tester, label), greaterThanOrEqualTo(smallTextContrast));
        // The placeholder is gone with its copy of the name
        expect(find.byIcon(Icons.image_outlined), findsNothing);
        expect(find.text('IMG_1.jpg'), findsOneWidget);
      });
    }
  }

  testWidgets('the placeholder as before: the name under its icon in the colour of the theme, no scrim', (
    tester,
  ) async {
    await pumpTile(tester, entry('/Photos/IMG_1.jpg'));
    await settlePicture(tester);

    expect(label, findsNothing);
    expect(find.byKey(PictureLabel.scrimKey), findsNothing);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    final name = tester.widget<Text>(find.text('IMG_1.jpg'));
    final scheme = Theme.of(tester.element(find.text('IMG_1.jpg'))).colorScheme;
    expect(name.style?.color, scheme.onSurface.withAlpha(150));
    expect(name.maxLines, 2);
  });

  testWidgets('the scrim lets the picture show: transparent at its top, never above 75 % black', (tester) async {
    await pumpTile(tester, entry('/Photos/IMG_1.jpg'), picture: Colors.white);
    await settlePicture(tester);

    final fade = tester.widget<DecoratedBox>(find.byKey(PictureLabel.fadeKey)).decoration as BoxDecoration;
    expect(fade.gradient!.colors.first.a, 0);
    final scrim = tester.widget<DecoratedBox>(find.byKey(PictureLabel.scrimKey)).decoration as BoxDecoration;
    for (final color in [...fade.gradient!.colors, ...scrim.gradient!.colors]) {
      expect(color.a, lessThanOrEqualTo(0.75));
    }
    // The band of the name takes the bottom of the tile only
    final band =
        tester.getBottomLeft(find.byKey(PictureLabel.scrimKey)).dy -
        tester.getTopLeft(find.byKey(PictureLabel.fadeKey)).dy;
    expect(band, lessThan(120 / 2));
    expect(
      tester.getBottomLeft(find.byKey(PictureLabel.scrimKey)).dy,
      tester.getBottomLeft(find.byType(NetworkMediaTile)).dy,
    );
  });

  testWidgets('a long file name is cut in the middle: its end and extension stay', (tester) async {
    await pumpTile(tester, entry('/Photos/PXL_20261012_143522123_PORTRAIT_FINAL.jpg'), picture: Colors.black);
    await settlePicture(tester);

    final shown = tester.widget<Text>(find.descendant(of: label, matching: find.byType(Text))).data!;
    expect(shown, contains(MiddleEllipsisText.ellipsis));
    expect(shown, startsWith('PXL_'));
    expect(shown, endsWith('.jpg'));
    final painted = tester.getSize(find.descendant(of: label, matching: find.byType(Text)));
    expect(painted.width, lessThanOrEqualTo(120 - 12));
  });

  testWidgets('a video keeps its name above the row of marks along the bottom edge', (tester) async {
    await pumpTile(tester, entry('/Videos/clip.mp4'), picture: Colors.white);
    await settlePicture(tester);

    expect(label, findsOneWidget);
    final play = tester.getRect(find.byIcon(Icons.play_circle_outline_rounded));
    final name = tester.getRect(find.descendant(of: label, matching: find.text('clip.mp4')));
    expect(name.bottom, lessThanOrEqualTo(play.top));
    expect(lowestContrast(tester, label), greaterThanOrEqualTo(smallTextContrast));
  });

  testWidgets('a film whose caption writes the title under the tile has no name over its picture', (tester) async {
    await pumpTile(tester, entry('/Films/f.mkv', title: 'The Film'), picture: Colors.white, showName: false);
    await settlePicture(tester);

    expect(find.byKey(const Key('network_media_server_thumbnail')), findsOneWidget);
    expect(label, findsNothing);
  });

  testWidgets('a picked file keeps its name above the tint of the selection, as readable', (tester) async {
    await pumpTile(tester, entry('/Photos/IMG_1.jpg'), picture: Colors.white, isSelected: true);
    await settlePicture(tester);

    expect(find.byKey(const Key('network_media_selected')), findsOneWidget);
    expect(label, findsOneWidget);
    // Painted after the tint: the tint is not over the name
    final stack = find.descendant(of: find.byType(NetworkMediaTile), matching: find.byType(Stack)).first;
    final children = tester.widget<Stack>(stack).children;
    final tint = children.indexWhere((child) => child.runtimeType.toString() == '_SelectionMark');
    final name = children.indexWhere((child) => child is ValueListenableBuilder);
    expect(tint, isNonNegative);
    expect(name, greaterThan(tint));
    expect(lowestContrast(tester, label), greaterThanOrEqualTo(smallTextContrast));
  });
}
