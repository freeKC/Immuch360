// The Share menu of a computer (lib/desktop/share/desktop_share.dart): the ways it names on each system, each with its
// line; each entry takes its own path (Copy to the copier, Save to a folder through the folder dialog, the share
// window of the system with the files kept, the share link, the quality); a failure of the share window shown with the
// reason of the system and logged without any folder or URL, a window closed without a choice and a cancel silent; and
// the files fetched for the window kept in the folder of the copies while it is open, then an hour after it let them go.

import 'dart:async';
import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/desktop/clipboard/clipboard_copies.dart';
import 'package:immich_mobile/desktop/files/file_pickers.dart';
import 'package:immich_mobile/desktop/share/desktop_share.dart';
import 'package:immich_mobile/desktop/share/system_share_sheet.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_ui/immich_ui.dart' show scaffoldMessengerKey;
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;

import '../../test_utils.dart';
import '../clipboard/recording_copier.dart';
import '../selection/selection_test_app.dart';

class _NativeSyncApi extends Mock implements NativeSyncApi {}

class _Storage extends Mock implements StorageRepository {}

/// The fetch of the files of a share, answered by the test
class _Media extends AssetMediaRepository {
  _Media() : super(_NativeSyncApi(), _Storage());

  List<ShareFetchedFile>? answer;
  Completer<void>? hold;
  final fileTypes = <ShareAssetType>[];
  final released = <List<ShareFetchedFile>>[];

  @override
  Future<List<ShareFetchedFile>?> fetchShareFiles(
    List<BaseAsset> assets, {
    ShareAssetType fileType = ShareAssetType.original,
    Completer<void>? cancelCompleter,
    void Function(double progress)? onAssetDownloadProgress,
    bool Function()? mounted,
  }) async {
    fileTypes.add(fileType);
    if (hold != null) {
      await Future.any([hold!.future, if (cancelCompleter != null) cancelCompleter.future]);
      if (cancelCompleter?.isCompleted ?? false) {
        return null;
      }
    }
    return answer;
  }

  @override
  Future<void> releaseShareFiles(List<ShareFetchedFile> files) async => released.add(files);
}

/// The share window, answered by the test
class _Sheet implements SystemShareSheet {
  bool isSupported = true;
  final asked = <({List<String> paths, String title})>[];
  // Made at the share, in the zone of the test: an error of a completer made in setUp would not reach the app
  late Completer<void> opened;
  late Completer<SystemShareEnd> finished;

  @override
  Future<bool> supported() async => isSupported;

  @override
  SystemShare share(List<String> paths, {required String title, Rect? origin}) {
    asked.add((paths: paths, title: title));
    opened = Completer();
    finished = Completer();
    return SystemShare(opened: opened.future, finished: finished.future);
  }
}

class _Pickers implements FilePickers {
  String? folderAnswer;

  @override
  Future<String?> folder({String? initialDirectory, String? confirmButtonText}) async => folderAnswer;

  @override
  Future<String?> saveLocation({
    required String suggestedName,
    String? initialDirectory,
    String? typeLabel,
    List<String> extensions = const [],
  }) async => null;

  @override
  Future<String?> openFile({String? initialDirectory, String? typeLabel, List<String> extensions = const []}) async =>
      null;
}

void main() {
  late Directory temp;
  late Directory root;
  late _Media media;
  late _Sheet sheet;
  late RecordingCopier copier;
  late _Pickers pickers;
  late List<LogRecord> logs;
  StreamSubscription<LogRecord>? logging;

  final photo = TestUtils.createRemoteAsset(id: 'remote-1').copyWith(name: 'IMG_0042.jpg');
  final video = TestUtils.createRemoteAsset(id: 'remote-2').copyWith(name: 'IMG_0043.mp4', type: AssetType.video);

  setUp(() {
    resetDesktopShare();
    temp = Directory.systemTemp.createTempSync('desktop-share-test');
    root = Directory(p.join(temp.path, 'immuch360-clipboard'));
    media = _Media();
    sheet = _Sheet();
    copier = RecordingCopier();
    pickers = _Pickers();
    filePickers = pickers;
    logs = [];
    Logger.root.level = Level.ALL;
    logging = Logger.root.onRecord.listen(logs.add);
  });

  tearDown(() async {
    await logging?.cancel();
    filePickers = const SystemFilePickers();
    debugDefaultTargetPlatformOverride = null;
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  DesktopShareServices services({SystemShareSheet? withSheet, bool noSheet = false}) => DesktopShareServices(
    copier: copier,
    storage: _Storage(),
    media: media,
    sheet: noSheet ? null : (withSheet ?? sheet),
    clipboardRoot: () async => root,
  );

  /// A file fetched from the server into a folder of its own, as the downloads of a share are
  ShareFetchedFile fetchedFile(String name) {
    final folder = Directory(p.join(temp.path, 'download-$name'))..createSync();
    final file = File(p.join(folder.path, name))..writeAsStringSync('bytes of $name');
    return (file: file, temporary: folder);
  }

  Future<BuildContext> pumpPage(WidgetTester tester) async {
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          path: '/',
          initial: true,
          page: PageInfo(
            'Page',
            builder: (_) => const Scaffold(body: SizedBox.expand(key: Key('page'))),
          ),
        ),
      ],
    );
    await pumpSelectionApp(tester, router: router, messenger: scaffoldMessengerKey);
    await tester.pumpAndSettle();
    return tester.element(find.byKey(const Key('page')));
  }

  /// Lets the real file system and the frames go on until [condition] holds (the copies and moves are real)
  Future<void> until(WidgetTester tester, bool Function() condition) async {
    for (var i = 0; i < 200 && !condition(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue, reason: 'waited 6 s');
  }

  /// Waits for [future] as [until] does
  Future<void> finish(WidgetTester tester, Future<void> future) async {
    var done = false;
    Object? failure;
    unawaited(future.then((_) => done = true, onError: (Object error) => failure = error));
    await until(tester, () => done || failure != null);
    if (failure != null) {
      fail('The share failed: $failure');
    }
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  Future<void> Function() openMenu(
    WidgetTester tester,
    BuildContext context, {
    List<BaseAsset>? assets,
    ShareAssetType fileType = ShareAssetType.original,
    Future<void> Function()? shareLink,
    SystemShareSheet? withSheet,
    bool noSheet = false,
  }) {
    final opening = openDesktopShareMenu(
      context,
      services(withSheet: withSheet, noSheet: noSheet),
      assets ?? [photo],
      fileType: fileType,
      shareLink: shareLink,
    );
    return () => opening;
  }

  Finder entry(DesktopShareWay way) => find.byKey(Key('desktop_share_${way.name}'));

  group('the ways of each system', () {
    test('Copy and Save first, the share window of Windows and macOS, never of Linux', () {
      for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
        expect(desktopShareWays(platform: platform, systemSheet: true, shareLink: true, quality: true), [
          DesktopShareWay.copy,
          DesktopShareWay.saveToFolder,
          DesktopShareWay.systemSheet,
          DesktopShareWay.shareLink,
          DesktopShareWay.quality,
        ]);
      }
      expect(desktopShareWays(platform: TargetPlatform.linux, systemSheet: true, shareLink: true, quality: true), [
        DesktopShareWay.copy,
        DesktopShareWay.saveToFolder,
        DesktopShareWay.shareLink,
        DesktopShareWay.quality,
      ]);
    });

    test('no share window where the system says it has none, no link without the server, no quality for videos', () {
      expect(desktopShareWays(platform: TargetPlatform.windows, systemSheet: false, shareLink: false, quality: false), [
        DesktopShareWay.copy,
        DesktopShareWay.saveToFolder,
      ]);
    });
  });

  group('the menu', () {
    testWidgets('Windows: each way named with its line, and Copy goes to the copier', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final context = await pumpPage(tester);
      final t = StaticTranslations.instance;
      final done = openMenu(tester, context, shareLink: () async {});
      await settle(tester);
      for (final text in [
        t.desktop_copy,
        t.desktop_share_copy_line,
        t.desktop_share_save,
        t.desktop_share_save_line,
        t.desktop_share_windows,
        t.desktop_share_windows_line,
        t.desktop_share_link,
        t.desktop_share_link_line,
        t.select_quality,
        t.share_original,
      ]) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      expect(t.desktop_share_windows, 'Share with Windows…');
      expect(find.text(t.desktop_share_macos), findsNothing);

      await tester.tap(entry(DesktopShareWay.copy));
      await settle(tester);
      await done();
      expect(copier.copies.single.single.name, 'IMG_0042.jpg');
      expect(media.fileTypes, isEmpty, reason: 'Copy fetches through the copier, not the share');
      expect(sheet.asked, isEmpty);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('macOS names its own; Linux has no share window; a system without one neither', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      var context = await pumpPage(tester);
      final t = StaticTranslations.instance;
      var done = openMenu(tester, context);
      await settle(tester);
      expect(find.text(t.desktop_share_macos), findsOneWidget);
      expect(find.text(t.desktop_share_macos_line), findsOneWidget);
      expect(entry(DesktopShareWay.shareLink), findsNothing, reason: 'no link without the server');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await done();

      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      resetDesktopShare();
      context = await pumpPage(tester);
      done = openMenu(tester, context, noSheet: true);
      await settle(tester);
      expect(entry(DesktopShareWay.copy), findsOneWidget);
      expect(entry(DesktopShareWay.saveToFolder), findsOneWidget);
      expect(entry(DesktopShareWay.systemSheet), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await done();

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      resetDesktopShare();
      sheet.isSupported = false;
      context = await pumpPage(tester);
      done = openMenu(tester, context, assets: [video]);
      await settle(tester);
      expect(entry(DesktopShareWay.systemSheet), findsNothing, reason: 'Windows Server 2022 has no share window');
      expect(entry(DesktopShareWay.quality), findsNothing, reason: 'a video is shared as its original');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await done();
      expect(copier.copies, isEmpty);
      expect(media.fileTypes, isEmpty);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Save to a folder: the fetched files copied into the folder picked, then let go', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final context = await pumpPage(tester);
      final target = Directory(p.join(temp.path, 'picked'))..createSync();
      pickers.folderAnswer = target.path;
      final fetched = [fetchedFile('IMG_0042.jpg')];
      media.answer = fetched;
      final done = openMenu(tester, context);
      await settle(tester);
      await tester.tap(entry(DesktopShareWay.saveToFolder));
      await settle(tester);
      await finish(tester, done());
      await settle(tester);
      expect(File(p.join(target.path, 'IMG_0042.jpg')).readAsStringSync(), 'bytes of IMG_0042.jpg');
      expect(media.fileTypes, [ShareAssetType.original]);
      expect(media.released.single, fetched);
      expect(sheet.asked, isEmpty);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Share with Windows: the files kept, the window given them, a close without a choice silent', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final context = await pumpPage(tester);
      final fetched = [fetchedFile('IMG_0042.jpg')];
      media.answer = fetched;
      final done = openMenu(tester, context);
      await settle(tester);
      await tester.tap(entry(DesktopShareWay.systemSheet));
      await until(tester, () => sheet.asked.isNotEmpty);
      await settle(tester);
      final asked = sheet.asked.single;
      expect(asked.title, 'IMG_0042.jpg');
      final kept = File(asked.paths.single);
      expect(p.isWithin(root.path, kept.path), isTrue, reason: 'moved into the folder of the copies');
      expect(kept.readAsStringSync(), 'bytes of IMG_0042.jpg');
      expect(fetched.single.file.existsSync(), isFalse);
      expect(media.released.single, fetched, reason: "the download's own folder and record go");
      expect(shareCopiesOpen(kept.parent), isTrue);

      sheet.opened.complete();
      await settle(tester);
      // Still open: kept whatever its age
      await tester.runAsync(
        () => cleanClipboardCopies(
          root,
          holds: (_) async => false,
          systemTokens: true,
          now: () => DateTime.now().add(const Duration(hours: 5)),
        ),
      );
      expect(kept.existsSync(), isTrue);

      sheet.finished.complete(SystemShareEnd.dismissed);
      await finish(tester, done());
      await settle(tester);
      expect(find.byType(SnackBar), findsNothing, reason: 'a window closed without a choice says nothing');
      expect(shareCopiesOpen(kept.parent), isFalse);
      expect(File(p.join(kept.parent.path, shareCopyMarker)).existsSync(), isTrue);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a failure of the share window shows the reason of the system, logged without folder nor URL', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final context = await pumpPage(tester);
      final t = StaticTranslations.instance;
      media.answer = [fetchedFile('IMG_0042.mp4')];
      final done = openMenu(tester, context);
      await settle(tester);
      await tester.tap(entry(DesktopShareWay.systemSheet));
      await until(tester, () => sheet.asked.isNotEmpty);
      final kept = File(sheet.asked.single.paths.single);
      sheet.opened.completeError(
        const SystemShareException(
          'file',
          'The system cannot find the file specified.',
          code: '0x80070002',
          file: 'IMG_0042.mp4',
        ),
      );
      sheet.finished.complete(SystemShareEnd.dismissed);
      await finish(tester, done());
      await settle(tester);
      expect(
        find.text(t.desktop_share_failed(reason: 'IMG_0042.mp4: The system cannot find the file specified.')),
        findsOneWidget,
      );
      final warning = logs.singleWhere(
        (record) => record.loggerName == 'DesktopShare' && record.level == Level.WARNING,
      );
      expect(warning.message, contains('0x80070002'));
      expect(warning.message, contains('IMG_0042.mp4'));
      expect(warning.message, isNot(contains(temp.path)));
      expect(warning.message, isNot(contains('://')));
      expect(shareCopiesOpen(kept.parent), isFalse, reason: 'let go at once');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a window that never asked for the files says it did not open, in the language of the app', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final context = await pumpPage(tester);
      final t = StaticTranslations.instance;
      media.answer = [fetchedFile('IMG_0042.jpg')];
      final done = openMenu(tester, context);
      await settle(tester);
      await tester.tap(entry(DesktopShareWay.systemSheet));
      await until(tester, () => sheet.asked.isNotEmpty);
      sheet.opened.completeError(const SystemShareException('request', 'The share window did not ask for the files'));
      sheet.finished.complete(SystemShareEnd.dismissed);
      await finish(tester, done());
      await settle(tester);
      expect(find.text(t.desktop_share_failed(reason: t.desktop_share_not_opened)), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a cancel of the fetch says nothing and hands nothing on', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final context = await pumpPage(tester);
      media
        ..answer = [fetchedFile('IMG_0042.jpg')]
        ..hold = Completer<void>();
      final done = openMenu(tester, context);
      await settle(tester);
      await tester.tap(entry(DesktopShareWay.systemSheet));
      await settle(tester);
      expect(find.byKey(const Key('desktop_share_preparing')), findsOneWidget);
      await tester.tap(find.byKey(const Key('desktop_share_cancel')));
      await finish(tester, done());
      await settle(tester);
      expect(find.byKey(const Key('desktop_share_preparing')), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(sheet.asked, isEmpty);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Create a share link opens the link of the server; the quality reopens the menu with it', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final context = await pumpPage(tester);
      final t = StaticTranslations.instance;
      var links = 0;
      var done = openMenu(tester, context, shareLink: () async => links++);
      await settle(tester);
      await tester.tap(entry(DesktopShareWay.shareLink));
      await settle(tester);
      await done();
      expect(links, 1);

      final target = Directory(p.join(temp.path, 'picked'))..createSync();
      pickers.folderAnswer = target.path;
      media.answer = [fetchedFile('IMG_0042-preview.jpg')];
      done = openMenu(tester, context);
      await settle(tester);
      await tester.tap(entry(DesktopShareWay.quality));
      await settle(tester);
      await tester.tap(find.byKey(const Key('desktop_share_preview')));
      await settle(tester);
      expect(find.text(t.share_preview), findsOneWidget, reason: 'the menu again, with the quality picked');
      await tester.tap(entry(DesktopShareWay.saveToFolder));
      await settle(tester);
      await finish(tester, done());
      await settle(tester);
      expect(media.fileTypes, [ShareAssetType.preview]);
      expect(File(p.join(target.path, 'IMG_0042-preview.jpg')).existsSync(), isTrue);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('the files of a share window', () {
    test('kept while open, then an hour after it let them go', () async {
      final download = fetchedFile('IMG_0042.mp4');
      final start = DateTime.utc(2026, 11, 28, 2);
      final copies = await keepShareCopies([download.file], root, now: () => start);
      final kept = File(copies.paths.single);
      Future<int> cleanAt(Duration after) =>
          cleanClipboardCopies(root, holds: (_) async => false, systemTokens: true, now: () => start.add(after));

      expect(await cleanAt(const Duration(days: 2)), 0, reason: 'open: never');
      expect(kept.existsSync(), isTrue);

      await releaseShareCopies(copies.folder, now: () => start.add(const Duration(hours: 3)));
      expect(await cleanAt(const Duration(hours: 3, minutes: 30)), 0, reason: 'half an hour after its end');
      expect(kept.existsSync(), isTrue);
      expect(await cleanAt(const Duration(hours: 4, minutes: 1)), 1, reason: 'an hour after its end');
      expect(kept.parent.existsSync(), isFalse);
    });

    test('a share of an earlier run that never ended goes an hour after its fetch, as a copy without marker', () async {
      final start = DateTime.utc(2026, 11, 28, 2);
      final copies = await keepShareCopies([fetchedFile('a.jpg').file], root, now: () => start);
      // The app quit with the window open: a later run does not know it
      await releaseShareCopies(copies.folder);
      File(p.join(copies.folder.path, shareCopyMarker)).deleteSync();
      expect(
        await cleanClipboardCopies(
          root,
          holds: (_) async => true,
          systemTokens: true,
          now: () => start.add(const Duration(minutes: 61)),
        ),
        1,
      );
    });

    test('the title the window shows: the name of the file, or how many there are', () {
      final t = StaticTranslations.instance;
      expect(desktopShareTitle([p.join('a', 'IMG_0042.mp4')], t), 'IMG_0042.mp4');
      expect(desktopShareTitle(['a.jpg', 'b.jpg'], t), t.desktop_share_title_files(count: 2));
    });
  });
}
