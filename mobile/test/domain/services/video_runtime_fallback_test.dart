// The server's other file after a decoder that refused, while it played, a file its decoder check accepted (a TV, 8
// November 2026): the whole rule of runtimeFallback, and which errors count as a decoder's refusal.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/native_playback_error.dart';
import 'package:immich_mobile/domain/services/video_runtime_fallback.dart';
import 'package:immich_mobile/domain/services/video_source_policy.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';

void main() {
  DecodeVerdict verdict({required bool supported, int maxWidth = 4096, int maxHeight = 2304}) =>
      DecodeVerdict(supported: supported, hardware: true, maxWidth: maxWidth, maxHeight: maxHeight, reason: 'test');

  // The TV's case: an HEVC 5760 x 2880 original the decoder check accepted, which the decoder refused at start
  const refusedHevc = NativePlaybackError(.decoder, mime: 'video/hevc', width: 5760, height: 2880);
  final hevcOriginal = VideoCandidate(codec: 'HEVC', width: 5760, height: 2880, verdict: verdict(supported: true));
  final smallCopy = VideoCandidate(codec: 'H.264', width: 1920, height: 960, verdict: verdict(supported: true));
  final copyBeyond = VideoCandidate(codec: 'H.264', width: 5760, height: 2880, verdict: verdict(supported: false));
  const copyNotice = VideoSourceNotice(.copyAfterRefusal, codec: 'HEVC', width: 5760, height: 2880);

  group('after a refused original', () {
    test('plays an unknown copy, and says the original was refused, from the token', () {
      final result = runtimeFallback(
        refused: .original,
        error: refusedHevc,
        original: hevcOriginal,
        copy: VideoCandidate.unknown,
      );

      expect(result.next, VideoSourceKind.transcoded);
      expect(result.notice, copyNotice);
      expect(result.copyBeyondDecoders, isNull);
    });

    test('plays a copy the device decodes', () {
      final result = runtimeFallback(refused: .original, error: refusedHevc, original: hevcOriginal, copy: smallCopy);

      expect(result.next, VideoSourceKind.transcoded);
      expect(result.notice, copyNotice);
    });

    test("tells the codec and the size from the original's probe when the token has none", () {
      final result = runtimeFallback(
        refused: .original,
        error: const NativePlaybackError(.decoder),
        original: hevcOriginal,
        copy: smallCopy,
      );

      expect(result.next, VideoSourceKind.transcoded);
      expect(result.notice, copyNotice);
    });

    test('tells nothing when neither the token nor the probe knows the file, and switches all the same', () {
      final result = runtimeFallback(
        refused: .original,
        error: const NativePlaybackError(.noFrame),
        original: VideoCandidate.unknown,
        copy: smallCopy,
      );

      expect(result.next, VideoSourceKind.transcoded);
      expect(result.notice, isNull);
    });

    test('stays when the copy is beyond the decoders too, and gives its refusal for the panel', () {
      final result = runtimeFallback(refused: .original, error: refusedHevc, original: hevcOriginal, copy: copyBeyond);

      expect(result.next, isNull);
      expect(
        result.copyBeyondDecoders,
        const VideoSourceRefusal(codec: 'H.264', width: 5760, height: 2880, maxWidth: 4096, maxHeight: 2304),
      );
    });

    test('stays when the server has no copy of its own', () {
      final result = runtimeFallback(refused: .original, error: refusedHevc, original: hevcOriginal, copy: null);

      expect(result.next, isNull);
      expect(result.copyBeyondDecoders, isNull);
    });

    test('stays when the file was forced in the details or by "Always the original"', () {
      final result = runtimeFallback(
        refused: .original,
        error: refusedHevc,
        original: hevcOriginal,
        copy: smallCopy,
        forced: true,
      );

      expect(result.next, isNull);
    });

    test('stays when the copy has the same codec at the same size, and plays a smaller one', () {
      VideoSourceKind? next(VideoCandidate copy) =>
          runtimeFallback(refused: .original, error: refusedHevc, original: hevcOriginal, copy: copy).next;

      // A server that transcodes HEVC at the original size: the decoder that refused the original refuses its copy
      expect(next(VideoCandidate(codec: 'HEVC', width: 5760, height: 2880, verdict: verdict(supported: true))), isNull);
      // The same frame turned, as a copy may store a portrait video
      expect(next(const VideoCandidate(codec: 'HEVC', width: 2880, height: 5760)), isNull);
      expect(
        next(VideoCandidate(codec: 'HEVC', width: 3840, height: 1920, verdict: verdict(supported: true))),
        VideoSourceKind.transcoded,
      );
    });

    test('stays when the decoder refused the copy too earlier in the session', () {
      final result = runtimeFallback(
        refused: .original,
        error: refusedHevc,
        original: hevcOriginal,
        copy: smallCopy,
        refusedBefore: {VideoSourceKind.original, VideoSourceKind.transcoded},
      );

      expect(result.next, isNull);
    });
  });

  group('after a refused copy, under "Always the transcoded stream"', () {
    // A copy the decoder check accepted, whose decoder gave no picture
    const refusedCopy = NativePlaybackError(.noFrame, mime: 'video/avc', width: 5760, height: 2880);
    final acceptedCopy = VideoCandidate(codec: 'H.264', width: 5760, height: 2880, verdict: verdict(supported: true));
    const originalNotice = VideoSourceNotice(.originalAfterRefusal, codec: 'H.264', width: 5760, height: 2880);

    test('plays the original when its verdict says it decodes and it streams', () {
      final result = runtimeFallback(
        refused: .transcoded,
        error: refusedCopy,
        original: hevcOriginal,
        copy: acceptedCopy,
      );

      expect(result.next, VideoSourceKind.original);
      expect(result.notice, originalNotice);
    });

    test('stays when nothing tells the original decodes', () {
      for (final original in [
        VideoCandidate.unknown,
        const VideoCandidate(codec: 'HEVC', width: 5760, height: 2880),
        VideoCandidate(codec: 'HEVC', width: 7680, height: 3840, verdict: verdict(supported: false)),
      ]) {
        final result = runtimeFallback(
          refused: .transcoded,
          error: refusedCopy,
          original: original,
          copy: acceptedCopy,
        );
        expect(result.next, isNull, reason: '$original');
      }
    });

    test('stays when the original would download whole before it plays', () {
      final result = runtimeFallback(
        refused: .transcoded,
        error: refusedCopy,
        original: hevcOriginal,
        copy: acceptedCopy,
        originalStreams: false,
      );

      expect(result.next, isNull);
    });

    test('stays when the original has the same codec at a frame at least as large', () {
      final h264Original = VideoCandidate(codec: 'H.264', width: 5760, height: 2880, verdict: verdict(supported: true));

      expect(
        runtimeFallback(refused: .transcoded, error: refusedCopy, original: h264Original, copy: acceptedCopy).next,
        isNull,
      );
    });

    test('stays when the decoder refused the original earlier in the session', () {
      final result = runtimeFallback(
        refused: .transcoded,
        error: refusedCopy,
        original: hevcOriginal,
        copy: acceptedCopy,
        refusedBefore: {VideoSourceKind.transcoded, VideoSourceKind.original},
      );

      expect(result.next, isNull);
    });
  });

  test('a decoder that refused or gave no picture is a refusal, a stall, a stop or a text is not', () {
    expect(isDecoderRefusal(const NativePlaybackError(.decoder)), isTrue);
    expect(isDecoderRefusal(const NativePlaybackError(.noFrame)), isTrue);
    expect(isDecoderRefusal(const NativePlaybackError(.stalled)), isFalse);
    expect(isDecoderRefusal(const NativePlaybackError(.stopped)), isFalse);
    expect(isDecoderRefusal(NativePlaybackError.parse('Decoder init failed')), isFalse);
    expect(isDecoderRefusal(null), isFalse);
  });
}
