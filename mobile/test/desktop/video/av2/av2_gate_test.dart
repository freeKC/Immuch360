// What shows before an AV2 video plays (av2_gate.dart; store/m2/av2-2026-11-02/plan-2026-11-02.md, sections 1.3 and
// 1.4): the notices of a phone, of the setting turned off and of an old libmpv on a Mac, the card of the AV2 decoder
// (size, licence, Download and play, its progress, Cancel, a failure, a version that does not offer it), the format a
// probe refuses, and the notice of a computer too slow with Play anyway. The player is a text here: what the gate lets
// in once everything is settled.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/av2_decoder.dart';
import 'package:immich_mobile/desktop/video/av2_decoding.dart';
import 'package:immich_mobile/desktop/video/av2_gate.dart';
import 'package:immich_mobile/desktop/video/video_licenses.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_downloader.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/domain/services/av2_stream.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

import '../../../presentation/widgets/ai_immersive/fake_ai_components_service.dart';
import '../../../unit/presentation/presentation_context.dart';
import 'av2_test_components.dart';

const _head = Av2Head.ivf(width: 1920, height: 1080, rate: 24, scale: 1, framesInHeader: 240, headerLength: 32);
const _video = Av2VideoRef.file('/videos/cosmos.ivf', _head);
const _player = Text('the player');

void main() {
  late PresentationContext context;
  late FakeAiComponentsService service;
  late List<Av2VideoRef> probed;
  late Future<Av2VideoFormat> Function(Av2VideoRef video) probe;
  late Av2Speed? Function(Av2VideoFormat format) speed;

  setUp(() async {
    context = await PresentationContext.create();
    service = FakeAiComponentsService(catalogue: av2CompleteCatalogue);
    probed = [];
    probe = (video) async => Av2VideoFormat.ofHead(video.head);
    speed = (_) => null;
  });

  tearDown(() => context.dispose());

  Future<void> pumpGate(WidgetTester tester, {AiPlatform? platform = AiPlatform.windowsX64}) => tester.pumpTestWidget(
    context,
    const Av2PlaybackGate(video: _video, child: _player),
    overrides: [
      // The scope of the test is nested in that of PresentationContext: the decoder is made in it
      av2DecoderProvider.overrideWith((ref) => Av2Decoder(service, platform)),
      av2ProbeProvider.overrideWithValue((video) {
        probed.add(video);
        return probe(video);
      }),
      av2SpeedProvider.overrideWithValue((format) => speed(format)),
    ],
  );

  void installed() => service.setStatus(av2WindowsComplete, const AiComponentStatus(AiComponentState.installed));

  final desktop = TargetPlatformVariant.only(TargetPlatform.windows);

  testWidgets('a phone says AV2 videos play in Immuch360 Desktop only, and plays nothing', (tester) async {
    await pumpGate(tester, platform: null);
    expect(find.text('AV2 videos play in Immuch360 Desktop only for now (Windows, Linux, macOS)'), findsOneWidget);
    expect(find.text('the player'), findsNothing);
    expect(service.installs, isEmpty);
  });

  testWidgets('the setting off says so, and its switch there turns it on', (tester) async {
    await SettingsRepository.instance.write(.viewerAv2Videos, false);
    await pumpGate(tester);
    expect(find.byKey(const Key('av2_notice_off')), findsOneWidget);
    expect(find.text('the player'), findsNothing);

    await tester.tap(find.byKey(const Key('av2_turn_on')));
    await tester.pumpAndSettle();
    expect(SettingsRepository.instance.appConfig.viewer.av2Videos, isTrue);
    expect(find.byKey(const Key('av2_install_card')), findsOneWidget);
  }, variant: desktop);

  testWidgets('the card of the decoder: what it is, its size and its licence, and nothing downloaded before the tap', (
    tester,
  ) async {
    await pumpGate(tester);
    expect(find.text('Play AV2 videos (experimental)'), findsOneWidget);
    expect(
      find.text(
        'This video is AV2, a format no device decodes in hardware yet. Immuch360 can decode it with the processor of '
        'this computer: download the AV2 decoder once (${formatBytes(790281)}, open source: dav2d by VideoLAN, '
        'BSD-2-Clause).',
      ),
      findsOneWidget,
    );
    expect(find.text('Licence: BSD-2-Clause'), findsOneWidget);
    expect(find.text('Download and play'), findsOneWidget);
    expect(find.text('the player'), findsNothing);
    expect(service.installs, isEmpty);
    expect(probed, isEmpty);
  }, variant: desktop);

  testWidgets('Download and play: the progress, then the player once the decoder is installed', (tester) async {
    final hold = Completer<void>();
    service.onInstall = (component) {
      service.setStatus(component, const AiComponentStatus(AiComponentState.downloading, received: 400, total: 1000));
      return hold.future;
    };
    await pumpGate(tester);

    await tester.tap(find.text('Download and play'));
    await tester.pump();
    expect(service.spaceAsked, [
      ['av2-decoder-windows-x64'],
    ]);
    expect(service.installs, ['av2-decoder-windows-x64']);
    expect(find.text('Downloading the AV2 decoder: 40%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('the player'), findsNothing);

    hold.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('av2_install_card')), findsNothing);
    expect(find.text('the player'), findsOneWidget);
    expect(probed, [_video]);
  }, variant: desktop);

  testWidgets('Cancel stops the download, and the card stays', (tester) async {
    final hold = Completer<void>();
    service.onInstall = (_) => hold.future;
    await pumpGate(tester);

    await tester.tap(find.text('Download and play'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(service.cancels, ['av2-decoder-windows-x64']);

    hold.completeError(const AiDownloadException(AiDownloadFailure.cancelled, 'cancelled'));
    await tester.pumpAndSettle();
    expect(find.text('Download and play'), findsOneWidget);
    expect(find.byKey(const Key('av2_install_failure')), findsNothing);
  }, variant: desktop);

  testWidgets('a download that fails says why, and Download and play tries again', (tester) async {
    var attempts = 0;
    service.onInstall = (_) async {
      if (attempts++ == 0) {
        throw const AiDownloadException(AiDownloadFailure.network, 'no route');
      }
    };
    await pumpGate(tester);

    await tester.tap(find.text('Download and play'));
    await tester.pumpAndSettle();
    expect(find.text('Download failed: the server cannot be reached'), findsOneWidget);
    expect(find.text('the player'), findsNothing);

    await tester.tap(find.text('Download and play'));
    await tester.pumpAndSettle();
    expect(find.text('the player'), findsOneWidget);
  }, variant: desktop);

  testWidgets('a drive too small is said before the first byte', (tester) async {
    service.shortage = const AiSpaceShortage(volume: 'C:', needed: 1100000000, free: 300000000);
    await pumpGate(tester);

    await tester.tap(find.text('Download and play'));
    await tester.pumpAndSettle();
    expect(service.installs, isEmpty);
    expect(find.textContaining('Not enough space on C:'), findsOneWidget);
  }, variant: desktop);

  testWidgets('an error that is no failed download is said with the sentence of the decoder', (tester) async {
    service.onInstall = (_) async => throw StateError('the folder is gone');
    await pumpGate(tester);

    await tester.tap(find.text('Download and play'));
    await tester.pumpAndSettle();
    expect(find.text('The AV2 decoder was not downloaded: Bad state: the folder is gone'), findsOneWidget);
  }, variant: desktop);

  testWidgets('a version without the sum of the decoder says it is not in this version, with no button', (
    tester,
  ) async {
    service = FakeAiComponentsService();
    await pumpGate(tester);
    expect(find.text('Not in this version of the app'), findsOneWidget);
    expect(find.text('Download and play'), findsNothing);
    expect(find.text('the player'), findsNothing);
  }, variant: desktop);

  testWidgets('installed: the probe, then the player', (tester) async {
    installed();
    await pumpGate(tester);
    expect(find.text('the player'), findsOneWidget);
    expect(probed, [_video]);
  }, variant: desktop);

  testWidgets('a format the decoder does not play is named, and nothing plays', (tester) async {
    installed();
    probe = (_) async => const Av2VideoFormat(frameRate: 24, bitDepth: 10, refusedFormat: '4:4:4 10-bit');
    await pumpGate(tester);
    expect(
      find.text('This AV2 video is 4:4:4 10-bit: this version of the AV2 decoder does not play it yet'),
      findsOneWidget,
    );
    expect(find.text('the player'), findsNothing);
  }, variant: desktop);

  testWidgets('a probe that fails says the decoder stopped on this video', (tester) async {
    installed();
    probe = (_) async => throw const FormatException('not an AV2 stream');
    await pumpGate(tester);
    expect(find.text('The AV2 decoder stopped on this video: FormatException: not an AV2 stream'), findsOneWidget);
  }, variant: desktop);

  testWidgets('a format measured too slow here: the numbers, then Play anyway plays it', (tester) async {
    installed();
    final asked = <Av2VideoFormat>[];
    speed = (format) {
      asked.add(format);
      return const Av2Speed(decodedFps: 7.4, neededFps: 24);
    };
    await pumpGate(tester);
    expect(asked.single, const Av2VideoFormat(width: 1920, height: 1080, frameRate: 24));
    expect(
      find.text(
        'This computer decodes this AV2 video at about 7.4 frames per second and it needs 24: it will pause to catch up',
      ),
      findsOneWidget,
    );
    expect(find.text('the player'), findsNothing);

    await tester.tap(find.text('Play anyway'));
    await tester.pumpAndSettle();
    expect(find.text('the player'), findsOneWidget);
  }, variant: desktop);

  testWidgets('a format measured fast enough here, or never measured, plays at once', (tester) async {
    installed();
    speed = (_) => const Av2Speed(decodedFps: 23, neededFps: 24);
    await pumpGate(tester);
    expect(find.text('the player'), findsOneWidget, reason: '0.96 times the real time is enough');
  }, variant: desktop);

  testWidgets('a Mac with the libmpv of before lot AD4 says it needs a newer Immuch360 Desktop', (tester) async {
    installed();
    await pumpGate(tester, platform: AiPlatform.macosArm64);
    expect(macosLibmpvWithoutY4m, contains(macosLibmpvRelease));
    expect(find.text('AV2 videos need a newer Immuch360 Desktop on this Mac'), findsOneWidget);
    expect(find.text('the player'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Linux has its own decoder, offered the same way', (tester) async {
    await pumpGate(tester, platform: AiPlatform.linuxX64);
    expect(find.text('Download and play'), findsOneWidget);
    await tester.tap(find.text('Download and play'));
    await tester.pumpAndSettle();
    expect(service.installs, ['av2-decoder-linux-x64']);
    expect(find.text('the player'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  group('named like an AV2 file', () {
    test('.ivf and .obu, in any case, and nothing else', () {
      for (final name in ['a.ivf', 'B.IVF', 'c.obu', 'clip.Obu']) {
        expect(isAv2FileName(name), isTrue, reason: name);
      }
      for (final name in ['a.mp4', 'ivf', 'a.ivf.mp4', 'a.webm', 'a.mkv', 'obu']) {
        expect(isAv2FileName(name), isFalse, reason: name);
      }
    });

    test('a libmpv of macOS rebuilt by lot AD4 plays the pictures of the decoder', () {
      expect(av2PlaysWithMacLibmpv('libmpv-macos-20261020-9'), isFalse);
      expect(av2PlaysWithMacLibmpv('libmpv-macos-20261102-12'), isTrue);
    });

    test('the frames per second as the texts say them', () {
      expect(av2FpsText(7.4, 'en'), '7.4');
      expect(av2FpsText(7.0, 'en'), '7');
      expect(av2FpsText(120.4, 'en'), '120');
      expect(av2FpsText(24, 'en', exact: true), '24');
      expect(av2FpsText(29.97, 'en', exact: true), '29.97');
      expect(av2FpsText(7.4, 'fr'), '7,4');
      expect(av2FpsText(7.4, 'zz-ZZ'), '7.4');
    });

    test('the speed of a format: too slow under 0.95 times its frame rate', () {
      expect(const Av2Speed(decodedFps: 7.4, neededFps: 24).tooSlow, isTrue);
      expect(const Av2Speed(decodedFps: 22.7, neededFps: 24).tooSlow, isTrue);
      expect(const Av2Speed(decodedFps: 22.8, neededFps: 24).tooSlow, isFalse);
      expect(const Av2Speed(decodedFps: 120, neededFps: 30).ratio, 4);
    });

    test('the format of a head: an IVF gives its size and its rate, a Section 5 stream 30 frames a second', () {
      expect(Av2VideoFormat.ofHead(_head), const Av2VideoFormat(width: 1920, height: 1080, frameRate: 24));
      const ntsc = Av2Head.ivf(
        width: 1080,
        height: 1920,
        rate: 60000,
        scale: 1001,
        framesInHeader: 2,
        headerLength: 32,
      );
      expect(Av2VideoFormat.ofHead(ntsc).frameRate, closeTo(59.94, 0.01));
      expect(Av2VideoFormat.ofHead(const Av2Head.obu()), const Av2VideoFormat(frameRate: 30));
    });
  });

  test('the target platform is reset', () => expect(debugDefaultTargetPlatformOverride, isNull));
}
