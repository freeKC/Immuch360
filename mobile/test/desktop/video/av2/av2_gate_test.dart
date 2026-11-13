// What shows before an AV2 video plays (av2_gate.dart; store/m2/av2-2026-11-02/plan-2026-11-02.md, sections 1.3 and
// 1.4): the notices of a phone, of the setting turned off and of an old libmpv on a Mac, the card of the AV2 decoder
// (size, licence, Download and play, its progress, Cancel, a failure, a version that does not offer it), the format a
// probe refuses, and the notice of a computer too slow with Play anyway. The player is a text here: what the gate lets
// in once everything is settled.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/av2_decoder.dart';
import 'package:immich_mobile/desktop/video/av2_decoding.dart';
import 'package:immich_mobile/desktop/video/av2_gate.dart';
import 'package:immich_mobile/desktop/video/av2_playback.dart';
import 'package:immich_mobile/desktop/video/video_licenses.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_downloader.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/domain/services/av2_stream.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

import '../../../presentation/widgets/ai_immersive/fake_ai_components_service.dart';
import '../../../unit/presentation/presentation_context.dart';
import 'av2_test_components.dart';

const _head = Av2Head.ivf(width: 1920, height: 1080, rate: 24, scale: 1, framesInHeader: 240, headerLength: 32);
const _video = Av2VideoRef.file('/videos/cosmos.ivf', _head);
const _player = Text('the player');

/// The files of the folder library by asset id
class _Files extends StorageRepository {
  _Files(this.files);

  final Map<String, File> files;
  final asked = <String>[];

  @override
  Future<File?> getFileForAsset(String assetId) async {
    asked.add(assetId);
    return files[assetId];
  }
}

LocalAsset _asset(String id, String name) => LocalAsset(
  id: id,
  name: name,
  type: AssetType.video,
  createdAt: DateTime(2026, 11, 2),
  updatedAt: DateTime(2026, 11, 2),
  playbackStyle: AssetPlaybackStyle.video,
  isEdited: false,
);

void main() {
  late PresentationContext context;
  late FakeAiComponentsService service;
  late List<Av2VideoRef> probed;
  late Future<Av2VideoFormat> Function(Av2VideoRef video) probe;
  late Av2Speed? Function(Av2VideoFormat format) speed;
  late List<Av2VideoRef> playedAnyway;

  setUp(() async {
    context = await PresentationContext.create();
    service = FakeAiComponentsService(catalogue: av2CompleteCatalogue);
    probed = [];
    probe = (video) async => Av2VideoFormat.ofHead(video.head);
    speed = (_) => null;
    playedAnyway = [];
  });

  tearDown(() => context.dispose());

  /// The gate of [_video] on [platform]; [macLibmpv], the libmpv release of macOS the gate asks about, the pinned one
  /// when null
  Future<void> pumpGate(WidgetTester tester, {AiPlatform? platform = AiPlatform.windowsX64, String? macLibmpv}) =>
      tester.pumpTestWidget(
        context,
        const Av2PlaybackGate(video: _video, child: _player),
        overrides: [
          // The scope of the test is nested in that of PresentationContext: the decoder is made in it
          av2DecoderProvider.overrideWith((ref) => Av2Decoder(service, platform)),
          if (macLibmpv != null) av2MacLibmpvReleaseProvider.overrideWithValue(macLibmpv),
          av2ProbeProvider.overrideWithValue((video) {
            probed.add(video);
            return probe(video);
          }),
          av2SpeedProvider.overrideWithValue((format) async => speed(format)),
          av2PlayAnywayProvider.overrideWithValue(playedAnyway.add),
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
    // Where the setting is: the Asset Viewer section of the settings, its Videos group
    expect(find.text('AV2 videos are turned off: Settings, Asset Viewer, AV2 videos (experimental)'), findsOneWidget);
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
    // The words of the error, not its type
    expect(find.text('The AV2 decoder was not downloaded: the folder is gone'), findsOneWidget);
  }, variant: desktop);

  testWidgets('a version without the sum of the decoder says it is not in this version, with no button', (
    tester,
  ) async {
    service = FakeAiComponentsService(catalogue: av2IncompleteCatalogue);
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

  testWidgets('a probe that fails says the decoder stopped on this video, in its words, and Retry probes again', (
    tester,
  ) async {
    installed();
    var attempts = 0;
    probe = (video) async {
      if (attempts++ == 0) {
        throw const FormatException('not an AV2 stream');
      }
      return Av2VideoFormat.ofHead(video.head);
    };
    await pumpGate(tester);
    expect(find.text('The AV2 decoder stopped on this video: not an AV2 stream'), findsOneWidget);
    expect(find.text('the player'), findsNothing);

    await tester.tap(find.byKey(const Key('av2_retry')));
    await tester.pumpAndSettle();
    expect(find.text('the player'), findsOneWidget);
    expect(probed, [_video, _video]);
  }, variant: desktop);

  testWidgets('a file the probe cannot open is said without its path, which holds the name of the user', (
    tester,
  ) async {
    installed();
    probe = (_) async => throw const FileSystemException(
      'Cannot open file',
      r'C:\Users\Jean Dupont\Videos\cosmos.ivf',
      OSError('The process cannot access the file because it is being used by another process.', 32),
    );
    await pumpGate(tester);
    expect(
      find.text(
        'The AV2 decoder stopped on this video: The process cannot access the file because it is being used by '
        'another process.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Jean'), findsNothing);
  }, variant: desktop);

  testWidgets('a measure that cannot be read is no measure: the video plays', (tester) async {
    installed();
    speed = (_) => throw const FileSystemException('Cannot read file', '/home/jean/.local/share/measures.json');
    await pumpGate(tester);
    expect(find.text('the player'), findsOneWidget);
    expect(find.byKey(const Key('av2_notice_stopped')), findsNothing);
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
    expect(playedAnyway, isEmpty);

    await tester.tap(find.text('Play anyway'));
    await tester.pumpAndSettle();
    expect(find.text('the player'), findsOneWidget);
    expect(playedAnyway, [_video], reason: 'the playback is told, or its own check would stop the player');
  }, variant: desktop);

  testWidgets('a format measured fast enough here, or never measured, plays at once', (tester) async {
    installed();
    speed = (_) => const Av2Speed(decodedFps: 23, neededFps: 24);
    await pumpGate(tester);
    expect(find.text('the player'), findsOneWidget, reason: '0.96 times the real time is enough');
  }, variant: desktop);

  testWidgets('a Mac whose libmpv has no y4m demuxer says it needs a newer Immuch360 Desktop', (tester) async {
    installed();
    await pumpGate(tester, platform: AiPlatform.macosArm64, macLibmpv: 'libmpv-macos-20261020-9');
    expect(find.text('AV2 videos need a newer Immuch360 Desktop on this Mac'), findsOneWidget);
    expect(find.text('the player'), findsNothing);
    expect(service.installs, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('a Mac whose libmpv reads the y4m of the decoder is offered the decoder like the others', (tester) async {
    await pumpGate(tester, platform: AiPlatform.macosArm64, macLibmpv: 'libmpv-macos-20261102-12');
    expect(find.text('AV2 videos need a newer Immuch360 Desktop on this Mac'), findsNothing);
    expect(find.text('Download and play'), findsOneWidget);
    await tester.tap(find.text('Download and play'));
    await tester.pumpAndSettle();
    expect(service.installs, ['av2-decoder-macos-universal']);
    expect(find.text('the player'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  test('the gate asks about the libmpv the app pins, whichever release it is', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(av2MacLibmpvReleaseProvider), macosLibmpvRelease);
  });

  test('whether the decoder is installed is told again when it is installed or removed (the tiles of the shares)', () {
    final container = ProviderContainer(
      overrides: [av2DecoderProvider.overrideWith((ref) => Av2Decoder(service, AiPlatform.windowsX64))],
    );
    addTearDown(container.dispose);
    final told = <bool>[];
    container.listen(av2DecoderInstalledProvider, (_, next) => told.add(next), fireImmediately: true);
    installed();
    service.setStatus(av2WindowsComplete, const AiComponentStatus(AiComponentState.downloading));
    service.setStatus(av2WindowsComplete, const AiComponentStatus(AiComponentState.notInstalled));
    expect(told, [false, true, false]);
  });

  test('the libmpv of macOS the app pins reads the pictures of the decoder (lot AD4)', () {
    expect(macosLibmpvRelease, 'libmpv-macos-20261113-2');
    expect(macosLibmpvWithoutY4m, isNot(contains(macosLibmpvRelease)));
    expect(av2PlaysWithMacLibmpv(macosLibmpvRelease), isTrue);
  });

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
        expect(isAv2VideoPath(name), isTrue, reason: name);
      }
      for (final name in ['a.mp4', 'ivf', 'a.ivf.mp4', 'a.webm', 'a.mkv', 'obu']) {
        expect(isAv2VideoPath(name), isFalse, reason: name);
      }
    });

    test('a libmpv of macOS rebuilt by lot AD4 plays the pictures of the decoder', () {
      expect(av2PlaysWithMacLibmpv('libmpv-macos-20261020-9'), isFalse);
      expect(av2PlaysWithMacLibmpv('libmpv-macos-20261102-12'), isTrue);
      expect(av2PlaysWithMacLibmpv('libmpv-macos-20261110-1'), isTrue);
      expect(av2PlaysWithMacLibmpv('libmpv-macos-20261113-2'), isTrue);
    });

    test('the reason of an error: its words, without its type nor a path of the computer', () {
      expect(av2ErrorReason(const FormatException('not an AV2 stream')), 'not an AV2 stream');
      expect(av2ErrorReason(StateError('the folder is gone')), 'the folder is gone');
      expect(av2ErrorReason(Exception('the companion did not start')), 'the companion did not start');
      expect(
        av2ErrorReason(const FileSystemException('Cannot open file', '/home/jean/Videos/cosmos.ivf')),
        'Cannot open file',
      );
      expect(
        av2ErrorReason(const ProcessException('/home/jean/.local/share/immuch360/immuch360-av2', [], 'No such file')),
        'No such file',
      );
      // Paths written inside a message: the name of the file stays, the folders go
      expect(
        av2ErrorReason(Exception(r"cannot read 'C:\Users\Jean Dupont\Videos\été 2026.ivf' now")),
        "cannot read 'été 2026.ivf' now",
      );
      expect(av2ErrorReason(Exception(r'cannot read C:\Users\jean\cosmos.ivf')), 'cannot read cosmos.ivf');
      expect(av2ErrorReason(Exception(r'cannot read \\nas\videos\cosmos.ivf')), 'cannot read cosmos.ivf');
      expect(av2ErrorReason(Exception('cannot read /home/jean/Videos/cosmos.ivf')), 'cannot read cosmos.ivf');
      expect(
        av2ErrorReason(Exception('see https://code.videolan.org/videolan/dav2d')),
        'see https://code.videolan.org/videolan/dav2d',
        reason: 'an address stays whole',
      );
      expect(av2ErrorReason(Exception('first line\nsecond line')), 'first line');
      expect(av2ErrorReason(Exception('')), 'no reason given');
      expect(av2ErrorReason(Exception('x' * 400)).length, 160);
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

  group('the gates of the pages', () {
    Future<void> pumpPage(WidgetTester tester, Widget gate, List<Override> more) => tester.pumpTestWidget(
      context,
      gate,
      overrides: [
        av2DecoderProvider.overrideWith((ref) => Av2Decoder(service, AiPlatform.windowsX64)),
        av2ProbeProvider.overrideWithValue((video) async => Av2VideoFormat.ofHead(video.head)),
        ...more,
      ],
    );

    testWidgets('a video of the library or opened with the app: the AV2 file goes through the gate', (tester) async {
      final read = <({String id, String name})>[];
      final more = [
        av2LocalVideoProvider.overrideWith((ref, asset) async {
          read.add(asset);
          return asset.name == 'cosmos.ivf' ? _video : null;
        }),
      ];
      await pumpPage(tester, Av2AssetGate(asset: _asset('v1', 'cosmos.ivf'), child: _player), more);
      expect(find.byKey(const Key('av2_install_card')), findsOneWidget);
      expect(find.text('the player'), findsNothing);

      // An IVF of AV1: its head says no, the player has it
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpPage(tester, Av2AssetGate(asset: _asset('v2', 'old.ivf'), child: _player), more);
      expect(find.text('the player'), findsOneWidget);

      // Any other video, without a read
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpPage(tester, Av2AssetGate(asset: _asset('v3', 'clip.mp4'), child: _player), more);
      expect(find.text('the player'), findsOneWidget);
      expect(read.map((asset) => asset.name), ['cosmos.ivf', 'old.ivf']);
      expect(Av2AssetGate.applies(_asset('v3', 'clip.mp4')), isFalse);
    }, variant: desktop);

    testWidgets('a file of a share: the AV2 file goes through the gate', (tester) async {
      const av2 = (sourceId: 'nas', path: '/clips/cosmos.ivf', size: 5365, modified: null);
      const av1 = (sourceId: 'nas', path: '/clips/old.ivf', size: 442, modified: null);
      final more = [networkAv2HeadProvider.overrideWith((ref, key) async => key.path == av2.path ? _head : null)];
      await pumpPage(tester, const Av2ShareGate(file: av2, child: _player), more);
      expect(find.byKey(const Key('av2_install_card')), findsOneWidget);
      installed();
      await tester.pumpAndSettle();
      expect(find.text('the player'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await pumpPage(tester, const Av2ShareGate(file: av1, child: _player), more);
      expect(find.text('the player'), findsOneWidget);
    }, variant: desktop);

    testWidgets('a file of a share whose head cannot be read: never the player, what the share said, and Retry', (
      tester,
    ) async {
      const file = (sourceId: 'nas', path: '/clips/cosmos.ivf', size: 5365, modified: null);
      var reads = 0;
      final more = [
        networkAv2HeadProvider.overrideWith((ref, key) async {
          if (reads++ == 0) {
            throw const NetworkFileSystemException('The share does not answer');
          }
          return _head;
        }),
      ];
      await pumpPage(tester, const Av2ShareGate(file: file, child: _player), more);
      expect(find.text('the player'), findsNothing);
      expect(find.byKey(const Key('av2_share_head_error')), findsOneWidget);
      expect(find.text('Could not open this file: The share does not answer'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('av2_install_card')), findsOneWidget);
      expect(reads, 2);
    }, variant: desktop);

    testWidgets('on a phone, an AV2 file of a share or of the device says it plays on the computers', (tester) async {
      const file = (sourceId: 'nas', path: '/clips/cosmos.ivf', size: 5365, modified: null);
      await pumpPage(tester, const Av2ShareGate(file: file, child: _player), const []);
      expect(find.text('AV2 videos play in Immuch360 Desktop only for now (Windows, Linux, macOS)'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpPage(tester, Av2AssetGate(asset: _asset('v1', 'cosmos.obu'), child: _player), const []);
      expect(find.text('AV2 videos play in Immuch360 Desktop only for now (Windows, Linux, macOS)'), findsOneWidget);
      expect(find.text('the player'), findsNothing);
    });

    test('the file of a video: its path and its head, read only for an AV2 file of the library', () async {
      final storage = _Files({
        'a': File('test/fixtures/av2/av2-256x144-8bit.ivf'),
        'b': File('test/fixtures/av2/av1-256x144-8bit.ivf'),
      });
      final container = ProviderContainer(overrides: [storageRepositoryProvider.overrideWithValue(storage)]);
      addTearDown(container.dispose);
      final video = await container.read(av2LocalVideoProvider((id: 'a', name: 'cosmos.ivf')).future);
      expect(video?.path, 'test/fixtures/av2/av2-256x144-8bit.ivf');
      expect((video?.head.width, video?.head.height), (256, 144));
      expect(await container.read(av2LocalVideoProvider((id: 'b', name: 'old.ivf')).future), isNull);
      expect(await container.read(av2LocalVideoProvider((id: 'c', name: 'gone.ivf')).future), isNull);
      expect(await container.read(av2LocalVideoProvider((id: 'd', name: 'clip.mp4')).future), isNull);
      expect(storage.asked, ['a', 'b', 'c']);
    });
  });

  test('the target platform is reset', () => expect(debugDefaultTargetPlatformOverride, isNull));
}
