// The glue of "Make 3D (AI)" to the real data, which the dialog tests replace: the facts of a photo as the viewers
// know them (the turns the user chose, read once its exif or its stereo check answered, and the rotation saved in the
// edits of Immich; the 360° rules; the versions of the library).

import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/library/stereo_badge.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/domain/models/apple_spatial.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/local_panorama.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/models/server_info/server_version.model.dart';
import 'package:immich_mobile/providers/asset_viewer/apple_spatial.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/local_panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/view_rotation.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart' show RotateParameters;

import '../../../service.mocks.dart';
import '../../../unit/factories/local_asset_factory.dart';
import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/factories/user_factory.dart';

const _userId = 'me';

class _ServerInfo extends ServerInfoNotifier {
  _ServerInfo() : super(MockServerInfoService()) {
    state = state.copyWith(serverVersion: const ServerVersion(major: 2, minor: 6, patch: 0));
  }
}

class _ReadOnly extends ReadOnlyModeNotifier {
  @override
  bool build() => false;
}

class _Records extends LocalPanoramaAssets {
  @override
  Map<String, LocalPanoramaRecord> build() => const {};
}

class _Sources extends NetworkSourcesNotifier {
  @override
  List<NetworkSource> build() => const [];
}

const _flatExif = ExifInfo(width: 4000, height: 3000, make: 'Canon', model: 'EOS');
const _sphereExif = ExifInfo(width: 8000, height: 4000, projectionType: ProjectionType.equirectangular);

const _pair = HeicStereoPair(
  primaryItemId: 1,
  leftItemId: 1,
  rightItemId: 2,
  pitmIdOffset: 0,
  pitmIdBytes: 2,
  width: 100,
  height: 100,
);

/// [value] a moment later, as a stream of the database or a read of a file gives it
Stream<T> _late<T>(T value) => Stream.fromFuture(Future.delayed(const Duration(milliseconds: 30), () => value));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Drift db;
  late StoreService store;

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    ViewRotations.resetPrune();
  });

  tearDown(() async {
    await store.dispose();
    await db.close();
  });

  /// A container where the exif of each asset of [exif] comes a moment later (an asset of the server not in it has its
  /// exif still loading), the stereo check of each HEIF photo of [spatial] answers as given, the signed in user is
  /// [_userId] on a server that takes edits, [edits] are the edits of Immich by remote id, and [origins] the versions
  /// the library knows
  ProviderContainer createContainer({
    Map<BaseAsset, ExifInfo?> exif = const {},
    Map<BaseAsset, Future<AppleSpatialInfo?>> spatial = const {},
    Map<String, List<AssetEdit>> edits = const {},
    Map<String, IndexedOrigin> origins = const {},
  }) {
    final users = MockUserService();
    when(users.tryGetMyUser).thenReturn(UserFactory.createDto(id: _userId));
    when(users.watchMyUser).thenAnswer((_) => const Stream.empty());
    final container = ProviderContainer(
      overrides: [
        storeServiceProvider.overrideWithValue(store),
        serverInfoProvider.overrideWith((ref) => _ServerInfo()),
        currentUserProvider.overrideWith((ref) => CurrentUserProvider(users)),
        readonlyModeProvider.overrideWith(_ReadOnly.new),
        localPanoramaAssetsProvider.overrideWith(_Records.new),
        networkSourcesProvider.overrideWith(_Sources.new),
        viewRotationAssetIdsProvider.overrideWithValue((_) async => null),
        viewRotationServerProvider.overrideWithValue(
          ViewRotationServer(
            edits: (remoteId) async => edits[remoteId] ?? const [],
            hasUnknownEdits: (_) async => false,
            apply: (_, _) async => null,
          ),
        ),
        generatedOriginsProvider.overrideWith((ref) async => origins),
        for (final MapEntry(key: asset, value: info) in exif.entries)
          assetExifProvider(asset).overrideWith((ref) => _late(info)),
        for (final asset in [...spatial.keys]) appleSpatialInfoProvider(asset).overrideWith((ref) => spatial[asset]!),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('the facts of a photo', () {
    test('the turns the user chose, read once the exif of a photo with a server copy answered', () async {
      final partner = RemoteAssetFactory.create(ownerId: 'partner', name: 'partner.jpg');
      final merged = RemoteAssetFactory.create(ownerId: _userId, name: 'salon.jpg', localId: 'local-salon');
      final local = LocalAssetFactory.create(id: 'local-only', name: 'jardin.jpg');
      await store.put(StoreKey.viewRotations, '{"a:${partner.id}":1,"a:${merged.id}":3,"a:${local.id}":2}');
      final container = createContainer(exif: {partner: _flatExif, merged: _flatExif});
      // Read at once, as nothing else listens outside the viewer: still "no turn"
      expect(container.read(displayQuarterTurnsProvider(partner)), 0);

      final read = container.read(conversionFactsReaderProvider);
      expect((await read(partner)).quarterTurns, 1);
      expect((await read(merged)).quarterTurns, 3);
      expect((await read(local)).quarterTurns, 2);
      expect((await read(partner)).serverEdits, isFalse);
    });

    test('the turns of a HEIF photo, read once its stereo check answered; a spatial one is said', () async {
      final heic = LocalAssetFactory.create(id: 'heic', name: 'IMG_0001.HEIC');
      final spatial = LocalAssetFactory.create(id: 'spatial', name: 'IMG_0002.HEIC');
      await store.put(StoreKey.viewRotations, '{"a:${heic.id}":1}');
      final container = createContainer(
        spatial: {
          heic: Future<AppleSpatialInfo?>.delayed(const Duration(milliseconds: 30)),
          spatial: Future<AppleSpatialInfo?>.delayed(
            const Duration(milliseconds: 30),
            () => const AppleSpatialInfo.photo(_pair),
          ),
        },
      );
      final read = container.read(conversionFactsReaderProvider);
      final flat = await read(heic);
      final stereo = await read(spatial);
      if (Platform.isLinux) {
        // No decoder for HEIF there: skipped whatever its facts
        expect(conversionSkipOf(heic, flat), ConversionSkipReason.unreadableFormat);
      } else {
        expect((flat.quarterTurns, flat.isSpatial), (1, false));
        expect(stereo.isSpatial, isTrue);
      }
    });

    test('the rotation saved in the edits of Immich, plus the turns the viewer draws on top', () async {
      final edited = RemoteAssetFactory.create(ownerId: 'partner', name: 'edited.jpg').copyWith(isEdited: true);
      final mine = RemoteAssetFactory.create(
        ownerId: _userId,
        name: 'mine.jpg',
        localId: 'local-mine',
      ).copyWith(isEdited: true);
      final plain = RemoteAssetFactory.create(ownerId: _userId, name: 'plain.jpg');
      await store.put(StoreKey.viewRotations, '{"a:${edited.id}":1}');
      final container = createContainer(
        exif: {edited: _flatExif, mine: _flatExif, plain: _flatExif},
        edits: {
          edited.id: [RotateEdit(RotateParameters(angle: 90))],
          mine.id: [RotateEdit(RotateParameters(angle: 270))],
          plain.id: [RotateEdit(RotateParameters(angle: 90))],
        },
      );
      final read = container.read(conversionFactsReaderProvider);

      final ofEdited = await read(edited);
      expect((ofEdited.quarterTurns, ofEdited.serverEdits), (2, true));
      final ofMine = await read(mine);
      expect((ofMine.quarterTurns, ofMine.serverEdits), (3, true), reason: 'a library file of an edited photo too');
      final ofPlain = await read(plain);
      expect((ofPlain.quarterTurns, ofPlain.serverEdits), (0, false), reason: 'not edited: its edits are not read');
    });

    test('a 360° photo of the server is told once its exif answered; one of our versions is two eyes', () async {
      final sphere = RemoteAssetFactory.create(ownerId: _userId, name: 'sphere.jpg', width: 8000, height: 4000);
      final version = LocalAssetFactory.create(id: 'made', name: 'salon_3D.jpg');
      final photo = LocalAssetFactory.create(id: 'photo', name: 'salon.jpg');
      final container = createContainer(exif: {sphere: _sphereExif}, origins: {'made': IndexedOrigin.estimated});
      final read = container.read(conversionFactsReaderProvider);

      expect((await read(sphere)).isPanorama, isTrue);
      expect((await read(version)).isStereo, isTrue);
      final flat = await read(photo);
      expect((flat.isPanorama, flat.isStereo, flat.isSpatial), (false, false, false));
    });
  });
}
