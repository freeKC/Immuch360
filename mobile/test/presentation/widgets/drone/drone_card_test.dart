// The Drone card of the Library and the Drone page (p2/design-final-2026-10-24.md, section 2): one function offered
// opens it directly, two open the page, none hides the card; the page lists the live video and the photos.

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/pages/drone/drone.page.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/drone_card.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/drone_import_tile.widget.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
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
    expect(droneCardTarget(liveOffered: true, importOffered: true, headset: false), DroneCardTarget.page);
    expect(droneCardTarget(liveOffered: true, importOffered: false, headset: false), DroneCardTarget.live);
    expect(droneCardTarget(liveOffered: false, importOffered: true, headset: false), DroneCardTarget.photos);
    // The Quest: the import is never offered there, the card opens the watch page
    expect(droneCardTarget(liveOffered: true, importOffered: false, headset: true), DroneCardTarget.watch);
    expect(droneCardTarget(liveOffered: false, importOffered: false, headset: false), DroneCardTarget.none);
    expect(droneCardTarget(liveOffered: false, importOffered: false, headset: true), DroneCardTarget.none);
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
