import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/network/computer_share.dart';
import 'package:immich_mobile/desktop/network/interface_rank.dart';
import 'package:immich_mobile/desktop/network/network_category.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/pages/network/phone_share.page.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_focus_ring.widget.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/network/phone_share.provider.dart';

const _onState = PhoneShareState(
  status: PhoneShareStatus.on,
  addresses: ['192.168.1.20'],
  port: 8360,
  serviceName: 'Immuch360 on DESKTOP-TEST',
  username: 'phone4821',
  password: 'k7m3x9p2',
);

const _homeWifi = RankedAddress(
  name: 'Wi-Fi',
  address: '192.168.1.20',
  tier: 0,
  facts: AdapterFacts(
    name: 'Wi-Fi',
    kind: AdapterKind.wifi,
    defaultRoute: true,
    category: NetworkCategory.private,
    networkId: '{00000000-0000-0000-0000-00000000000A}',
  ),
);

const _cafeWifi = RankedAddress(
  name: 'Wi-Fi 2',
  address: '10.42.0.15',
  tier: 1,
  facts: AdapterFacts(
    name: 'Wi-Fi 2',
    kind: AdapterKind.wifi,
    hasGateway: true,
    category: NetworkCategory.public,
    networkId: '{00000000-0000-0000-0000-00000000000B}',
  ),
);

/// How often the page started and stopped the share
class _Calls {
  int starts = 0;
  int stops = 0;
}

/// The share without a server: [start] turns it on with [_onState]
class _FakeController extends PhoneShareController {
  _FakeController(this._initial, this._calls);

  final PhoneShareState _initial;
  final _Calls _calls;

  @override
  PhoneShareState build() => _initial;

  @override
  Future<void> start() async {
    _calls.starts++;
    state = _onState;
  }

  @override
  Future<void> stop({bool idle = false}) async {
    _calls.stops++;
    state = PhoneShareState(username: state.username, password: state.password);
  }
}

void main() {
  late _Calls calls;
  late List<RankedAddress> candidates;
  late int settingsOpened;
  late bool hasFolders;

  setUp(() {
    candidates = const [_homeWifi];
    settingsOpened = 0;
    hasFolders = true;
  });

  tearDown(forgetPublicNetworksAllowed);

  Future<void> pump(WidgetTester tester, Widget child, {PhoneShareState initial = const PhoneShareState()}) async {
    final current = calls = _Calls();
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: locales.values.first,
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: ProviderScope(
          overrides: [
            phoneShareProvider.overrideWith(() => _FakeController(initial, current)),
            phoneSharePermissionsProvider.overrideWithValue(() async => hasFolders),
            isHorizonOsProvider.overrideWith((_) async => false),
            computerShareNetworkProvider.overrideWithValue(
              ComputerShareNetwork(
                candidates: () async => candidates,
                openSettings: () async => settingsOpened++,
                refreshEvery: const Duration(hours: 1),
              ),
            ),
          ],
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: child,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Runs [body] as on [platform], reset within the test: the binding checks it before the tear downs run
  Future<void> on(TargetPlatform platform, Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  Future<void> flipSwitch(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('phone_share_switch')));
    await tester.pumpAndSettle();
  }

  group('the page on Windows', () {
    testWidgets('says "computer" and warns of the firewall before the first start', (tester) async {
      await on(TargetPlatform.windows, () async {
        await pump(tester, const PhoneSharePage());

        expect(find.text('Share this computer on the network'), findsOneWidget);
        expect(find.byKey(const Key('computer_share_firewall')), findsOneWidget);
        expect(
          find.text(
            'Windows may ask whether Immuch360 Desktop can use the network: allow it on private networks so that your '
            'other devices can connect.',
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('computer_share_public_left_out')), findsNothing);
      });
    });

    testWidgets('starts at once on a private network', (tester) async {
      await on(TargetPlatform.windows, () async {
        await pump(tester, const PhoneSharePage());
        await flipSwitch(tester);

        expect(find.byKey(const Key('computer_share_public_network')), findsNothing);
        expect(calls.starts, 1);
      });
    });

    testWidgets('without a folder chosen, nothing starts and the folders are asked for', (tester) async {
      await on(TargetPlatform.windows, () async {
        hasFolders = false;
        await pump(tester, const PhoneSharePage());
        await flipSwitch(tester);

        expect(calls.starts, 0);
        expect(find.text('Choose the folders of your photos and videos'), findsOneWidget);
        expect(find.text('The app cannot see the photos of this device'), findsNothing);
      });
    });

    testWidgets('asks first on a network marked public; Cancel keeps the share off', (tester) async {
      await on(TargetPlatform.windows, () async {
        candidates = const [_homeWifi, _cafeWifi];
        await pump(tester, const PhoneSharePage());
        await flipSwitch(tester);

        expect(find.byKey(const Key('computer_share_public_network')), findsOneWidget);
        expect(find.text('This network is marked as public'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(calls.starts, 0);
        expect(isLeftOutAsPublic(_cafeWifi), isTrue);
      });
    });

    testWidgets('"Share for this session" starts it on that network', (tester) async {
      await on(TargetPlatform.windows, () async {
        candidates = const [_cafeWifi];
        await pump(tester, const PhoneSharePage());
        await flipSwitch(tester);
        await tester.tap(find.byKey(const Key('computer_share_public_network_anyway')));
        await tester.pumpAndSettle();

        expect(calls.starts, 1);
        expect(isLeftOutAsPublic(_cafeWifi), isFalse);
        expect(servedShareAddresses(candidates), ['10.42.0.15']);
      });
    });

    testWidgets('"Open the settings" opens the network settings of Windows and keeps the share off', (tester) async {
      await on(TargetPlatform.windows, () async {
        candidates = const [_cafeWifi];
        await pump(tester, const PhoneSharePage());
        await flipSwitch(tester);
        await tester.tap(find.byKey(const Key('computer_share_public_network_settings')));
        await tester.pumpAndSettle();

        expect(settingsOpened, 1);
        expect(calls.starts, 0);
      });
    });

    testWidgets('the question has a focus ring of its own: Cancel first, then each answer with Tab', (tester) async {
      await on(TargetPlatform.windows, () async {
        candidates = const [_cafeWifi];
        await pump(tester, const PhoneSharePage());
        await flipSwitch(tester);

        final ring = tester.state<TvFocusRingState>(
          find.ancestor(of: find.byKey(const Key('computer_share_public_network')), matching: find.byType(TvFocusRing)),
        );
        Key? focused() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TextButton>()?.key;
        final keys = [focused()];
        expect(ring.ringRect, isNotNull, reason: 'Cancel has the focus and the ring from the start');
        for (var i = 0; i < 2; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
          expect(ring.ringRect, isNotNull, reason: 'stop ${i + 2} shows the ring');
          keys.add(focused());
        }
        expect(keys, const [
          Key('computer_share_public_network_cancel'),
          Key('computer_share_public_network_settings'),
          Key('computer_share_public_network_anyway'),
        ]);
        expect(calls.starts, 0, reason: 'moving the focus answers nothing');
      });
    });

    testWidgets('while it runs, a public network left out is shown, and allowed from there', (tester) async {
      await on(TargetPlatform.windows, () async {
        candidates = const [_homeWifi, _cafeWifi];
        await pump(tester, const PhoneSharePage(), initial: _onState);

        final anyway = find.byKey(const Key('computer_share_public_left_out_anyway'));
        await tester.ensureVisible(anyway);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('computer_share_public_left_out')), findsOneWidget);
        await tester.tap(anyway);
        await tester.pumpAndSettle();

        expect(isLeftOutAsPublic(_cafeWifi), isFalse);
        // Nobody was connected: restarted, so that the new address shows at once
        expect(calls.stops, 1);
        expect(calls.starts, 1);
        expect(find.byKey(const Key('computer_share_public_left_out')), findsNothing);
      });
    });

    testWidgets('with a device connected, allowing a public network does not restart the share', (tester) async {
      await on(TargetPlatform.windows, () async {
        candidates = const [_homeWifi, _cafeWifi];
        await pump(tester, const PhoneSharePage(), initial: _onState.copyWith(clients: 1));

        final anyway = find.byKey(const Key('computer_share_public_left_out_anyway'));
        await tester.ensureVisible(anyway);
        await tester.pumpAndSettle();
        await tester.tap(anyway);
        await tester.pumpAndSettle();

        expect(calls.stops, 0);
        expect(calls.starts, 0);
        expect(isLeftOutAsPublic(_cafeWifi), isFalse);
      });
    });
  });

  group('the tile of the network shares page', () {
    testWidgets('shows "Share this computer on the network" on Windows', (tester) async {
      await on(TargetPlatform.windows, () async {
        await pump(tester, const Scaffold(body: PhoneShareTile()));

        expect(find.byKey(const Key('phone_share_tile')), findsOneWidget);
        expect(find.text('Share this computer on the network'), findsOneWidget);
        expect(find.byIcon(Icons.computer), findsOneWidget);
      });
    });

    for (final platform in [TargetPlatform.linux, TargetPlatform.macOS]) {
      testWidgets('is hidden on ${platform.name}, which has no public network check yet', (tester) async {
        await on(platform, () async {
          await pump(tester, const Scaffold(body: PhoneShareTile()));

          expect(find.byKey(const Key('phone_share_tile')), findsNothing);
        });
      });
    }
  });

  testWidgets('a phone shows neither the firewall nor the public network notices', (tester) async {
    candidates = const [_cafeWifi];
    await pump(tester, const PhoneSharePage(), initial: _onState);

    expect(find.text('Share this phone on the network'), findsOneWidget);
    expect(find.byType(ComputerShareNotices), findsNothing);
    expect(find.byKey(const Key('computer_share_firewall')), findsNothing);
  });
}
