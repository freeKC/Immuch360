// Why the decoder is not the first of the order: every code the native side sends has its line under the decoder
// line of Diagnostics, and an unknown code shows nothing (p2/quest-2026-10-24/fix-decoder.md).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_texts.dart';

import '../../../unit/presentation/presentation_context.dart';

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  /// The English texts, from a widget under the app's localisation
  Future<Translations> english(WidgetTester tester) async {
    late Translations t;
    await tester.pumpTestWidget(
      context,
      Builder(
        builder: (context) {
          t = context.t;
          return const SizedBox();
        },
      ),
    );
    return t;
  }

  testWidgets('every switch reason of the decoder has its line, and an unknown one none', (tester) async {
    final t = await english(tester);
    final reasons = {
      'noOutputAfterJoin': t.dji_link_video_switch_join,
      'hardwareRetryFailed': t.dji_link_video_switch_retry,
      'fatalErrors': t.dji_link_video_switch_errors,
      'noPictureWithKey': t.dji_link_video_switch_no_picture,
      'noPictureNothingLeft': t.dji_link_video_switch_nothing_left,
      'rememberedNoPicture': t.dji_link_video_switch_remembered,
    };
    for (final entry in reasons.entries) {
      expect(djiLinkSwitchReasonText(t, entry.key), entry.value, reason: entry.key);
      expect(entry.value, isNotEmpty, reason: entry.key);
    }
    expect(reasons.values.toSet().length, reasons.length);
    expect(djiLinkSwitchReasonText(t, null), isNull);
    expect(djiLinkSwitchReasonText(t, 'aCodeOfALaterBuild'), isNull);
    // The Quest has no software decoder: the lines of the new rule never promise one
    expect(t.dji_link_video_switch_no_picture, contains('next decoder'));
    expect(t.dji_link_video_switch_errors, isNot(contains('software')));
    expect(t.dji_link_video_switches, 'Decoder switches');
  });
}
