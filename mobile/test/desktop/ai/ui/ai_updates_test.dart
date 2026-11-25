// The screens of the updates of the AI components (issue 21): the line "2 AI components can be updated" with Update
// all, the question asked on a metered connection or above the limit, the progress with Pause, the paused state with
// Resume, what no connection left, the files no longer used with Remove, the button of the app bar and its badge, the
// badge of "This computer", and the row of an older version in the tile with its versions and its Update.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/ui/ai_updates.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_downloader.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_updater.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/components_tile.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:immich_ui/immich_ui.dart' show SettingsCard;

import '../../../presentation/widgets/ai_immersive/fake_ai_components_service.dart';
import '../../../widget_tester_extensions.dart';

/// An updater whose state the test sets; its calls noted
class _FakeUpdater extends AiComponentsUpdater {
  _FakeUpdater(AiComponentsService service) : super(service: service);

  List<AiComponentUpdate> fakeUpdates = const [];
  AiUnusedFiles fakeUnused = const AiUnusedFiles();
  AiUpdatePhase fakePhase = AiUpdatePhase.idle;
  AiUpdateOutcome? fakeOutcome;
  AiDownloadException? fakeFailure;
  AiComponent? fakeCurrent;
  int fakeReceived = 0;
  int fakeTotal = 0;

  /// What askFor answers: null asks nothing
  AiUpdateAsk? ask;

  /// The confirmed of each updateAll, the ids of each update, and the pauses, resumes and removals
  final updateAllCalls = <bool>[];
  final updateCalls = <String>[];
  var pauses = 0;
  var resumes = 0;
  var removals = 0;

  /// What resume answers first: needsConfirmation when the connection became metered during the pause
  AiUpdateOutcome resumeAnswer = AiUpdateOutcome.updated;
  final resumeCalls = <bool>[];
  AiUnusedFiles? removedListed;

  void changed() => notifyListeners();

  @override
  List<AiComponentUpdate> get updates => fakeUpdates;
  @override
  int get updateBytes => fakeUpdates.fold(0, (sum, update) => sum + update.downloadBytes);
  @override
  AiUnusedFiles get unused => fakeUnused;
  @override
  AiUpdatePhase get phase => fakePhase;
  @override
  AiUpdateOutcome? get outcome => fakeOutcome;
  @override
  AiDownloadException? get failure => fakeFailure;
  @override
  AiComponent? get current => fakeCurrent;
  @override
  int get receivedBytes => fakeReceived;
  @override
  int get totalBytes => fakeTotal;
  @override
  bool get isRunning => fakePhase == AiUpdatePhase.running;

  @override
  Future<void> refresh() async {}

  @override
  Future<AiUpdateAsk?> askFor(int bytes) async => ask;

  @override
  Future<AiUpdateOutcome> updateAll({bool confirmed = false}) async {
    updateAllCalls.add(confirmed);
    return ask != null && !confirmed ? AiUpdateOutcome.needsConfirmation : AiUpdateOutcome.updated;
  }

  @override
  Future<AiUpdateOutcome> update(AiComponent component, {bool confirmed = false}) async {
    updateCalls.add(component.id);
    return AiUpdateOutcome.updated;
  }

  @override
  void pause() => pauses++;

  @override
  Future<AiUpdateOutcome> resume({bool confirmed = false}) async {
    resumes++;
    resumeCalls.add(confirmed);
    return confirmed ? AiUpdateOutcome.updated : resumeAnswer;
  }

  @override
  int get pausedBytes => fakeTotal - fakeReceived;

  @override
  Future<AiRemoveOutcome> removeUnused({required AiUnusedFiles listed}) async {
    removals++;
    removedListed = listed;
    return AiRemoveOutcome.removed;
  }
}

void main() {
  const runtime = onnxRuntimeLinuxComponent;
  const model = depthModelOnnxComponent;
  late FakeAiComponentsService service;
  late _FakeUpdater updater;

  setUp(() {
    service = FakeAiComponentsService();
    updater = _FakeUpdater(service);
  });

  Future<void> pump(WidgetTester tester, Widget widget, {bool aiOn = true}) => tester.pumpConsumerWidget(
    Scaffold(body: SingleChildScrollView(child: widget)),
    overrides: [
      aiComponentsServiceProvider.overrideWithValue(service),
      aiComponentsUpdaterProvider.overrideWithValue(updater),
      aiFeaturesEnabledProvider.overrideWith((ref) => aiOn),
    ],
  );

  final twoUpdates = [
    const AiComponentUpdate(runtime, installedVersion: '1.30.0'),
    const AiComponentUpdate(model, installedVersion: '0000000'),
  ];
  String sizeOf(List<AiComponentUpdate> updates) =>
      formatBytes(updates.fold(0, (sum, update) => sum + update.downloadBytes));

  group('the panel', () {
    testWidgets('says how many can be updated and their size; Update all updates them', (tester) async {
      updater.fakeUpdates = twoUpdates;
      await pump(tester, const AiUpdatesPanel());

      expect(find.text('2 AI components can be updated, ${sizeOf(twoUpdates)}'), findsOneWidget);
      expect(find.text('Each installed version stays until its update is downloaded and checked.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ai_updates_update_all')));
      await tester.pumpAndSettle();

      expect(updater.updateAllCalls, [false]);
      expect(find.byKey(const Key('ai_update_confirm')), findsNothing);
    });

    testWidgets('on a metered connection it asks first; Cancel downloads nothing, Update goes on', (tester) async {
      updater.fakeUpdates = twoUpdates;
      updater.ask = AiUpdateAsk(bytes: updater.updateBytes, metered: true);
      await pump(tester, const AiUpdatesPanel());

      await tester.tap(find.byKey(const Key('ai_updates_update_all')));
      await tester.pumpAndSettle();
      expect(find.text('This connection is metered. The update downloads ${sizeOf(twoUpdates)}.'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(updater.updateAllCalls, [false]);

      await tester.tap(find.byKey(const Key('ai_updates_update_all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ai_update_confirm_yes')));
      await tester.pumpAndSettle();
      expect(updater.updateAllCalls, [false, false, true]);
    });

    testWidgets('above the limit it names the size alone', (tester) async {
      updater.fakeUpdates = twoUpdates;
      updater.ask = const AiUpdateAsk(bytes: 3 * 1024 * 1024 * 1024, metered: false);
      await pump(tester, const AiUpdatesPanel());

      await tester.tap(find.byKey(const Key('ai_updates_update_all')));
      await tester.pumpAndSettle();
      expect(find.text('The update downloads 3.0 GiB.'), findsOneWidget);
    });

    testWidgets('while it downloads: the component, the bytes and Pause; paused: Resume', (tester) async {
      updater
        ..fakeUpdates = twoUpdates
        ..fakePhase = AiUpdatePhase.running
        ..fakeCurrent = model
        ..fakeReceived = 50 * 1024 * 1024
        ..fakeTotal = 100 * 1024 * 1024;
      await pump(tester, const AiUpdatesPanel());

      expect(find.text('Updating Depth Anything V2 Small: 50.0 MiB of 100.0 MiB'), findsOneWidget);
      expect(find.byKey(const Key('ai_updates_update_all')), findsNothing);
      await tester.tap(find.byKey(const Key('ai_updates_pause')));
      expect(updater.pauses, 1);

      updater
        ..fakePhase = AiUpdatePhase.paused
        ..changed();
      await tester.pump();
      expect(find.text('Update paused: 50.0 MiB of 100.0 MiB'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ai_updates_resume')));
      expect(updater.resumes, 1);
    });

    testWidgets('without a connection it says the installed versions stay', (tester) async {
      updater
        ..fakeUpdates = twoUpdates
        ..fakePhase = AiUpdatePhase.failed
        ..fakeOutcome = AiUpdateOutcome.offline
        ..fakeFailure = const AiDownloadException(AiDownloadFailure.network);
      await pump(tester, const AiUpdatesPanel());

      expect(
        find.text('No connection. The installed versions stay: update them once the connection is back.'),
        findsOneWidget,
      );
      // Update all stays offered
      expect(find.byKey(const Key('ai_updates_update_all')), findsOneWidget);
    });

    testWidgets('a component that did not update says so, with why', (tester) async {
      updater
        ..fakeUpdates = [twoUpdates.first]
        ..fakePhase = AiUpdatePhase.failed
        ..fakeOutcome = AiUpdateOutcome.failed;
      updater.fakeFailure = const AiDownloadException(AiDownloadFailure.damaged);
      await pump(tester, const AiUpdatesPanel());

      expect(find.byKey(const Key('ai_updates_failed')), findsOneWidget);
    });

    testWidgets('the files no longer used, with their size and Remove; up to date otherwise', (tester) async {
      updater.fakeUnused = const AiUnusedFiles(paths: ['engines/x.new/run'], bytes: 3 * 1024 * 1024);
      await pump(tester, const AiUpdatesPanel(always: true));

      expect(find.text('AI components are up to date'), findsOneWidget);
      expect(find.text('Files no longer used: 3.0 MiB'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ai_updates_remove_unused')));
      await tester.pumpAndSettle();
      // Asked first, with the list: another version of the app may use them
      expect(find.byKey(const Key('ai_unused_confirm')), findsOneWidget);
      expect(find.text('engines/x.new/run'), findsOneWidget);
      expect(find.textContaining('Another version of Immuch360 on this computer may still use them'), findsOneWidget);
      expect(updater.removals, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(updater.removals, 0);

      await tester.tap(find.byKey(const Key('ai_updates_remove_unused')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ai_unused_confirm_yes')));
      await tester.pumpAndSettle();
      expect(updater.removals, 1);
      expect(updater.removedListed?.paths, ['engines/x.new/run'], reason: 'the list shown is the list removed');
    });

    testWidgets('Resume asks first when the connection became metered during the pause', (tester) async {
      updater
        ..fakeUpdates = twoUpdates
        ..fakePhase = AiUpdatePhase.paused
        ..fakeReceived = 50 * 1024 * 1024
        ..fakeTotal = 100 * 1024 * 1024
        ..resumeAnswer = AiUpdateOutcome.needsConfirmation
        ..ask = const AiUpdateAsk(bytes: 50 * 1024 * 1024, metered: true);
      await pump(tester, const AiUpdatesPanel());

      await tester.tap(find.byKey(const Key('ai_updates_resume')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ai_update_confirm')), findsOneWidget);
      expect(find.text('This connection is metered. The update downloads 50.0 MiB.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ai_update_confirm_yes')));
      await tester.pumpAndSettle();
      expect(updater.resumeCalls, [false, true]);
    });

    testWidgets('with the AI features off nothing is downloaded from it', (tester) async {
      updater.fakeUpdates = twoUpdates;
      await pump(tester, const AiUpdatesPanel(canDownload: false));

      final button = tester.widget<FilledButton>(find.byKey(const Key('ai_updates_update_all')));
      expect(button.onPressed, isNull);
    });
  });

  group('the app bar and the settings', () {
    testWidgets('the button shows only with updates, its badge counting them, and opens the panel', (tester) async {
      await pump(tester, const AiUpdatesBarButton());
      expect(find.byKey(const Key('ai_updates_button')), findsNothing);

      updater
        ..fakeUpdates = twoUpdates
        ..changed();
      await tester.pump();
      expect(find.byKey(const Key('ai_updates_button')), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.byTooltip('2 AI components can be updated, ${sizeOf(twoUpdates)}'), findsOneWidget);

      await tester.tap(find.byKey(const Key('ai_updates_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ai_updates_panel')), findsOneWidget);
    });

    testWidgets('no button while the AI features are off', (tester) async {
      updater.fakeUpdates = twoUpdates;
      await pump(tester, const AiUpdatesBarButton(), aiOn: false);

      expect(find.byKey(const Key('ai_updates_button')), findsNothing);
    });

    testWidgets('the narrow list of the settings shows the same badge on its card', (tester) async {
      updater.fakeUpdates = twoUpdates;
      await pump(
        tester,
        SettingsCard(
          icon: Icons.computer_outlined,
          title: 'This computer',
          subtitle: '',
          onTap: () {},
          decorateIcon: (icon) => AiUpdatesBadge(child: icon),
        ),
      );
      expect(tester.widget<Badge>(find.byKey(const Key('ai_updates_badge'))).isLabelVisible, isTrue);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('no count on This computer while the AI features are off', (tester) async {
      updater.fakeUpdates = twoUpdates;
      await pump(tester, const AiUpdatesBadge(child: Icon(Icons.computer_outlined)), aiOn: false);
      expect(tester.widget<Badge>(find.byKey(const Key('ai_updates_badge'))).isLabelVisible, isFalse);
    });

    testWidgets('the badge of This computer counts the updates', (tester) async {
      await pump(tester, const AiUpdatesBadge(child: Icon(Icons.computer_outlined)));
      expect(tester.widget<Badge>(find.byKey(const Key('ai_updates_badge'))).isLabelVisible, isFalse);

      updater
        ..fakeUpdates = twoUpdates
        ..changed();
      await tester.pump();
      expect(tester.widget<Badge>(find.byKey(const Key('ai_updates_badge'))).isLabelVisible, isTrue);
      expect(find.text('2'), findsOneWidget);
    });
  });

  testWidgets('the tile: an older version says both versions, its group offers Update, its row Update', (tester) async {
    service = FakeAiComponentsService(
      states: {runtime: AiComponentState.outdated, model: AiComponentState.installed},
      catalogue: [runtime, model],
    );
    service.versions[runtime.id] = '1.30.0';
    final updated = <String>[];
    await tester.pumpConsumerWidget(
      Scaffold(
        body: SingleChildScrollView(
          child: AiComponentsTile(
            platform: AiPlatform.linuxX64,
            onCancelConversions: () async {},
            onUpdate: (component) async => updated.add(component.id),
          ),
        ),
      ),
      overrides: [aiComponentsServiceProvider.overrideWithValue(service)],
    );
    await tester.pumpAndSettle();

    expect(find.byKey(Key('ai_component_outdated_${runtime.id}')), findsOneWidget);
    expect(find.text('Version 1.30.0 installed, version 1.31.0 available'), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const Key('ai_components_group_download_photos')), matching: find.text('Update')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(Key('ai_component_update_${runtime.id}')));
    await tester.pumpAndSettle();
    expect(updated, [runtime.id]);
  });
}
