import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/film_player/film_player_choice.dart';
import 'package:immich_mobile/presentation/widgets/network/film_player_menu.widget.dart';

import '../../../unit/presentation/presentation_context.dart';

/// A menu with the player item, as the video page has it
class _Menu extends StatelessWidget {
  const _Menu({required this.asked, required this.playing, required this.onPicked});

  final FilmPlayerPreference asked;
  final FilmPlayerKind playing;
  final void Function(FilmPlayerPreference) onPicked;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: PopupMenuButton<void>(
        key: const Key('menu'),
        itemBuilder: (_) => [filmPlayerMenuItem(context, asked: asked, playing: playing, onPicked: onPicked)],
      ),
    ),
  );
}

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  testWidgets('Automatic names the player that plays; a pick in the dialog is handed back', (tester) async {
    final picked = <FilmPlayerPreference>[];
    await tester.pumpTestWidget(
      context,
      _Menu(asked: FilmPlayerPreference.automatic, playing: FilmPlayerKind.mpv, onPicked: picked.add),
    );
    await tester.tap(find.byKey(const Key('menu')));
    await tester.pumpAndSettle();
    expect(find.text('Player: Automatic (mpv)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('network_video_player')));
    await tester.pumpAndSettle();
    expect(find.byType(FilmPlayerDialog), findsOneWidget);
    expect(find.text('Player'), findsOneWidget);
    expect(
      find.text('The device\'s own player when it decodes every stream of the film, mpv otherwise'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('film_player_device')));
    await tester.pumpAndSettle();
    expect(picked, [FilmPlayerPreference.device]);
    expect(find.byType(FilmPlayerDialog), findsNothing);
  });

  testWidgets('a film the server converts, and a player asked by name', (tester) async {
    await tester.pumpTestWidget(
      context,
      _Menu(asked: FilmPlayerPreference.automatic, playing: FilmPlayerKind.serverConversion, onPicked: (_) {}),
    );
    await tester.tap(find.byKey(const Key('menu')));
    await tester.pumpAndSettle();
    expect(find.text('Player: Automatic (Converted by the Plex server)'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await tester.pumpTestWidget(
      context,
      _Menu(asked: FilmPlayerPreference.mpv, playing: FilmPlayerKind.mpv, onPicked: (_) {}),
    );
    await tester.tap(find.byKey(const Key('menu')));
    await tester.pumpAndSettle();
    expect(find.text('Player: mpv'), findsOneWidget);
  });

  testWidgets('the dialog closed without a pick changes nothing', (tester) async {
    final picked = <FilmPlayerPreference>[];
    await tester.pumpTestWidget(
      context,
      _Menu(asked: FilmPlayerPreference.device, playing: FilmPlayerKind.device, onPicked: picked.add),
    );
    await tester.tap(find.byKey(const Key('menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('network_video_player')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Icon>(find.descendant(of: find.byKey(const Key('film_player_device')), matching: find.byType(Icon)))
          .icon,
      Icons.radio_button_checked,
    );
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(picked, isEmpty);
  });
}
