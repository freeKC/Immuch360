// How a computer opens the files given to the program (lib/desktop/files/open_files.dart): the command line, the
// files of later starts and of drops coming on the channel of the runner, a batch at a time, kept until a session is
// open; one file in the viewer, a 360° one in its 360° view at once; several files or a folder on a page of their own.

import 'dart:async';
import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/files/open_files.dart';
import 'package:immich_mobile/desktop/files/opened_files.dart';
import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/window/single_instance.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/domain/services/local_panorama.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/domain/services/user.service.dart';
import 'package:immich_mobile/models/auth/auth_state.model.dart';
import 'package:immich_mobile/platform/view_intent_api.g.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/local_panorama.provider.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/auth.service.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';
import 'package:immich_mobile/services/toast.service.dart';
import 'package:immich_mobile/services/widget.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;

import '../../providers/infrastructure/local_session.fake.dart';

class _MockAppRouter extends Mock implements AppRouter {}

class _MockTimelineFactory extends Mock implements TimelineFactory {}

class _MockAuthService extends Mock implements AuthService {}

class _MockApiService extends Mock implements ApiService {}

class _MockUserService extends Mock implements UserService {}

class _MockSecureStorageService extends Mock implements SecureStorageService {}

class _MockWidgetService extends Mock implements WidgetService {}

class _FakeTimelineService extends Fake implements TimelineService {}

class _FakeAssetService extends Fake implements AssetService {
  @override
  Stream<BaseAsset?> watchAsset(BaseAsset asset) => const Stream.empty();

  @override
  Stream<ExifInfo?> watchExif(BaseAsset asset) => Stream.value(null);
}

class _RecordingToasts extends ToastService {
  final errors = <String>[];

  @override
  FutureOr<void> error(String message, {ToastOption? toast}) {
    errors.add(message);
  }
}

class _TestAuthNotifier extends AuthNotifier {
  _TestAuthNotifier(Ref ref)
    : super(
        _MockAuthService(),
        _MockApiService(),
        _MockUserService(),
        _MockSecureStorageService(),
        _MockWidgetService(),
        ref,
      ) {
    state = const AuthState(
      deviceId: 'device-1',
      userId: 'user-1',
      userEmail: 'user@example.com',
      isAuthenticated: false,
      name: 'User',
      isAdmin: false,
      profileImagePath: '',
    );
  }

  void setAuthenticated(bool isAuthenticated) => state = state.copyWith(isAuthenticated: isAuthenticated);
}

/// A file opened with the program as [readOpenedPaths] gives it, without reading anything
OpenedFile _opened(String path, {bool is360 = false, bool raw = false}) {
  final name = p.basename(path);
  final kind = mediaKindOfName(name)!;
  final id = 'f-$name';
  return OpenedFile(
    file: LibraryFile(
      assetId: id,
      path: path,
      name: name,
      kind: kind,
      size: 1,
      modifiedMs: 0,
      createdSeconds: 0,
      mimeType: mimeTypeOfName(name),
      cloudOnly: false,
      available: true,
      width: 4000,
      height: 2000,
    ),
    asset: LocalAsset(
      id: id,
      name: name,
      type: kind == LibraryMediaKind.video ? AssetType.video : AssetType.image,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      width: 4000,
      height: 2000,
      playbackStyle: kind == LibraryMediaKind.video ? AssetPlaybackStyle.video : AssetPlaybackStyle.image,
      isEdited: false,
    ),
    record: LocalPanoramaRecord(isPanorama: is360 || raw, raw360: raw, checkedAt: DateTime.utc(2026)),
  );
}

final _handlerProvider = Provider<DesktopOpenFilesHandler>(
  (ref) => DesktopOpenFilesHandler(ref, read: (paths) async => _reads(paths)),
);

// What the tests give the handler to read, by path; a path not listed holds no photo or video
var _readable = <String, OpenedFile>{};

OpenedBatch _reads(List<String> paths) =>
    OpenedBatch([for (final path in paths) ?_readable[path]], fromFolder: paths.any(FileSystemEntity.isDirectorySync));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the command line', () {
    test('its files are its arguments that are no options, a file URI as its path', () {
      final uri = Uri.file(Platform.isWindows ? r'C:\Photos\pano 1.jpg' : '/photos/pano 1.jpg').toString();

      expect(launchPathsOf(['--version', '-psn_0_123', '', '  ', 'IMG_1.jpg', r'D:\DCIM\VID_2.insv', uri]), [
        'IMG_1.jpg',
        r'D:\DCIM\VID_2.insv',
        Platform.isWindows ? r'C:\Photos\pano 1.jpg' : '/photos/pano 1.jpg',
      ]);
    });
  });

  group('the requests', () {
    tearDown(DesktopOpenRequests.reset);

    test('come as batches in their order, an empty one dropped, each new one told', () {
      var told = 0;
      DesktopOpenRequests.listen(() => told++);

      DesktopOpenRequests.add(['a.jpg', 'b.jpg']);
      DesktopOpenRequests.add(['--flag']);
      DesktopOpenRequests.add(['c.mp4']);

      expect(told, 2);
      expect(DesktopOpenRequests.take(), ['a.jpg', 'b.jpg']);
      expect(DesktopOpenRequests.take(), ['c.mp4']);
      expect(DesktopOpenRequests.take(), isNull);
    });

    test('a later start and a drop on the window come on the channel of the runner, a batch each', () async {
      var told = 0;
      listenForLaterStarts(onFiles: () => told++);
      addTearDown(() => singleInstanceChannel.setMethodCallHandler(null));

      Future<void> send(String method, Object? arguments) =>
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
            singleInstanceChannel.name,
            singleInstanceChannel.codec.encodeMethodCall(MethodCall(method, arguments)),
            (_) {},
          );

      await send('openFiles', [r'C:\Users\me\Pictures\pano.jpg']);
      await send('openFiles', [r'C:\Users\me\Pictures\a.jpg', r'C:\Users\me\Pictures\b.jpg', 3]);
      await send('somethingElse', ['x.jpg']);
      await send('openFiles', 'not a list');

      expect(told, 2);
      expect(DesktopOpenRequests.take(), [r'C:\Users\me\Pictures\pano.jpg']);
      expect(DesktopOpenRequests.take(), [r'C:\Users\me\Pictures\a.jpg', r'C:\Users\me\Pictures\b.jpg']);
      expect(DesktopOpenRequests.take(), isNull);
    });
  });

  group('the title of the page of opened files', () {
    late Directory directory;

    setUp(() => directory = Directory.systemTemp.createTempSync('opened_title_'));
    tearDown(() => directory.deleteSync(recursive: true));

    test('the folder given, the folder of the files, or nothing for files of several folders', () {
      final card = Directory(p.join(directory.path, 'DCIM'))..createSync();
      final other = Directory(p.join(directory.path, 'Other'))..createSync();

      expect(openedFilesTitle([card.path]), 'DCIM');
      expect(openedFilesTitle([p.join(card.path, 'a.jpg'), p.join(card.path, 'b.jpg')]), 'DCIM');
      expect(openedFilesTitle([p.join(card.path, 'a.jpg'), p.join(other.path, 'b.jpg')]), isNull);
      expect(openedFilesTitle([card.path, other.path]), isNull);
    });
  });

  group('the handler', () {
    late _MockAppRouter router;
    late _MockTimelineFactory timelines;
    late _RecordingToasts toasts;
    late ProviderContainer container;
    late _TestAuthNotifier auth;
    late DesktopOpenFilesHandler handler;
    late Directory directory;

    setUpAll(() {
      registerFallbackValue(<PageRouteInfo<dynamic>>[]);
      registerFallbackValue(<BaseAsset>[]);
      registerFallbackValue(TimelineOrigin.deepLink);
    });

    setUp(() {
      directory = Directory.systemTemp.createTempSync('open_files_handler_');
      _readable = {};
      OpenedFiles.clear();
      router = _MockAppRouter();
      timelines = _MockTimelineFactory();
      toasts = _RecordingToasts();
      when(() => router.replaceAll(any())).thenAnswer((_) async {});
      when(() => timelines.fromAssets(any(), any())).thenReturn(_FakeTimelineService());
      container = ProviderContainer(
        overrides: [
          appRouterProvider.overrideWithValue(router),
          timelineFactoryProvider.overrideWithValue(timelines),
          toastServiceProvider.overrideWithValue(toasts),
          assetServiceProvider.overrideWithValue(_FakeAssetService()),
          localSessionProvider.overrideWith(FakeLocalSessionNotifier.new),
          authProvider.overrideWith(_TestAuthNotifier.new),
        ],
      );
      auth = container.read(authProvider.notifier) as _TestAuthNotifier;
      handler = container.read(_handlerProvider)..init();
    });

    tearDown(() {
      container.dispose();
      DesktopOpenRequests.reset();
      OpenedFiles.clear();
      directory.deleteSync(recursive: true);
    });

    String file(String name, {bool is360 = false, bool raw = false}) {
      final path = p.join(directory.path, name);
      File(path).writeAsBytesSync([0]);
      _readable[path] = _opened(path, is360: is360, raw: raw);
      return path;
    }

    List<String> routesOf(List<dynamic> captured) => [
      for (final route in captured.single as List<PageRouteInfo<dynamic>>) route.routeName,
    ];

    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('keeps the files given before a session, and opens them once one is open', () async {
      final photo = file('IMG_1.jpg');

      DesktopOpenRequests.add([photo]);
      await settle();
      verifyNever(() => router.replaceAll(any()));

      await container.read(localSessionProvider.notifier).enter();
      await settle();

      expect(routesOf(verify(() => router.replaceAll(captureAny())).captured), [
        TabShellRoute.name,
        AssetViewerRoute.name,
      ]);
      expect(container.read(assetViewerProvider).currentAsset?.id, 'f-IMG_1.jpg');
    });

    test('opens the files given before a sign in to a server once the server session is open', () async {
      DesktopOpenRequests.add([file('IMG_1.jpg')]);
      await settle();
      verifyNever(() => router.replaceAll(any()));

      auth.setAuthenticated(true);
      await settle();

      verify(() => router.replaceAll(any())).called(1);
    });

    test('one 360° photo opens in the viewer, then in its 360° view, read by its id', () async {
      auth.setAuthenticated(true);
      final pano = file('pano.jpg', is360: true);

      DesktopOpenRequests.add([pano]);
      await settle();

      final captured = verify(() => timelines.fromAssets(captureAny(), captureAny())).captured;
      expect((captured[0] as List<BaseAsset>).single.id, 'f-pano.jpg');
      expect(captured[1], TimelineOrigin.deepLink);
      expect(OpenedFiles.file('f-pano.jpg')?.path, pano);
      expect(container.read(openedFilePanoramasProvider)['f-pano.jpg']?.isPanorama, isTrue);
      expect(container.read(desktopOpenIn360Provider)?.id, 'f-pano.jpg');
    });

    test('a flat photo opens in the viewer only; a raw .insp photo in its 360° view too', () async {
      auth.setAuthenticated(true);

      DesktopOpenRequests.add([file('IMG_2.jpg')]);
      await settle();
      expect(container.read(desktopOpenIn360Provider), isNull);

      DesktopOpenRequests.add([file('IMG_3.insp', raw: true)]);
      await settle();
      expect(container.read(desktopOpenIn360Provider)?.id, 'f-IMG_3.insp');
      verify(() => router.replaceAll(any())).called(2);
    });

    test('several files open on the page of opened files, named after their folder', () async {
      await container.read(localSessionProvider.notifier).enter();
      final paths = [file('IMG_1.jpg'), file('VID_2.mp4')];

      DesktopOpenRequests.add(paths);
      await settle();

      final routes = verify(() => router.replaceAll(captureAny())).captured.single as List<PageRouteInfo<dynamic>>;
      expect(routes.map((route) => route.routeName), [TabShellRoute.name, OpenedFilesRoute.name]);
      final args = routes.last.args as OpenedFilesRouteArgs;
      expect(args.title, p.basename(directory.path));
      final batch = await args.files;
      expect(batch.assets.map((asset) => asset.id), ['f-IMG_1.jpg', 'f-VID_2.mp4']);
      expect(OpenedFiles.file('f-VID_2.mp4')?.path, paths.last);
      expect(container.read(desktopOpenIn360Provider), isNull);
    });

    test('a folder opens on the page of opened files, even with one photo in it', () async {
      await container.read(localSessionProvider.notifier).enter();
      file('IMG_1.jpg');

      DesktopOpenRequests.add([directory.path]);
      await settle();

      final routes = verify(() => router.replaceAll(captureAny())).captured.single as List<PageRouteInfo<dynamic>>;
      expect(routes.last.routeName, OpenedFilesRoute.name);
      expect((routes.last.args as OpenedFilesRouteArgs).title, p.basename(directory.path));
    });

    test('one file that is no photo or video says so and opens nothing', () async {
      await container.read(localSessionProvider.notifier).enter();
      final text = p.join(directory.path, 'notes.txt');
      File(text).writeAsStringSync('text');

      DesktopOpenRequests.add([text]);
      await settle();

      verifyNever(() => router.replaceAll(any()));
      expect(toasts.errors, hasLength(1));
    });

    test('a request made while files are opened waits for them, then opens', () async {
      await container.read(localSessionProvider.notifier).enter();
      final reading = Completer<void>();
      final first = file('IMG_1.jpg');
      final second = file('IMG_2.jpg');
      final slowHandler = DesktopOpenFilesHandler(
        container.read(_refProvider),
        read: (paths) async {
          if (paths.single == first) {
            await reading.future;
          }
          return _reads(paths);
        },
      )..init();

      DesktopOpenRequests.add([first]);
      await settle();
      DesktopOpenRequests.add([second]);
      await settle();
      verifyNever(() => router.replaceAll(any()));

      reading.complete();
      await settle();

      verify(() => router.replaceAll(any())).called(2);
      expect(container.read(assetViewerProvider).currentAsset?.id, 'f-IMG_2.jpg');
      expect(slowHandler, isNot(handler));
    });

    test('a view intent payload opens its path, as the phones hand one over', () async {
      await container.read(localSessionProvider.notifier).enter();
      final photo = file('IMG_1.jpg');

      await handler.handle(ViewIntentPayload(path: photo, mimeType: 'image/jpeg'));
      await settle();

      verify(() => router.replaceAll(any())).called(1);
    });
  });
}

// The Ref of the container, for a second handler made in a test
final _refProvider = Provider<Ref>((ref) => ref);
