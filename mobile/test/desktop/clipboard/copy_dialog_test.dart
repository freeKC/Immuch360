// The progress of a copy that fetches remote files first (copyToClipboard, lib/desktop/clipboard/clipboard_copy.dart):
// shown while they come, with their share fetched; Escape (through the window shell) and Cancel stop the fetch and close
// it; a fetch that fails closes it too. A copy of files of this computer shows none. Then the message each end gives:
// copied, could not copy (a failure, and any other error, never a raw one), and none for a cancel or a copy a later
// one overtook.

import 'dart:async';
import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/clipboard/clipboard_copies.dart';
import 'package:immich_mobile/desktop/clipboard/clipboard_copy.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_ui/immich_ui.dart' show scaffoldMessengerKey;

import '../selection/selection_test_app.dart';

/// A copier whose fetch goes on until the test ends it, or until it is cancelled
class _SlowCopier extends ClipboardCopier {
  final asked = <List<ClipboardSource>>[];
  ClipboardFetchProgress? progress;
  final done = Completer<ClipboardCopyResult>();
  var cancelled = false;

  @override
  Future<ClipboardCopyResult> copy(
    List<ClipboardSource> sources, {
    Future<void>? cancelled,
    ClipboardFetchProgress? onProgress,
  }) {
    asked.add(sources);
    progress = onProgress;
    unawaited(
      cancelled?.then((_) {
        // The end of a copy that went through lets go of its cancel too: only one before counts
        if (!done.isCompleted) {
          this.cancelled = true;
          done.completeError(const ClipboardCopyException(ClipboardCopyFailure.cancelled));
        }
      }),
    );
    return done.future;
  }
}

final _remote = RemoteClipboardSource(
  name: 'IMG_0042.HEIC',
  isVideo: false,
  size: 100,
  fetch: (abort) => Completer<http.StreamedResponse>().future,
);

void main() {
  final dialog = find.byKey(const Key('desktop_copy_fetching'));

  /// A few frames: an indeterminate progress never settles
  Future<void> step(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<BuildContext> pumpPage(WidgetTester tester, {bool messages = false}) async {
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          path: '/',
          initial: true,
          page: PageInfo(
            'Grid',
            builder: (_) => const Scaffold(
              body: Focus(autofocus: true, child: SizedBox.expand(key: Key('page'))),
            ),
          ),
        ),
      ],
    );
    await pumpSelectionApp(tester, router: router, messenger: messages ? scaffoldMessengerKey : null);
    await tester.pumpAndSettle();
    return tester.element(find.byKey(const Key('page')));
  }

  testWidgets('remote files: a progress while they come, which Escape stops and closes', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final context = await pumpPage(tester);
    final copier = _SlowCopier();
    final copying = copyToClipboard(context, copier, () async => [_remote]);
    await step(tester);
    expect(dialog, findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, isNull);
    copier.progress!(25, 100);
    await tester.pump();
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.25);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await step(tester);
    await copying;
    expect(copier.cancelled, isTrue, reason: 'Escape cancels the fetch');
    expect(dialog, findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Cancel stops it too; a fetch that fails or ends closes the progress', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final context = await pumpPage(tester);
    var copier = _SlowCopier();
    var copying = copyToClipboard(context, copier, () async => [_remote]);
    await step(tester);
    await tester.tap(find.byKey(const Key('desktop_copy_cancel')));
    await step(tester);
    await copying;
    expect(copier.cancelled, isTrue);
    expect(dialog, findsNothing);

    copier = _SlowCopier();
    copying = copyToClipboard(context, copier, () async => [_remote]);
    await step(tester);
    copier.done.completeError(const ClipboardCopyException(ClipboardCopyFailure.fetchFailed));
    await step(tester);
    await copying;
    expect(dialog, findsNothing);

    copier = _SlowCopier();
    copying = copyToClipboard(context, copier, () async => [_remote]);
    await step(tester);
    copier.done.complete((files: 1, picture: true));
    await step(tester);
    await copying;
    expect(dialog, findsNothing);
    expect(copier.cancelled, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('files of this computer: no progress', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final context = await pumpPage(tester);
    final copier = _SlowCopier();
    final copying = copyToClipboard(
      context,
      copier,
      () async => [const LocalClipboardSource('/photos/a.jpg', isVideo: false)],
    );
    await step(tester);
    expect(dialog, findsNothing);
    copier.done.complete((files: 1, picture: true));
    await copying;
    expect(copier.asked.single.single, isA<LocalClipboardSource>());
    debugDefaultTargetPlatformOverride = null;
  });

  group('the message at the end', () {
    final t = StaticTranslations.instance;

    Future<void> end(
      WidgetTester tester,
      BuildContext context,
      FutureOr<void> Function(_SlowCopier copier) ending,
    ) async {
      final copier = _SlowCopier();
      final copying = copyToClipboard(context, copier, () async => [_remote]);
      await step(tester);
      await ending(copier);
      await step(tester);
      await copying;
      await tester.pump();
    }

    Future<void> clear(WidgetTester tester) async {
      scaffoldMessengerKey.currentState?.removeCurrentSnackBar();
      await tester.pumpAndSettle();
    }

    testWidgets(
      'copied; could not copy for a failure and for any other error; nothing for a cancel or an overtaken copy',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        final context = await pumpPage(tester, messages: true);

        await end(tester, context, (copier) => copier.done.complete((files: 1, picture: true)));
        expect(find.text(t.desktop_copy_done(count: 1)), findsOneWidget);
        await clear(tester);

        await end(
          tester,
          context,
          (copier) => copier.done.completeError(const ClipboardCopyException(ClipboardCopyFailure.fetchFailed)),
        );
        expect(find.text(t.desktop_copy_failed), findsOneWidget);
        await clear(tester);

        await end(
          tester,
          context,
          (copier) => copier.done.completeError(const ClipboardCopyException(ClipboardCopyFailure.clipboardRefused)),
        );
        expect(find.text(t.desktop_copy_failed), findsOneWidget);
        await clear(tester);

        // Not a ClipboardCopyException: the cache folder not found, for one
        await end(tester, context, (copier) => copier.done.completeError(const FileSystemException('no cache', '/x')));
        expect(find.text(t.desktop_copy_failed), findsOneWidget);
        await clear(tester);

        await end(tester, context, (copier) => tester.tap(find.byKey(const Key('desktop_copy_cancel'))));
        expect(_messages(), isEmpty);

        await end(
          tester,
          context,
          (copier) => copier.done.completeError(const ClipboardCopyException(ClipboardCopyFailure.superseded)),
        );
        expect(_messages(), isEmpty);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  });
}

/// The snackbars shown
Iterable<SnackBar> _messages() => find.byType(SnackBar).evaluate().map((element) => element.widget as SnackBar);
