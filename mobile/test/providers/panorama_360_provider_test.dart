import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/panorama_360.model.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/services/local_panorama.service.dart';
import 'package:immich_mobile/domain/services/panorama_360_list.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/providers/asset_viewer/local_panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/sphere_coverage.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/panorama_360.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../infrastructure/repository.mock.dart';
import '../medium/repository_context.dart';
import '../service.mocks.dart';
import '../unit/factories/user_factory.dart';

class _MockTimelineFactory extends Mock implements TimelineFactory {}

class _Forced extends ForcedPanoramaAssets {
  _Forced(this._initial);

  final Set<String> _initial;

  @override
  Set<String> build() => _initial;

  set keys(Set<String> keys) => state = keys;
}

class _Found extends FoundLocalPanoramaIds {
  _Found(this._initial);

  final Set<String> _initial;

  @override
  Set<String> build() => _initial;
}

class _Records extends LocalPanoramaAssets {
  _Records(this._initial);

  final Map<String, LocalPanoramaRecord> _initial;

  @override
  Map<String, LocalPanoramaRecord> build() => _initial;
}

class _Coverages extends SphereCoverageOverrides {
  _Coverages(this._initial);

  final Map<String, SphereCoverage> _initial;

  @override
  Map<String, SphereCoverage> build() => _initial;
}

void main() {
  late MediumRepositoryContext ctx;
  late MockUserService userService;
  late UserDto user;

  setUp(() async {
    ctx = MediumRepositoryContext();
    user = UserFactory.createDto();
    await ctx.newUser(id: user.id);
    userService = MockUserService();
    when(() => userService.tryGetMyUser()).thenReturn(user);
    when(() => userService.watchMyUser()).thenAnswer((_) => const Stream.empty());
  });

  tearDown(() async {
    await ctx.dispose();
  });

  ProviderContainer newContainer({
    bool hasServer = true,
    Set<String> forced = const {},
    Set<String> found = const {},
    Map<String, LocalPanoramaRecord> records = const {},
    Map<String, SphereCoverage> coverages = const {},
  }) {
    final factory = _MockTimelineFactory();
    when(() => factory.groupBy).thenReturn(GroupAssetsBy.day);
    final container = ProviderContainer(
      overrides: [
        driftProvider.overrideWithValue(ctx.db),
        timelineFactoryProvider.overrideWithValue(factory),
        hasServerProvider.overrideWithValue(hasServer),
        currentUserProvider.overrideWith((ref) => CurrentUserProvider(userService)),
        forcedPanoramaAssetsProvider.overrideWith(() => _Forced(forced)),
        foundLocalPanoramaIdsProvider.overrideWith(() => _Found(found)),
        localPanoramaAssetsProvider.overrideWith(() => _Records(records)),
        sphereCoverageOverridesProvider.overrideWith(() => _Coverages(coverages)),
        sphericalProbeServiceProvider.overrideWithValue(
          SphericalProbeService(
            storage: MockStorageRepository(),
            client: () => throw UnimplementedError('no network in these tests'),
            serverEndpoint: () => null,
            headers: () => const {},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// The first view of the list of [container] that [test] accepts
  Future<Panorama360View> viewWhere(ProviderContainer container, bool Function(Panorama360View view) test) {
    container.listen(panorama360ListProvider, (_, _) {});
    return container.read(panorama360ListProvider).views.firstWhere(test).timeout(const Duration(seconds: 5));
  }

  List<String> idsOf(Panorama360View view) => [for (final entry in view.entries) entry.asset.id];

  group('Panorama360FilterNotifier', () {
    test('keeps at least one source, toggles the other chips, and clears back to the default', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(panorama360FilterProvider.notifier);

      notifier.toggleSource(Panorama360Source.server);
      notifier.toggleSource(Panorama360Source.device);
      expect(container.read(panorama360FilterProvider).sources, {Panorama360Source.device});

      notifier.toggleKind(Panorama360Kind.video);
      notifier.toggleTrait(Panorama360Trait.stereo3d);
      notifier.toggleCamera('');
      notifier.setPeriod(const Panorama360Month(2024, 9));
      expect(
        container.read(panorama360FilterProvider),
        const Panorama360Filter(
          period: Panorama360Month(2024, 9),
          sources: {Panorama360Source.device},
          kinds: {Panorama360Kind.video},
          traits: {Panorama360Trait.stereo3d},
          cameras: {''},
        ),
      );

      notifier.toggleCamera('');
      expect(container.read(panorama360FilterProvider).cameras, isEmpty);
      notifier.clear();
      expect(container.read(panorama360FilterProvider).isDefault, isTrue);
    });
  });

  group('panorama360ListProvider', () {
    test('lists the server assets and the device files the scan found, then follows a new forced asset', () async {
      final flagged = await ctx.newRemoteAsset(ownerId: user.id, createdAt: DateTime.utc(2024, 9, 14, 12));
      await ctx.newRemoteExif(assetId: flagged.id, projectionType: 'EQUIRECTANGULAR');
      final later = await ctx.newRemoteAsset(ownerId: user.id, createdAt: DateTime.utc(2024, 9, 10, 12));
      final found = await ctx.newLocalAsset(createdAt: DateTime.utc(2024, 9, 12, 12));
      final container = newContainer(found: {found.id});

      final first = await viewWhere(container, (view) => view.entries.length == 2);
      expect(idsOf(first), [flagged.id, found.id]);

      (container.read(forcedPanoramaAssetsProvider.notifier) as _Forced).keys = {later.id};
      final second = await viewWhere(container, (view) => view.entries.length == 3);
      expect(idsOf(second), [flagged.id, found.id, later.id]);
    });

    test('gives a new view of the same list for a new filter', () async {
      final photo = await ctx.newRemoteAsset(ownerId: user.id);
      await ctx.newRemoteExif(assetId: photo.id, projectionType: 'EQUIRECTANGULAR');
      final video = await ctx.newRemoteAsset(ownerId: user.id, type: AssetType.video);
      await ctx.newRemoteExif(assetId: video.id, projectionType: 'EQUIRECTANGULAR');
      final container = newContainer();
      await viewWhere(container, (view) => view.entries.length == 2);
      final service = container.read(panorama360ListProvider);

      container.read(panorama360FilterProvider.notifier).toggleKind(Panorama360Kind.video);
      final filtered = await viewWhere(container, (view) => view.entries.length == 1);

      expect(idsOf(filtered), [video.id]);
      expect(container.read(panorama360ListProvider), same(service));
    });

    test('lists the device files only without a server', () async {
      final flagged = await ctx.newRemoteAsset(ownerId: user.id);
      await ctx.newRemoteExif(assetId: flagged.id, projectionType: 'EQUIRECTANGULAR');
      final found = await ctx.newLocalAsset();
      final container = newContainer(hasServer: false, found: {found.id});

      final view = await viewWhere(container, (view) => view.entries.isNotEmpty);

      expect(idsOf(view), [found.id]);
    });

    test('reads the database again after a change of the exif', () async {
      final asset = await ctx.newRemoteAsset(ownerId: user.id);
      final container = newContainer();
      final empty = await viewWhere(container, (view) => true);
      expect(empty.entries, isEmpty);

      await ctx.newRemoteExif(assetId: asset.id, projectionType: 'EQUIRECTANGULAR');

      final view = await viewWhere(container, (view) => view.entries.isNotEmpty);
      expect(idsOf(view), [asset.id]);
    });
  });

  group('panorama360TraitsReader', () {
    final traitsReaderProvider = Provider<Panorama360TraitsReader>((ref) => panorama360TraitsReader(ref));

    Panorama360Entry entry(String id, {String? localId, String name = 'a.mp4'}) => Panorama360Entry(
      asset: RemoteAsset(
        id: id,
        localId: localId,
        name: name,
        ownerId: 'me',
        checksum: 'checksum-$id',
        type: AssetType.video,
        createdAt: DateTime(2024, 9, 14),
        updatedAt: DateTime(2024, 9, 14),
        width: 4096,
        height: 2048,
        isEdited: false,
      ),
      day: DateTime(2024, 9, 14),
    );

    test('takes the coverage the user picked, under the server id or the id on the device', () {
      final container = newContainer(coverages: {'r1': SphereCoverage.half, 'local-2': SphereCoverage.half});
      final traitsOf = container.read(traitsReaderProvider);

      expect(traitsOf(entry('r1')), {Panorama360Trait.stereo3d, Panorama360Trait.vr180});
      expect(traitsOf(entry('r2', localId: 'local-2')), {Panorama360Trait.stereo3d, Panorama360Trait.vr180});
      expect(traitsOf(entry('r3')), isEmpty);
    });

    test('takes what the scan of the device read', () {
      final container = newContainer(
        records: {
          'local-1': LocalPanoramaRecord(isPanorama: true, halfSphere: true, checkedAt: DateTime(2024)),
          'local-2': LocalPanoramaRecord(isPanorama: true, raw360: true, checkedAt: DateTime(2024)),
        },
      );
      final traitsOf = container.read(traitsReaderProvider);

      expect(traitsOf(entry('r1', localId: 'local-1')), {Panorama360Trait.stereo3d, Panorama360Trait.vr180});
      expect(
        traitsOf(entry('r2', localId: 'local-2', name: 'trip_180.mp4')),
        isEmpty,
        reason: 'a raw file',
      );
    });
  });
}
