import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/video_details.dart';
import 'package:immich_mobile/generated/translations.g.dart';

import '../../widget_tester_extensions.dart';

void main() {
  group('videoBitRateOf', () {
    test('takes the bit rate of the video tracks first', () {
      expect(
        videoBitRateOf(
          probe: const SphericalProbe(videoBitRate: 210000000, declaredBitRate: 200000000, mediaBitRate: 211000000),
          fileSize: 50000000,
          durationMs: 20000,
        ),
        (bitsPerSecond: 210000000, source: VideoBitRateSource.videoTracks),
      );
    });

    test('then the one the file declares, then the one of the media data', () {
      expect(videoBitRateOf(probe: const SphericalProbe(declaredBitRate: 120000000, mediaBitRate: 121000000)), (
        bitsPerSecond: 120000000,
        source: VideoBitRateSource.declared,
      ));
      expect(videoBitRateOf(probe: const SphericalProbe(mediaBitRate: 67600000)), (
        bitsPerSecond: 67600000,
        source: VideoBitRateSource.mediaData,
      ));
    });

    test('then the size of the file over the duration', () {
      expect(videoBitRateOf(probe: const SphericalProbe(), fileSize: 50000000, durationMs: 20000), (
        bitsPerSecond: 20000000,
        source: VideoBitRateSource.fileSize,
      ));
      expect(videoBitRateOf(fileSize: 50000000, durationMs: 20000), (
        bitsPerSecond: 20000000,
        source: VideoBitRateSource.fileSize,
      ), reason: 'no probe');
    });

    test('gives nothing without anything to tell it', () {
      expect(videoBitRateOf(), isNull);
      expect(videoBitRateOf(probe: const SphericalProbe()), isNull);
      expect(videoBitRateOf(fileSize: 50000000), isNull, reason: 'no duration');
      expect(videoBitRateOf(durationMs: 20000), isNull, reason: 'no size');
      expect(videoBitRateOf(fileSize: 50000000, durationMs: 0), isNull);
    });

    test('skips the rates of zero', () {
      expect(videoBitRateOf(probe: const SphericalProbe(videoBitRate: 0, declaredBitRate: 0, mediaBitRate: 4000000)), (
        bitsPerSecond: 4000000,
        source: VideoBitRateSource.mediaData,
      ));
      expect(videoBitRateOf(probe: const SphericalProbe(videoBitRate: 0), fileSize: 0, durationMs: 20000), isNull);
    });
  });

  group('formatBitRate', () {
    // The translations are loaded by the app around a widget
    Future<Translations> translations(WidgetTester tester) async {
      await tester.pumpConsumerWidget(const SizedBox());
      return StaticTranslations.instance;
    }

    testWidgets('writes megabits with one decimal below 10, and kilobits below one megabit', (tester) async {
      final t = await translations(tester);

      expect(formatBitRate(210000000, t, locale: 'en'), '210 Mbit/s');
      expect(formatBitRate(67600000, t, locale: 'en'), '68 Mbit/s');
      expect(formatBitRate(4520000, t, locale: 'en'), '4.5 Mbit/s');
      expect(formatBitRate(4000000, t, locale: 'en'), '4 Mbit/s');
      expect(formatBitRate(850000, t, locale: 'en'), '850 kbit/s');
    });

    testWidgets('writes the decimal separator of the language', (tester) async {
      final t = await translations(tester);

      expect(formatBitRate(4520000, t, locale: 'fr'), '4,5 Mbit/s');
      expect(formatBitRate(4520000, t, locale: 'en-US'), '4.5 Mbit/s');
    });

    testWidgets('falls back to English numbers for a language without number symbols', (tester) async {
      final t = await translations(tester);

      expect(formatBitRate(4520000, t, locale: 'xx'), '4.5 Mbit/s');
    });
  });

  group('videoProfileName', () {
    test('names the HEVC profiles, with or without a profile space', () {
      expect(videoProfileName('hvc1.1.6.L153'), 'Main');
      expect(videoProfileName('hev1.2.4.H153'), 'Main 10');
      expect(videoProfileName('hvc1.A1.2.L120'), 'Main');
      expect(videoProfileName('hvc1.4.10.L153'), 'Range extensions');
    });

    test('names the H.264 profiles, constrained baseline included', () {
      expect(videoProfileName('avc1.640033'), 'High');
      expect(videoProfileName('avc1.42E01E'), 'Constrained Baseline');
      expect(videoProfileName('avc1.42001E'), 'Baseline');
      expect(videoProfileName('avc1.6E0033'), 'High 10');
      expect(videoProfileName('avc3.4D401F'), 'Main');
    });

    test('names the AV1 and Dolby Vision profiles', () {
      expect(videoProfileName('av01.0.13M.08'), 'Main');
      expect(videoProfileName('av01.1.13M.10'), 'High');
      expect(videoProfileName('dvh1.08.06'), 'Profile 8');
      expect(videoProfileName('dvhe.05.06'), 'Profile 5');
    });

    test('names nothing it does not know', () {
      expect(videoProfileName('vp09.00.10.08'), isNull);
      expect(videoProfileName(null), isNull);
      expect(videoProfileName('hvc1'), isNull);
      expect(videoProfileName('avc1.64'), isNull);
      expect(videoProfileName('hvc1.9.4.L153'), isNull);
    });
  });

  group('videoPictureSummary', () {
    testWidgets('tells the bit depth, Dolby Vision, the transfer and the primaries', (tester) async {
      await tester.pumpConsumerWidget(const SizedBox());
      final t = StaticTranslations.instance;

      expect(
        videoPictureSummary(const SphericalProbe(bitDepth: 10, transferCharacteristics: 18, colourPrimaries: 9), t),
        '10 bit  •  HDR, HLG  •  BT.2020',
      );
      expect(
        videoPictureSummary(
          const SphericalProbe(bitDepth: 10, dolbyVision: true, transferCharacteristics: 18, colourPrimaries: 9),
          t,
        ),
        '10 bit  •  Dolby Vision  •  HDR, HLG  •  BT.2020',
      );
      expect(
        videoPictureSummary(const SphericalProbe(transferCharacteristics: 16, colourPrimaries: 12), t),
        'HDR10, PQ  •  Display P3',
      );
      expect(
        videoPictureSummary(const SphericalProbe(bitDepth: 8, transferCharacteristics: 1, colourPrimaries: 1), t),
        '8 bit  •  SDR  •  BT.709',
      );
      expect(videoPictureSummary(const SphericalProbe(colourPrimaries: 6), t), 'BT.601');
    });

    testWidgets('tells nothing of a file that says nothing of its picture', (tester) async {
      await tester.pumpConsumerWidget(const SizedBox());
      final t = StaticTranslations.instance;

      expect(videoPictureSummary(null, t), isNull);
      expect(videoPictureSummary(const SphericalProbe(codec: 'hvc1'), t), isNull);
      expect(videoPictureSummary(const SphericalProbe(transferCharacteristics: 2, colourPrimaries: 2), t), isNull);
    });
  });
}
