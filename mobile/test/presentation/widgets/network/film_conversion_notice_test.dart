// What the app says of a film the Plex server converts for this device (release 47, the S24 test of 13 November 2026:
// a DTS film and a DivX 3 film played converted with an icon alone): a notice that fades after a few seconds, and a
// line of the film page

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/viewer_config.dart';
import 'package:immich_mobile/domain/services/film_player/device_decoder_types.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:immich_mobile/presentation/widgets/network/film_conversion_notice.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/network/film_player.provider.dart';

import '../../pages/network/network_test_app.dart';

/// A phone with H.264 and AAC decoders, no DTS, no libmpv
FilmPlayers _phone() => FilmPlayers(
  decoderTypes: DeviceDecoderTypes(read: () async => {'video/avc', 'audio/mp4a-latm'}),
  mpvReady: () async => false,
);

PlexFilmPart _part(String audio) => PlexFilmPart(
  id: 1,
  key: '/library/parts/1/file.mkv',
  container: 'mkv',
  streams: [
    const PlexStream(id: 10, type: PlexStreamType.video, codec: 'h264'),
    PlexStream(id: 11, type: PlexStreamType.audio, codec: audio, isDefault: true),
  ],
);

void main() {
  const wakelock = 'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
      wakelock,
      (_) async => const StandardMessageCodec().encodeMessage(<Object?>[]),
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(wakelock, null);
  });

  testWidgets('the notice says why the server converts, and fades after a few seconds', (tester) async {
    await pumpNetworkTestApp(
      tester,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showFilmConversionNotice(context, const ['audio dca']),
            child: const Text('play'),
          ),
        ),
      ),
      overrides: const [],
    );

    await tester.tap(find.text('play'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Converted by the Plex server: this device cannot play DTS'), findsOneWidget);

    await tester.pump(filmConversionNoticeDuration);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('film_conversion_notice')), findsNothing);
  });

  testWidgets('a conversion that follows a failure says only that the server converts', (tester) async {
    await pumpNetworkTestApp(
      tester,
      home: Scaffold(body: Builder(builder: (context) => Text(filmConversionText(context.t, const [])))),
      overrides: const [],
    );
    expect(find.text('Converted by the Plex server'), findsOneWidget);
  });

  Future<void> pumpLine(WidgetTester tester, String audio, {bool conversion = true}) => pumpNetworkTestApp(
    tester,
    home: Scaffold(body: FilmConversionLine(part: _part(audio))),
    overrides: [
      filmPlayersProvider.overrideWithValue(_phone()),
      appConfigProvider.overrideWithValue(AppConfig(viewer: ViewerConfig(plexConversion: conversion))),
    ],
  );

  testWidgets('the film page says that this device plays a DTS film through the server', (tester) async {
    await pumpLine(tester, 'dca');
    await tester.pumpAndSettle();
    expect(find.text('On this device: converted by the Plex server (this device cannot play DTS)'), findsOneWidget);
  });

  testWidgets('nothing for a film the device plays, nor with the conversion off', (tester) async {
    await pumpLine(tester, 'aac');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('plex_film_conversion_line')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await pumpLine(tester, 'dca', conversion: false);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('plex_film_conversion_line')), findsNothing);
  });
}
