// The install sheet of the AI components: what it lists before anything is downloaded (each missing component with
// its sizes and licence, the promise with the total), the download one component after the other with its bar, Cancel,
// a failure said in words, and a sheet that closes at once when nothing is missing.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_downloader.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/install_sheet.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

import '../../../widget_tester_extensions.dart';
import 'fake_ai_components_service.dart';

void main() {
  final windows = aiComponentsFor(AiPlatform.windowsX64);
  const runtime = onnxRuntimeWindowsComponent;
  const model = depthModelOnnxComponent;
  const quest = depthModelTfliteComponent;

  late FakeAiComponentsService service;
  late List<bool> results;

  setUp(() {
    service = FakeAiComponentsService();
    results = [];
  });

  /// A button that opens the sheet for [components], the answer of each sheet kept in [results]
  Future<void> pumpOpener(WidgetTester tester, List<AiComponent> components) async {
    await tester.pumpConsumerWidget(
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => results.add(await showAiInstallSheet(context, components)),
            child: const Text('open'),
          ),
        ),
      ),
      overrides: [aiComponentsServiceProvider.overrideWithValue(service)],
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('lists each missing component with its sizes and licence, and the promise; nothing before Download', (
    tester,
  ) async {
    service.setStatus(model, const AiComponentStatus(AiComponentState.installed));
    await pumpOpener(tester, windows);

    // The model is installed: only the runtime is offered, its 6 MB of gzip and its notices
    expect(find.byKey(Key('ai_install_row_${runtime.id}')), findsOneWidget);
    expect(find.byKey(Key('ai_install_row_${model.id}')), findsNothing);
    final download = formatBytes(AiComponentsService.downloadBytesOf([runtime]));
    expect(
      find.text(
        'This needs the components below, downloaded once ($download). They run on this device and work offline '
        'afterwards; no photo leaves it.',
      ),
      findsOneWidget,
    );
    expect(find.text('ONNX Runtime 1.31.0'), findsOneWidget);
    expect(
      find.text('$download to download, ${formatBytes(AiComponentsService.diskBytesOf([runtime]))} on disk'),
      findsOneWidget,
    );
    expect(find.text('Licence: MIT'), findsOneWidget);
    expect(service.installs, isEmpty);
  });

  testWidgets('a drive without the space: said with the drive and the way out before the first byte', (tester) async {
    service.shortage = const AiSpaceShortage(needed: 7400000000, free: 3100000000, volume: 'C:');
    await pumpOpener(tester, windows);

    await tester.tap(find.byKey(const Key('ai_install_download')));
    await tester.pumpAndSettle();

    expect(service.spaceAsked, [
      [runtime.id, model.id],
    ]);
    expect(service.installs, isEmpty);
    expect(
      find.text(
        'Not enough space on C: (${formatBytes(7400000000)} needed, ${formatBytes(3100000000)} free). Move the AI '
        'components to another drive in the settings.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('ai_install_download')), findsOneWidget);
  });

  testWidgets('on the Quest: the model, 94.9 MiB, Apache-2.0 with its link', (tester) async {
    await pumpOpener(tester, aiComponentsFor(AiPlatform.questArm64));

    expect(find.text('Depth Anything V2 Small'), findsOneWidget);
    expect(find.text('94.9 MiB to download, 94.9 MiB on disk'), findsOneWidget);
    expect(find.textContaining('downloaded once (94.9 MiB)'), findsOneWidget);

    await tester.tap(find.byKey(Key('ai_licence_${quest.id}')));
    await tester.pumpAndSettle();

    expect(find.text('Licence: Apache-2.0, ${quest.licenceUrl}'), findsOneWidget);
  });

  testWidgets('Download installs the runtime then the model, with a bar, and the sheet answers true', (tester) async {
    final gate = Completer<void>();
    service.onInstall = (component) async {
      if (component == runtime) {
        service.setStatus(
          component,
          const AiComponentStatus(AiComponentState.downloading, received: 1500, total: 6000),
        );
        await gate.future;
      }
    };
    await pumpOpener(tester, windows);

    await tester.tap(find.byKey(const Key('ai_install_download')));
    await tester.pump();

    expect(service.installs, [runtime.id]);
    final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(bar.value, 0.25);
    expect(find.text('Downloading ONNX Runtime 1.31.0: 25%'), findsOneWidget);
    expect(find.byKey(const Key('ai_install_cancel')), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();

    expect(service.installs, [runtime.id, model.id]);
    expect(results, [true]);
    expect(find.byKey(const Key('ai_install_prompt')), findsNothing);
  });

  testWidgets('Cancel stops the download under way and the next one; Download comes back', (tester) async {
    final started = Completer<void>();
    final stopped = Completer<void>();
    service.onInstall = (component) async {
      started.complete();
      await stopped.future;
      throw const AiDownloadException(AiDownloadFailure.cancelled);
    };
    await pumpOpener(tester, windows);

    await tester.tap(find.byKey(const Key('ai_install_download')));
    await tester.pump();
    expect(started.isCompleted, isTrue);
    await tester.tap(find.byKey(const Key('ai_install_cancel')));
    stopped.complete();
    await tester.pumpAndSettle();

    expect(service.cancels, containsAll([runtime.id, model.id]));
    expect(service.installs, [runtime.id], reason: 'the model is not started after a cancel');
    expect(find.byKey(const Key('ai_install_failure')), findsNothing, reason: 'a cancel is not a failure');
    expect(find.byKey(const Key('ai_install_download')), findsOneWidget);
    expect(results, isEmpty, reason: 'the sheet stays open');
  });

  testWidgets('Cancel while the runtime ends normally: the model is not started', (tester) async {
    final finish = Completer<void>();
    service.onInstall = (component) async {
      if (component == runtime) {
        // The download is past the point where a cancel stops it: it ends well all the same
        await finish.future;
      }
    };
    await pumpOpener(tester, windows);

    await tester.tap(find.byKey(const Key('ai_install_download')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('ai_install_cancel')));
    await tester.pump();
    finish.complete();
    await tester.pumpAndSettle();

    expect(service.installs, [runtime.id], reason: 'the sheet checks Cancel between two components');
    expect(service.statusOf(runtime).state, AiComponentState.installed);
    expect(service.statusOf(model).state, AiComponentState.notInstalled);
    expect(find.byKey(const Key('ai_install_failure')), findsNothing);
    expect(find.byKey(const Key('ai_install_download')), findsOneWidget);
    expect(results, isEmpty, reason: 'the sheet stays open');
  });

  testWidgets('a failure is said in words, and Download tries again', (tester) async {
    var attempts = 0;
    service.onInstall = (component) async {
      if (attempts++ == 0) {
        throw const AiDownloadException(AiDownloadFailure.notFound, 'HTTP 404 at every address');
      }
    };
    await pumpOpener(tester, windows);

    await tester.tap(find.byKey(const Key('ai_install_download')));
    await tester.pumpAndSettle();

    expect(find.text('Download failed: file not found on the server'), findsOneWidget);
    expect(find.textContaining('404'), findsNothing, reason: 'the detail goes to the log');

    await tester.tap(find.byKey(const Key('ai_install_download')));
    await tester.pumpAndSettle();

    expect(service.installs, [runtime.id, runtime.id, model.id]);
    expect(results, [true]);
  });

  testWidgets('nothing missing: the sheet closes at once and answers true', (tester) async {
    for (final component in windows) {
      service.setStatus(component, const AiComponentStatus(AiComponentState.installed));
    }

    await pumpOpener(tester, windows);

    expect(results, [true]);
    expect(service.installs, isEmpty);
  });

  testWidgets('each failure has its words', (tester) async {
    await tester.pumpConsumerWidget(const SizedBox());
    final t = StaticTranslations.instance;

    final texts = {
      for (final failure in AiDownloadFailure.values)
        failure: aiDownloadFailureText(
          t,
          AiDownloadException(failure, 'detail', const AiSpaceShortage(needed: 2048, free: 1024, volume: '/home')),
        ),
    };

    // In words, none an internal name such as insecureAddress
    expect(texts, {
      AiDownloadFailure.incomplete: 'Download failed: not available in this version of the app',
      AiDownloadFailure.insecureAddress: 'Download failed: this address is not secure',
      AiDownloadFailure.notFound: 'Download failed: file not found on the server',
      AiDownloadFailure.network: 'Download failed: the server cannot be reached',
      AiDownloadFailure.damaged: 'The file received is damaged. Try again.',
      AiDownloadFailure.diskFull: 'Disk full',
      AiDownloadFailure.writeFailed: 'Download failed: the file could not be written',
      AiDownloadFailure.cancelled: 'Cancelled',
      AiDownloadFailure.notEnoughSpace:
          'Not enough space on /home (${formatBytes(2048)} needed, ${formatBytes(1024)} free). Move the AI components '
          'to another drive in the settings.',
    });
  });
}
