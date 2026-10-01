import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/spatial_media.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/generated/translations.g.dart';

import '../../unit/factories/remote_asset_factory.dart';
import '../../utils.dart';

void main() {
  group('guessSpatialLayout for a flat video', () {
    test('takes a frame twice as wide as a regular one for two full eyes side by side', () {
      for (final (width, height) in [(3840, 1080), (3840, 1200), (4096, 1080), (2560, 720), (7680, 2160)]) {
        expect(
          guessSpatialLayout(width: width, height: height),
          SpatialStereoLayout.sideBySide,
          reason: '$width x $height',
        );
      }
    });

    test('takes a frame a little taller than wide for two full eyes stacked', () {
      for (final (width, height) in [(1920, 2160), (1280, 1440), (3840, 4320), (1900, 2000)]) {
        expect(
          guessSpatialLayout(width: width, height: height),
          SpatialStereoLayout.topBottom,
          reason: '$width x $height',
        );
      }
    });

    test('says auto for regular frames, portrait 4:5 videos included', () {
      for (final (width, height) in [
        (1920, 1080),
        (1080, 1920),
        (1080, 1350),
        (1440, 1080),
        (1080, 1080),
        (5120, 1080),
      ]) {
        expect(
          guessSpatialLayout(width: width, height: height),
          SpatialStereoLayout.auto,
          reason: '$width x $height',
        );
      }
    });

    test('says auto for unknown or empty dimensions', () {
      for (final (width, height) in [(null, null), (3840, null), (null, 1080), (0, 0), (3840, 0), (-3840, -1080)]) {
        expect(
          guessSpatialLayout(width: width, height: height),
          SpatialStereoLayout.auto,
          reason: '$width x $height',
        );
      }
    });

    test('reads side by side from the words of the file name, in any case', () {
      for (final name in [
        'Avatar.SBS.mkv',
        'trip_hsbs.mp4',
        'Concert-3D-SBS.mov',
        'clip 3D SBS.mp4',
        'movie.Half-SBS.1080p.mkv',
        'scene_LR.mp4',
        'scene.fsbs.mp4',
        'scene.3dsbs.mp4',
      ]) {
        expect(
          guessSpatialLayout(width: 1920, height: 1080, fileName: name),
          SpatialStereoLayout.sideBySide,
          reason: name,
        );
      }
    });

    test('reads top and bottom from the words of the file name, in any case', () {
      for (final name in [
        'Avatar.OU.mkv',
        'trip_hou.mp4',
        'Concert-3D-TB.mov',
        'clip Half-OU.mp4',
        'scene.tab.mp4',
        'scene_OverUnder.mp4',
        'scene.htb.mp4',
      ]) {
        expect(
          guessSpatialLayout(width: 1920, height: 1080, fileName: name),
          SpatialStereoLayout.topBottom,
          reason: name,
        );
      }
    });

    test('reads side by side with the right eye first from the word rl', () {
      expect(guessSpatialLayout(fileName: 'crossview_RL.mp4'), SpatialStereoLayout.sideBySideSwapped);
    });

    test('ignores the marks inside other words', () {
      for (final name in ['VID_20240101_120000.mp4', 'Outdoor.mp4', 'subsbsidy.mp4', 'table.mov', 'Bobsled.mp4', '']) {
        expect(guessSpatialLayout(width: 1920, height: 1080, fileName: name), SpatialStereoLayout.auto, reason: name);
      }
      expect(guessSpatialLayout(), SpatialStereoLayout.auto);
    });

    test('trusts the frame shape over the file name', () {
      expect(guessSpatialLayout(width: 3840, height: 1080, fileName: 'clip.ou.mp4'), SpatialStereoLayout.sideBySide);
      expect(guessSpatialLayout(width: 1920, height: 2160, fileName: 'clip.sbs.mp4'), SpatialStereoLayout.topBottom);
    });

    test('leaves a file that declares its layout to the player', () {
      expect(
        guessSpatialLayout(width: 3840, height: 1080, fileName: 'clip.sbs.mp4', declaredStereo: true),
        SpatialStereoLayout.auto,
      );
    });
  });

  group('guessSpatialLayout for a 360° video', () {
    const equirectangular = SpatialProjection.equirectangular;

    test('follows the guess of the 360° viewers', () {
      for (final (width, height, expected) in [
        (5760, 5760, SpatialStereoLayout.topBottom),
        (4096, 4096, SpatialStereoLayout.topBottom),
        (7680, 1920, SpatialStereoLayout.sideBySide),
        (5760, 2880, SpatialStereoLayout.auto),
        (null, null, SpatialStereoLayout.auto),
      ]) {
        expect(
          guessSpatialLayout(width: width, height: height, projection: equirectangular),
          expected,
          reason: '$width x $height',
        );
        final stereo = guessStereoLayout(width: width, height: height);
        expect(spatialLayoutOf(stereo), expected, reason: '$width x $height, $stereo');
      }
    });

    test('ignores the flat frame shapes', () {
      // 3840x1080 or 1920x2160 are no 3D layouts of a 360° video
      expect(guessSpatialLayout(width: 3840, height: 1080, projection: equirectangular), SpatialStereoLayout.auto);
      expect(guessSpatialLayout(width: 1920, height: 2160, projection: equirectangular), SpatialStereoLayout.auto);
    });

    test('reads the file name of a 2:1 frame', () {
      expect(
        guessSpatialLayout(width: 5760, height: 2880, fileName: 'VR180_TB.mp4', projection: equirectangular),
        SpatialStereoLayout.topBottom,
      );
      expect(
        guessSpatialLayout(width: 5760, height: 5760, fileName: 'clip_sbs.mp4', projection: equirectangular),
        SpatialStereoLayout.topBottom,
        reason: 'the frame shape wins',
      );
    });
  });

  test('spatialLayoutOf maps every layout of the 360° viewers', () {
    expect(spatialLayoutOf(StereoLayout.topBottom), SpatialStereoLayout.topBottom);
    expect(spatialLayoutOf(StereoLayout.leftRight), SpatialStereoLayout.sideBySide);
    expect(spatialLayoutOf(StereoLayout.mono), SpatialStereoLayout.auto);
  });

  group('spatialLayoutKey', () {
    test('is the server id of an asset on the server, whether or not it is on the device too', () {
      final remote = RemoteAssetFactory.create(id: 'remote-1');
      final merged = RemoteAssetFactory.create(id: 'remote-1', localId: 'local-1');
      final local = LocalAsset(
        id: 'local-1',
        remoteId: remote.id,
        name: 'clip.mp4',
        type: AssetType.video,
        createdAt: TestUtils.now(),
        updatedAt: TestUtils.now(),
        isEdited: false,
        playbackStyle: AssetPlaybackStyle.video,
      );

      expect(spatialLayoutKey(remote), remote.id);
      expect(spatialLayoutKey(merged), remote.id);
      expect(spatialLayoutKey(local), remote.id);
    });

    test('is the device id of an asset only on the device', () {
      final local = LocalAsset(
        id: 'local-1',
        name: 'clip.mp4',
        type: AssetType.video,
        createdAt: TestUtils.now(),
        updatedAt: TestUtils.now(),
        isEdited: false,
        playbackStyle: AssetPlaybackStyle.video,
      );

      expect(spatialLayoutKey(local), 'local-1');
    });
  });

  group('remembered layouts', () {
    test('survive their JSON form, with the layout names', () {
      final layouts = {
        'asset-1': SpatialStereoLayout.sideBySide,
        'asset-2': SpatialStereoLayout.topBottomSwapped,
        'asset-3': SpatialStereoLayout.none,
      };

      final json = encodeSpatialLayouts(layouts);

      expect(json, '{"asset-1":"sideBySide","asset-2":"topBottomSwapped","asset-3":"none"}');
      expect(decodeSpatialLayouts(json), layouts);
    });

    test('read as none from a missing or damaged value', () {
      for (final json in [null, '', '{', '[]', '"sideBySide"', '42']) {
        expect(decodeSpatialLayouts(json), isEmpty, reason: '$json');
      }
    });

    test('skip unknown layout names', () {
      expect(decodeSpatialLayouts('{"asset-1":"sideBySide","asset-2":"diagonal","asset-3":3}'), {
        'asset-1': SpatialStereoLayout.sideBySide,
      });
    });
  });

  test('spatialLabels gives the player every label it reads', () {
    final labels = spatialLabels(StaticTranslations.instance);

    expect(labels.keys, {
      'spatial',
      'normal',
      'layout',
      'layoutAuto',
      'layoutSideBySide',
      'layoutTopBottom',
      'layoutSideBySideSwapped',
      'layoutTopBottomSwapped',
      'layoutNone',
      'recenter',
      'trackingLost',
      'cameraDenied',
      'unavailable',
      'sensitivity',
      'close',
      'error',
    });
  });
}
