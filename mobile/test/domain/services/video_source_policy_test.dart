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
    }) => chooseVideoSource(policy: policy, probe: probe, verdict: verdict, hasTranscode: hasTranscode);

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

    test('plays the transcoded stream whatever the file when the user asks for it', () {
      for (final given in [null, verdict(supported: true), verdict(supported: false)]) {
        expect(choose(.alwaysTranscoded, verdict: given), const VideoSourceChoice(.transcoded), reason: '$given');
      }
    });

    test('plays a file with no transcoded stream as it is, whatever the policy', () {
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

    test('says that a file with no transcoded stream may not play, rather than a switch that cannot happen', () {
      for (final policy in VideoSourcePolicy.values) {
        expect(
          choose(policy, verdict: verdict(supported: false), hasTranscode: false),
          const VideoSourceChoice(
            .original,
            notice: VideoSourceNotice(.originalForced, codec: 'HEVC', width: 7680, height: 3840),
          ),
          reason: '$policy',
        );
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
