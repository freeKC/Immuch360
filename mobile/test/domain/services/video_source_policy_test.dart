import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/config/viewer_config.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/video_source_policy.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';

void main() {
  // An 8K HEVC 360° video, as a Quest 3 cannot decode it
  const probe = SphericalProbe(
    codec: 'hvc1',
    codecs: 'hvc1.1.6.L183',
    codedWidth: 7680,
    codedHeight: 3840,
    frameRate: 30,
  );
  DecodeVerdict verdict({required bool supported}) =>
      DecodeVerdict(supported: supported, hardware: true, maxWidth: 4096, maxHeight: 4096, reason: 'test');

  group('chooseVideoSource', () {
    VideoSourceChoice choose(
      VideoSourcePolicy policy, {
      SphericalProbe? probe = probe,
      DecodeVerdict? verdict,
      bool hasTranscode = true,
    }) => chooseVideoSource(
      policy: policy,
      original: VideoCandidate.of(probe, verdict),
      copy: hasTranscode ? VideoCandidate.unknown : null,
    );

    test('plays the original within the decoders, with the transcoded stream to fall back to', () {
      expect(
        choose(.preferOriginalWithinDecoder, verdict: verdict(supported: true)),
        const VideoSourceChoice(.original, allowFallback: true),
      );
    });

    test('plays the transcoded stream when the device cannot decode the original, and says why', () {
      expect(
        choose(.preferOriginalWithinDecoder, verdict: verdict(supported: false)),
        const VideoSourceChoice(
          .transcoded,
          notice: VideoSourceNotice(.switched, codec: 'HEVC', width: 7680, height: 3840),
        ),
      );
    });

    test('keeps the original, with the transcoded stream to fall back to, when nothing tells', () {
      // No probe, no verdict (the check failed), or a file whose video track was not found
      for (final given in [null, probe, const SphericalProbe()]) {
        expect(
          choose(.preferOriginalWithinDecoder, probe: given),
          const VideoSourceChoice(.original, allowFallback: true),
          reason: 'probe $given',
        );
      }
    });

    test('plays the original whatever the device when the user asks for it, without falling back', () {
      expect(choose(.alwaysOriginal, verdict: verdict(supported: true)), const VideoSourceChoice(.original));
      expect(choose(.alwaysOriginal), const VideoSourceChoice(.original));
      expect(
        choose(.alwaysOriginal, verdict: verdict(supported: false)),
        const VideoSourceChoice(
          .original,
          notice: VideoSourceNotice(.originalForced, codec: 'HEVC', width: 7680, height: 3840),
        ),
      );
    });

    test('plays the transcoded stream when the user asks for it and nothing says it does not decode', () {
      for (final given in [null, verdict(supported: true), verdict(supported: false)]) {
        expect(choose(.alwaysTranscoded, verdict: given), const VideoSourceChoice(.transcoded), reason: '$given');
      }
    });

    test('plays a server video with no transcoded stream as it is when it may play, whatever the policy', () {
      for (final policy in VideoSourcePolicy.values) {
        for (final given in [null, verdict(supported: true)]) {
          expect(
            choose(policy, verdict: given, hasTranscode: false),
            const VideoSourceChoice(.original),
            reason: '$policy, $given',
          );
        }
      }
    });

    test('says nothing of an original whose codec or size is unknown', () {
      const noSize = SphericalProbe(codec: 'hvc1');
      expect(
        choose(.preferOriginalWithinDecoder, probe: noSize, verdict: verdict(supported: false)),
        const VideoSourceChoice(.transcoded),
      );
    });
  });

  group('chooseVideoSource, decodability first', () {
    // What a Meta Quest 3 says: HEVC up to 8192 x 4320, H.264 up to the 4096 x 2304 at 30 fps measured there
    DecodeVerdict quest(String codec, int width, int height) {
      final hevc = codec == 'HEVC';
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

    VideoCandidate file(String codec, int width, int height, {bool measured = true}) => VideoCandidate(
      codec: codec,
      width: width,
      height: height,
      verdict: measured ? quest(codec, width, height) : null,
    );

    final hevcOriginal = file('HEVC', 5760, 2880);
    final h264Original = file('H.264', 5760, 2880);
    final h264FullSizeCopy = file('H.264', 5760, 2880);
    final h264SmallCopy = file('H.264', 1920, 960);

    test('plays the HEVC original rather than an H.264 copy at the same size, which the headset cannot decode', () {
      // The case of 30 October: the server transcodes to H.264 at the original 5760 x 2880
      for (final policy in [VideoSourcePolicy.preferOriginalWithinDecoder, VideoSourcePolicy.alwaysTranscoded]) {
        final choice = chooseVideoSource(policy: policy, original: hevcOriginal, copy: h264FullSizeCopy);
        expect(choice.kind, VideoSourceKind.original, reason: '$policy');
        expect(choice.allowFallback, isFalse, reason: '$policy: never a switch to a copy that does not decode');
        expect(choice.refusal, isNull, reason: '$policy');
      }
      // The settings asked for the copy: the user is told why the original plays, and of which copy
      expect(
        chooseVideoSource(policy: .alwaysTranscoded, original: hevcOriginal, copy: h264FullSizeCopy).notice,
        const VideoSourceNotice(.originalOverCopy, codec: 'H.264', width: 5760, height: 2880),
      );
      // The settings asked for the original: it plays as asked, nothing to tell
      expect(
        chooseVideoSource(policy: .preferOriginalWithinDecoder, original: hevcOriginal, copy: h264FullSizeCopy).notice,
        isNull,
      );
    });

    test('plays a smaller copy rather than an H.264 original above 4096 x 2304, and says why', () {
      for (final policy in [VideoSourcePolicy.preferOriginalWithinDecoder, VideoSourcePolicy.alwaysTranscoded]) {
        final choice = chooseVideoSource(policy: policy, original: h264Original, copy: h264SmallCopy);
        expect(choice.kind, VideoSourceKind.transcoded, reason: '$policy');
        expect(choice.refusal, isNull, reason: '$policy');
      }
      expect(
        chooseVideoSource(policy: .preferOriginalWithinDecoder, original: h264Original, copy: h264SmallCopy),
        const VideoSourceChoice(
          .transcoded,
          notice: VideoSourceNotice(.switched, codec: 'H.264', width: 5760, height: 2880),
        ),
      );
    });

    test('lets the policy decide when the device decodes both files', () {
      final original = file('HEVC', 3840, 1920);
      final copy = file('H.264', 1920, 960);
      expect(
        chooseVideoSource(policy: .preferOriginalWithinDecoder, original: original, copy: copy),
        const VideoSourceChoice(.original, allowFallback: true),
      );
      expect(
        chooseVideoSource(policy: .alwaysTranscoded, original: original, copy: copy),
        const VideoSourceChoice(.transcoded),
      );
      expect(
        chooseVideoSource(policy: .alwaysOriginal, original: original, copy: copy),
        const VideoSourceChoice(.original),
      );
    });

    test('keeps the choice of the policy when the device measured nothing', () {
      final original = file('H.264', 5760, 2880, measured: false);
      final copy = file('H.264', 5760, 2880, measured: false);
      expect(
        chooseVideoSource(policy: .preferOriginalWithinDecoder, original: original, copy: copy),
        const VideoSourceChoice(.original, allowFallback: true),
      );
      expect(
        chooseVideoSource(policy: .alwaysTranscoded, original: original, copy: copy),
        const VideoSourceChoice(.transcoded),
      );
      // A phone or a TV whose decoder list takes the file: its own limit, not the headset's
      final phone = DecodeVerdict(supported: true, hardware: true, maxWidth: 8192, maxHeight: 4320);
      expect(
        chooseVideoSource(
          policy: .alwaysTranscoded,
          original: VideoCandidate(codec: 'H.264', width: 5760, height: 2880, verdict: phone),
          copy: VideoCandidate(codec: 'H.264', width: 5760, height: 2880, verdict: phone),
        ),
        const VideoSourceChoice(.transcoded),
      );
    });

    test('refuses at once when neither the original nor the copy decodes, naming the copy and the limit', () {
      final original = file('H.264', 7680, 3840);
      for (final policy in [VideoSourcePolicy.preferOriginalWithinDecoder, VideoSourcePolicy.alwaysTranscoded]) {
        expect(
          chooseVideoSource(policy: policy, original: original, copy: h264FullSizeCopy),
          const VideoSourceChoice(
            .transcoded,
            refusal: VideoSourceRefusal(codec: 'H.264', width: 5760, height: 2880, maxWidth: 4096, maxHeight: 2304),
          ),
          reason: '$policy',
        );
      }
    });

    test('refuses at once a server video with no copy whose original does not decode', () {
      for (final policy in [VideoSourcePolicy.preferOriginalWithinDecoder, VideoSourcePolicy.alwaysTranscoded]) {
        expect(
          chooseVideoSource(policy: policy, original: h264Original),
          const VideoSourceChoice(
            .original,
            refusal: VideoSourceRefusal(codec: 'H.264', width: 5760, height: 2880, maxWidth: 4096, maxHeight: 2304),
          ),
          reason: '$policy',
        );
      }
    });

    test('plays the file the user forced, with a word when it is beyond the decoders', () {
      expect(
        chooseVideoSource(
          policy: .preferOriginalWithinDecoder,
          original: hevcOriginal,
          copy: h264FullSizeCopy,
          forced: .transcoded,
        ),
        const VideoSourceChoice(
          .transcoded,
          notice: VideoSourceNotice(.copyForced, codec: 'H.264', width: 5760, height: 2880),
        ),
      );
      expect(
        chooseVideoSource(policy: .alwaysTranscoded, original: h264Original, copy: h264SmallCopy, forced: .original),
        const VideoSourceChoice(
          .original,
          notice: VideoSourceNotice(.originalForced, codec: 'H.264', width: 5760, height: 2880),
        ),
      );
      // Forced on a server video without a copy, or with nothing that decodes: it plays all the same
      expect(
        chooseVideoSource(policy: .preferOriginalWithinDecoder, original: h264Original, forced: .original).refusal,
        isNull,
      );
      expect(
        chooseVideoSource(policy: .preferOriginalWithinDecoder, original: h264Original, forced: .transcoded),
        const VideoSourceChoice(
          .original,
          notice: VideoSourceNotice(.originalForced, codec: 'H.264', width: 5760, height: 2880),
        ),
      );
      expect(
        chooseVideoSource(policy: .alwaysOriginal, original: file('H.264', 7680, 3840), copy: h264FullSizeCopy).refusal,
        isNull,
      );
    });

    test('plays a file of the device or of a share as it is, with a word when it is beyond the decoders', () {
      for (final policy in VideoSourcePolicy.values) {
        expect(
          chooseVideoSource(policy: policy, original: h264Original, fromServer: false),
          const VideoSourceChoice(
            .original,
            notice: VideoSourceNotice(.beyondDecoders, codec: 'H.264', width: 5760, height: 2880),
          ),
          reason: '$policy',
        );
        expect(
          chooseVideoSource(policy: policy, original: hevcOriginal, fromServer: false),
          const VideoSourceChoice(.original),
          reason: '$policy',
        );
      }
    });

    test('builds a candidate from the probe of its file', () {
      final candidate = VideoCandidate.of(probe, verdict(supported: false));
      expect(candidate.codec, 'HEVC');
      expect(candidate.width, 7680);
      expect(candidate.height, 3840);
      expect(candidate.undecodable, isTrue);
      expect(VideoCandidate.of(null, null).undecodable, isFalse);
      expect(VideoCandidate.of(probe, verdict(supported: true)).refusal, isNull);
    });
  });

  group('ViewerConfig video source', () {
    test('follows the former switch until the user picks a source', () {
      expect(const ViewerConfig().videoSourcePolicy, VideoSourcePolicy.alwaysTranscoded);
      expect(
        const ViewerConfig(loadOriginalVideo: true).videoSourcePolicy,
        VideoSourcePolicy.preferOriginalWithinDecoder,
      );
      for (final policy in VideoSourcePolicy.values) {
        for (final loadOriginalVideo in [false, true]) {
          expect(ViewerConfig(loadOriginalVideo: loadOriginalVideo, videoSource: policy).videoSourcePolicy, policy);
        }
      }
    });

    test('plays the original in the immersive viewer whatever the former switch, until the user picks a source', () {
      for (final loadOriginalVideo in [false, true]) {
        expect(
          ViewerConfig(loadOriginalVideo: loadOriginalVideo).immersiveVideoSourcePolicy,
          VideoSourcePolicy.preferOriginalWithinDecoder,
        );
      }
      expect(
        const ViewerConfig(videoSource: .alwaysTranscoded).immersiveVideoSourcePolicy,
        VideoSourcePolicy.alwaysTranscoded,
      );
    });

    test('reads the file unless the transcoded stream always plays', () {
      expect(VideoSourcePolicy.preferOriginalWithinDecoder.readsTheFile, isTrue);
      expect(VideoSourcePolicy.alwaysOriginal.readsTheFile, isTrue);
      expect(VideoSourcePolicy.alwaysTranscoded.readsTheFile, isFalse);
    });
  });

  test('names the codecs of the sample entries and of the decoders', () {
    for (final (codec, name) in [
      ('avc1', 'H.264'),
      ('avc3', 'H.264'),
      ('video/avc', 'H.264'),
      ('hvc1', 'HEVC'),
      ('hev1', 'HEVC'),
      ('video/hevc', 'HEVC'),
      ('dvh1', 'Dolby Vision'),
      ('av01', 'AV1'),
      ('video/av01', 'AV1'),
      ('vp09', 'VP9'),
      ('video/x-vnd.on2.vp9', 'VP9'),
      ('video/x-unknown', 'video/x-unknown'),
    ]) {
      expect(videoCodecName(codec), name, reason: codec);
    }
  });

  test('writes a frame rate with two decimals at most', () {
    expect(formatFrameRate(30), '30');
    expect(formatFrameRate(30000 / 1001), '29.97');
    expect(formatFrameRate(60000 / 1001), '59.94');
    expect(formatFrameRate(24000 / 1001), '23.98');
    expect(formatFrameRate(29.5), '29.5');
  });
}
