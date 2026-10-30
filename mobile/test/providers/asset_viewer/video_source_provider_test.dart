import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/video_details.dart';
import 'package:immich_mobile/domain/services/video_source_policy.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../infrastructure/repository.mock.dart';
import '../../unit/factories/remote_asset_factory.dart';
import '../../unit/presentation/presentation_context.dart';

/// What the file of every video declares: [result]
class _FakeSphericalProbes extends SphericalProbeService {
  _FakeSphericalProbes(this.result)
    : super(
        storage: MockStorageRepository(),
        client: () => throw UnimplementedError('no network in these tests'),
        serverEndpoint: () => null,
        headers: () => const {},
      );

  final SphericalProbe? result;

  @override
  Future<SphericalProbe?> probe(BaseAsset asset, {File? localFile}) async => result;
}

/// Answers the decoder check with [supported], or fails with [failure], or never answers when [hangs]. Records the
/// questions.
class _FakeVideoDecoderApi extends VideoDecoderApi {
  bool supported = true;
  Exception? failure;
  bool hangs = false;

  /// Answers as a Meta Quest 3 does when set: HEVC up to 8192 x 4320, H.264 up to 4096 x 2304, whatever [supported]
  bool quest = false;
  final questions = <(String, String?, int, int, double)>[];

  /// The bit depth, the transfer and the number of streams of each question, in the order of [questions]
  final colours = <(int, int, int)>[];

  @override
  Future<DecodeVerdict> canDecode(
    String codec,
    String? codecs,
    int width,
    int height,
    double frameRate,
    int bitDepth,
    int transferCharacteristics, {
    int instances = 1,
  }) async {
    questions.add((codec, codecs, width, height, frameRate));
    colours.add((bitDepth, transferCharacteristics, instances));
    if (hangs) {
      return Completer<DecodeVerdict>().future;
    }
    final failure = this.failure;
    if (failure != null) {
      throw failure;
    }
    if (quest) {
      final hevc = codec.startsWith('hvc') || codec.startsWith('hev');
      final maxWidth = hevc ? 8192 : 4096;
      final maxHeight = hevc ? 4320 : 2304;
      return DecodeVerdict(
        supported: width <= maxWidth && height <= maxHeight,
        hardware: true,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        reason: 'Quest 3',
      );
    }
    return DecodeVerdict(supported: supported, hardware: true, maxWidth: 4096, maxHeight: 4096, reason: 'test');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const server = PresentationContext.serverEndpoint;
  const probe = SphericalProbe(
    codec: 'hvc1',
    codecs: 'hvc1.1.6.L183',
    codedWidth: 7680,
    codedHeight: 3840,
    frameRate: 30,
  );

  late PresentationContext context;
  late _FakeVideoDecoderApi api;
  late VideoSourceService service;
  // The size requests to the server, and what it answers to them: a transcoded stream of its own by default
  late List<http.Request> sizeRequests;
  late Future<http.Response> Function(http.Request request) respond;

  http.Response sized(http.Request request, {required int original, required int transcoded}) => http.Response(
    '',
    200,
    headers: {'content-length': '${request.url.path.endsWith('/original') ? original : transcoded}'},
  );

  setUp(() async {
    context = await PresentationContext.create();
    api = _FakeVideoDecoderApi();
    sizeRequests = [];
    respond = (request) async => sized(request, original: 1000, transcoded: 100);
    service = VideoSourceService(
      api,
      client: () => MockClient((request) {
        sizeRequests.add(request);
        return respond(request);
      }),
      timeout: const Duration(milliseconds: 100),
      sizeTimeout: const Duration(milliseconds: 100),
    );
  });

  tearDown(() async {
    await context.dispose();
  });

  group('VideoSourceService.verdict', () {
    test('asks the decoder check with the codec, the profile and level, the frame size and the frame rate', () async {
      final verdict = await service.verdict(probe);

      expect(verdict?.supported, isTrue);
      expect(api.questions, [('hvc1', 'hvc1.1.6.L183', 7680, 3840, 30.0)]);
      expect(api.colours, [(0, 0, 1)], reason: 'bit depth and transfer unknown, one stream');
    });

    test('asks the decoders with the bit depth and the transfer of the probe', () async {
      await service.verdict(
        const SphericalProbe(
          codec: 'hvc1',
          codecs: 'hvc1.2.4.L153',
          codedWidth: 7680,
          codedHeight: 3840,
          frameRate: 30,
          bitDepth: 10,
          transferCharacteristics: 18,
        ),
      );

      expect(api.questions, [('hvc1', 'hvc1.2.4.L153', 7680, 3840, 30.0)]);
      expect(api.colours, [(10, 18, 1)]);
    });

    test('keeps a verdict per bit depth and transfer', () async {
      const hlg = SphericalProbe(
        codec: 'hvc1',
        codecs: 'hvc1.2.4.L153',
        codedWidth: 7680,
        codedHeight: 3840,
        bitDepth: 10,
        transferCharacteristics: 18,
      );
      const pq = SphericalProbe(
        codec: 'hvc1',
        codecs: 'hvc1.2.4.L153',
        codedWidth: 7680,
        codedHeight: 3840,
        bitDepth: 10,
        transferCharacteristics: 16,
      );

      await service.verdict(hlg);
      await service.verdict(pq);
      await service.verdict(hlg);

      expect(api.colours, [(10, 18, 1), (10, 16, 1)]);
    });

    test('asks with a frame rate of 0 when the file does not tell it', () async {
      await service.verdict(const SphericalProbe(codec: 'avc1', codedWidth: 1920, codedHeight: 1080));

      expect(api.questions, [('avc1', null, 1920, 1080, 0.0)]);
    });

    test('asks about the HEVC base layer of a Dolby Vision track without its own configuration', () async {
      await service.verdict(
        const SphericalProbe(codec: 'dvh1', codecs: 'hvc1.2.4.L153', codedWidth: 3840, codedHeight: 2160),
      );
      await service.verdict(
        const SphericalProbe(codec: 'dvh1', codecs: 'dvh1.08.06', codedWidth: 3840, codedHeight: 2160),
      );

      expect(api.questions, [('hvc1', 'hvc1.2.4.L153', 3840, 2160, 0.0), ('dvh1', 'dvh1.08.06', 3840, 2160, 0.0)]);
    });

    test('asks nothing without the codec or the frame size', () async {
      for (final probe in [
        null,
        const SphericalProbe(),
        const SphericalProbe(codec: 'hvc1', codedWidth: 1920),
        const SphericalProbe(codedWidth: 1920, codedHeight: 1080),
      ]) {
        expect(await service.verdict(probe), isNull, reason: '$probe');
      }
      expect(api.questions, isEmpty);
    });

    test('keeps the answers in memory', () async {
      await service.verdict(probe);
      await service.verdict(probe);
      expect(api.questions, hasLength(1));

      await service.verdict(const SphericalProbe(codec: 'hvc1', codedWidth: 3840, codedHeight: 1920));
      expect(api.questions, hasLength(2), reason: 'another size is another question');
    });

    test('gives null when the check fails or takes too long, and asks again next time', () async {
      api.failure = PlatformException(code: 'channel-error');
      expect(await service.verdict(probe), isNull);

      api
        ..failure = null
        ..hangs = true;
      expect(await service.verdict(probe), isNull);

      api.hangs = false;
      expect((await service.verdict(probe))?.supported, isTrue);
      expect(api.questions, hasLength(3));
    });
  });

  group('VideoSourceService.twoStreamVerdict', () {
    test('asks about two streams of the size of one lens at once', () async {
      api.supported = false;

      final verdict = await service.twoStreamVerdict(
        codec: 'hvc1',
        codecs: 'hvc1.1.6.L153',
        width: 3840,
        height: 3840,
        frameRate: 30,
        bitDepth: 8,
      );

      expect(verdict?.supported, isFalse);
      expect(api.questions, [('hvc1', 'hvc1.1.6.L153', 3840, 3840, 30.0)]);
      expect(api.colours, [(8, 0, 2)]);
    });

    test('keeps its answers apart from the ones about a single stream', () async {
      const lens = SphericalProbe(codec: 'avc1', codecs: 'avc1.640033', codedWidth: 2880, codedHeight: 2880);

      await service.verdict(lens);
      await service.twoStreamVerdict(codec: 'avc1', codecs: 'avc1.640033', width: 2880, height: 2880);
      await service.twoStreamVerdict(codec: 'avc1', codecs: 'avc1.640033', width: 2880, height: 2880);

      expect(api.colours, [(0, 0, 1), (0, 0, 2)]);
    });

    test('asks nothing without the codec or the size of a lens', () async {
      expect(await service.twoStreamVerdict(codec: null, width: 3840, height: 3840), isNull);
      expect(await service.twoStreamVerdict(codec: 'hvc1', width: null, height: 3840), isNull);
      expect(await service.twoStreamVerdict(codec: 'hvc1', width: 0, height: 0), isNull);
      expect(api.questions, isEmpty);
    });

    test('gives null when the check takes too long', () async {
      api.hangs = true;

      expect(await service.twoStreamVerdict(codec: 'hvc1', width: 3840, height: 3840), isNull);
    });
  });

  group('VideoSourceService.serverSource', () {
    const original = '$server/assets/video-1/original';
    const transcoded = '$server/assets/video-1/video/playback';

    test('plays the original the device decodes, with the transcoded stream to fall back to', () async {
      final source = await service.serverSource(videoId: 'video-1', policy: .preferOriginalWithinDecoder, probe: probe);

      expect(source.url, original);
      expect(source.fallbackUrl, transcoded);
      expect(source.notice, isNull);
    });

    test('plays the transcoded stream when the device cannot decode the original, and says why', () async {
      api.supported = false;

      final source = await service.serverSource(videoId: 'video-1', policy: .preferOriginalWithinDecoder, probe: probe);

      expect(source.url, transcoded);
      expect(source.fallbackUrl, isNull);
      expect(source.notice, const VideoSourceNotice(.switched, codec: 'HEVC', width: 7680, height: 3840));
      expect([
        for (final request in sizeRequests) (request.method, request.url.toString()),
      ], unorderedEquals([('HEAD', original), ('HEAD', transcoded)]));
    });

    test('refuses at once the original the device cannot decode when the server transcoded nothing', () async {
      api.supported = false;
      respond = (request) async => sized(request, original: 1000, transcoded: 1000);

      final source = await service.serverSource(videoId: 'video-1', policy: .preferOriginalWithinDecoder, probe: probe);

      expect(source.url, original);
      expect(source.fallbackUrl, isNull, reason: 'the transcoded stream is the same file');
      expect(source.notice, isNull);
      expect(
        source.refusal,
        const VideoSourceRefusal(codec: 'HEVC', width: 7680, height: 3840, maxWidth: 4096, maxHeight: 4096),
      );
    });

    test('asks the server for the sizes once per video', () async {
      api.supported = false;
      respond = (request) async => sized(request, original: 1000, transcoded: 1000);

      await service.serverSource(videoId: 'video-1', policy: .preferOriginalWithinDecoder, probe: probe);
      await service.serverSource(videoId: 'video-1', policy: .preferOriginalWithinDecoder, probe: probe);
      expect(sizeRequests, hasLength(2));

      await service.serverSource(videoId: 'video-2', policy: .preferOriginalWithinDecoder, probe: probe);
      expect(sizeRequests, hasLength(4), reason: 'another video is another question');
    });

    test('switches when a size is unknown, and asks again next time', () async {
      api.supported = false;
      for (final answer in <Future<http.Response> Function(http.Request)>[
        (request) async => http.Response('', 200),
        (request) async => http.Response('', 404, headers: {'content-length': '1000'}),
        (request) async => throw http.ClientException('no network'),
        (request) => Completer<http.Response>().future,
      ]) {
        respond = answer;

        final source = await service.serverSource(
          videoId: 'video-1',
          policy: .preferOriginalWithinDecoder,
          probe: probe,
        );

        expect(source.url, transcoded);
        expect(source.notice?.kind, VideoSourceNoticeKind.switched);
      }
      expect(sizeRequests, hasLength(8));
    });

    test('switches without asking the server when there is no client', () async {
      api.supported = false;
      final service = VideoSourceService(api);

      final source = await service.serverSource(videoId: 'video-1', policy: .preferOriginalWithinDecoder, probe: probe);

      expect(source.url, transcoded);
      expect(await service.transcodeIsOriginal('video-1'), isFalse);
    });

    test('asks the server for the sizes only when the copy may play or be the fallback', () async {
      api.supported = false;
      await service.serverSource(videoId: 'video-1', policy: .alwaysOriginal, probe: probe);
      // A frame every decoder takes: the copy, no larger, plays without a look at it
      await service.serverSource(
        videoId: 'video-1',
        policy: .alwaysTranscoded,
        probe: probe,
        width: 1920,
        height: 1080,
      );
      expect(sizeRequests, isEmpty);

      // The original with the transcoded stream at hand: the fallback is only handed out when it is a file of its own
      api.supported = true;
      await service.serverSource(videoId: 'video-1', policy: .preferOriginalWithinDecoder, probe: probe);
      expect(sizeRequests, isNotEmpty);
    });

    test('plays the original with the transcoded stream at hand when the file is unknown', () async {
      final source = await service.serverSource(videoId: 'video-1', policy: .preferOriginalWithinDecoder);

      expect(source.url, original);
      expect(source.fallbackUrl, transcoded);
      expect(api.questions, isEmpty);
    });

    test('plays the original whatever the device when the user asks for it, and says it may not play', () async {
      api.supported = false;

      final source = await service.serverSource(videoId: 'video-1', policy: .alwaysOriginal, probe: probe);

      expect(source.url, original);
      expect(source.fallbackUrl, isNull);
      expect(source.notice?.kind, VideoSourceNoticeKind.originalForced);
    });

    test('plays the transcoded stream when the user asks for it, without asking the decoder check', () async {
      final source = await service.serverSource(
        videoId: 'video-1',
        policy: VideoSourcePolicy.alwaysTranscoded,
        probe: probe,
      );

      expect(source.url, transcoded);
      expect(source.fallbackUrl, isNull);
      expect(source.notice, isNull);
      expect(api.questions, isEmpty);
    });
  });

  group('VideoSourceService.serverSource, decodability first', () {
    const original = '$server/assets/video-1/original';
    const transcoded = '$server/assets/video-1/video/playback';
    const hevcOriginal = SphericalProbe(codec: 'hvc1', codedWidth: 5760, codedHeight: 2880, frameRate: 29.97);
    const h264Original = SphericalProbe(codec: 'avc1', codedWidth: 5760, codedHeight: 2880, frameRate: 29.97);
    const h264FullSizeCopy = SphericalProbe(
      codec: 'avc1',
      codecs: 'avc1.42C03C',
      codedWidth: 5760,
      codedHeight: 2880,
      frameRate: 29.97,
    );
    const h264SmallCopy = SphericalProbe(codec: 'avc1', codedWidth: 1920, codedHeight: 960, frameRate: 29.97);

    late SphericalProbe? copyProbe;
    late SphericalProbe? lateOriginal;
    late List<String> copyProbes;
    late int originalProbes;
    late VideoSourceService service;

    setUp(() {
      api.quest = true;
      copyProbe = h264FullSizeCopy;
      lateOriginal = null;
      copyProbes = [];
      originalProbes = 0;
      service = VideoSourceService(
        api,
        client: () => MockClient((request) {
          sizeRequests.add(request);
          return respond(request);
        }),
        probeTranscoded: (videoId) async {
          copyProbes.add(videoId);
          return copyProbe;
        },
        timeout: const Duration(milliseconds: 100),
        sizeTimeout: const Duration(milliseconds: 100),
      );
    });

    Future<SphericalProbe?> probeOriginal() async {
      originalProbes++;
      return lateOriginal;
    }

    test(
      'the headset plays the HEVC original rather than the H.264 copy at its size, never falling back to it',
      () async {
        // The immersive viewer of 30 October: the server transcodes to H.264 at the original 5760 x 2880
        final source = await service.serverSource(
          videoId: 'video-1',
          policy: .preferOriginalWithinDecoder,
          probe: hevcOriginal,
          wantsFallback: true,
        );

        expect(source.url, original);
        expect(source.fallbackUrl, isNull, reason: 'the copy does not decode on the headset');
        expect(source.notice, isNull, reason: 'the original plays, as the setting asked');
        expect(
          source.copyBeyondDecoders,
          const VideoSourceNotice(.originalOverCopy, codec: 'H.264', width: 5760, height: 2880),
        );
        expect(copyProbes, ['video-1']);
      },
    );

    test('the in-app player plays the HEVC original under "Always the transcoded stream", and says why', () async {
      // The in-app player of 30 October: the setting asks for the copy, which stalls after 10 s
      final source = await service.serverSource(
        videoId: 'video-1',
        policy: .alwaysTranscoded,
        probeOriginal: () async {
          originalProbes++;
          return hevcOriginal;
        },
      );

      expect(source.url, original);
      expect(source.fallbackUrl, isNull);
      expect(source.notice, const VideoSourceNotice(.originalOverCopy, codec: 'H.264', width: 5760, height: 2880));
      expect(source.refusal, isNull);
      expect(originalProbes, 1, reason: 'the original is only read once the copy does not decode');
    });

    test('plays the original of a server without Range whose probe found nothing, rather than the copy', () async {
      // The original of FreeKC's server cannot be probed (no Range, its moov at the end): unknown beats undecodable
      final source = await service.serverSource(
        videoId: 'video-1',
        policy: .alwaysTranscoded,
        probeOriginal: probeOriginal,
      );

      expect(source.url, original);
      expect(source.notice?.kind, VideoSourceNoticeKind.originalOverCopy);
    });

    test('plays a smaller copy rather than an H.264 original above 4096 x 2304', () async {
      copyProbe = h264SmallCopy;

      final source = await service.serverSource(
        videoId: 'video-1',
        policy: .preferOriginalWithinDecoder,
        probe: h264Original,
      );

      expect(source.url, transcoded);
      expect(source.notice, const VideoSourceNotice(.switched, codec: 'H.264', width: 5760, height: 2880));
      expect(source.refusal, isNull);
    });

    test('refuses at once when neither the original nor the copy decodes', () async {
      final source = await service.serverSource(
        videoId: 'video-1',
        policy: .preferOriginalWithinDecoder,
        probe: h264Original,
      );

      expect(
        source.refusal,
        const VideoSourceRefusal(codec: 'H.264', width: 5760, height: 2880, maxWidth: 4096, maxHeight: 2304),
      );
      expect(source.url, transcoded, reason: 'what plays when the user asks to play anyway');
    });

    test(
      'refuses at once the undecodable original of a server that has no copy, under every policy but the forced one',
      () async {
        respond = (request) async => sized(request, original: 1000, transcoded: 1000);
        lateOriginal = h264Original;

        for (final policy in [VideoSourcePolicy.preferOriginalWithinDecoder, VideoSourcePolicy.alwaysTranscoded]) {
          final source = await service.serverSource(
            videoId: 'video-1',
            policy: policy,
            probe: policy.readsTheFile ? h264Original : null,
            probeOriginal: probeOriginal,
          );
          expect(source.refusal?.codec, 'H.264', reason: '$policy');
          expect(source.url, original, reason: '$policy');
        }
        expect(copyProbes, isEmpty, reason: 'no copy to read');

        final forced = await service.serverSource(videoId: 'video-1', policy: .alwaysOriginal, probe: h264Original);
        expect(forced.refusal, isNull);
        expect(forced.notice?.kind, VideoSourceNoticeKind.originalForced);
      },
    );

    test('plays what the user forced from the details', () async {
      final copy = await service.serverSource(
        videoId: 'video-1',
        policy: .preferOriginalWithinDecoder,
        probe: hevcOriginal,
        forced: .transcoded,
      );
      expect(copy.url, transcoded);
      expect(copy.notice, const VideoSourceNotice(.copyForced, codec: 'H.264', width: 5760, height: 2880));

      copyProbes.clear();
      sizeRequests.clear();
      final originalSource = await service.serverSource(
        videoId: 'video-1',
        policy: .alwaysTranscoded,
        probe: h264Original,
        forced: .original,
      );
      expect(originalSource.url, original);
      expect(copyProbes, isEmpty, reason: 'the copy plays no part');
      expect(sizeRequests, isEmpty);
    });

    test('keeps the old choice when the device measured nothing', () async {
      api.quest = false;
      api.failure = PlatformException(code: 'no-check');

      final immersive = await service.serverSource(
        videoId: 'video-1',
        policy: .preferOriginalWithinDecoder,
        probe: h264Original,
        wantsFallback: true,
      );
      expect(immersive.url, original);
      expect(immersive.fallbackUrl, transcoded);

      final inApp = await service.serverSource(
        videoId: 'video-1',
        policy: .alwaysTranscoded,
        probeOriginal: probeOriginal,
      );
      expect(inApp.url, transcoded);
      expect(inApp.notice, isNull);
      expect(originalProbes, 0);
    });

    test('does not read the copy of a video whose frame every decoder takes', () async {
      final source = await service.serverSource(
        videoId: 'video-1',
        policy: .alwaysTranscoded,
        probeOriginal: probeOriginal,
        width: 1080,
        height: 1920,
      );

      expect(source.url, transcoded);
      expect(copyProbes, isEmpty);
      expect(sizeRequests, isEmpty);
    });
  });

  group('VideoSourceService.refusedServerStream', () {
    const original = '$server/assets/video-1/original';
    const transcoded = '$server/assets/video-1/video/playback';

    Future<DecodeVerdict?> refused(ChosenVideoSource source, {SphericalProbe? probe = probe}) =>
        service.refusedServerStream(videoId: 'video-1', probe: probe, source: source);

    test('refuses the transcoded stream of a server that transcoded nothing, under every policy', () async {
      api.supported = false;
      respond = (request) async => sized(request, original: 1000, transcoded: 1000);

      final verdict = await refused(const ChosenVideoSource(url: transcoded));

      expect(verdict?.supported, isFalse);
      expect(api.questions, hasLength(1), reason: 'asked even under "Always the transcoded stream"');
    });

    test('refuses the original with nothing to fall back to', () async {
      api.supported = false;

      expect(await refused(const ChosenVideoSource(url: original)), isNotNull);
    });

    test('lets a smaller stream of the server play', () async {
      api.supported = false;

      expect(await refused(const ChosenVideoSource(url: transcoded)), isNull);
    });

    test('lets the player fall back by itself', () async {
      api.supported = false;

      expect(await refused(const ChosenVideoSource(url: original, fallbackUrl: transcoded)), isNull);
    });

    test('lets a file the device decodes, or an unknown one, play', () async {
      expect(await refused(const ChosenVideoSource(url: original)), isNull);

      api.supported = false;
      expect(await refused(const ChosenVideoSource(url: original), probe: null), isNull);
    });
  });

  group('videoDecodeDetailsProvider', () {
    final video = RemoteAssetFactory.create(type: .video).copyWith(durationMs: 20000);
    late MockStorageRepository storage;
    late List<BaseAsset> exifRead;

    Future<VideoDecodeDetails> details(SphericalProbe? probe, {int? fileSize}) async {
      final container = ProviderContainer(
        overrides: [
          sphericalProbeServiceProvider.overrideWithValue(_FakeSphericalProbes(probe)),
          videoSourceServiceProvider.overrideWithValue(service),
          storageRepositoryProvider.overrideWithValue(storage),
          assetExifProvider.overrideWith((ref, asset) {
            exifRead.add(asset);
            return Stream.value(ExifInfo(fileSize: fileSize));
          }),
        ],
      );
      addTearDown(container.dispose);
      return container.read(videoDecodeDetailsProvider(video).future);
    }

    setUp(() {
      storage = MockStorageRepository();
      exifRead = [];
    });

    test('gives the bit rate of the probe, without asking for the size of the file', () async {
      final result = await details(
        const SphericalProbe(codec: 'hvc1', codedWidth: 7680, codedHeight: 3840, videoBitRate: 210000000),
        fileSize: 50000000,
      );

      expect(result.bitRate, (bitsPerSecond: 210000000, source: VideoBitRateSource.videoTracks));
      expect(result.verdict?.supported, isTrue);
      expect(exifRead, isEmpty);
    });

    test('estimates the bit rate from the size of the file when the probe tells none', () async {
      final result = await details(
        const SphericalProbe(codec: 'hvc1', codedWidth: 7680, codedHeight: 3840),
        fileSize: 50000000,
      );

      expect(result.bitRate, (bitsPerSecond: 20000000, source: VideoBitRateSource.fileSize));
    });

    test('gives no bit rate when neither the probe nor the file size tells it', () async {
      final result = await details(null);

      expect(result.probe, isNull);
      expect(result.bitRate, isNull);
      verifyNever(() => storage.getFileForAsset(any()));
    });
  });
}
