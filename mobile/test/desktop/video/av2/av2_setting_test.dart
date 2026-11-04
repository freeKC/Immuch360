// "AV2 videos (experimental)" in the settings of the videos on a computer (av2_setting.dart; store/m2/av2-2026-11-02/
// plan-2026-11-02.md, sections 1.3 and 4): the switch on by default, what it does, the decoder installed with its size
// and Remove, the size it downloads at the first AV2 video, or not in this version; its licence; nothing on a phone.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/av2_decoder.dart';
import 'package:immich_mobile/desktop/video/av2_setting.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:immich_mobile/widgets/settings/asset_viewer_settings/video_viewer_settings.dart';

import '../../../presentation/widgets/ai_immersive/fake_ai_components_service.dart';
import '../../../unit/presentation/presentation_context.dart';
import 'av2_test_components.dart';

// On the speeds the app measured (review of lot AD6, m3): 1080p in 8 bit smooth on the PC and in the Linux containers,
// 10-bit at the limit, 4K in 8 bit too slow even on the i9 (18.6 to 20.6 frames a second kept, the pictures of 12 MB
// that the player takes being the limit as much as the decoder), so no promise of 4K on four cores
const _description =
    'Decodes AV2 videos with the processor (experimental). In our tests, 8-bit videos up to 1080p play smoothly; '
    '10-bit and 4K videos may need more than the computer can give, and then pause to catch up. Video decoding, in the '
    'details of a video, shows how fast this computer decodes it. Decoding uses every core and warms the computer.';

void main() {
  late PresentationContext context;
  late FakeAiComponentsService service;

  setUp(() async {
    context = await PresentationContext.create();
    service = FakeAiComponentsService(catalogue: av2CompleteCatalogue);
  });

  tearDown(() => context.dispose());

  final desktop = TargetPlatformVariant.only(TargetPlatform.windows);
  final switchTile = find.widgetWithText(SwitchListTile, 'AV2 videos (experimental)');

  Future<void> pumpSetting(WidgetTester tester, {Widget widget = const Av2VideoSetting()}) => tester.pumpTestWidget(
    context,
    SingleChildScrollView(child: widget),
    overrides: [
      // The scope of the test is nested in that of PresentationContext: the decoder is made in it
      av2DecoderProvider.overrideWith((ref) => Av2Decoder(service, AiPlatform.windowsX64)),
      aiComponentsServiceProvider.overrideWithValue(service),
      isHorizonOsProvider.overrideWith((ref) => false),
    ],
  );

  String decoderLine(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('av2_setting_decoder'))).data!;

  testWidgets('on by default, with what it does, and the size of the decoder still to download', (tester) async {
    await pumpSetting(tester);
    expect(switchTile, findsOneWidget);
    expect(tester.widget<SwitchListTile>(switchTile).value, isTrue);
    expect(SettingsRepository.instance.appConfig.viewer.av2Videos, isTrue);
    expect(find.text(_description), findsOneWidget);
    expect(decoderLine(tester), 'The AV2 decoder downloads the first time an AV2 video plays (${formatBytes(790281)})');
    expect(find.text('Remove the AV2 decoder'), findsNothing);
    expect(
      find.text(
        'dav2d, the AV2 decoder of VideoLAN (BSD-2-Clause), under the Alliance for Open Media Patent License 1.0',
      ),
      findsOneWidget,
    );
  }, variant: desktop);

  test('promises no more than the app measured, in every language: no smooth 4K, no four cores, experimental', () {
    final folder = Directory('../i18n');
    final english = jsonDecode(File('${folder.path}/en.json').readAsStringSync()) as Map<String, dynamic>;
    final text = english['av2_settings_description'] as String;
    expect(text, _description);
    expect(text, contains('experimental'));
    expect(text, isNot(matches(RegExp(r'four.core|smoothly up to 4K', caseSensitive: false))));
    final locales = folder.listSync().whereType<File>().where((file) => file.path.endsWith('.json'));
    expect(locales, hasLength(89));
    for (final file in locales) {
      final values = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final value = values['av2_settings_description'];
      expect(value, isA<String>(), reason: file.path);
      // The text before lot AD11 promised 4K in 8 bit on four cores: its 4K came before 10-bit
      expect((value as String).contains('1080p'), isTrue, reason: file.path);
      expect(value.indexOf('1080p') < value.indexOf('4K'), isTrue, reason: '${file.path}: $value');
    }
  });

  testWidgets('turns the AV2 videos off and on', (tester) async {
    await pumpSetting(tester);
    await tester.tap(switchTile);
    await tester.pumpAndSettle();
    expect(SettingsRepository.instance.appConfig.viewer.av2Videos, isFalse);
    await tester.tap(switchTile);
    await tester.pumpAndSettle();
    expect(SettingsRepository.instance.appConfig.viewer.av2Videos, isTrue);
  }, variant: desktop);

  testWidgets('installed: its version and the space it takes, and Remove takes it away', (tester) async {
    service.setStatus(av2WindowsComplete, const AiComponentStatus(AiComponentState.installed));
    await pumpSetting(tester);
    final disk = formatBytes(AiComponentsService.diskBytesOf([av2WindowsComplete]));
    expect(decoderLine(tester), 'AV2 decoder 30140b5-1, $disk');

    await tester.tap(find.text('Remove the AV2 decoder'));
    await tester.pumpAndSettle();
    expect(service.groupRemovals, [AiFeatureGroup.av2]);
    expect(decoderLine(tester), 'The AV2 decoder downloads the first time an AV2 video plays (${formatBytes(790281)})');
    expect(find.text('Remove the AV2 decoder'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  }, variant: desktop);

  testWidgets('a decoder the system holds (a video playing on Windows) goes at the next start', (tester) async {
    service.setStatus(av2WindowsComplete, const AiComponentStatus(AiComponentState.installed));
    service.removeOutcome = AiRemoveOutcome.nextStart;
    await pumpSetting(tester);
    await tester.tap(find.text('Remove the AV2 decoder'));
    await tester.pumpAndSettle();
    expect(find.text('Space freed at the next start'), findsOneWidget);
  }, variant: desktop);

  testWidgets('a conversion running holds the removal, as for the AI components', (tester) async {
    service.setStatus(av2WindowsComplete, const AiComponentStatus(AiComponentState.installed));
    service.converting = true;
    await pumpSetting(tester);
    await tester.tap(find.text('Remove the AV2 decoder'));
    await tester.pumpAndSettle();
    expect(find.text('Not while a conversion or a download runs'), findsOneWidget);
    expect(decoderLine(tester), startsWith('AV2 decoder 30140b5-1'));
  }, variant: desktop);

  testWidgets('a download under way is said', (tester) async {
    service.setStatus(
      av2WindowsComplete,
      const AiComponentStatus(AiComponentState.downloading, received: 250, total: 1000),
    );
    await pumpSetting(tester);
    expect(decoderLine(tester), 'Downloading the AV2 decoder: 25%');
  }, variant: desktop);

  testWidgets('a version without the sums of the decoder says it is not in this version', (tester) async {
    service = FakeAiComponentsService(catalogue: av2IncompleteCatalogue);
    await pumpSetting(tester);
    expect(switchTile, findsOneWidget);
    expect(decoderLine(tester), 'Not in this version of the app');
    expect(find.text('Remove the AV2 decoder'), findsNothing);
  }, variant: desktop);

  testWidgets('its licence opens the texts of the decoder', (tester) async {
    await pumpSetting(tester);
    await tester.tap(find.byKey(const Key('av2_setting_licence')));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.text('AV2 decoder')), findsOneWidget);
    // The texts the app keeps until the decoder is installed, from their start (the list builds the lines on screen)
    for (final line in [
      'Licence: BSD-2-Clause, https://code.videolan.org/videolan/dav2d',
      'immuch360-av2, the AV2 decoder of Immuch360 Desktop',
      'Copyright © 2018-2026, VideoLAN and dav2d authors',
    ]) {
      expect(
        find.descendant(of: dialog, matching: find.textContaining(line)),
        findsWidgets,
        reason: line,
      );
    }
  }, variant: desktop);

  testWidgets('in the settings of the videos on a computer, never on a phone', (tester) async {
    await pumpSetting(tester, widget: const VideoViewerSettings());
    expect(find.byKey(const Key('av2_setting')), findsOneWidget);
    expect(switchTile, findsOneWidget);
  }, variant: desktop);

  testWidgets('nothing on a phone', (tester) async {
    await pumpSetting(tester, widget: const VideoViewerSettings());
    expect(find.byKey(const Key('av2_setting')), findsNothing);
  });
}
