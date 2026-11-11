import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/film_player_preference.dart';
import 'package:immich_mobile/infrastructure/mpv/android_mpv.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/widgets/settings/film_player_settings.dart';

import '../../unit/presentation/presentation_context.dart';

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  final conversionSwitch = find.descendant(
    of: find.byKey(const Key('advanced_settings_plex_conversion')),
    matching: find.byType(SwitchListTile),
  );

  testWidgets('the Quest build: the three players, Automatic by default, and a pick saved', (tester) async {
    await tester.pumpTestWidget(
      context,
      const SingleChildScrollView(child: FilmPlayerSettings(android: true)),
      overrides: [androidMpvAvailableProvider.overrideWith((ref) async => true)],
    );
    expect(find.text('Film player'), findsOneWidget);
    expect(find.text('Automatic'), findsOneWidget);
    expect(find.text('Device'), findsOneWidget);
    expect(find.text('mpv'), findsOneWidget);
    expect(SettingsRepository.instance.appConfig.viewer.filmPlayer, FilmPlayerPreference.automatic);

    await tester.tap(find.text('mpv'));
    await tester.pumpAndSettle();
    expect(SettingsRepository.instance.appConfig.viewer.filmPlayer, FilmPlayerPreference.mpv);
  });

  testWidgets('the conversion: experimental, on by default, turns off', (tester) async {
    await tester.pumpTestWidget(
      context,
      const SingleChildScrollView(child: FilmPlayerSettings(android: true)),
      overrides: [androidMpvAvailableProvider.overrideWith((ref) async => true)],
    );
    expect(find.text('Let the Plex server convert what this device cannot play (experimental)'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(conversionSwitch).value, isTrue);
    expect(SettingsRepository.instance.appConfig.viewer.plexConversion, isTrue);

    await tester.tap(conversionSwitch);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(conversionSwitch).value, isFalse);
    expect(SettingsRepository.instance.appConfig.viewer.plexConversion, isFalse);
  });

  testWidgets('a phone build (no libmpv): the conversion only', (tester) async {
    await tester.pumpTestWidget(
      context,
      const SingleChildScrollView(child: FilmPlayerSettings(android: true)),
      overrides: [androidMpvAvailableProvider.overrideWith((ref) async => false)],
    );
    expect(find.text('Film player'), findsNothing);
    expect(conversionSwitch, findsOneWidget);
  });

  testWidgets('iOS and the computers: nothing', (tester) async {
    await tester.pumpTestWidget(
      context,
      const SingleChildScrollView(child: FilmPlayerSettings(android: false)),
      overrides: [androidMpvAvailableProvider.overrideWith((ref) async => true)],
    );
    expect(find.text('Film player'), findsNothing);
    expect(conversionSwitch, findsNothing);
  });
}
