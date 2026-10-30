// The details of a server video tell which file plays and offer the other one (lot fix-decoder-limit): the user can
// still force the original or the server's copy, whatever decodability first chose.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/video_source_policy.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_details/video_source_tile.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';

import '../../../../unit/factories/remote_asset_factory.dart';
import '../../../../widget_tester_extensions.dart';

void main() {
  final video = RemoteAssetFactory.create(type: .video);

  Future<ProviderContainer> pump(WidgetTester tester, ChosenVideoSource? chosen) async {
    late ProviderContainer container;
    await tester.pumpConsumerWidget(
      Consumer(
        builder: (context, ref, _) {
          container = ProviderScope.containerOf(context);
          return Material(child: VideoSourceTile(asset: video));
        },
      ),
      overrides: [
        chosenVideoSourcesProvider.overrideWith((ref) {
          final sources = ChosenVideoSources();
          if (chosen != null) {
            sources.record(video.id, chosen);
          }
          return sources;
        }),
      ],
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('tells that the original plays, and why, with the server copy to force', (tester) async {
    final container = await pump(
      tester,
      ChosenVideoSource(
        url: 'original',
        notice: const VideoSourceNotice(.originalOverCopy, codec: 'H.264', width: 5760, height: 2880),
      ),
    );

    expect(find.text('Video source'), findsOneWidget);
    expect(find.textContaining('The original'), findsOneWidget);
    expect(
      find.textContaining("Playing the original: the server's copy (H.264 5760 x 2880) is above this device's decoder"),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(TextButton, "Play the server's copy"));
    await tester.pumpAndSettle();

    expect(container.read(videoSourceOverridesProvider)[video.id], VideoSourceKind.transcoded);
  });

  testWidgets('tells that the copy plays, with the original to force', (tester) async {
    final container = await pump(
      tester,
      ChosenVideoSource(
        url: 'playback',
        kind: VideoSourceKind.transcoded,
        notice: const VideoSourceNotice(.switched, codec: 'H.264', width: 5760, height: 2880),
      ),
    );

    expect(find.textContaining("The server's copy"), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Play the original'));
    await tester.pumpAndSettle();

    expect(container.read(videoSourceOverridesProvider)[video.id], VideoSourceKind.original);
  });

  testWidgets('says what to change in Immich when nothing decodes, and lets the user try', (tester) async {
    await pump(
      tester,
      ChosenVideoSource(
        url: 'playback',
        kind: VideoSourceKind.transcoded,
        refusal: const VideoSourceRefusal(codec: 'H.264', width: 5760, height: 2880, maxWidth: 4096, maxHeight: 2304),
      ),
    );

    expect(find.textContaining('set the video transcoding to HEVC or lower the resolution'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Play the original'), findsOneWidget);
  });

  testWidgets('offers no copy a server does not have', (tester) async {
    await pump(tester, ChosenVideoSource(url: 'original', hasCopy: false));
    expect(find.text('Video source'), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets('shows nothing before the player chose', (tester) async {
    await pump(tester, null);
    expect(find.text('Video source'), findsNothing);
  });
}
