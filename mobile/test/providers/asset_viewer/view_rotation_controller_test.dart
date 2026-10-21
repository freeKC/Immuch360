// The one-key rotation on the server: quick presses make one request with the whole list of edits, one request at a
// time; the picture turns at once and gives way to the server's turned picture by its thumbhash; nothing is sent for a
// photo that became 360° meanwhile; edits the app does not know are never dropped.

import 'dart:async';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/models/server_info/server_version.model.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/view_rotation.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart' show CropParameters, MirrorAxis, MirrorParameters, RotateParameters;

import '../../service.mocks.dart';
import '../../unit/factories/remote_asset_factory.dart';
import '../../unit/factories/user_factory.dart';

const _userId = 'me';

class _ServerInfo extends ServerInfoNotifier {
  _ServerInfo() : super(MockServerInfoService()) {
    state = state.copyWith(serverVersion: const ServerVersion(major: 2, minor: 7, patch: 0));
  }
}

class _ReadOnlyOff extends ReadOnlyModeNotifier {
  @override
  bool build() => false;
}

/// The server's side of the rotation: what was sent, and how it answers
class _FakeServer {
  final sent = <String>[];
  List<AssetEdit> base = const [];
  bool unknownEdits = false;
  Object? failure;
  Completer<String?>? gate;
  var _hash = 0;

  ViewRotationServer get server => ViewRotationServer(
    edits: (_) async => base,
    hasUnknownEdits: (_) async => unknownEdits,
    apply: (_, edits) async {
      sent.add(_describe(edits));
      final failure = this.failure;
      if (failure != null) {
        throw failure;
      }
      final gate = this.gate;
      return gate != null ? gate.future : 'hash-${++_hash}';
    },
  );
}

String _describe(List<AssetEdit> edits) => edits.isEmpty
    ? 'none'
    : edits
          .map(
            (edit) => switch (edit) {
              RotateEdit(:final parameters) => 'rotate ${parameters.angle}',
              MirrorEdit(:final parameters) => 'mirror ${parameters.axis}',
              CropEdit() => 'crop',
            },
          )
          .join(', ');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Drift db;
  late StoreService store;
  late _FakeServer server;
  late MockToastService toast;
  final photo = RemoteAssetFactory.create(ownerId: _userId).copyWith(thumbHash: 'original');

  setUpAll(() => registerFallbackValue(''));

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    server = _FakeServer();
    toast = MockToastService();
    when(() => toast.info(any())).thenAnswer((_) async {});
    when(() => toast.error(any())).thenAnswer((_) async {});
    ViewRotations.resetPrune();
    resetKeptOnDeviceNotice();
  });

  tearDown(() async {
    await store.dispose();
    await db.close();
  });

  /// A container where [photo] is a flat photo of the user on a server that takes edits, its mode known
  ProviderContainer createContainer(FakeAsync async) {
    final users = MockUserService();
    when(users.tryGetMyUser).thenReturn(UserFactory.createDto(id: _userId));
    when(users.watchMyUser).thenAnswer((_) => const Stream.empty());
    final container = ProviderContainer(
      overrides: [
        storeServiceProvider.overrideWithValue(store),
        serverInfoProvider.overrideWith((ref) => _ServerInfo()),
        currentUserProvider.overrideWith((ref) => CurrentUserProvider(users)),
        readonlyModeProvider.overrideWith(_ReadOnlyOff.new),
        assetExifProvider(photo).overrideWith((ref) => Stream.value(ExifInfo(width: 4000, height: 3000))),
        viewRotationServerProvider.overrideWithValue(server.server),
        viewRotationAssetIdsProvider.overrideWithValue((_) async => null),
        toastServiceProvider.overrideWithValue(toast),
      ],
    );
    addTearDown(container.dispose);
    final mode = container.listen(rotationModeProvider(photo), (_, _) {});
    addTearDown(mode.close);
    async.flushMicrotasks();
    expect(container.read(rotationModeProvider(photo)), RotationMode.server);
    return container;
  }

  int shown(ProviderContainer container, BaseAsset asset) => container.read(displayQuarterTurnsProvider(asset));

  test('quick presses turn the picture at once and make one request, with the whole list', () {
    fakeAsync((async) {
      final container = createContainer(async);
      final controller = container.read(viewRotationControllerProvider.notifier);

      for (var press = 0; press < 3; press++) {
        controller.rotate(photo, 1);
        async.elapse(const Duration(milliseconds: 300));
      }
      expect(shown(container, photo), 3, reason: 'turned on screen right away');
      expect(server.sent, isEmpty, reason: 'still gathering presses');

      async.elapse(ViewRotationController.debounce);
      expect(server.sent, ['rotate 270']);
      expect(shown(container, photo), 3, reason: 'the original picture is still drawn');
      expect(shown(container, photo.copyWith(thumbHash: 'hash-1')), 0, reason: 'the server turned it');
      expect(shown(container, photo.copyWith(thumbHash: 'elsewhere')), 0, reason: 'a picture the session did not make');
      expect(store.tryGet(StoreKey.viewRotations), isNull, reason: 'nothing kept on the device');
    });
  });

  test('four presses are no turn and make no request', () {
    fakeAsync((async) {
      final container = createContainer(async);
      final controller = container.read(viewRotationControllerProvider.notifier);
      for (var press = 0; press < 4; press++) {
        controller.rotate(photo, 1);
      }
      async.elapse(const Duration(seconds: 1));
      expect(server.sent, isEmpty);
      expect(shown(container, photo), 0);
    });
  });

  test('counter clockwise presses send the other way round, the edits already there kept', () {
    fakeAsync((async) {
      server.base = [
        CropEdit(CropParameters(x: 1, y: 2, width: 300, height: 200)),
        MirrorEdit(MirrorParameters(axis: MirrorAxis.vertical)),
        RotateEdit(RotateParameters(angle: 90)),
      ];
      final container = createContainer(async);
      container.read(viewRotationControllerProvider.notifier).rotate(photo, -1);
      async.elapse(const Duration(seconds: 1));
      expect(server.sent, ['crop, mirror vertical']);
    });
  });

  test('a press during a request makes one more request once it is over, never two at once', () {
    fakeAsync((async) {
      final container = createContainer(async);
      final controller = container.read(viewRotationControllerProvider.notifier);
      server.gate = Completer();
      controller.rotate(photo, 1);
      async.elapse(const Duration(seconds: 1));
      expect(server.sent, ['rotate 90']);
      expect(container.read(rotationSavingProvider(photo.id)), isTrue, reason: 'the progress bar shows');

      controller.rotate(photo, 1);
      async.elapse(const Duration(seconds: 1));
      expect(server.sent, ['rotate 90'], reason: 'waits for the request under way');

      final first = server.gate!;
      server.gate = null;
      first.complete('after-90');
      async.flushMicrotasks();
      expect(server.sent, ['rotate 90', 'rotate 180']);
      expect(shown(container, photo.copyWith(thumbHash: 'after-90')), 1);
      expect(shown(container, photo.copyWith(thumbHash: 'hash-1')), 0);
      expect(container.read(rotationSavingProvider(photo.id)), isFalse);
    });
  });

  test('a failed request drops the turn and says so', () {
    fakeAsync((async) {
      final container = createContainer(async);
      server.failure = Exception('offline');
      container.read(viewRotationControllerProvider.notifier).rotate(photo, 1);
      expect(shown(container, photo), 1);
      async.elapse(const Duration(seconds: 1));
      expect(shown(container, photo), 0, reason: "the server's picture comes back");
      verify(() => toast.error(any())).called(1);
      expect(container.read(viewRotationControllerProvider), isEmpty);
    });
  });

  test('sends nothing for a photo chosen to be viewed as 360° before the request', () {
    fakeAsync((async) {
      final container = createContainer(async);
      container.read(viewRotationControllerProvider.notifier).rotate(photo, 1);
      async.elapse(const Duration(milliseconds: 300));
      container.read(forcedPanoramaAssetsProvider.notifier).add(photo).ignore();
      async.elapse(const Duration(seconds: 1));
      expect(server.sent, isEmpty);
      expect(shown(container, photo), 0);
      expect(store.tryGet(StoreKey.viewRotations), isNull, reason: 'nothing kept for a sphere either');
    });
  });

  test('keeps the rotation on the device for a photo with edits the app does not know', () {
    fakeAsync((async) {
      final container = createContainer(async);
      server.unknownEdits = true;
      container.read(viewRotationControllerProvider.notifier).rotate(photo, 1);
      async.elapse(const Duration(seconds: 1));
      expect(server.sent, isEmpty);
      expect(store.tryGet(StoreKey.viewRotations), '{"a:${photo.id}":1}');
      expect(shown(container, photo), 1);
      verify(() => toast.info(any())).called(1);
    });
  });

  test('folds a rotation kept while the server took no edits into the first request, then forgets it', () {
    fakeAsync((async) {
      store.put(StoreKey.viewRotations, '{"a:${photo.id}":1}').ignore();
      async.flushMicrotasks();
      final container = createContainer(async);
      expect(shown(container, photo), 1, reason: 'the turn kept on the device shows until then');

      container.read(viewRotationControllerProvider.notifier).rotate(photo, 1);
      expect(shown(container, photo), 2);
      async.elapse(const Duration(seconds: 1));
      expect(server.sent, ['rotate 180']);
      expect(store.tryGet(StoreKey.viewRotations), isNull);
      expect(shown(container, photo.copyWith(thumbHash: 'hash-1')), 0);
    });
  });

  test('ends an idle session after a while, and starts again from the edits of a picture made elsewhere', () {
    fakeAsync((async) {
      final container = createContainer(async);
      final controller = container.read(viewRotationControllerProvider.notifier);
      controller.rotate(photo, 1);
      async.elapse(const Duration(seconds: 1));
      expect(container.read(viewRotationControllerProvider).keys, [photo.id]);

      // Edited on the web meanwhile: the session does not know that picture, and reads the edits again
      server.base = [RotateEdit(RotateParameters(angle: 180))];
      controller.rotate(photo.copyWith(thumbHash: 'from-the-web'), 1);
      async.elapse(const Duration(seconds: 1));
      expect(server.sent, ['rotate 90', 'rotate 270']);

      async.elapse(ViewRotationController.lifetime);
      expect(container.read(viewRotationControllerProvider), isEmpty);
    });
  });
}
