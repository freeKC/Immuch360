// The AV2 files of a share on a computer (network_media_tile.widget.dart, networkAv2HeadProvider; store/m2/
// av2-2026-11-02/plan-2026-11-02.md, section 1.2): the head of an .ivf or .obu is read, 32 bytes, and an AV2 file gets
// the "AV2" badge of the 3D splat tiles on a neutral tile, no frame asked of mpv; an IVF of AV1 is a video as any other;
// nothing is read on a phone, which does not list them.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/av2_decoding.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/av2_stream.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';

import '../../../unit/presentation/presentation_context.dart';
import '../../pages/network/network_viewer_fakes.dart';

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

const _source = NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'Home NAS', host: 'nas', share: 'media');

Uint8List _fixture(String name) => File('test/fixtures/av2/$name').readAsBytesSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PresentationContext context;
  late MemoryShare share;
  late List<NetworkVideoThumbnailRequest> frames;

  setUp(() async {
    context = await PresentationContext.create();
    share = MemoryShare(
      _source,
      files: {
        '/clips/cosmos.ivf': _fixture('av2-256x144-8bit.ivf'),
        '/clips/cosmos.obu': _fixture('av2-256x144-10bit.obu'),
        '/clips/old.ivf': _fixture('av1-256x144-8bit.ivf'),
      },
    );
    frames = [];
  });

  tearDown(() => context.dispose());

  final badge = find.byKey(const Key('network_media_av2_badge'));

  Future<void> pumpTile(WidgetTester tester, String path, {bool? isSelected}) => tester.pumpTestWidget(
    context,
    SizedBox(
      width: 120,
      height: 120,
      child: NetworkMediaTile(
        entry: share.file(path),
        url: Uri.parse('http://127.0.0.1:1234/token/nas$path'),
        onTap: () {},
        isSelected: isSelected,
      ),
    ),
    overrides: [
      overrideConnections((ref) => FakeConnections(ref, share)),
      // The scope of the test is nested in that of PresentationContext: the head is read in it, as the provider does
      // (its own test is below)
      networkAv2HeadProvider.overrideWith(
        (ref, key) async => readAv2Head(await share.readRange(key.path, 0, av2HeadLength)),
      ),
      networkMediaInfoProvider(networkMediaKey(share.file(path))).overrideWith((ref) async => null),
      networkVideoThumbnailProvider.overrideWith((ref, request) async {
        frames.add(request);
        return null;
      }),
      networkUploadRecordsProvider.overrideWith(_NoRecords.new),
      networkUploadProvider.overrideWith(_IdleUpload.new),
      isHorizonOsProvider.overrideWith((ref) async => false),
    ],
  );

  final desktop = TargetPlatformVariant.only(TargetPlatform.windows);

  testWidgets('an AV2 file: its 32 first bytes read, the AV2 badge on a neutral tile, no frame asked of mpv', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpTile(tester, '/clips/cosmos.ivf');
    expect(share.reads, [('/clips/cosmos.ivf', 0, 32)]);
    expect(badge, findsOneWidget);
    expect(find.descendant(of: badge, matching: find.text('AV2')), findsOneWidget);
    final style = tester.widget<Text>(find.text('AV2')).style!;
    expect(style.color, Theme.of(tester.element(badge)).colorScheme.primary);
    expect(find.text('cosmos.ivf'), findsOneWidget, reason: 'the name on the neutral tile');
    expect(frames, isEmpty);
    expect(find.bySemanticsLabel('cosmos.ivf, AV2'), findsOneWidget);
    semantics.dispose();
  }, variant: desktop);

  testWidgets('a Section 5 stream too', (tester) async {
    await pumpTile(tester, '/clips/cosmos.obu');
    expect(badge, findsOneWidget);
    expect(frames, isEmpty);
  }, variant: desktop);

  testWidgets('an IVF of AV1 is a video as any other: no badge, a frame once its head is read', (tester) async {
    await pumpTile(tester, '/clips/old.ivf');
    expect(badge, findsNothing);
    expect(frames.map((request) => request.key.path), ['/clips/old.ivf']);
  }, variant: desktop);

  testWidgets('while files are picked, the badge stands beside the selection mark', (tester) async {
    await pumpTile(tester, '/clips/cosmos.ivf', isSelected: false);
    expect(tester.widget<Positioned>(badge).left, 32);
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpTile(tester, '/clips/cosmos.ivf');
    expect(tester.widget<Positioned>(badge).left, 6);
  }, variant: desktop);

  testWidgets('a phone reads nothing: it does not list these files', (tester) async {
    await pumpTile(tester, '/clips/cosmos.ivf');
    expect(share.reads, isEmpty);
    expect(badge, findsNothing);
  });

  group('the head of a file of a share', () {
    test('read for an .ivf or .obu on a computer, never for another file nor on a phone', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final container = ProviderContainer(overrides: [overrideConnections((ref) => FakeConnections(ref, share))]);
      addTearDown(() {
        container.dispose();
        debugDefaultTargetPlatformOverride = null;
      });
      share.files['/clips/clip.mp4'] = Uint8List(64);
      final head = await container.read(
        networkAv2HeadProvider(networkMediaKey(share.file('/clips/cosmos.ivf'))).future,
      );
      expect((head?.width, head?.height), (256, 144));
      expect(await container.read(networkAv2HeadProvider(networkMediaKey(share.file('/clips/old.ivf'))).future), null);
      expect(await container.read(networkAv2HeadProvider(networkMediaKey(share.file('/clips/clip.mp4'))).future), null);
      expect(share.reads.map((read) => read.$1), ['/clips/cosmos.ivf', '/clips/old.ivf']);

      // A file gone from the share since it was listed
      final gone = await container.read(networkAv2HeadProvider(networkMediaKey(share.file('/clips/gone.ivf'))).future);
      expect(gone, isNull);

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(
        await container.read(networkAv2HeadProvider(networkMediaKey(share.file('/clips/cosmos.obu'))).future),
        null,
      );
      expect(share.reads.map((read) => read.$1), isNot(contains('/clips/cosmos.obu')));
    });
  });
}
