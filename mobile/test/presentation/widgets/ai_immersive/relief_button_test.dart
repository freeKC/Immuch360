// The "AI relief" button of the 2D panel of the Meta Quest: greyed with its reason where the gate refuses, the install
// sheet first when the depth model is missing (a fake download, nothing before Download), then the depthRelief request
// to the immersive viewer with the model installed on the headset, the identity of the photo and its quarter turns.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/domain/services/ai_immersive/quest_relief.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/relief_button.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/providers/ai_immersive/relief_gate.provider.dart';

import '../../../widget_tester_extensions.dart';
import 'quest_relief_fakes.dart';

void main() {
  const model = depthModelTfliteComponent;
  final contract =
      jsonDecode(File('test/fixtures/ai_immersive/stereo_pair_contract_v1.json').readAsStringSync())
          as Map<String, dynamic>;
  final serverPhoto = ((contract['depthRelief'] as List)[0] as Map<String, dynamic>)['request'];
  final serverPhotoIn25d = ((contract['depthRelief'] as List)[2] as Map<String, dynamic>)['request'];

  late InstalledModelService service;
  late List<StereoPhotoRequest> opened;
  late int identitiesAsked;

  setUp(() {
    service = InstalledModelService();
    opened = [];
    identitiesAsked = 0;
  });

  ReliefTarget target({int quarterTurns = 0}) => ReliefTarget(
    identity: () async {
      identitiesAsked++;
      return 'sha1:X8tYgvibyzHDDN2yXGU/ft1XxeM=';
    },
    quarterTurns: () async => quarterTurns,
    open: (request) async => opened.add(request),
  );

  Future<void> pumpButton(
    WidgetTester tester,
    ReliefGate gate, {
    int quarterTurns = 0,
    ReliefViewMode mode = ReliefViewMode.stereo,
  }) => tester.pumpConsumerWidget(
    Scaffold(
      body: Center(
        child: AiReliefButton(
          gate: gate,
          target: target(quarterTurns: quarterTurns),
          mode: mode,
        ),
      ),
    ),
    overrides: [aiComponentsServiceProvider.overrideWithValue(service)],
  );

  IconButton button(WidgetTester tester) => tester.widget<IconButton>(find.byKey(aiReliefButtonKey));

  Map<String, Object?> jsonOf(StereoPhotoRequest request) =>
      jsonDecode(request.toImmersiveJson()) as Map<String, Object?>;

  group('greyed with its reason where the gate refuses', () {
    for (final (refusal, reason) in [
      (ReliefRefusal.build, 'Not in this version of the app'),
      (ReliefRefusal.memory, 'Not enough memory'),
      (ReliefRefusal.headset, 'Not tested on this headset yet'),
    ]) {
      testWidgets('${refusal.name}: "$reason"', (tester) async {
        await pumpButton(tester, ReliefGate.refused(refusal));

        expect(find.byKey(aiReliefButtonKey), findsOneWidget, reason: 'never hidden');
        expect(button(tester).onPressed, isNull);
        expect(find.byTooltip(reason), findsOneWidget);

        await tester.tap(find.byKey(aiReliefButtonKey), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(opened, isEmpty);
        expect(service.installs, isEmpty);
      });
    }
  });

  testWidgets('shows nothing for a hidden gate', (tester) async {
    await pumpButton(tester, ReliefGate.hidden);

    expect(find.byKey(aiReliefButtonKey), findsNothing);
  });

  testWidgets('with the model installed, asks the immersive viewer for the relief of the contract', (tester) async {
    service.setStatus(model, const AiComponentStatus(AiComponentState.installed));
    await pumpButton(tester, ReliefGate.offered);
    expect(find.byTooltip('AI relief'), findsOneWidget);

    await tester.tap(find.byKey(aiReliefButtonKey));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ai_install_prompt')), findsNothing, reason: 'nothing to install');
    expect(opened, hasLength(1));
    expect(jsonOf(opened.single), serverPhoto);
    expect(opened.single, isA<DepthReliefStereoPhotoRequest>());
  });

  testWidgets('asks for 2.5D first when the setting says so, the same photo and the same cache key', (tester) async {
    service.setStatus(model, const AiComponentStatus(AiComponentState.installed));
    await pumpButton(tester, ReliefGate.offered, mode: ReliefViewMode.mesh25d);

    await tester.tap(find.byKey(aiReliefButtonKey));
    await tester.pumpAndSettle();

    expect(jsonOf(opened.single), serverPhotoIn25d);
  });

  testWidgets('keys the relief with the quarter turns the photo is seen with', (tester) async {
    service.setStatus(model, const AiComponentStatus(AiComponentState.installed));
    await pumpButton(tester, ReliefGate.offered, quarterTurns: 3);

    await tester.tap(find.byKey(aiReliefButtonKey));
    await tester.pumpAndSettle();

    final expected = questReliefRequest(
      modelPath: service.modelPath,
      identity: 'sha1:X8tYgvibyzHDDN2yXGU/ft1XxeM=',
      quarterTurns: 3,
    );
    expect(jsonOf(opened.single), jsonDecode(expected.toJsonString()));
    expect(jsonOf(opened.single)['quarterTurns'], 3);
  });

  testWidgets('without the model, the install sheet comes first; nothing is downloaded before Download', (
    tester,
  ) async {
    final download = Completer<void>();
    service.onInstall = (component) async {
      service.setStatus(component, const AiComponentStatus(AiComponentState.downloading, received: 25, total: 100));
      await download.future;
    };
    await pumpButton(tester, ReliefGate.offered);

    await tester.tap(find.byKey(aiReliefButtonKey));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ai_install_prompt')), findsOneWidget);
    expect(find.text('Depth Anything V2 Small'), findsOneWidget);
    expect(find.text('94.9 MiB to download, 94.9 MiB on disk'), findsOneWidget);
    expect(service.installs, isEmpty);
    expect(opened, isEmpty);

    await tester.tap(find.byKey(const Key('ai_install_download')));
    await tester.pump();
    expect(service.installs, [model.id]);
    expect(find.text('Downloading Depth Anything V2 Small: 25%'), findsOneWidget);
    expect(opened, isEmpty, reason: 'the relief waits for the model');

    download.complete();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ai_install_prompt')), findsNothing);
    expect(jsonOf(opened.single), serverPhoto);
  });

  testWidgets('a sheet closed without installing opens nothing, and the button can be pressed again', (tester) async {
    await pumpButton(tester, ReliefGate.offered);

    await tester.tap(find.byKey(aiReliefButtonKey));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ai_install_prompt')), findsOneWidget);

    // Closed by a tap above the sheet
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ai_install_prompt')), findsNothing);
    expect(opened, isEmpty);
    expect(identitiesAsked, 0, reason: 'no photo is read for nothing');
    expect(button(tester).onPressed, isNotNull);
    // Closing is an answer: nothing is said afterwards
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('The AI components are not installed'), findsNothing);
  });

  testWidgets('a model damaged on the disk is offered again in the sheet', (tester) async {
    service.setStatus(model, const AiComponentStatus(AiComponentState.damaged));
    await pumpButton(tester, ReliefGate.offered);

    await tester.tap(find.byKey(aiReliefButtonKey));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('ai_install_row_${model.id}')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ai_install_download')));
    await tester.pumpAndSettle();

    expect(service.installs, [model.id]);
    expect(jsonOf(opened.single), serverPhoto);
  });

  testWidgets('a model still not there after the sheet says so, and opens nothing', (tester) async {
    service.lose = true;
    await pumpButton(tester, ReliefGate.offered);

    await tester.tap(find.byKey(aiReliefButtonKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai_install_download')));
    await tester.pumpAndSettle();

    expect(find.text('The AI components are not installed'), findsOneWidget);
    expect(opened, isEmpty);
  });

  testWidgets('on a Quest 2 or Pro allowed by the untested switch, a passing word that it may take seconds', (
    tester,
  ) async {
    service.setStatus(model, const AiComponentStatus(AiComponentState.installed));
    await pumpButton(tester, ReliefGate.offeredSlow);

    await tester.tap(find.byKey(aiReliefButtonKey));
    await tester.pump();

    expect(find.text('On this headset the relief can take several seconds'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(opened, hasLength(1));
    // A SnackBar: it fades by itself
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('On this headset the relief can take several seconds'), findsNothing);
  });

  testWidgets('a photo that cannot be told says the viewer could not open, and opens nothing', (tester) async {
    service.setStatus(model, const AiComponentStatus(AiComponentState.installed));
    await tester.pumpConsumerWidget(
      Scaffold(
        body: Center(
          child: AiReliefButton(
            gate: ReliefGate.offered,
            target: ReliefTarget(
              identity: () async => throw StateError('no checksum and no file'),
              quarterTurns: () async => 0,
              open: (request) async => opened.add(request),
            ),
          ),
        ),
      ),
      overrides: [aiComponentsServiceProvider.overrideWithValue(service)],
    );

    await tester.tap(find.byKey(aiReliefButtonKey));
    await tester.pumpAndSettle();

    expect(opened, isEmpty);
    expect(find.text('Could not open the immersive viewer'), findsOneWidget);
    expect(button(tester).onPressed, isNotNull);
  });

  test('the Quest needs the depth model of the Quest only', () {
    expect(aiComponentsFor(AiPlatform.questArm64), [model]);
    expect(AiComponentsService.downloadBytesOf([model]), 99530468);
  });

  test('the relief asks for the components of the 3D photo, whatever the catalogue holds for the later features', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    const later = AiComponent(
      id: 'later-quest-model',
      version: '1',
      kind: AiComponentKind.model,
      platforms: {AiPlatform.questArm64},
      assetName: 'later.tflite',
      installPath: 'models/later/later.tflite',
      size: 1,
      sha256: null,
      compression: AiCompression.none,
      licence: 'MIT',
      licenceUrl: 'https://example.org',
      features: {AiFeature.scene},
    );

    expect(container.read(reliefComponentsProvider), [model]);
    expect(reliefComponentsOf([model, later]), [model]);
  });
}
