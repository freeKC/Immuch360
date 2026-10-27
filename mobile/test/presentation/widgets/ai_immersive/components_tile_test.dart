// The tile of the AI components in the settings: the sizes before the installation (from the catalogue) and after (the
// space the folder takes), the licence link, the removal refused while a conversion runs (and the offer to cancel it),
// "space freed at the next start" for a file the system keeps, and Remove all.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_licences.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/components_tile.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:path/path.dart' as p;

import '../../../widget_tester_extensions.dart';
import 'fake_ai_components_service.dart';

void main() {
  final linux = aiComponentsFor(AiPlatform.linuxX64);
  const runtime = onnxRuntimeLinuxComponent;
  const model = depthModelOnnxComponent;

  late FakeAiComponentsService service;
  late int cancelled;

  setUp(() {
    service = FakeAiComponentsService();
    cancelled = 0;
  });

  Future<void> pumpTile(WidgetTester tester) => tester.pumpConsumerWidget(
    Scaffold(
      body: SingleChildScrollView(
        child: AiComponentsTile(
          components: linux,
          onCancelConversions: () async {
            cancelled++;
            service.converting = false;
          },
        ),
      ),
    ),
    overrides: [aiComponentsServiceProvider.overrideWithValue(service)],
  );

  Finder inRow(AiComponent component, Finder finder) =>
      find.descendant(of: find.byKey(Key('ai_component_${component.id}')), matching: finder);

  /// Lets the dialog read its file from the disk: each step of a read waits for the real event loop, then a frame
  Future<void> readFiles(WidgetTester tester) async {
    for (var step = 0; step < 20; step++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  String sizes(AiComponent component) =>
      '${formatBytes(AiComponentsService.downloadBytesOf([component]))} to download, '
      '${formatBytes(AiComponentsService.diskBytesOf([component]))} on disk';

  testWidgets('before the installation: the sizes of the catalogue; after: on disk and the space really taken', (
    tester,
  ) async {
    await pumpTile(tester);

    expect(find.text('ONNX Runtime 1.31.0'), findsOneWidget);
    expect(find.text('Depth Anything V2 Small'), findsOneWidget);
    expect(inRow(runtime, find.text('Not installed')), findsOneWidget);
    // The gzip library and its notices to download, the library and its notices on the disk
    expect(inRow(runtime, find.text(sizes(runtime))), findsOneWidget);
    expect(inRow(model, find.text(sizes(model))), findsOneWidget);
    expect(find.text('Total: 0 B'), findsOneWidget);
    expect(find.byKey(const Key('ai_components_remove_all')), findsNothing);
    expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
    expect(service.installs, isEmpty, reason: 'nothing is downloaded without a tap on Download');

    // Download opens the install sheet; its Download installs the runtime then the model
    await tester.tap(find.byKey(const Key('ai_components_download')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai_install_download')));
    await tester.pumpAndSettle();

    expect(service.installs, [runtime.id, model.id]);
    expect(find.byKey(const Key('ai_install_download')), findsNothing, reason: 'the sheet closed');
    final disk = AiComponentsService.diskBytesOf([runtime]);
    expect(inRow(runtime, find.text('${formatBytes(disk)} on disk')), findsOneWidget);
    expect(inRow(runtime, find.text('Not installed')), findsNothing);
    expect(find.text('Total: ${formatBytes(service.space)}'), findsOneWidget);
    expect(service.space, AiComponentsService.diskBytesOf(linux));
    expect(find.byKey(const Key('ai_components_download')), findsNothing);
    expect(find.byKey(const Key('ai_components_remove_all')), findsOneWidget);
  });

  testWidgets('the licence link shows the licence the app keeps, before the installation', (tester) async {
    await pumpTile(tester);

    await tester.tap(inRow(runtime, find.text('Licence: MIT')));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.text('ONNX Runtime 1.31.0')), findsOneWidget);
    expect(find.text('Licence: MIT, https://github.com/microsoft/onnxruntime/blob/v1.31.0/LICENSE'), findsOneWidget);
    expect(find.text('Copyright (c) Microsoft Corporation'), findsOneWidget);
    expect(find.text('Open in browser'), findsOneWidget);
    expect(find.byKey(const Key('ai_licence_notices')), findsNothing, reason: 'no notices before the download');

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(inRow(model, find.text('Licence: Apache-2.0')));
    await tester.pumpAndSettle();

    expect(find.text('                                 Apache License'), findsOneWidget);
  });

  testWidgets('after the installation, the licence copied next to the component and the notices of ONNX Runtime', (
    tester,
  ) async {
    final folder = Directory.systemTemp.createTempSync('ai-licence');
    addTearDown(() => folder.deleteSync(recursive: true));
    service
      ..licence = (File(p.join(folder.path, 'licence.txt'))
        ..writeAsStringSync(
          aiComponentLicenceNotice(
            runtime,
            source: 'https://example.test/x.gz',
            installedAt: DateTime.utc(2026, 10, 27),
          ),
        ))
      ..notices = (File(p.join(folder.path, 'notices.txt'))..writeAsStringSync('protobuf\nBSD-3-Clause\n'))
      ..setStatus(runtime, const AiComponentStatus(AiComponentState.installed));
    await pumpTile(tester);

    await tester.tap(inRow(runtime, find.text('Licence: MIT')));
    await readFiles(tester);

    expect(find.text('Downloaded from: https://example.test/x.gz'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ai_licence_notices')));
    await readFiles(tester);

    expect(find.text('BSD-3-Clause'), findsOneWidget);
  });

  testWidgets('a removal refused while a conversion runs asks to cancel it, then removes', (tester) async {
    service
      ..setStatus(runtime, const AiComponentStatus(AiComponentState.installed))
      ..setStatus(model, const AiComponentStatus(AiComponentState.installed))
      ..space = AiComponentsService.diskBytesOf(linux)
      ..converting = true;
    await pumpTile(tester);

    // No: the conversion goes on, nothing is removed
    await tester.tap(find.byKey(Key('ai_component_remove_${model.id}')));
    await tester.pumpAndSettle();
    expect(find.text('A conversion is running. Cancel it to remove the components?'), findsOneWidget);
    await tester.tap(find.text('No'));
    await tester.pumpAndSettle();

    expect(cancelled, 0);
    expect(service.removals, [model.id]);
    expect(service.statusOf(model).state, AiComponentState.installed);

    // Yes: the conversions are cancelled, then the model goes
    await tester.tap(find.byKey(Key('ai_component_remove_${model.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai_components_cancel_conversions')));
    await tester.pumpAndSettle();

    expect(cancelled, 1);
    expect(service.removals, [model.id, model.id, model.id]);
    expect(service.statusOf(model).state, AiComponentState.notInstalled);
    expect(inRow(model, find.text('Not installed')), findsOneWidget);
    expect(find.text('Total: ${formatBytes(AiComponentsService.diskBytesOf([runtime]))}'), findsOneWidget);
  });

  testWidgets('a file the system keeps: "space freed at the next start", on the row and in a message', (tester) async {
    service
      ..setStatus(runtime, const AiComponentStatus(AiComponentState.installed))
      ..space = AiComponentsService.diskBytesOf([runtime])
      ..removeOutcome = AiRemoveOutcome.nextStart;
    await pumpTile(tester);

    await tester.tap(find.byKey(Key('ai_component_remove_${runtime.id}')));
    await tester.pump();

    expect(find.descendant(of: find.byType(SnackBar), matching: find.text('Space freed at the next start')), findsOne);
    await tester.pumpAndSettle();
    expect(inRow(runtime, find.text('Space freed at the next start')), findsOneWidget);
    expect(find.byKey(Key('ai_component_remove_${runtime.id}')), findsNothing);
  });

  testWidgets('Remove all removes every component; a list that cannot be written is said', (tester) async {
    service
      ..setStatus(runtime, const AiComponentStatus(AiComponentState.installed))
      ..setStatus(model, const AiComponentStatus(AiComponentState.installed))
      ..space = AiComponentsService.diskBytesOf(linux)
      ..removeOutcome = AiRemoveOutcome.writeFailed;
    await pumpTile(tester);

    await tester.tap(find.byKey(const Key('ai_components_remove_all')));
    await tester.pump();

    expect(find.text('Not removed: the list of the components could not be written'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(service.statusOf(runtime).state, AiComponentState.installed);

    service.removeOutcome = AiRemoveOutcome.removed;
    await tester.tap(find.byKey(const Key('ai_components_remove_all')));
    await tester.pumpAndSettle();

    expect(service.removals, [null, null]);
    expect(find.text('Not installed'), findsNWidgets(2));
    expect(find.text('Total: 0 B'), findsOneWidget);
    expect(find.byKey(const Key('ai_components_remove_all')), findsNothing);
  });

  testWidgets('a damaged component says so and can be removed or downloaded again', (tester) async {
    service.setStatus(runtime, const AiComponentStatus(AiComponentState.damaged));
    await pumpTile(tester);

    expect(inRow(runtime, find.text('Damaged: download it again')), findsOneWidget);
    expect(find.byKey(Key('ai_component_remove_${runtime.id}')), findsOneWidget);
    expect(find.byKey(const Key('ai_components_download')), findsOneWidget);
  });
}
