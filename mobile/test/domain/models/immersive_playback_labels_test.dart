// The texts the immersive viewer of the Meta Quest gets for the video it plays (lot quest-playback-resilience): under
// the keys PlaybackDetails.kt reads, their places left in braces for the viewer, with every opening.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/immersive_playback_labels.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';

import '../../widget_tester_extensions.dart';

void main() {
  /// The English texts, from a widget under the app's localisation, which loads them for the static translations too
  Future<Translations> english(WidgetTester tester) async {
    late Translations t;
    await tester.pumpConsumerWidget(
      Builder(
        builder: (context) {
          t = context.t;
          return const SizedBox();
        },
      ),
    );
    return t;
  }

  testWidgets('the viewer gets its notices and units under the keys it reads, the places kept for it', (tester) async {
    final labels = immersivePlaybackLabels(await english(tester));

    expect(labels, {
      'playbackRestarted': 'The video stopped at {position}, it plays again from there',
      'playbackRestartedLater':
          'The video stopped at {position}, it plays again from {resume}, past the part that failed',
      'playbackNoPicture':
          'No picture for 3 seconds while the sound plays ({video}). What the headset saw is in the Logs of the app',
      'playbackNoPictureSwitch': 'No picture for 3 seconds from {video}, trying the server playback stream',
      'playbackMbps': '{value} Mbit/s',
      'playbackKbps': '{value} kbit/s',
    });
  });

  testWidgets('every opening of the immersive viewer carries them, a label of the opener winning', (tester) async {
    await english(tester);
    final labels = immersiveOpeningLabels({'stereo': '3D', playbackKbpsLabelKey: '{value} kb/s'});

    expect(labels['stereo'], '3D');
    expect(labels[playbackKbpsLabelKey], '{value} kb/s');
    expect(labels[playbackRestartedLabelKey], 'The video stopped at {position}, it plays again from there');
    expect(labels[playbackRestartedLaterLabelKey], allOf(contains('{position}'), contains('{resume}')));
    expect(labels[playbackNoPictureSwitchLabelKey], contains('{video}'));
    expect(labels[playbackMbpsLabelKey], '{value} Mbit/s');
  });
}
