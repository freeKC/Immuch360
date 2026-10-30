// The glue of "Make 3D (AI)" to the real data, which the dialog tests replace: the facts of a photo as the viewers
// know them (the turns the user chose, read once its exif or its stereo check answered, and the rotation saved in the
// edits of Immich; the 360° rules; the versions of the library), whether the viewer offers the entry for a photo, and
// where the original of a photo is (a file opened with the program, a file of the library, a drive that is not
// connected, the original of the server, no server).

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/destination.dart';
import 'package:immich_mobile/desktop/ai/creator/server_original_source.dart';
import 'package:immich_mobile/desktop/ai/library/stereo_badge.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/apple_spatial.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/domain/services/local_panorama.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/models/server_info/server_version.model.dart';
import 'package:immich_mobile/providers/ai_immersive/flat_stereo.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/apple_spatial.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/local_panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/sphere_coverage.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/view_rotation.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart' show RotateParameters;
import 'package:path/path.dart' as p;

import '../../../domain/ai_immersive/stereo_photo_fixtures.dart';
import '../../../fixtures/raw/insta360.stub.dart';
import '../../../service.mocks.dart';
import '../../../unit/factories/local_asset_factory.dart';
import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/factories/user_factory.dart';
import '../../library/library_fixtures.dart';
import '../../library/library_test_support.dart';

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

/// What the scan of the device read, by id on the device
class _Records extends LocalPanoramaAssets {
  _Records(this.records);

  final Map<String, LocalPanoramaRecord> records;

  @override
  Map<String, LocalPanoramaRecord> build() => records;
}

class _Sources extends NetworkSourcesNotifier {
  @override
  List<NetworkSource> build() => const [];
}

const _flatExif = ExifInfo(width: 4000, height: 3000, make: 'Canon', model: 'EOS');
const _sphereExif = ExifInfo(width: 8000, height: 4000, projectionType: ProjectionType.equirectangular);

/// The exif of a 360° photo without GPano tags nor a 360° camera, as the server gives it: no projection
const _plainSphereExif = ExifInfo(width: 8192, height: 4096);

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
  /// [_userId] on a server that takes edits, [edits] are the edits of Immich by remote id, and [versions] the versions
  /// the library knows; [records] what the scan of the device read, by id on the device; [heads] the files of the
  /// device and [serverHeads] the originals of the server, by remote id, whose heads the check of two eyes side by
  /// side reads (see flatStereoProvider), nothing else being read
  ProviderContainer createContainer({
    Map<BaseAsset, ExifInfo?> exif = const {},
    Map<BaseAsset, Future<AppleSpatialInfo?>> spatial = const {},
    Map<String, List<AssetEdit>> edits = const {},
    Map<String, IndexedVersion> versions = const {},
    Set<BaseAsset> panoramas = const {},
    Map<String, LocalPanoramaRecord> records = const {},
    Map<String, File> heads = const {},
    Map<String, Uint8List> serverHeads = const {},
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
        localPanoramaAssetsProvider.overrideWith(() => _Records(records)),
        flatStereoServiceProvider.overrideWithValue(
          FlatStereoService(
            localFile: (localId) async => heads[localId],
            serverReader: (remoteId) => switch (serverHeads[remoteId]) {
              final bytes? => (offset, length) async => Uint8List.sublistView(
                bytes,
                math.min(offset, bytes.length),
                math.min(offset + length, bytes.length),
              ),
              null => null,
            },
          ),
        ),
        networkSourcesProvider.overrideWith(_Sources.new),
        viewRotationAssetIdsProvider.overrideWithValue((_) async => null),
        viewRotationServerProvider.overrideWithValue(
          ViewRotationServer(
            edits: (remoteId) async => edits[remoteId] ?? const [],
            hasUnknownEdits: (_) async => false,
            apply: (_, _) async => null,
          ),
        ),
        generatedVersionsProvider.overrideWith((ref) async => versions),
        for (final MapEntry(key: asset, value: info) in exif.entries)
          assetExifProvider(asset).overrideWith((ref) => _late(info)),
        for (final asset in [...spatial.keys]) appleSpatialInfoProvider(asset).overrideWith((ref) => spatial[asset]!),
        // Photos of the library the 360° rules take, as the scan of the device would have found them
        for (final asset in panoramas) isEquirectangularProvider(asset).overrideWith((ref) => true),
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

    test('a version of the library says its kind; a 3D scene or a panorama holds no two eyes', () async {
      final scene = LocalAssetFactory.create(id: 'scene', name: 'salon_scene3D.jpg');
      final pano = LocalAssetFactory.create(id: 'pano', name: 'salon_360.jpg');
      final stereo = LocalAssetFactory.create(id: 'stereo', name: 'salon_360_3D.jpg');
      const sceneVersion = (origin: IndexedOrigin.reconstructed, kind: ImmersiveKind.volumetricScene);
      const panoVersion = (origin: IndexedOrigin.generated, kind: ImmersiveKind.panorama360);
      const stereoVersion = (origin: IndexedOrigin.generated, kind: ImmersiveKind.stereoPanorama360);
      final container = createContainer(
        versions: {'scene': sceneVersion, 'pano': panoVersion, 'stereo': stereoVersion},
        panoramas: {pano, stereo},
      );
      final read = container.read(conversionFactsReaderProvider);

      final ofScene = await read(scene);
      expect((ofScene.version, ofScene.isStereo, ofScene.isPanorama), (sceneVersion, false, false));
      final ofPano = await read(pano);
      expect((ofPano.version, ofPano.isStereo, ofPano.isPanorama), (panoVersion, false, true));
      expect((await read(stereo)).isStereo, isTrue);
      expect(
        conversionSkipOf(scene, ofScene, kind: ConversionKind.sceneFromPhoto),
        ConversionSkipReason.alreadyVersion,
      );
      expect(conversionSkipOf(pano, ofPano, kind: ConversionKind.stereoPanoramaFromPanorama), isNull);
    });

    test('a raw photo of a 360° camera is said, its lenses not stitched', () async {
      final raw = LocalAssetFactory.create(id: 'raw', name: 'IMG_20261020_101010_00_001.insp');
      final container = createContainer();
      final facts = await container.read(conversionFactsReaderProvider)(raw);
      expect((facts.isPanorama, facts.isRaw360), (true, true));
    });

    test('a 360° photo of the server is told once its exif answered; one of our versions is two eyes', () async {
      final sphere = RemoteAssetFactory.create(ownerId: _userId, name: 'sphere.jpg', width: 8000, height: 4000);
      final version = LocalAssetFactory.create(id: 'made', name: 'salon_3D.jpg');
      final photo = LocalAssetFactory.create(id: 'photo', name: 'salon.jpg');
      final container = createContainer(
        exif: {sphere: _sphereExif},
        versions: {'made': (origin: IndexedOrigin.estimated, kind: ImmersiveKind.stereoPhoto)},
      );
      final read = container.read(conversionFactsReaderProvider);

      expect((await read(sphere)).isPanorama, isTrue);
      expect((await read(version)).isStereo, isTrue);
      final flat = await read(photo);
      expect((flat.isPanorama, flat.isStereo, flat.isSpatial), (false, false, false));
    });
  });

  group('the entry of the viewer', () {
    /// What the entry says of [asset] once what it reads had the time to answer
    Future<bool> offered(ProviderContainer container, BaseAsset asset) async {
      final subscription = container.listen(aiFlatPhotoProvider(asset), (_, _) {});
      addTearDown(subscription.close);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      return container.read(aiFlatPhotoProvider(asset));
    }

    test('a flat photo only: not a 360° one, two eyes, one of our versions, nor a spatial one', () async {
      final flat = LocalAssetFactory.create(id: 'flat', name: 'salon.jpg');
      final sphere = RemoteAssetFactory.create(ownerId: _userId, name: 'sphere.jpg', width: 8000, height: 4000);
      final sbs = LocalAsset(
        id: 'sbs',
        name: 'iw3_LRF_Full_SBS.jpg',
        type: AssetType.image,
        createdAt: DateTime(2026, 10, 20),
        updatedAt: DateTime(2026, 10, 20),
        width: 8000,
        height: 3000,
        playbackStyle: AssetPlaybackStyle.image,
        isEdited: false,
      );
      final made = LocalAssetFactory.create(id: 'made', name: 'salon_3D.jpg');
      final spatial = LocalAssetFactory.create(id: 'spatial', name: 'IMG_0002.HEIC');
      final heic = LocalAssetFactory.create(id: 'heic', name: 'IMG_0001.HEIC');
      final checking = LocalAssetFactory.create(id: 'checking', name: 'IMG_0003.HEIC');
      final container = createContainer(
        exif: {sphere: _sphereExif},
        versions: {'made': (origin: IndexedOrigin.estimated, kind: ImmersiveKind.stereoPhoto)},
        spatial: {
          spatial: Future.value(const AppleSpatialInfo.photo(_pair)),
          heic: Future<AppleSpatialInfo?>.value(),
          checking: Completer<AppleSpatialInfo?>().future,
        },
      );

      expect(await offered(container, flat), isTrue);
      expect(await offered(container, sphere), isFalse);
      expect(await offered(container, sbs), isFalse);
      expect(await offered(container, made), isFalse);
      expect(await offered(container, spatial), isFalse);
      expect(await offered(container, checking), isFalse, reason: 'until its check answered');
      expect(await offered(container, heic), !Platform.isLinux, reason: 'no decoder for HEIF on Linux');
    });
  });

  group('the entry of the viewer by type', () {
    /// What [provider] says once what it reads had the time to answer
    Future<bool> says(ProviderContainer container, ProviderListenable<bool> provider) async {
      final subscription = container.listen(provider, (_, _) {});
      addTearDown(subscription.close);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      return container.read(provider);
    }

    LocalAsset local(String id, String name, int width, int height) => LocalAsset(
      id: id,
      name: name,
      type: AssetType.image,
      createdAt: DateTime(2026, 10, 20),
      updatedAt: DateTime(2026, 10, 20),
      width: width,
      height: height,
      playbackStyle: AssetPlaybackStyle.image,
      isEdited: false,
    );

    test(
      'a 360° photo that holds one eye is offered its 3D version, a flat photo the kinds made from a photo',
      () async {
        final sphere = RemoteAssetFactory.create(ownerId: _userId, name: 'sphere.jpg', width: 8000, height: 4000);
        final flat = local('flat', 'salon.jpg', 4000, 3000);
        final generated = local('pano', 'salon_360.jpg', 8192, 4096);
        final container = createContainer(
          exif: {sphere: _sphereExif},
          versions: {'pano': (origin: IndexedOrigin.generated, kind: ImmersiveKind.panorama360)},
          panoramas: {generated},
        );

        for (final (asset, isFlat, isSphere) in [
          (sphere, false, true),
          (flat, true, false),
          (generated, false, true),
        ]) {
          expect(await says(container, aiMonoPanoramaProvider(asset)), isSphere, reason: asset.name);
          for (final kind in ConversionKind.values) {
            final offered = kind == ConversionKind.stereoPanoramaFromPanorama ? isSphere : isFlat;
            expect(
              await says(container, aiSourceProvider((asset: asset, kind: kind))),
              offered,
              reason: '${asset.name} ${kind.name}',
            );
          }
        }
      },
    );

    test('a 2:1 photo nothing flags 360°, from each source, is offered its 3D version beside the flat kinds', () async {
      // As FreeKC's rooftop_night.jpg (8192 x 4096, no GPano tag): a file of the library, a photo of the server, the
      // two at once, a file opened with the program whose reading found no 360° projection
      final library = local('library', 'rooftop_night.jpg', 8192, 4096);
      final server = RemoteAssetFactory.create(ownerId: _userId, name: 'dawn.jpg', width: 8192, height: 4096);
      final merged = RemoteAssetFactory.create(
        ownerId: _userId,
        name: 'rooftop.jpg',
        width: 8192,
        height: 4096,
        localId: 'local-rooftop',
      );
      final opened = local('opened-1', 'carte.jpg', 6080, 3040);
      final container = createContainer(exif: {server: _plainSphereExif, merged: _plainSphereExif});
      container.read(openedFilePanoramasProvider.notifier).addAll({
        'opened-1': LocalPanoramaRecord(isPanorama: false, checkedAt: DateTime(2026, 10, 30)),
      });
      final read = container.read(conversionFactsReaderProvider);

      for (final asset in [library, server, merged, opened]) {
        expect(await says(container, aiMonoPanoramaProvider(asset)), isTrue, reason: asset.name);
        for (final kind in ConversionKind.values) {
          expect(
            await says(container, aiSourceProvider((asset: asset, kind: kind))),
            isTrue,
            reason: '${asset.name} ${kind.name}',
          );
        }
        // The dialog reads the same: flat for the 360° rules, taken by the type of the 3D version
        final facts = await read(asset);
        expect(facts.isPanorama, isFalse, reason: asset.name);
        expect(
          conversionSkipOf(asset, facts, kind: ConversionKind.stereoPanoramaFromPanorama),
          isNull,
          reason: asset.name,
        );
      }
      // A 4:3 photo is still no sphere
      final flat = local('flat', 'salon.jpg', 4000, 3000);
      expect(await says(container, aiMonoPanoramaProvider(flat)), isFalse);
    });

    test('viewed as 360° by the user, it gets its 3D version only, and the dialog reads it so', () async {
      final rooftop = local('library', 'rooftop_night.jpg', 8192, 4096);
      final server = RemoteAssetFactory.create(ownerId: _userId, name: 'dawn.jpg', width: 8192, height: 4096);
      await store.put(StoreKey.forcedPanoramaAssets, '["library","${server.id}"]');
      final container = createContainer(exif: {server: _plainSphereExif});
      final read = container.read(conversionFactsReaderProvider);

      for (final asset in [rooftop, server]) {
        for (final kind in ConversionKind.values) {
          expect(
            await says(container, aiSourceProvider((asset: asset, kind: kind))),
            kind == ConversionKind.stereoPanoramaFromPanorama,
            reason: '${asset.name} ${kind.name}',
          );
        }
        final facts = await read(asset);
        expect(facts.isPanorama, isTrue, reason: asset.name);
        expect(conversionSkipOf(asset, facts), ConversionSkipReason.sphere360, reason: asset.name);
      }
    });

    test('an Insta360 photo of the server nothing flags 360° may be a raw one renamed: refused as raw', () async {
      // The make of the stitched photos of the camera, and their frame: only the trailer of the file, which the server
      // does not hold, tells a raw one renamed .jpg. Viewed as 360° by the user, it is a stitched one.
      const insta360 = ExifInfo(width: 6080, height: 3040, make: 'Arashi Vision', model: 'Insta360 X4');
      final renamed = RemoteAssetFactory.create(ownerId: _userId, name: 'IMG_1.jpg', width: 6080, height: 3040);
      final viewed = RemoteAssetFactory.create(ownerId: _userId, name: 'IMG_2.jpg', width: 6080, height: 3040);
      await store.put(StoreKey.forcedPanoramaAssets, '["${viewed.id}"]');
      final container = createContainer(exif: {renamed: insta360, viewed: insta360});
      final read = container.read(conversionFactsReaderProvider);
      const ofPanorama = ConversionKind.stereoPanoramaFromPanorama;

      expect(await says(container, aiMonoPanoramaProvider(renamed)), isFalse);
      final facts = await read(renamed);
      expect((facts.isPanorama, facts.isRaw360), (false, true));
      expect(conversionSkipOf(renamed, facts, kind: ofPanorama), ConversionSkipReason.raw360);

      expect(await says(container, aiMonoPanoramaProvider(viewed)), isTrue);
      final ofViewed = await read(viewed);
      expect((ofViewed.isPanorama, ofViewed.isRaw360), (true, false));
      expect(conversionSkipOf(viewed, ofViewed, kind: ofPanorama), isNull);
    });

    test(
      'a 2:1 photo whose head holds our XMP is one of our 3D photos renamed: two eyes, as the viewer shows it',
      () async {
        // Our 3D photo of a square photo (two eyes of 3000 x 3000), renamed: neither its name nor the index of the library
        // tells it, our XMP does, which the viewer of a computer reads to show it in 3D (fix-stereo-360-pc review, M1). A
        // file of the library and an original of the server alike.
        final directory = Directory.systemTemp.createTempSync('conversion_facts');
        addTearDown(() => directory.deleteSync(recursive: true));
        File write(String name, Uint8List bytes) => File(p.join(directory.path, name))..writeAsBytesSync(bytes);
        final ours = jpegFile(width: 6000, height: 3000, xmp: ourXmp(eyeWidth: 3000, eyeHeight: 3000));
        final library = local('square', 'square_3D.jpg', 6000, 3000);
        final server = RemoteAssetFactory.create(ownerId: _userId, name: 'square_3D.jpg', width: 6000, height: 3000);
        // Two square eyes side by side under a plain name, no XMP: nothing in it tells them, the plan names it to check
        final plain = local('plain', 'IMG_0001.jpg', 4000, 2000);
        final container = createContainer(
          exif: {server: const ExifInfo(width: 6000, height: 3000)},
          heads: {
            'square': write('square_3D.jpg', ours),
            'plain': write('IMG_0001.jpg', jpegFile(width: 4000, height: 2000)),
          },
          serverHeads: {server.id: ours},
        );
        final read = container.read(conversionFactsReaderProvider);

        for (final asset in [library, server]) {
          expect(await says(container, aiMonoPanoramaProvider(asset)), isFalse, reason: asset.name);
          expect(
            await says(container, aiFlatPhotoProvider(asset)),
            isFalse,
            reason: '${asset.name}: no 3D photo of it',
          );
          final facts = await read(asset);
          expect((facts.isPanorama, facts.isStereo), (false, true), reason: asset.name);
          for (final kind in ConversionKind.values) {
            expect(
              conversionSkipOf(asset, facts, kind: kind),
              ConversionSkipReason.alreadyStereo,
              reason: '${asset.name} ${kind.name}',
            );
          }
        }
        expect(await says(container, aiMonoPanoramaProvider(plain)), isTrue);
        final ofPlain = await read(plain);
        expect(ofPlain.isStereo, isFalse);
        expect(conversionSkipOf(plain, ofPlain, kind: ConversionKind.stereoPanoramaFromPanorama), isNull);
      },
    );

    test('a 360° photo named for two eyes side by side is refused as two eyes, by the entry as by the plan', () async {
      final beach = RemoteAssetFactory.create(ownerId: _userId, name: 'beach_LR.jpg', width: 8000, height: 4000);
      final container = createContainer(exif: {beach: _sphereExif});

      expect(await says(container, aiMonoPanoramaProvider(beach)), isFalse);
      final facts = await container.read(conversionFactsReaderProvider)(beach);
      expect((facts.isPanorama, facts.isStereo), (true, true));
      expect(
        conversionSkipOf(beach, facts, kind: ConversionKind.stereoPanoramaFromPanorama),
        ConversionSkipReason.alreadyStereo,
      );
    });

    test('the coverage the user picked in a 360° viewer holds: a half sphere is VR180, a whole one is not', () async {
      final rooftop = local('library', 'rooftop_night.jpg', 8192, 4096);
      final trip = RemoteAssetFactory.create(ownerId: _userId, name: 'trip_180.jpg', width: 8000, height: 4000);
      final container = createContainer(exif: {trip: _sphereExif});
      final coverages = container.read(sphereCoverageOverridesProvider.notifier);
      await coverages.set(rooftop, SphereCoverage.half);
      await coverages.set(trip, SphereCoverage.full);
      final read = container.read(conversionFactsReaderProvider);
      const ofPanorama = ConversionKind.stereoPanoramaFromPanorama;

      expect(await says(container, aiMonoPanoramaProvider(rooftop)), isFalse);
      final ofRooftop = await read(rooftop);
      expect(ofRooftop.coverage, SphereCoverage.half);
      expect(conversionSkipOf(rooftop, ofRooftop, kind: ofPanorama), ConversionSkipReason.vr180);

      expect(
        await says(container, aiMonoPanoramaProvider(trip)),
        isTrue,
        reason: 'named VR180, a whole sphere for the user',
      );
      final ofTrip = await read(trip);
      expect(ofTrip.coverage, SphereCoverage.full);
      expect(conversionSkipOf(trip, ofTrip, kind: ofPanorama), isNull);
    });

    test('an Insta360 photo whose file the scan read is not refused for the make the server gives', () async {
      // In a folder of the library and on the server: the scan read its file and found no trailer of a raw photo
      const insta360 = ExifInfo(width: 6080, height: 3040, make: 'Arashi Vision', model: 'Insta360 X4');
      final read360 = RemoteAssetFactory.create(
        ownerId: _userId,
        name: 'IMG_3.jpg',
        width: 6080,
        height: 3040,
        localId: 'local-read',
      );
      final unread = RemoteAssetFactory.create(
        ownerId: _userId,
        name: 'IMG_4.jpg',
        width: 6080,
        height: 3040,
        localId: 'local-unread',
      );
      final container = createContainer(
        exif: {read360: insta360, unread: insta360},
        records: {'local-read': LocalPanoramaRecord(isPanorama: false, checkedAt: DateTime(2026, 10, 30))},
      );
      final read = container.read(conversionFactsReaderProvider);
      const ofPanorama = ConversionKind.stereoPanoramaFromPanorama;

      expect(await says(container, aiMonoPanoramaProvider(read360)), isTrue);
      final facts = await read(read360);
      expect((facts.isPanorama, facts.isRaw360), (false, false));
      expect(conversionSkipOf(read360, facts, kind: ofPanorama), isNull);
      // Its file not read yet: the make tells, until the dialog reads the file it found
      expect(await says(container, aiMonoPanoramaProvider(unread)), isFalse);
      expect((await read(unread)).isRaw360, isTrue);
    });

    test('never a 3D one, a VR180 one, a raw one, nor another version of ours', () async {
      final stacked = RemoteAssetFactory.create(ownerId: _userId, name: 'stacked.jpg', width: 4096, height: 4096);
      final vr180 = RemoteAssetFactory.create(ownerId: _userId, name: 'trip_180.jpg', width: 8000, height: 4000);
      final raw = local('raw', 'IMG_20261020_101010_00_001.insp', 6080, 3040);
      final stereoVersion = local('stereo', 'salon_360_3D.jpg', 8192, 4096);
      final scene = local('scene', 'salon_scene3D.jpg', 2048, 1536);
      final container = createContainer(
        exif: {stacked: _sphereExif, vr180: _sphereExif},
        versions: {
          'stereo': (origin: IndexedOrigin.estimated, kind: ImmersiveKind.stereoPanorama360),
          'scene': (origin: IndexedOrigin.reconstructed, kind: ImmersiveKind.volumetricScene),
        },
        panoramas: {stereoVersion},
      );

      for (final asset in [stacked, vr180, raw, stereoVersion, scene]) {
        expect(await says(container, aiMonoPanoramaProvider(asset)), isFalse, reason: asset.name);
      }
      expect(await says(container, aiFlatPhotoProvider(scene)), isFalse, reason: 'a version of ours');
    });
  });

  test('the file of a photo taken by its frame tells a raw Insta360 photo, a GPano projection, or nothing', () async {
    final directory = Directory.systemTemp.createTempSync('conversion_probe');
    addTearDown(() => directory.deleteSync(recursive: true));
    String write(String name, Uint8List bytes) {
      final path = p.join(directory.path, name);
      File(path).writeAsBytesSync(bytes);
      return path;
    }

    LocalAsset photo(String name, int width, int height) => LocalAsset(
      id: name,
      name: name,
      type: AssetType.image,
      createdAt: DateTime(2026, 10, 30),
      updatedAt: DateTime(2026, 10, 30),
      width: width,
      height: height,
      playbackStyle: AssetPlaybackStyle.image,
      isEdited: false,
    );

    // A raw photo renamed .jpg, of a folder the scan has not reached: only the trailer of its file tells it
    final raw = write(
      'IMG_2.jpg',
      insta360File([
        insta360Record(1, x3Metadata(), format: 1),
      ], body: jpegFile(width: 6080, height: 3040, dataLength: 200000)),
    );
    final tagged = write('PANO_1.jpg', jpegFile(width: 8192, height: 4096, segments: [gpanoSegment()]));
    final plain = write('rooftop_night.jpg', jpegFile(width: 8192, height: 4096));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final probe = container.read(conversionFileProbeProvider);

    expect(await probe(LocalFileSource(raw), photo('IMG_2.jpg', 6080, 3040)), (
      isPanorama: true,
      halfSphere: null,
      raw360: true,
    ));
    expect(await probe(LocalFileSource(tagged), photo('PANO_1.jpg', 8192, 4096)), (
      isPanorama: true,
      halfSphere: null,
      raw360: false,
    ));
    expect(await probe(LocalFileSource(plain), photo('rooftop_night.jpg', 8192, 4096)), (
      isPanorama: false,
      halfSphere: null,
      raw360: false,
    ));
    expect(await probe(LocalFileSource(p.join(directory.path, 'gone.jpg')), photo('gone.jpg', 8192, 4096)), isNull);
    final server = ServerOriginalSource(
      name: 'dawn.jpg',
      remoteId: 'remote-dawn',
      endpoint: 'http://nas:2283/api',
      fetch: (_) => throw StateError('nothing is fetched'),
    );
    expect(await probe(server, photo('dawn.jpg', 8192, 4096)), isNull, reason: 'the engine checks the copy');
  });

  group('where the original of a photo is', () {
    late TestLibrary fixture;
    late String photos;
    late FolderLibrary library;

    setUp(() async {
      fixture = TestLibrary();
      fixture.probe.mounts[fixture.files.path] = 'win-0000beef';
      photos = p.join(fixture.files.path, 'Photos');
      fixture
        ..write('Photos/salon.jpg', jpegBytes(width: 40, height: 30))
        ..write('Photos/fleur.png', pngBytes(width: 40, height: 30));
      library = fixture.library();
      library.addRoot(photos);
      await fixture.scan();
    });

    tearDown(() => fixture.dispose());

    LocalAsset libraryAsset(String name) => LocalAsset(
      id: library.idOfPath(p.join(photos, name))!,
      name: name,
      type: AssetType.image,
      createdAt: DateTime.utc(2026, 10, 20, 8, 5, 9),
      updatedAt: DateTime.utc(2026, 10, 20, 8, 5, 9),
      playbackStyle: AssetPlaybackStyle.image,
      isEdited: false,
    );

    DesktopConversionAssetFiles files({String? endpoint, Map<String, LibraryFile> opened = const {}}) =>
        DesktopConversionAssetFiles(library: () async => library, endpoint: () => endpoint, opened: (id) => opened[id]);

    test('a file of the library is read where it is; the date of a photo that is not a JPEG goes with it', () async {
      final jpeg = (await files().locate(libraryAsset('salon.jpg')))!;
      expect(
        jpeg.location,
        isA<LibraryOriginal>().having((original) => original.path, 'path', p.join(photos, 'salon.jpg')),
      );
      expect((jpeg.source as LocalFileSource).path, p.join(photos, 'salon.jpg'));
      expect(jpeg.source.exif.dateTimeOriginal, isNull, reason: 'the engine reads the EXIF of a JPEG itself');

      final png = (await files().locate(libraryAsset('fleur.png')))!;
      final date = DateTime.utc(2026, 10, 20, 8, 5, 9).toLocal();
      String two(int value) => value.toString().padLeft(2, '0');
      expect(
        png.source.exif.dateTimeOriginal,
        '${date.year}:${two(date.month)}:${two(date.day)} ${two(date.hour)}:${two(date.minute)}:${two(date.second)}',
      );
    });

    test('a file opened with the program, before the library', () async {
      final path = p.join(fixture.files.path, 'Desktop', 'carte.jpg');
      final opened = LibraryFile(
        assetId: 'opened-1',
        path: path,
        name: 'carte.jpg',
        kind: LibraryMediaKind.image,
        size: 100,
        modifiedMs: 0,
        createdSeconds: 0,
        mimeType: 'image/jpeg',
        cloudOnly: false,
        available: true,
      );
      final found = (await files(opened: {'opened-1': opened}).locate(LocalAssetFactory.create(id: 'opened-1')))!;
      expect(found.location, isA<OpenedOriginal>().having((original) => original.path, 'path', path));
      expect((found.source as LocalFileSource).path, path);
    });

    test('a drive that is not connected: the original of the server when there is one, else nothing', () async {
      final asset = libraryAsset('salon.jpg');
      fixture.probe.mounts.clear();
      await fixture.scan();

      expect(await files(endpoint: 'http://nas:2283/api').locate(asset), isNull, reason: 'no copy on the server');
      final merged = RemoteAssetFactory.create(id: 'remote-salon', name: 'salon.jpg', localId: asset.id);
      final found = (await files(endpoint: 'http://nas:2283/api').locate(merged))!;
      expect(found.location, isA<ServerOriginal>());
      expect(found.source, isA<ServerOriginalSource>().having((source) => source.remoteId, 'remoteId', 'remote-salon'));
      expect(await files().locate(merged), isNull, reason: 'no server signed in');
    });

    test('a photo of the server only: its original, when a server is signed in', () async {
      final remote = RemoteAssetFactory.create(id: 'remote-1', name: 'plage.jpg');
      final found = (await files(endpoint: 'http://nas:2283/api').locate(remote))!;
      expect(found.location, isA<ServerOriginal>().having((original) => original.name, 'name', 'plage.jpg'));
      expect(await files().locate(remote), isNull);
    });
  });
}
