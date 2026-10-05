import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/panorama_360.model.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/panorama_360_list.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

const _me = 'me';
const _partner = 'partner';

var _ids = 0;

RemoteAsset _remote({
  String? id,
  String? name,
  String ownerId = _me,
  String? checksum,
  AssetType type = AssetType.image,
  int? width,
  int? height,
  DateTime? createdAt,
  String? localId,
}) {
  final assetId = id ?? 'r${_ids++}';
  return RemoteAsset(
    id: assetId,
    name: name ?? 'remote_$assetId.jpg',
    ownerId: ownerId,
    checksum: checksum ?? 'checksum-$assetId',
    type: type,
    createdAt: createdAt ?? DateTime(2024, 9, 14, 12),
    updatedAt: DateTime(2024, 9, 14, 12),
    width: width,
    height: height,
    localId: localId,
    isEdited: false,
  );
}

LocalAsset _local({
  String? id,
  String? name,
  String? checksum,
  AssetType type = AssetType.image,
  int? width,
  int? height,
  DateTime? createdAt,
}) {
  final assetId = id ?? 'l${_ids++}';
  return LocalAsset(
    id: assetId,
    name: name ?? 'local_$assetId.jpg',
    checksum: checksum,
    type: type,
    createdAt: createdAt ?? DateTime(2024, 9, 14, 12),
    updatedAt: DateTime(2024, 9, 14, 12),
    width: width,
    height: height,
    playbackStyle: type == AssetType.video ? AssetPlaybackStyle.video : AssetPlaybackStyle.image,
    isEdited: false,
  );
}

Panorama360Entry _entry(BaseAsset asset, {DateTime? day, bool isOwn = true, String? make, String? model}) =>
    Panorama360Entry(asset: asset, day: day ?? DateTime(2024, 9, 14), isOwn: isOwn, make: make, model: model);

Set<Panorama360Trait> _noTraits(Panorama360Entry entry) => const {};

void main() {
  group('mergePanorama360Candidates', () {
    test('keeps one entry per checksum, the own server copy first, then the device copy, then a shared one', () {
      final shared1 = _entry(_remote(ownerId: _partner, checksum: 'c1'), isOwn: false);
      final device1 = _entry(_local(checksum: 'c1'));
      final own1 = _entry(_remote(checksum: 'c1'));
      final shared2 = _entry(_remote(ownerId: _partner, checksum: 'c2'), isOwn: false);
      final device2 = _entry(_local(checksum: 'c2'));
      final unknown1 = _entry(_local());
      final unknown2 = _entry(_local());

      final merged = mergePanorama360Candidates([shared1, device1, own1, shared2, device2, unknown1, unknown2]);

      expect(merged, unorderedEquals([own1, device2, unknown1, unknown2]));
    });

    test('keeps the first copy of each kind in input order', () {
      final first = _entry(_remote(checksum: 'c1'));
      final second = _entry(_remote(checksum: 'c1'));

      expect(mergePanorama360Candidates([first, second]), [first]);
    });

    test('hides the second lens of a split recording when its first lens is listed by the same owner', () {
      final firstLens = _entry(_remote(name: 'VID_20240914_175112_00_027.insv'));
      final secondLens = _entry(_remote(name: 'VID_20240914_175112_10_027.insv'));
      final alone = _entry(_remote(name: 'VID_20240914_175112_10_028.insv'));
      final partnerFirstLens = _entry(
        _remote(name: 'VID_20240914_175112_00_029.insv', ownerId: _partner),
        isOwn: false,
      );
      final ownSecondLens = _entry(_remote(name: 'VID_20240914_175112_10_029.insv'));
      final upperFirstLens = _entry(_local(name: 'VID_20240914_175112_00_030.INSV', checksum: 'u0'));
      final upperSecondLens = _entry(_local(name: 'vid_20240914_175112_10_030.insv', checksum: 'u1'));

      final merged = mergePanorama360Candidates([
        secondLens,
        firstLens,
        alone,
        partnerFirstLens,
        ownSecondLens,
        upperSecondLens,
        upperFirstLens,
      ]);

      expect(merged, unorderedEquals([firstLens, alone, partnerFirstLens, ownSecondLens, upperFirstLens]));
    });

    test('orders the newest day first, then the newest instant, then by hero tag', () {
      final older = _entry(
        _remote(id: 'a', createdAt: DateTime(2024, 9, 12, 23)),
        day: DateTime(2024, 9, 12),
      );
      // Taken before [older], but on a later day of its own (a local date time set on the server): the day wins
      final laterDay = _entry(
        _remote(id: 'b', createdAt: DateTime(2024, 9, 12, 8)),
        day: DateTime(2024, 9, 13),
      );
      final morning = _entry(_remote(id: 'c', createdAt: DateTime(2024, 9, 14, 8)));
      final evening = _entry(_remote(id: 'd', createdAt: DateTime(2024, 9, 14, 20)));
      final sameInstantA = _entry(_remote(id: 'e', createdAt: DateTime(2024, 9, 14, 12)));
      final sameInstantB = _entry(_remote(id: 'f', createdAt: DateTime(2024, 9, 14, 12)));

      final merged = mergePanorama360Candidates([older, morning, sameInstantA, laterDay, evening, sameInstantB]);

      expect(merged, [evening, sameInstantB, sameInstantA, morning, laterDay, older]);
    });
  });

  group('panorama360Buckets', () {
    final entries = [
      _entry(_remote(), day: DateTime(2024, 9, 14)),
      _entry(_remote(), day: DateTime(2024, 9, 14)),
      _entry(_remote(), day: DateTime(2024, 9, 12)),
      _entry(_remote(), day: DateTime(2024, 8, 30)),
    ];

    test('one bucket per day, newest first', () {
      expect(panorama360Buckets(entries.sublist(0, 3), GroupAssetsBy.day), [
        TimeBucket(date: DateTime(2024, 9, 14), assetCount: 2),
        TimeBucket(date: DateTime(2024, 9, 12), assetCount: 1),
      ]);
      expect(panorama360Buckets(entries.sublist(0, 3), GroupAssetsBy.auto), [
        TimeBucket(date: DateTime(2024, 9, 14), assetCount: 2),
        TimeBucket(date: DateTime(2024, 9, 12), assetCount: 1),
      ]);
    });

    test('one bucket per month, dated the first of the month', () {
      expect(panorama360Buckets(entries, GroupAssetsBy.month), [
        TimeBucket(date: DateTime(2024, 9), assetCount: 3),
        TimeBucket(date: DateTime(2024, 8), assetCount: 1),
      ]);
    });

    test('a single bucket without grouping, none for no entry', () {
      final buckets = panorama360Buckets(entries, GroupAssetsBy.none);
      expect(buckets, hasLength(1));
      expect(buckets.single, isNot(isA<TimeBucket>()));
      expect(buckets.single.assetCount, 4);
      for (final groupBy in GroupAssetsBy.values) {
        expect(panorama360Buckets(const [], groupBy), isEmpty, reason: groupBy.name);
      }
    });
  });

  group('matchesPanorama360Filter', () {
    bool matches(
      Panorama360Entry entry,
      Panorama360Filter filter, {
      bool hasServer = true,
      Set<Panorama360Trait> traits = const {},
    }) => matchesPanorama360Filter(entry, filter, hasServer: hasServer, traits: traits);

    test('a year, a month and a range of days, both ends included', () {
      Panorama360Entry on(int month, int day) => _entry(_remote(), day: DateTime(2024, month, day));
      final range = Panorama360Filter(
        period: Panorama360Range(DateTime(2024, 9, 14, 18, 30), DateTime(2024, 9, 20, 6)),
      );

      expect(matches(on(9, 14), const Panorama360Filter(period: Panorama360Year(2024))), isTrue);
      expect(matches(on(9, 14), const Panorama360Filter(period: Panorama360Year(2023))), isFalse);
      expect(matches(on(9, 14), const Panorama360Filter(period: Panorama360Month(2024, 9))), isTrue);
      expect(matches(on(8, 31), const Panorama360Filter(period: Panorama360Month(2024, 9))), isFalse);
      expect(matches(on(9, 13), range), isFalse);
      expect(matches(on(9, 14), range), isTrue);
      expect(matches(on(9, 20), range), isTrue);
      expect(matches(on(9, 21), range), isFalse);
      expect(
        matchesPanorama360Filter(
          on(8, 31),
          const Panorama360Filter(period: Panorama360Month(2024, 9)),
          hasServer: true,
          traits: const {},
          ignorePeriod: true,
        ),
        isTrue,
      );
    });

    test('sources: an uploaded asset with a copy on the device is on the server and on this device; a partner asset '
        'is shared only; sources are ignored without a server', () {
      final uploaded = _entry(_remote(localId: 'l1'));
      final serverOnly = _entry(_remote());
      final deviceOnly = _entry(_local());
      final partner = _entry(_remote(ownerId: _partner), isOwn: false);
      const onServer = Panorama360Filter(sources: {Panorama360Source.server});
      const onDevice = Panorama360Filter(sources: {Panorama360Source.device});
      const shared = Panorama360Filter(sources: {Panorama360Source.shared});

      expect(uploaded.sources, {Panorama360Source.server, Panorama360Source.device});
      expect(partner.sources, {Panorama360Source.shared});
      expect(matches(uploaded, onServer), isTrue);
      expect(matches(uploaded, onDevice), isTrue);
      expect(matches(uploaded, shared), isFalse);
      expect(matches(serverOnly, onDevice), isFalse);
      expect(matches(deviceOnly, onServer), isFalse);
      expect(matches(deviceOnly, onDevice), isTrue);
      expect(matches(partner, const Panorama360Filter()), isFalse);
      expect(matches(partner, shared), isTrue);
      expect(matches(partner, onDevice, hasServer: false), isTrue);
      expect(matches(serverOnly, onDevice, hasServer: false), isTrue);
    });

    test('photos and videos, both or none selected letting everything through', () {
      final photo = _entry(_remote());
      final video = _entry(_remote(type: AssetType.video));
      const photos = Panorama360Filter(kinds: {Panorama360Kind.photo});
      const videos = Panorama360Filter(kinds: {Panorama360Kind.video});
      const both = Panorama360Filter(kinds: {Panorama360Kind.photo, Panorama360Kind.video});

      expect(matches(photo, photos), isTrue);
      expect(matches(video, photos), isFalse);
      expect(matches(photo, videos), isFalse);
      expect(matches(video, videos), isTrue);
      for (final filter in [both, const Panorama360Filter()]) {
        expect(matches(photo, filter), isTrue);
        expect(matches(video, filter), isTrue);
      }
    });

    test('3D and VR180 match on either trait', () {
      final entry = _entry(_remote());
      const both = Panorama360Filter(traits: {Panorama360Trait.stereo3d, Panorama360Trait.vr180});
      const stereo = Panorama360Filter(traits: {Panorama360Trait.stereo3d});

      expect(matches(entry, both, traits: {Panorama360Trait.vr180}), isTrue);
      expect(matches(entry, both, traits: {Panorama360Trait.stereo3d}), isTrue);
      expect(matches(entry, both), isFalse);
      expect(matches(entry, stereo, traits: {Panorama360Trait.vr180}), isFalse);
      expect(matches(entry, const Panorama360Filter()), isTrue);
    });

    test('cameras by key, the unknown camera included', () {
      final x3 = _entry(_remote(), make: 'Arashi Vision', model: 'Insta360 X3');
      final unknown = _entry(_remote());
      final goPro = _entry(_remote(), make: 'GoPro', model: 'GoPro MAX');
      const filter = Panorama360Filter(cameras: {'insta360 x3', ''});

      expect(matches(x3, filter), isTrue);
      expect(matches(unknown, filter), isTrue);
      expect(matches(goPro, filter), isFalse);
      expect(matchesPanorama360Filter(goPro, filter, hasServer: true, traits: const {}, ignoreCameras: true), isTrue);
    });
  });

  group('buildPanorama360View', () {
    final x3Photo = _entry(_remote(), day: DateTime(2024, 9, 14), make: 'Arashi Vision', model: 'Insta360 X3');
    final goProPhoto = _entry(_remote(), day: DateTime(2024, 9, 10), make: 'GoPro', model: 'GoPro MAX');
    final x3Video = _entry(
      _remote(type: AssetType.video),
      day: DateTime(2024, 8, 1),
      make: 'Arashi Vision',
      model: 'Insta360 X3',
    );
    final unknown = _entry(_local(), day: DateTime(2023, 5, 5));
    final partner = _entry(_remote(ownerId: _partner), day: DateTime(2022, 1, 2), isOwn: false);
    final candidates = [x3Photo, goProPhoto, x3Video, unknown, partner];

    Panorama360View build(Panorama360Filter filter, {bool hasServer = true}) =>
        buildPanorama360View(candidates, filter, hasServer: hasServer, traitsOf: _noTraits, groupBy: GroupAssetsBy.day);

    test('counts the cameras without the camera filter and the months without the period filter', () {
      final view = build(const Panorama360Filter(period: Panorama360Month(2024, 9), cameras: {'insta360 x3'}));

      expect(view.entries, [x3Photo]);
      expect(view.buckets, [TimeBucket(date: DateTime(2024, 9, 14), assetCount: 1)]);
      expect(view.facets.cameras, [
        (key: 'gopro max', label: 'GoPro MAX', count: 1),
        (key: 'insta360 x3', label: 'Insta360 X3', count: 1),
      ]);
      expect(view.facets.months, {
        2024: {9: 1, 8: 1},
      });
      expect(view.facets.months.keys, [2024]);
      expect(view.facets.months[2024]!.keys, [9, 8]);
    });

    test('puts the unknown camera last, and the most used camera first', () {
      final view = build(const Panorama360Filter());

      expect(view.facets.cameras, [
        (key: 'insta360 x3', label: 'Insta360 X3', count: 2),
        (key: 'gopro max', label: 'GoPro MAX', count: 1),
        (key: '', label: '', count: 1),
      ]);
      expect(view.facets.months.keys, [2024, 2023]);
    });

    test('lists a selected camera that has no media left, with a count of 0', () {
      final view = build(
        const Panorama360Filter(kinds: {Panorama360Kind.video}, cameras: {'gopro max', 'ricoh theta z1'}),
      );

      expect(view.entries, isEmpty);
      expect(view.buckets, isEmpty);
      expect(view.facets.cameras, [
        (key: 'insta360 x3', label: 'Insta360 X3', count: 1),
        (key: 'gopro max', label: 'GoPro MAX', count: 0),
        (key: 'ricoh theta z1', label: 'ricoh theta z1', count: 0),
      ]);
    });

    test('reports the first and last day and the sources of all candidates', () {
      final view = build(const Panorama360Filter(period: Panorama360Year(2024)));

      expect(view.facets.total, 5);
      expect(view.facets.firstDay, DateTime(2022, 1, 2));
      expect(view.facets.lastDay, DateTime(2024, 9, 14));
      expect(view.facets.availableSources, {
        Panorama360Source.server,
        Panorama360Source.device,
        Panorama360Source.shared,
      });
      expect(view.entries, [x3Photo, goProPhoto, x3Video]);
    });

    test('lists the shared media without a server whatever the sources', () {
      expect(build(const Panorama360Filter()).entries, isNot(contains(partner)));
      expect(build(const Panorama360Filter(), hasServer: false).entries, contains(partner));
    });

    test('asks the traits of each candidate once', () {
      final asked = <Panorama360Entry>[];
      final view = buildPanorama360View(
        candidates,
        const Panorama360Filter(traits: {Panorama360Trait.vr180}),
        hasServer: true,
        traitsOf: (entry) {
          asked.add(entry);
          return entry == goProPhoto ? const {Panorama360Trait.vr180} : const {};
        },
        groupBy: GroupAssetsBy.day,
      );

      expect(view.entries, [goProPhoto]);
      expect(asked, candidates);
    });
  });

  group('panorama360CameraOf', () {
    test('reads the make and the model, with the aliases of the makers', () {
      expect(panorama360CameraOf(make: 'Arashi Vision', model: 'Insta360 X3', fileName: 'a.insp'), (
        key: 'insta360 x3',
        label: 'Insta360 X3',
      ));
      expect(panorama360CameraOf(make: 'GoPro', model: 'GoPro MAX', fileName: 'a.mp4'), (
        key: 'gopro max',
        label: 'GoPro MAX',
      ));
      expect(panorama360CameraOf(make: 'RICOH', model: 'THETA Z1', fileName: 'a.jpg'), (
        key: 'ricoh theta z1',
        label: 'RICOH THETA Z1',
      ));
      expect(panorama360CameraOf(model: 'Insta360 X4', fileName: 'a.jpg'), (key: 'insta360 x4', label: 'Insta360 X4'));
      expect(panorama360CameraOf(make: 'DJI', fileName: 'a.jpg'), (key: 'dji', label: 'DJI'));
    });

    test('names a raw file without exif after its brand, anything else the unknown camera', () {
      expect(panorama360CameraOf(fileName: 'VID_1.insv'), (key: 'insta360', label: 'Insta360'));
      expect(panorama360CameraOf(fileName: 'IMG_1.INSP'), (key: 'insta360', label: 'Insta360'));
      expect(panorama360CameraOf(fileName: 'GS010013.360'), (key: 'gopro', label: 'GoPro'));
      expect(panorama360CameraOf(fileName: 'CAM_20250715191201_0003_D.OSV'), (key: 'dji', label: 'DJI'));
      expect(panorama360CameraOf(fileName: 'a.mp4'), (key: '', label: ''));
      expect(panorama360CameraOf(make: '  ', model: '', fileName: 'a.mp4'), (key: '', label: ''));
      expect(panorama360CameraOf(make: ' ', model: ' Insta360 X4 ', fileName: 'a.mp4'), (
        key: 'insta360 x4',
        label: 'Insta360 X4',
      ));
    });
  });

  group('panorama360TraitsOf', () {
    Panorama360Entry media(String name, int width, int height, {AssetType type = AssetType.video}) =>
        _entry(_remote(name: name, width: width, height: height, type: type));

    test('follows the guesses of the viewers from the name and the frame shape', () {
      expect(panorama360TraitsOf(media('a.jpg', 4000, 4000, type: AssetType.image)), {Panorama360Trait.stereo3d});
      expect(panorama360TraitsOf(media('trip_180.mp4', 4096, 2048)), {
        Panorama360Trait.stereo3d,
        Panorama360Trait.vr180,
      });
      expect(panorama360TraitsOf(media('a.mp4', 4096, 2048)), isEmpty);
    });

    test('takes the coverage the user picked, then the one the scan read', () {
      expect(panorama360TraitsOf(media('trip_180.mp4', 4096, 2048), chosenCoverage: SphereCoverage.full), isEmpty);
      expect(panorama360TraitsOf(media('a.mp4', 2048, 2048), recordHalfSphere: true), {Panorama360Trait.vr180});
      expect(
        panorama360TraitsOf(media('trip_180.mp4', 4096, 2048), recordHalfSphere: false),
        isEmpty,
        reason: 'the file says full sphere',
      );
    });

    test('takes what the probe in memory read', () {
      const probe = SphericalProbe(stereo: StereoLayout.leftRight, halfSphere: false, hasSphericalMetadata: true);
      expect(panorama360TraitsOf(media('a.mp4', 4096, 2048), probe: probe), {Panorama360Trait.stereo3d});
    });

    test('gives a raw file neither trait', () {
      expect(panorama360TraitsOf(media('VID_1.insv', 5760, 2880)), isEmpty);
      expect(panorama360TraitsOf(media('VID_180.insv', 2880, 2880)), isEmpty);
      expect(panorama360TraitsOf(media('a.mp4', 4096, 2048), recordRaw: true), isEmpty);
      expect(panorama360TraitsOf(media('trip_180.mp4', 4096, 2048), recordRaw: true), isEmpty);
    });
  });

  group('Panorama360Filter', () {
    test('is the default until a chip is picked, and compares by value', () {
      expect(const Panorama360Filter().isDefault, isTrue);
      expect(const Panorama360Filter(kinds: {Panorama360Kind.photo}).isDefault, isFalse);
      expect(const Panorama360Filter(sources: {Panorama360Source.server}).isDefault, isFalse);
      expect(
        const Panorama360Filter().copyWith(period: () => const Panorama360Year(2024)),
        const Panorama360Filter(period: Panorama360Year(2024)),
      );
      expect(
        const Panorama360Filter(period: Panorama360Year(2024)).copyWith(period: () => null),
        const Panorama360Filter(),
      );
      expect(
        Panorama360Range(DateTime(2024, 9, 14, 10), DateTime(2024, 9, 15, 23)),
        Panorama360Range(DateTime(2024, 9, 14), DateTime(2024, 9, 15)),
      );
    });
  });
}
