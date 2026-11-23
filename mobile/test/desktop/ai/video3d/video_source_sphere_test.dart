// What makes a video a 360° one for the 3D videos (lot ai-360-3d-51): its spherical side data, the app's probe of its
// sv3d or Spherical Video V1 box, its name words, the app's own mark (marked360); a 2:1 frame with nothing of these
// asked (looksLike360), never guessed; two eyes already, VR180, the raw file of a camera and a cube map refused in
// their words; the spatial sound said; the sizes offered and the name of the MP4.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_estimates.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_jobs.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_source.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

/// The ffprobe of a 360° camera's stitched video: [width] x [height], H.264 at 30 fps, [side] data, [audio] tracks
Map<String, Object?> _sphere({
  int width = 5760,
  int height = 2880,
  List<Map<String, Object?>> side = const [],
  List<Map<String, Object?>> audio = const [
    {'codec_name': 'aac', 'channels': 2},
  ],
  double rotation = 0,
  String format = 'mov,mp4,m4a,3gp,3g2,mj2',
}) =>
    jsonDecode(
          jsonEncode({
            'streams': [
              {
                'index': 0,
                'codec_type': 'video',
                'codec_name': 'h264',
                'width': width,
                'height': height,
                'pix_fmt': 'yuv420p',
                'r_frame_rate': '30/1',
                'avg_frame_rate': '30/1',
                'nb_frames': '300',
                'duration': '10.0',
                'side_data_list': [
                  ...side,
                  if (rotation != 0) {'side_data_type': 'Display Matrix', 'rotation': rotation},
                ],
                'disposition': {'attached_pic': 0},
              },
              for (final (i, track) in audio.indexed) {'index': i + 1, 'codec_type': 'audio', ...track},
            ],
            'format': {'duration': '10.0', 'start_time': '0.000000', 'format_name': format},
          }),
        )
        as Map<String, Object?>;

const _spherical = {'side_data_type': 'Spherical Mapping', 'projection': 'equirectangular'};

VideoSourceCheck _check(
  Map<String, Object?> json, {
  String name = 'VID_20261122_101500.mp4',
  SphericalProbe? spherical,
  bool marked360 = false,
  VideoProjectionAsk ask = VideoProjectionAsk.auto,
}) => checkVideoSource(
  VideoSource.fromFfprobe(json),
  fileName: name,
  spherical: spherical,
  marked360: marked360,
  ask: ask,
);

void main() {
  test('a 360° video of one eye by each of its marks is made 360° 3D', () {
    expect(_check(_sphere(side: [_spherical])).sphere, isTrue);
    expect(_check(_sphere(), spherical: const SphericalProbe(hasSphericalMetadata: true)).sphere, isTrue);
    expect(
      _check(_sphere(), spherical: const SphericalProbe(hasSphericalMetadata: true, stereo: StereoLayout.mono)).sphere,
      isTrue,
    );
    expect(_check(_sphere(), name: 'GS010012_360.mp4').sphere, isTrue);
    expect(_check(_sphere(), name: 'ride equirect.mp4').sphere, isTrue);
    expect(_check(_sphere(), marked360: true).sphere, isTrue);
    for (final check in [
      _check(_sphere(side: [_spherical])),
      _check(_sphere(), marked360: true),
    ]) {
      expect(check.accepted, isTrue);
      expect(check.looksLike360, isFalse);
      expect(check.grid!.rate, const VideoRate(30, 1));
    }
  });

  test('a 2:1 frame with no mark is asked, not guessed: flat until the user says 360°', () {
    final plain = _check(_sphere(width: 3840, height: 1920));
    expect((plain.accepted, plain.sphere, plain.looksLike360), (true, false, true));
    final said = _check(_sphere(width: 3840, height: 1920), ask: VideoProjectionAsk.sphere);
    expect((said.accepted, said.sphere, said.looksLike360), (true, true, false));
    // A flat job never asks, a 16:9 or a 2.39:1 film is never taken for a sphere
    expect(_check(_sphere(width: 3840, height: 1920), ask: VideoProjectionAsk.flat).looksLike360, isFalse);
    expect(_check(_sphere(width: 1920, height: 1080)).looksLike360, isFalse);
    expect(_check(_sphere(width: 1920, height: 804)).looksLike360, isFalse);
    // The answer read again from the facts of the dialog
    final source = VideoSource.fromFfprobe(_sphere(width: 3840, height: 1920));
    final facts = VideoDialogFacts(check: plain, source: source, fileName: 'VID.mp4');
    expect(facts.checkAs(null).looksLike360, isTrue);
    expect(facts.checkAs(true).sphere, isTrue);
    expect(facts.checkAs(false).sphere, isFalse);
  });

  test('a 360° video in a flat job is refused as before (sphere360, vr180)', () {
    expect(_check(_sphere(side: [_spherical]), ask: VideoProjectionAsk.flat).skip, VideoRefusal.sphere360);
    expect(_check(_sphere(), name: 'trip_VR180.mp4', ask: VideoProjectionAsk.flat).skip, VideoRefusal.vr180);
  });

  test('refused in their words: two eyes already, VR180, the raw file of a camera, a sphere not in one 2:1 frame, '
      'a sphere turned', () {
    // Top and bottom by its st3d, its side data, its square frame, its name
    expect(
      _check(
        _sphere(),
        spherical: const SphericalProbe(hasSphericalMetadata: true, stereo: StereoLayout.topBottom),
      ).skip,
      VideoRefusal.alreadyStereo,
    );
    expect(
      _check(
        _sphere(
          side: [
            _spherical,
            {'side_data_type': 'Stereo 3D', 'type': 'top and bottom'},
          ],
        ),
      ).skip,
      VideoRefusal.alreadyStereo,
    );
    expect(_check(_sphere(width: 5760, height: 5760, side: [_spherical])).skip, VideoRefusal.alreadyStereo);
    expect(_check(_sphere(width: 7680, height: 1920, side: [_spherical])).skip, VideoRefusal.alreadyStereo);
    expect(_check(_sphere(), name: 'trip_360_TB.mp4').skip, VideoRefusal.alreadyStereo);
    // VR180
    expect(
      _check(
        _sphere(
          side: [
            {..._spherical, 'bound_left': 1073741823, 'bound_right': 1073741823},
          ],
        ),
      ).skip,
      VideoRefusal.vr180,
    );
    expect(_check(_sphere(), name: 'trip_VR180.mp4').skip, VideoRefusal.vr180);
    // Raw lenses of an Insta360, a GoPro MAX, a DJI Osmo 360
    for (final name in ['VID_20261122_101500_00_001.insv', 'GS010012.360', 'CAM_20261122101500_0001_D.osv']) {
      expect(_check(_sphere(), name: name).skip, VideoRefusal.raw360, reason: name);
    }
    // A cube map (3:2) said 360°
    expect(_check(_sphere(width: 3072, height: 2048, side: [_spherical])).skip, VideoRefusal.sphereLayout);
    // A sphere turned by its display matrix: upside down, or on its side (then no longer 2:1)
    expect(_check(_sphere(side: [_spherical], rotation: 180)).skip, VideoRefusal.oddRotation);
    expect(_check(_sphere(side: [_spherical], rotation: 90)).skip, VideoRefusal.sphereLayout);
  });

  test('spatial sound: kept when the MP4 takes it as it is, said made plain otherwise', () {
    final kept = _check(
      _sphere(
        side: [_spherical],
        audio: [
          {'codec_name': 'aac', 'channels': 4, 'channel_layout': 'ambisonic 1'},
        ],
      ),
    );
    expect(kept.notes, contains(VideoPlanNote.spatialAudioKept));
    expect(kept.audio.single.ambisonic, isTrue);
    final plain = _check(
      _sphere(
        side: [_spherical],
        audio: [
          {'codec_name': 'pcm_s16le', 'channels': 4, 'channel_layout': 'ambisonic 1'},
        ],
      ),
    );
    expect(plain.notes, contains(VideoPlanNote.spatialAudioPlain));
    expect(plain.notes, isNot(contains(VideoPlanNote.spatialAudioKept)));
    // A Matroska or WebM file has no moov, so no SA3D box to copy back: copied, but said unmarked
    final matroska = _check(
      _sphere(
        side: [_spherical],
        format: 'matroska,webm',
        audio: [
          {'codec_name': 'opus', 'channels': 4, 'channel_layout': 'ambisonic 1'},
        ],
      ),
      name: 'ride.mkv',
    );
    expect(matroska.source!.quickTime, isFalse);
    expect(matroska.notes, contains(VideoPlanNote.spatialAudioUnmarked));
    expect(matroska.notes, isNot(contains(VideoPlanNote.spatialAudioKept)));
    expect(kept.source!.quickTime, isTrue);
    // A flat video never says it
    expect(
      _check(
        _sphere(
          width: 1920,
          height: 1080,
          audio: [
            {'codec_name': 'aac', 'channels': 4, 'channel_layout': 'ambisonic 1'},
          ],
        ),
      ).notes,
      isNot(contains(VideoPlanNote.spatialAudioKept)),
    );
  });

  test('the sizes offered, never wider than the video; the default 3072 (H.264 level 5.2 at 30 fps), 2048 above 30 '
      'fps (level 5.1 up to 60, where 3072 would need level 6); the name of the MP4', () {
    // 3072 x 3072: exactly the 36 864 macroblocks of level 5.1, 26.7 frames a second within its 983 040 a second
    expect(3072 * 3072 ~/ 256, 36864);
    expect(983040 / 36864, closeTo(26.7, 0.05));
    expect(2073600 / 36864, greaterThan(30)); // level 5.2
    expect(2048 * 2048 ~/ 256 * 60, lessThanOrEqualTo(983040)); // level 5.1 at 60
    expect(sphereDefaultEyeWidthOf([2048, 3072, 4096], null, rate: 30000 / 1001), 3072);
    expect(sphereDefaultEyeWidthOf([2048, 3072, 4096], null, rate: 30), 3072);
    expect(sphereDefaultEyeWidthOf([2048, 3072, 4096], null, rate: 50), 2048);
    expect(sphereDefaultEyeWidthOf([2048, 3072, 4096], null, rate: 60000 / 1001), 2048);
    expect(sphereDefaultEyeWidthOf([2048, 3072, 4096], 3072, rate: 60), 3072);
    expect(sphereDefaultEyeWidthOf([1920], null, rate: 60), 1920);
    expect(sphereEyeWidthsFor(VideoSource.fromFfprobe(_sphere())!), [2048, 3072, 4096]);
    expect(sphereEyeWidthsFor(VideoSource.fromFfprobe(_sphere(width: 3840, height: 1920))!), [2048, 3072]);
    expect(sphereEyeWidthsFor(VideoSource.fromFfprobe(_sphere(width: 1922, height: 961))!), [1920]);
    expect(sphereDefaultEyeWidthOf([2048, 3072, 4096], null), 3072);
    expect(sphereDefaultEyeWidthOf([2048, 3072, 4096], 4096), 4096);
    expect(sphereDefaultEyeWidthOf([2048], 3072), 2048);
    expect(sphereOutputName('VID_20261122_101500.mp4'), 'VID_20261122_101500_360_3D.mp4');
    expect(sphereOutputName('GS010012_360.mp4'), 'GS010012_360_3D.mp4');
  });

  test('the estimates of a 360° job: 3.4 times the depth of a flat video, more disk, more memory', () {
    expect(sphereDepthFactor(VideoDepthQuality.standard), closeTo(3.36, 0.01));
    final flat = videoTimeRange(frames: 1800, quality: VideoDepthQuality.standard, logicalProcessors: 32);
    final sphere = videoTimeRange(
      frames: 1800,
      quality: VideoDepthQuality.standard,
      logicalProcessors: 32,
      sphereEyeWidth: 3072,
    );
    expect(sphere.low.inSeconds, greaterThan(flat.low.inSeconds * 3));
    expect(sphere.high.inSeconds, greaterThan(flat.high.inSeconds * 3));
    // A minute at 3072 x 3072 in H.264, and two states of six faces
    final disk = videoDiskNeed(
      durationSeconds: 60,
      av1: false,
      half: false,
      modelWidth: 392,
      modelHeight: 392,
      outWidth: 3072,
      outHeight: 3072,
      stateBytes: sphereStateBytes(VideoDepthQuality.standard),
      sphere: true,
    );
    expect(disk, greaterThan(1000 * 1000 * 1000));
    expect(
      sphereJobMemoryBytes(VideoDepthQuality.standard, 3072),
      greaterThan(VideoDepthQuality.standard.jobMemoryBytes),
    );
    expect(videoPaceKey(VideoDepthQuality.standard), 'standard');
    expect(videoPaceKey(VideoDepthQuality.standard, sphereEyeWidth: 3072), '360-standard-3072');
  });

  test('the settings of a 360° job kept in video_jobs.json; those of a flat one as they were', () {
    const sphere = VideoJobSettings(recordId: 'a', workFolder: '/v/.immuch360-work-a', sphereEyeWidth: 3072);
    expect(VideoJobSettings.fromJson(sphere.toJson())!.sphereEyeWidth, 3072);
    const flat = VideoJobSettings(recordId: 'b', workFolder: '/v/.immuch360-work-b');
    expect(flat.toJson().containsKey('sphereEyeWidth'), isFalse);
    expect(VideoJobSettings.fromJson(flat.toJson())!.sphere, isFalse);
  });
}
