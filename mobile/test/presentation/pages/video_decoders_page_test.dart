import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/presentation/pages/video_decoders.page.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';

import '../../unit/presentation/presentation_context.dart';

/// Lists [decoders], or fails with [failure]
class _FakeVideoDecoderApi extends VideoDecoderApi {
  _FakeVideoDecoderApi(this.decoders);

  final List<DecoderInfo> decoders;
  Exception? failure;

  @override
  Future<List<DecoderInfo>> listDecoders() async {
    final failure = this.failure;
    if (failure != null) {
      throw failure;
    }
    return decoders;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PresentationContext context;

  // As a Meta Quest 3 lists them: its preferred decoder of each codec first
  final decoders = [
    DecoderInfo(
      name: 'c2.qti.avc.decoder',
      codec: 'video/avc',
      hardware: true,
      maxWidth: 4096,
      maxHeight: 2304,
      maxFrameRate: 60,
    ),
    DecoderInfo(
      name: 'c2.qti.hevc.decoder',
      codec: 'video/hevc',
      hardware: true,
      maxWidth: 8192,
      maxHeight: 4320,
      maxFrameRate: 30,
    ),
    DecoderInfo(
      name: 'c2.android.avc.decoder',
      codec: 'video/avc',
      hardware: false,
      maxWidth: 4080,
      maxHeight: 4080,
      maxFrameRate: 0,
    ),
  ];

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  Future<void> pumpPage(WidgetTester tester, _FakeVideoDecoderApi api) => tester.pumpTestWidget(
    context,
    const VideoDecodersPage(),
    overrides: [videoDecodersProvider.overrideWith((ref) => api.listDecoders())],
  );

  testWidgets('lists the decoders by codec, with their kind, their largest frame and their frame rate', (tester) async {
    await pumpPage(tester, _FakeVideoDecoderApi(decoders));

    expect(find.text('Video decoders of this device'), findsOneWidget);
    expect(find.text('H.264  •  video/avc'), findsOneWidget);
    expect(find.text('HEVC  •  video/hevc'), findsOneWidget);
    expect(find.text('c2.qti.avc.decoder'), findsOneWidget);
    expect(find.text('Hardware  •  Up to 4096 x 2304  •  60 fps'), findsOneWidget);
    expect(find.text('Hardware  •  Up to 8192 x 4320  •  30 fps'), findsOneWidget);
    expect(find.text('Software  •  Up to 4080 x 4080'), findsOneWidget, reason: 'no frame rate when unknown');
    // The H.264 decoders together, under their codec
    final avc = tester.getTopLeft(find.text('H.264  •  video/avc')).dy;
    final hevc = tester.getTopLeft(find.text('HEVC  •  video/hevc')).dy;
    expect(tester.getTopLeft(find.text('c2.android.avc.decoder')).dy, inExclusiveRange(avc, hevc));
  });

  testWidgets('copies a plain text report', (tester) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    await pumpPage(tester, _FakeVideoDecoderApi(decoders));

    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();

    expect(copied, startsWith('Video decoders ('));
    expect(copied, endsWith(videoDecodersReport(decoders).substring('Video decoders'.length)));
    expect(find.text('Copied'), findsOneWidget);
  });

  testWidgets('says so when the decoders cannot be listed, with nothing to copy', (tester) async {
    await pumpPage(tester, _FakeVideoDecoderApi(decoders)..failure = PlatformException(code: 'channel-error'));

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('Copy'), findsNothing);
  });

  testWidgets('says so when the device lists no decoder', (tester) async {
    await pumpPage(tester, _FakeVideoDecoderApi(const []));

    expect(find.text('No results'), findsOneWidget);
    expect(find.text('Copy'), findsNothing);
  });

  test('writes the report by codec, in the order the system lists the decoders', () {
    expect(
      videoDecodersReport(decoders, system: 'android 14'),
      'Video decoders (android 14)\n'
      'H.264 (video/avc)\n'
      '  c2.qti.avc.decoder: hardware, up to 4096 x 2304, 60 fps\n'
      '  c2.android.avc.decoder: software, up to 4080 x 4080\n'
      'HEVC (video/hevc)\n'
      '  c2.qti.hevc.decoder: hardware, up to 8192 x 4320, 30 fps',
    );
    expect(groupVideoDecoders(decoders).map((group) => group.$1), ['video/avc', 'video/hevc']);
  });
}
