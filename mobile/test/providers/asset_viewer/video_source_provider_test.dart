import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/video_source_policy.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';

import '../../unit/presentation/presentation_context.dart';

/// Answers the decoder check with [supported], or fails with [failure], or never answers when [hangs]. Records the
/// questions.
class _FakeVideoDecoderApi extends VideoDecoderApi {
  bool supported = true;
  Exception? failure;
  bool hangs = false;
  final questions = <(String, String?, int, int, double)>[];

  @override
  Future<DecodeVerdict> canDecode(String codec, String? codecs, int width, int height, double frameRate) async {
    questions.add((codec, codecs, width, height, frameRate));
    if (hangs) {
      return Completer<DecodeVerdict>().future;
    }
    final failure = this.failure;
    if (failure != null) {
      throw failure;
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

    test('keeps the original when the server transcoded nothing, and says it may not play', () async {
      api.supported = false;
      respond = (request) async => sized(request, original: 1000, transcoded: 1000);

      final source = await service.serverSource(videoId: 'video-1', policy: .preferOriginalWithinDecoder, probe: probe);

      expect(source.url, original);
      expect(source.fallbackUrl, isNull, reason: 'the transcoded stream is the same file');
      expect(source.notice, const VideoSourceNotice(.originalForced, codec: 'HEVC', width: 7680, height: 3840));
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

    test('asks the server for the sizes only when it hands out a fallback', () async {
      for (final (policy, supported) in [
        (VideoSourcePolicy.alwaysOriginal, false),
        (VideoSourcePolicy.alwaysTranscoded, false),
      ]) {
        api.supported = supported;
        await service.serverSource(videoId: 'video-1', policy: policy, probe: probe);
      }
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
}
