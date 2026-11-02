// The plan of a selection for a splat scene (plan 2026-11-01, sections 2.1 and 4.1, lot SP7), before anything runs:
// the refusals (fewer than 20 photos, photos and a video together, several videos, a video under 10 s or over 5 min,
// a 360° video, a video that cannot be reached), the photos left out with their reason, 200 photos at most spread
// evenly in time, the warning under 50 photos, the lenses, the folders, the name proposed, the folder the scene goes
// to, the frames of a video and the time on this computer.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/destination.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/ai/ui/splat_plan.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:path/path.dart' as p;

LocalAsset _asset(String name, {AssetType type = AssetType.image, DateTime? taken, int? durationMs}) => LocalAsset(
  id: 'id-$name',
  name: name,
  type: type,
  createdAt: taken ?? DateTime(2026, 10, 20, 9),
  updatedAt: DateTime(2026, 10, 20, 9),
  width: 4000,
  height: 3000,
  durationMs: durationMs,
  playbackStyle: type == AssetType.video ? AssetPlaybackStyle.video : AssetPlaybackStyle.image,
  isEdited: false,
);

/// A photo of the folder [folder] of the library, taken [minute] minutes after 9:00
SplatCandidate _photo(
  String name, {
  String folder = '/photos/salon',
  int minute = 0,
  ConversionPhotoFacts facts = const ConversionPhotoFacts(),
  int? focal35,
  bool server = false,
  bool reachable = true,
}) {
  final asset = _asset(name, taken: DateTime(2026, 10, 20, 9, minute));
  final path = p.posix.join(folder, name);
  return SplatCandidate(
    asset: asset,
    facts: facts,
    focal35: focal35,
    found: !reachable
        ? null
        : server
        ? (location: ServerOriginal(name: name), source: LocalFileSource('/tmp/copy/$name'))
        : (
            location: LibraryOriginal(
              name: name,
              path: path,
              rootId: 'local:/photos',
              rootPath: '/photos',
              rootIsNetwork: false,
            ),
            source: LocalFileSource(path),
          ),
  );
}

SplatCandidate _video(String name, Duration duration, {bool is360 = false, bool reachable = true}) {
  final path = '/videos/$name';
  return SplatCandidate(
    asset: _asset(name, type: AssetType.video, durationMs: duration.inMilliseconds),
    isVideo360: is360,
    found: reachable
        ? (
            location: LibraryOriginal(
              name: name,
              path: path,
              rootId: 'local:/videos',
              rootPath: '/videos',
              rootIsNetwork: false,
            ),
            source: LocalFileSource(path),
          )
        : null,
  );
}

List<SplatCandidate> _photos(int count, {String folder = '/photos/salon', int from = 0}) => [
  for (var index = 0; index < count; index++)
    _photo('IMG_${(from + index).toString().padLeft(4, '0')}.jpg', folder: folder, minute: from + index),
];

void main() {
  group('the refusals before anything runs', () {
    test('fewer than 20 photos, but 20 are enough', () {
      final few = planSplatSelection(_photos(19), linux: false);
      expect(few.refusal, SplatRefusal.tooFewPhotos);
      expect(few.usable, 19);

      final enough = planSplatSelection(_photos(20), linux: false);
      expect(enough.refusal, isNull);
      expect(enough.used, hasLength(20));
    });

    test('photos left out count against the 20: 25 photos, 6 of them 360°, leave 19', () {
      final candidates = [
        ..._photos(19),
        for (var index = 0; index < 6; index++)
          _photo('PANO_$index.jpg', facts: const ConversionPhotoFacts(isPanorama: true)),
      ];
      final plan = planSplatSelection(candidates, linux: false);
      expect(plan.refusal, SplatRefusal.tooFewPhotos);
      expect(plan.leftOut, {SplatLeftOutReason.sphere360: 6});
    });

    test('photos and a video together, several videos', () {
      final mixed = planSplatSelection([..._photos(30), _video('salon.mp4', const Duration(minutes: 1))], linux: false);
      expect(mixed.refusal, SplatRefusal.mixed);

      final two = planSplatSelection([
        _video('a.mp4', const Duration(minutes: 1)),
        _video('b.mp4', const Duration(minutes: 1)),
      ], linux: false);
      expect(two.refusal, SplatRefusal.severalVideos);
    });

    test('a video of 9 s, of more than 5 min, a 360° one, one that cannot be reached; 10 s and 5 min are taken', () {
      SplatRefusal? refusalOf(SplatCandidate video) => planSplatSelection([video], linux: false).refusal;

      expect(refusalOf(_video('short.mp4', const Duration(seconds: 9))), SplatRefusal.videoShort);
      expect(refusalOf(_video('ten.mp4', const Duration(seconds: 10))), isNull);
      expect(refusalOf(_video('five.mp4', const Duration(minutes: 5))), isNull);
      expect(refusalOf(_video('long.mp4', const Duration(minutes: 5, seconds: 1))), SplatRefusal.videoLong);
      expect(refusalOf(_video('VID_360.insv', const Duration(minutes: 1), is360: true)), SplatRefusal.video360);
      expect(
        refusalOf(_video('gone.mp4', const Duration(minutes: 1), reachable: false)),
        SplatRefusal.videoUnreachable,
      );
    });

    test('a video whose length is not known is not refused for it: the frames are counted as for two minutes', () {
      // The library of the computer and the sync of the server store 0 for a length they could not read (a MKV, an
      // AVI, a file kept online only by OneDrive), never null
      for (final durationMs in [null, 0]) {
        final video = SplatCandidate(
          asset: _asset('clip.mkv', type: AssetType.video, durationMs: durationMs),
          found: (
            location: const OpenedOriginal(name: 'clip.mkv', path: '/videos/clip.mkv'),
            source: LocalFileSource('/videos/clip.mkv'),
          ),
        );
        final plan = planSplatSelection([video], linux: false);
        expect(plan.refusal, isNull, reason: 'durationMs: $durationMs');
        expect(plan.videoDuration, isNull, reason: 'durationMs: $durationMs');
        expect(plan.images, SplatV1.videoFrames, reason: 'durationMs: $durationMs');
      }
    });

    test('nothing to take: a selection of no photo and no video', () {
      expect(planSplatSelection(const [], linux: false).refusal, SplatRefusal.nothing);
    });
  });

  test('the photos left out, each with its reason, in the order of the reasons', () {
    final candidates = [
      ..._photos(30),
      _photo('PANO.jpg', facts: const ConversionPhotoFacts(isPanorama: true)),
      _photo('RAW.insp', facts: const ConversionPhotoFacts(isRaw360: true)),
      _photo('salon.heic'),
      _photo('salon_3D_LRF_Full_SBS.jpg', facts: const ConversionPhotoFacts(isStereo: true)),
      _photo(
        'salon_scene3D.jpg',
        facts: const ConversionPhotoFacts(
          version: (origin: IndexedOrigin.reconstructed, kind: ImmersiveKind.volumetricScene),
        ),
      ),
      _photo('spatial.heic', facts: const ConversionPhotoFacts(isSpatial: true)),
      _photo('gone.jpg', reachable: false),
    ];
    final onLinux = planSplatSelection(candidates, linux: true);
    expect(onLinux.leftOut, {
      SplatLeftOutReason.sphere360: 2,
      SplatLeftOutReason.unreadable: 2,
      SplatLeftOutReason.threeD: 1,
      SplatLeftOutReason.aiVersion: 1,
      SplatLeftOutReason.unreachable: 1,
    });
    expect(onLinux.usable, 30);
    // A spatial photo is two eyes of HEIF: on Linux it cannot be read at all, elsewhere it is left out as 3D
    final elsewhere = planSplatSelection(candidates, linux: false);
    expect(elsewhere.leftOut[SplatLeftOutReason.unreadable], isNull);
    expect(elsewhere.leftOut[SplatLeftOutReason.threeD], 2);
    expect(elsewhere.usable, 31, reason: 'salon.heic is read on Windows and macOS');
  });

  test('200 photos at most, spread evenly in time: the first and the last kept, in the order of their time', () {
    // Taken in the reverse order of their names: the plan goes by the time
    final candidates = [
      for (var index = 0; index < 512; index++)
        _photo('IMG_${index.toString().padLeft(4, '0')}.jpg', minute: 600 - index),
    ];
    final plan = planSplatSelection(candidates, linux: false);
    expect(plan.refusal, isNull);
    expect(plan.usable, 512);
    expect(plan.capped, isTrue);
    expect(plan.used, hasLength(SplatV1.maxPhotos));
    expect(plan.used.first.asset.name, 'IMG_0511.jpg');
    expect(plan.used.last.asset.name, 'IMG_0000.jpg');
    final times = [for (final candidate in plan.used) candidate.asset.createdAt];
    expect(times, orderedEquals([...times]..sort()));
    expect(plan.images, SplatV1.maxPhotos);

    final spread = spreadEvenly([for (var index = 0; index < 512; index++) index], 200);
    expect(spread, hasLength(200));
    expect(spread.first, 0);
    expect(spread.last, 511);
    final gaps = {for (var index = 1; index < spread.length; index++) spread[index] - spread[index - 1]};
    expect(gaps, {2, 3});
    expect(spreadEvenly([1, 2, 3], 200), [1, 2, 3]);
  });

  test('a warning, not a refusal, from 20 to 49 photos', () {
    expect(planSplatSelection(_photos(20), linux: false).fewPhotos, isTrue);
    expect(planSplatSelection(_photos(49), linux: false).fewPhotos, isTrue);
    expect(planSplatSelection(_photos(50), linux: false).fewPhotos, isFalse);
    expect(planSplatSelection(_photos(12), linux: false).fewPhotos, isFalse, reason: 'refused, not warned');
  });

  test('the lenses of the photos, the one that took the most first; one lens says nothing', () {
    final candidates = [
      for (var index = 0; index < 30; index++)
        _photo('IMG_$index.jpg', minute: index, focal35: index < 20 ? 26 : (index < 28 ? 13 : null)),
    ];
    expect(planSplatSelection(candidates, linux: false).lenses, [26, 13]);
    expect(planSplatSelection(_photos(30), linux: false).lenses, isEmpty);
    final one = [for (var index = 0; index < 30; index++) _photo('IMG_$index.jpg', minute: index, focal35: 26)];
    expect(planSplatSelection(one, linux: false).lenses, isEmpty);
  });

  group('the name and the folder', () {
    test('photos of one folder: its name, and the scene goes there', () {
      final plan = planSplatSelection(_photos(30), linux: false);
      expect(plan.folders, 1);
      expect(plan.defaultName, 'salon');
      expect((plan.destination!.found!.location as LibraryOriginal).path, '/photos/salon/IMG_0000.jpg');
    });

    test('photos of several folders: the first photo in time names it, the folder that holds the most takes it', () {
      final candidates = [..._photos(10, folder: '/photos/garden', from: 0), ..._photos(25, from: 10)];
      final plan = planSplatSelection(candidates, linux: false);
      expect(plan.folders, 2);
      expect(plan.defaultName, 'IMG_0000');
      expect(p.posix.dirname((plan.destination!.found!.location as LibraryOriginal).path), '/photos/salon');
    });

    test('photos of the server: one place, named by the first photo, the folder of my choice', () {
      final candidates = [for (var index = 0; index < 30; index++) _photo('S_$index.jpg', minute: index, server: true)];
      final plan = planSplatSelection(candidates, linux: false);
      expect(plan.folders, 1);
      expect(plan.defaultName, 'S_0');
      expect(plan.destination!.found!.location, isA<ServerOriginal>());
    });

    test('a video: its name, and its folder', () {
      final plan = planSplatSelection([
        _video('Salon tour.mp4', const Duration(minutes: 1, seconds: 51)),
      ], linux: false);
      expect(plan.isVideo, isTrue);
      expect(plan.defaultName, 'Salon tour');
      expect((plan.destination!.found!.location as LibraryOriginal).path, '/videos/Salon tour.mp4');
      expect(plan.videoDuration, const Duration(minutes: 1, seconds: 51));
    });

    test('the place of the scene is named by the name chosen, so that its file is <name>_splat.spz', () {
      const library = LibraryOriginal(
        name: 'IMG_0001.jpg',
        path: '/photos/salon/IMG_0001.jpg',
        rootId: 'net-//nas/photos:/',
        rootPath: '/photos',
        rootIsNetwork: true,
        cloudOnly: true,
      );
      final named = splatNamedLocation(library, 'St. Paul') as LibraryOriginal;
      expect(named.name, 'St. Paul');
      expect(named.path, library.path);
      expect(named.rootId, library.rootId);
      expect(named.rootIsNetwork, isTrue);
      expect(named.cloudOnly, isTrue);
      expect(
        DestinationJob(id: 'splat', original: named, kind: ImmersiveKind.gaussianSplat).finalName,
        'St. Paul_splat.spz',
      );
      expect(
        splatNamedLocation(const OpenedOriginal(name: 'a.mp4', path: '/v/a.mp4'), 'salon'),
        isA<OpenedOriginal>().having((location) => location.name, 'name', 'salon'),
      );
      expect(splatNamedLocation(const ServerOriginal(name: 'a.jpg'), 'salon').name, 'salon');
    });
  });

  test('the frames of a video: 150 up to two minutes, one every 0.8 s after, 250 at most', () {
    expect(splatVideoFrameCount(const Duration(seconds: 30)), 150);
    expect(splatVideoFrameCount(const Duration(minutes: 2)), 150);
    expect(splatVideoFrameCount(const Duration(minutes: 3)), 225);
    expect(splatVideoFrameCount(const Duration(minutes: 5)), 250);
    final plan = planSplatSelection([_video('salon.mp4', const Duration(minutes: 3))], linux: false);
    expect(plan.images, 225);
  });

  test('the time on this computer: the poses follow the images and the pairs, the training stays', () {
    const timings = AiTimings();
    final photos = splatTimeOf(timings, images: 150, video: false);
    // The times of aiDefaultTimings are those of 150 photos: 5 + 45 + 15 + 195 + 50 s of poses, 450 s of training
    expect(photos.poses, const Duration(seconds: 310));
    expect(photos.training, const Duration(seconds: 450));
    expect(photos.total, const Duration(seconds: 771));

    final half = splatTimeOf(timings, images: 75, video: false);
    expect(half.training, photos.training);
    // A quarter of the pairs, half of the rest
    expect(half.poses.inMilliseconds, closeTo(115000 / 2 + 195000 * 75 * 74 / (150 * 149), 1));

    final video = splatTimeOf(timings, images: 150, video: true);
    expect(video.poses, const Duration(seconds: 191));
    expect(video.training, const Duration(seconds: 306));
    expect(video.total, const Duration(seconds: 508));

    // What this computer measured replaces the defaults
    final measured = splatTimeOf(
      const AiTimings({
        'splatScene': {'training': 600000},
      }),
      images: 150,
      video: false,
    );
    expect(measured.training, const Duration(minutes: 10));
  });
}
