// The Drone card of the Library and the Drone page (p2/design-final-2026-10-24.md, section 2): one function offered
// opens it directly, two open the page, none hides the card; the page lists the live video and the photos. On a TV
// (p2/design-tv-2026-10-24.md, 2.1) the card opens the watch page, as on the Quest, and the import is never offered.

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/presentation/pages/drone/drone.page.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/drone_card.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/drone_import_tile.widget.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/routing/router.dart';

import '../../../unit/presentation/presentation_context.dart';

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  test('one function opens straight away, two open the Drone page, none hides the card', () {
    expect(droneCardTarget(liveOffered: true, importOffered: true, receiverOnly: false), DroneCardTarget.page);
    expect(droneCardTarget(liveOffered: true, importOffered: false, receiverOnly: false), DroneCardTarget.live);
    expect(droneCardTarget(liveOffered: false, importOffered: true, receiverOnly: false), DroneCardTarget.photos);
    // The Quest and a TV: the import is never offered there, the card opens the watch page
    expect(droneCardTarget(liveOffered: true, importOffered: false, receiverOnly: true), DroneCardTarget.watch);
    expect(droneCardTarget(liveOffered: false, importOffered: false, receiverOnly: false), DroneCardTarget.none);
    expect(droneCardTarget(liveOffered: false, importOffered: false, receiverOnly: true), DroneCardTarget.none);
  });

  group('on a device', () {
    /// The providers of the card on an Android device: a television or not, its layout setting, Horizon OS or not
    ProviderContainer device({
      required bool television,
      required bool tvLayout,
      bool horizonOs = false,
      AppConfig config = const AppConfig(),
    }) {
      final container = ProviderContainer(
        overrides: [
          tvDeviceProvider.overrideWithValue(TvDeviceInfo(isTelevision: television, isLowRamDevice: false)),
          tvModeProvider.overrideWithValue(tvLayout),
          isHorizonOsProvider.overrideWith((ref) async => horizonOs),
          appConfigProvider.overrideWithValue(config),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('a television, in the TV layout or not, offers the live video only, its card opens the watch page', () async {
      for (final tvLayout in [true, false]) {
        final container = device(television: true, tvLayout: tvLayout);
        await container.read(isHorizonOsProvider.future);
        expect(container.read(djiLinkSupportedProvider), isTrue, reason: 'layout $tvLayout');
        expect(container.read(djiReceiverOnlyProvider), isTrue, reason: 'layout $tvLayout');
        expect(container.read(droneImportSupportedProvider), isFalse, reason: 'layout $tvLayout');
        expect(container.read(droneCardProvider), DroneCardTarget.watch, reason: 'layout $tvLayout');
      }
    });

    test('a television with DJI live video off has no card', () async {
      final container = device(television: true, tvLayout: true, config: const AppConfig(djiLinkEnabled: false));
      await container.read(isHorizonOsProvider.future);
      expect(container.read(droneCardProvider), DroneCardTarget.none);
    });

    test('a phone switched to the TV layout keeps hiding the live video, which is built for touch', () async {
      final container = device(television: false, tvLayout: true);
      await container.read(isHorizonOsProvider.future);
      expect(container.read(djiLinkSupportedProvider), isFalse);
      expect(container.read(djiReceiverOnlyProvider), isFalse);
    });

    test('a phone and the Quest keep their targets', () async {
      final phone = device(television: false, tvLayout: false);
      await phone.read(isHorizonOsProvider.future);
      expect(phone.read(droneCardProvider), DroneCardTarget.page);
      final quest = device(television: false, tvLayout: false, horizonOs: true);
      await quest.read(isHorizonOsProvider.future);
      expect(quest.read(djiReceiverOnlyProvider), isTrue);
      expect(quest.read(droneCardProvider), DroneCardTarget.watch);
    });
  });

  test('each target has its page', () {
    expect(droneCardRoute(DroneCardTarget.none), isNull);
    expect(droneCardRoute(DroneCardTarget.page)?.routeName, DroneRoute.name);
    expect(droneCardRoute(DroneCardTarget.live)?.routeName, DjiLiveRoute.name);
    expect(droneCardRoute(DroneCardTarget.watch)?.routeName, DjiWatchRoute.name);
    expect(droneCardRoute(DroneCardTarget.photos)?.routeName, DroneImportRoute.name);
  });

  testWidgets('the card: an aircraft and "Drone", hidden with both functions off', (tester) async {
    await tester.pumpTestWidget(
      context,
      const Wrap(children: [DroneCollectionCard()]),
      overrides: [
        djiLinkEnabledProvider.overrideWithValue(true),
        droneImportEnabledProvider.overrideWithValue(true),
        isHorizonOsProvider.overrideWith((ref) async => false),
      ],
    );
    expect(find.byKey(const Key('drone_card')), findsOneWidget);
    expect(find.text('Drone'), findsOneWidget);
    expect(find.byIcon(Icons.flight_rounded), findsOneWidget);
  });

  testWidgets('no card when neither function is offered here', (tester) async {
    await tester.pumpTestWidget(
      context,
      const Wrap(children: [DroneCollectionCard()]),
      overrides: [
        djiLinkEnabledProvider.overrideWithValue(false),
        droneImportEnabledProvider.overrideWithValue(false),
        isHorizonOsProvider.overrideWith((ref) async => false),
      ],
    );
    expect(find.byKey(const Key('drone_card')), findsNothing);
    expect(find.text('Drone'), findsNothing);
  });

  testWidgets('the Drone page lists the live video and the photos from the drone', (tester) async {
    await tester.pumpTestWidget(
      context,
      const DronePage(),
      overrides: [
        djiLinkEnabledProvider.overrideWithValue(true),
        droneImportEnabledProvider.overrideWithValue(true),
        isHorizonOsProvider.overrideWith((ref) async => false),
      ],
    );
    expect(find.text('Drone'), findsOneWidget);
    expect(find.byKey(const Key('dji_link_tile')), findsOneWidget);
    expect(find.text('DJI live video'), findsOneWidget);
    expect(find.byKey(const Key('drone_import_tile')), findsOneWidget);
    expect(find.text('Photos and videos from the drone'), findsOneWidget);
    expect(find.byIcon(Icons.photo_library_outlined), findsOneWidget);
    expect(find.byKey(const Key('drone_page_none')), findsNothing);
  });

  testWidgets('the Drone page says where the settings are when both are off', (tester) async {
    await tester.pumpTestWidget(
      context,
      const DronePage(),
      overrides: [
        djiLinkEnabledProvider.overrideWithValue(false),
        droneImportEnabledProvider.overrideWithValue(false),
        isHorizonOsProvider.overrideWith((ref) async => false),
      ],
    );
    expect(find.text('Turn on DJI drones or DJI live video in Settings, Advanced.'), findsOneWidget);
  });

  testWidgets('a tap on the card opens what it targets', (tester) async {
    final pushed = <String>[];
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          path: '/',
          initial: true,
          page: PageInfo('home', builder: (_) => const Scaffold(body: Wrap(children: [DroneCollectionCard()]))),
        ),
        AutoRoute(
          path: '/live',
          page: PageInfo(
            DjiLiveRoute.name,
            builder: (_) {
              pushed.add(DjiLiveRoute.name);
              return const Text('live screen');
            },
          ),
        ),
      ],
    );
    await tester.pumpTestWidget(
      context,
      SizedBox(height: 800, width: 400, child: MaterialApp.router(routerConfig: router.config())),
      overrides: [
        djiLinkEnabledProvider.overrideWithValue(true),
        droneImportEnabledProvider.overrideWithValue(false),
        isHorizonOsProvider.overrideWith((ref) async => false),
      ],
    );
    await tester.tap(find.byKey(const Key('drone_card')));
    await tester.pumpAndSettle();
    expect(find.text('live screen'), findsOneWidget);
    expect(pushed, [DjiLiveRoute.name]);
  });
}
