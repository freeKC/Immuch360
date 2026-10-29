// The kiosk mode of the Meta Quest in the advanced settings: the switch on by default with nothing chosen, Choose
// through the picker (replaced here), Clear, the end card text and its default, the rows greyed with the switch off,
// and nothing of it off Horizon OS.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/kiosk_media.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/presentation/widgets/kiosk/kiosk_settings.dart';
import 'package:immich_mobile/providers/ai_immersive/relief_gate.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/widgets/settings/advanced_settings.dart';

import '../../../unit/presentation/presentation_context.dart';

const _film = KioskAssetMedia(remoteId: 'remote-1', localId: 'local-2', name: 'expo_360.mp4', isVideo: true);
const _shareFile = KioskShareFile(sourceId: 'nas', path: '/Expo/visite.jpg', name: 'visite.jpg', isVideo: false);

void main() {
  late PresentationContext context;

  /// What the picker gives at each Choose, null for a Back; and how many times it opened
  late List<KioskMedia?> picks;
  late int pickerOpened;

  setUp(() async {
    context = await PresentationContext.create();
    picks = [];
    pickerOpened = 0;
  });

  tearDown(() async {
    await context.dispose();
  });

  final kioskSwitch = find.descendant(
    of: find.byKey(const Key('advanced_settings_kiosk_enabled')),
    matching: find.byType(SwitchListTile),
  );
  final mediaTile = find.byKey(const Key('advanced_settings_kiosk_media'));
  final chooseButton = find.byKey(const Key('advanced_settings_kiosk_choose'));
  final clearButton = find.byKey(const Key('advanced_settings_kiosk_clear'));
  final endTextField = find.byKey(const Key('advanced_settings_kiosk_end_text'));

  /// The advanced settings on a device that is a Meta Quest or not ([horizonOs]), the APK of the phone flavour (no AI
  /// components to list)
  Future<void> pumpSettings(WidgetTester tester, {bool horizonOs = true}) async {
    await tester.pumpTestWidget(
      context,
      const AdvancedSettings(),
      overrides: [
        isHorizonOsProvider.overrideWith((ref) async => horizonOs),
        appFlavorProvider.overrideWithValue('phone'),
        kioskMediaPickerProvider.overrideWithValue((_) async {
          pickerOpened++;
          return picks.isEmpty ? null : picks.removeAt(0);
        }),
      ],
    );
  }

  /// Scrolls until [finder] is built, then brings it whole on the screen
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 100, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  bool isEnabled(WidgetTester tester, Finder button) => tester.widget<TextButton>(button).onPressed != null;

  testWidgets('on a Meta Quest, the kiosk mode reads on by default with nothing chosen', (tester) async {
    await pumpSettings(tester);
    await scrollTo(tester, mediaTile);

    expect(find.text('Kiosk mode (experimental)'), findsOneWidget);
    expect(
      find.text(
        'At start, the headset opens the chosen 360° photo or video for visitors. The film starts again each time the '
        'headset is put on.',
      ),
      findsOneWidget,
    );
    expect(tester.widget<SwitchListTile>(kioskSwitch).value, isTrue);
    expect(find.text('Kiosk media'), findsOneWidget);
    expect(find.text('None chosen: the app starts as usual'), findsOneWidget);
    expect(clearButton, findsNothing, reason: 'nothing to clear');
    expect(SettingsRepository.instance.appConfig.kiosk.isActive, isFalse);
  });

  testWidgets('Choose keeps the media picked and names it, Clear forgets it', (tester) async {
    picks = [_film];
    await pumpSettings(tester);
    await scrollTo(tester, chooseButton);

    await tester.tap(chooseButton);
    await tester.pumpAndSettle();

    expect(pickerOpened, 1);
    expect(find.text('expo_360.mp4'), findsOneWidget);
    expect(SettingsRepository.instance.appConfig.kiosk.chosenMedia, _film);
    expect(SettingsRepository.instance.appConfig.kiosk.isActive, isTrue);

    await scrollTo(tester, clearButton);
    await tester.tap(clearButton);
    await tester.pumpAndSettle();

    expect(find.text('None chosen: the app starts as usual'), findsOneWidget);
    expect(SettingsRepository.instance.appConfig.kiosk.media, isNull);
    expect(SettingsRepository.instance.appConfig.kiosk.isActive, isFalse);
  });

  testWidgets('a file of a share chosen replaces the film, Back from the picker keeps it', (tester) async {
    picks = [_film, _shareFile, null];
    await pumpSettings(tester);
    await scrollTo(tester, chooseButton);

    for (var i = 0; i < 3; i++) {
      await tester.tap(chooseButton);
      await tester.pumpAndSettle();
    }

    expect(pickerOpened, 3);
    expect(find.text('visite.jpg'), findsOneWidget);
    expect(SettingsRepository.instance.appConfig.kiosk.chosenMedia, _shareFile);
  });

  testWidgets('the end card text shows its default, keeps what is typed, and an empty field goes back to it', (
    tester,
  ) async {
    await pumpSettings(tester);
    await scrollTo(tester, endTextField);

    expect(find.text('End card text'), findsOneWidget);
    expect(find.text('Thank you for the journey'), findsOneWidget, reason: 'the default, as the hint of the field');

    await tester.enterText(endTextField, 'Merci et à bientôt');
    await tester.pumpAndSettle();
    expect(SettingsRepository.instance.appConfig.kiosk.endText, 'Merci et à bientôt');

    await tester.enterText(endTextField, '   ');
    await tester.pumpAndSettle();
    final kiosk = SettingsRepository.instance.appConfig.kiosk;
    expect(kiosk.endText, isNull);
    expect(kiosk.endTextOr('Thank you for the journey'), 'Thank you for the journey');
  });

  testWidgets('a text typed before shows in the field at the next visit', (tester) async {
    await SettingsRepository.instance.write(.kioskEndText, 'Dziękujemy za wspólną podróż');
    await pumpSettings(tester);
    await scrollTo(tester, endTextField);

    expect(find.text('Dziękujemy za wspólną podróż'), findsOneWidget);
  });

  testWidgets('the switch turns the kiosk off and greys its rows, the media chosen stays for later', (tester) async {
    await SettingsRepository.instance.write(.kioskMedia, _film.encode());
    await pumpSettings(tester);
    await scrollTo(tester, chooseButton);
    expect(SettingsRepository.instance.appConfig.kiosk.isActive, isTrue);
    expect(find.text('expo_360.mp4'), findsOneWidget);

    await scrollTo(tester, kioskSwitch);
    await tester.tap(kioskSwitch);
    await tester.pumpAndSettle();
    await scrollTo(tester, chooseButton);

    expect(SettingsRepository.instance.appConfig.kiosk.enabled, isFalse);
    expect(SettingsRepository.instance.appConfig.kiosk.isActive, isFalse);
    expect(SettingsRepository.instance.appConfig.kiosk.chosenMedia, _film);
    expect(isEnabled(tester, chooseButton), isFalse);
    expect(isEnabled(tester, clearButton), isFalse);
    expect(tester.widget<TextField>(endTextField).enabled, isFalse);

    await tester.tap(chooseButton, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(pickerOpened, 0);
  });

  testWidgets('off Horizon OS, nothing of it', (tester) async {
    await pumpSettings(tester, horizonOs: false);

    expect(find.byType(KioskSettings), findsNothing);
    expect(find.text('Kiosk mode (experimental)'), findsNothing);
  });
}
