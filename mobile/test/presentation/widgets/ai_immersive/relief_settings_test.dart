// The AI settings of the Meta Quest in the advanced settings: the switch of the AI features, the untested switch of
// the Quest 2 and Pro, the relief cache with its size and Clear on a folder of the test, and the components of the
// headset; the cache and the components with the quest flavour only, nothing of it off Horizon OS.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/components_tile.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/relief_settings.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/providers/ai_immersive/relief_gate.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:immich_mobile/widgets/settings/advanced_settings.dart';
import 'package:path/path.dart' as p;

import '../../../unit/presentation/presentation_context.dart';
import 'fake_ai_components_service.dart';

void main() {
  late PresentationContext context;
  late Directory cache;
  late FakeAiComponentsService components;

  setUp(() async {
    context = await PresentationContext.create();
    cache = Directory.systemTemp.createTempSync('ai_relief_cache_');
    components = FakeAiComponentsService();
  });

  tearDown(() async {
    if (cache.existsSync()) {
      cache.deleteSync(recursive: true);
    }
    await context.dispose();
  });

  final aiSwitch = find.descendant(
    of: find.byKey(const Key('advanced_settings_ai_enabled')),
    matching: find.byType(SwitchListTile),
  );
  final olderSwitch = find.descendant(
    of: find.byKey(const Key('advanced_settings_ai_older_headsets')),
    matching: find.byType(SwitchListTile),
  );
  final meshSwitch = find.descendant(
    of: find.byKey(const Key('advanced_settings_ai_relief_25d')),
    matching: find.byType(SwitchListTile),
  );
  final cacheTile = find.byKey(const Key('ai_relief_cache_tile'));
  final clearButton = find.byKey(const Key('ai_relief_cache_clear'));

  /// The advanced settings on a device that is a Meta Quest or not ([horizonOs]), built with [flavor]
  Future<void> pumpSettings(WidgetTester tester, {bool horizonOs = true, String? flavor = 'quest'}) async {
    await tester.pumpTestWidget(
      context,
      const AdvancedSettings(),
      overrides: [
        isHorizonOsProvider.overrideWith((ref) async => horizonOs),
        appFlavorProvider.overrideWithValue(flavor),
        reliefCacheFolderProvider.overrideWithValue(() async => cache),
        aiComponentsServiceProvider.overrideWithValue(components),
      ],
    );
  }

  /// Lets the real file reads of the cache tile end, until [done]
  Future<void> pumpFiles(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  /// Scrolls until [finder] is built, then brings it whole on the screen
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 100, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  void writeMap(String name, int size) => File(p.join(cache.path, name)).writeAsBytesSync(List.filled(size, 7));

  testWidgets('on a Meta Quest, the AI features read on by default and turn off and on again', (tester) async {
    await pumpSettings(tester);
    await scrollTo(tester, aiSwitch);

    expect(find.text('AI and 3D'), findsOneWidget);
    expect(find.text('AI features'), findsOneWidget);
    expect(find.text('Off: no AI button anywhere, nothing downloaded'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(aiSwitch).value, isTrue);
    expect(SettingsRepository.instance.appConfig.aiImmersive.enabled, isTrue);

    await tester.tap(aiSwitch);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(aiSwitch).value, isFalse);
    expect(SettingsRepository.instance.appConfig.aiImmersive.enabled, isFalse);

    await tester.tap(aiSwitch);
    await tester.pumpAndSettle();
    expect(SettingsRepository.instance.appConfig.aiImmersive.enabled, isTrue);
  });

  testWidgets('the Quest 2 and Pro switch reads off, turns on, and waits for the AI features', (tester) async {
    await pumpSettings(tester);
    await scrollTo(tester, olderSwitch);

    expect(find.text('AI relief on Quest 2 and Quest Pro (untested)'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(olderSwitch).value, isFalse);

    await tester.tap(olderSwitch);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(olderSwitch).value, isTrue);
    expect(SettingsRepository.instance.appConfig.aiImmersive.olderHeadsets, isTrue);

    // With the AI features off, it does not move
    await scrollTo(tester, aiSwitch);
    await tester.tap(aiSwitch);
    await tester.pumpAndSettle();
    await scrollTo(tester, olderSwitch);
    await tester.tap(olderSwitch);
    await tester.pumpAndSettle();
    expect(SettingsRepository.instance.appConfig.aiImmersive.olderHeadsets, isTrue);
  });

  testWidgets('a relief opens in stereo; the 2.5D switch turns 2.5D first, and waits for the AI features', (
    tester,
  ) async {
    await pumpSettings(tester);
    await scrollTo(tester, meshSwitch);

    expect(find.text('Open AI reliefs in 2.5D (experimental)'), findsOneWidget);
    expect(
      find.text('Move your head to see around the objects. Off: they open in 3D. The 3D button switches at any time.'),
      findsOneWidget,
    );
    expect(tester.widget<SwitchListTile>(meshSwitch).value, isFalse);
    expect(SettingsRepository.instance.appConfig.aiImmersive.questMode, ReliefViewMode.stereo);

    await tester.tap(meshSwitch);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(meshSwitch).value, isTrue);
    expect(SettingsRepository.instance.appConfig.aiImmersive.questMode, ReliefViewMode.mesh25d);

    await tester.tap(meshSwitch);
    await tester.pumpAndSettle();
    expect(SettingsRepository.instance.appConfig.aiImmersive.questMode, ReliefViewMode.stereo);

    // With the AI features off, it does not move
    await scrollTo(tester, aiSwitch);
    await tester.tap(aiSwitch);
    await tester.pumpAndSettle();
    await scrollTo(tester, meshSwitch);
    await tester.tap(meshSwitch);
    await tester.pumpAndSettle();
    expect(SettingsRepository.instance.appConfig.aiImmersive.questMode, ReliefViewMode.stereo);
  });

  testWidgets('the relief cache shows its size, and Clear removes its maps and nothing else', (tester) async {
    writeMap('${'a' * 64}.u16', 710712);
    writeMap('${'b' * 64}.u16', 710712);
    writeMap('${'c' * 64}.u16.42.tmp', 1000);
    final inside = Directory(p.join(cache.path, 'inside'))..createSync();
    final kept = File(p.join(inside.path, 'kept.bin'))..writeAsBytesSync(List.filled(5000, 1));
    final size = formatBytes(2 * 710712 + 1000);

    await pumpSettings(tester);
    await scrollTo(tester, cacheTile);
    await pumpFiles(tester, () => find.text('Relief cache: $size').evaluate().isNotEmpty);

    expect(find.text('Relief cache: $size'), findsOneWidget);

    await tester.tap(clearButton);
    await pumpFiles(tester, () => find.text('Relief cache: 0 B').evaluate().isNotEmpty);

    expect(find.text('Relief cache: 0 B'), findsOneWidget);
    expect(tester.widget<TextButton>(clearButton).onPressed, isNull, reason: 'nothing more to clear');
    expect(cache.listSync().whereType<File>(), isEmpty);
    expect(kept.existsSync(), isTrue, reason: 'Clear touches nothing else');
  });

  testWidgets('an empty or missing cache reads 0 B with nothing to clear', (tester) async {
    cache.deleteSync(recursive: true);

    await pumpSettings(tester);
    await scrollTo(tester, cacheTile);
    await pumpFiles(tester, () => find.text('Relief cache: 0 B').evaluate().isNotEmpty);

    expect(find.text('Relief cache: 0 B'), findsOneWidget);
    expect(tester.widget<TextButton>(clearButton).onPressed, isNull);
  });

  testWidgets('the components of the headset: the depth model, its sizes and licence', (tester) async {
    await pumpSettings(tester);
    await scrollTo(tester, find.byType(AiComponentsTile));

    final tile = tester.widget<AiComponentsTile>(find.byType(AiComponentsTile));
    expect(tile.components, aiComponentsFor(AiPlatform.questArm64));
    expect(find.text('Depth Anything V2 Small'), findsOneWidget);
    expect(find.text('Licence: Apache-2.0'), findsOneWidget);
    expect(components.installs, isEmpty, reason: 'nothing is downloaded from the settings by themselves');
  });

  testWidgets('the APK of the phone flavour on a headset: the switches, no cache, no components', (tester) async {
    await pumpSettings(tester, flavor: 'phone');
    await scrollTo(tester, olderSwitch);

    expect(aiSwitch, findsOneWidget);
    expect(meshSwitch, findsNothing);
    expect(cacheTile, findsNothing);
    expect(find.byType(AiComponentsTile), findsNothing);
  });

  test('the relief cache of the app is ai-relief in its temporary folder, where the immersive viewer writes', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    final temporary = Directory.systemTemp.createTempSync('ai_relief_temporary_');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // The temporary folder only: another folder of path_provider would be a different place
    messenger.setMockMethodCallHandler(
      pathProvider,
      (call) async => call.method == 'getTemporaryDirectory' ? temporary.path : p.join(temporary.path, 'other'),
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(pathProvider, null);
      temporary.deleteSync(recursive: true);
    });

    expect((await appReliefCacheFolder()).path, p.join(temporary.path, 'ai-relief'));
  });

  testWidgets('off Horizon OS, nothing of it', (tester) async {
    await pumpSettings(tester, horizonOs: false);

    expect(find.byType(AiReliefSettings), findsNothing);
    expect(find.byKey(const Key('advanced_settings_ai_enabled')), findsNothing);
  });
}
