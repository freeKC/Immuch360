// What the 360° player of the computers draws for the parameters SphericalVideoApi.open carries
// (projection_params.dart): an equirectangular video in each layout and coverage, a raw camera file from its plan's
// rawProjection JSON (both lenses of a side by side file stitched; the two streams of a file of two tracks or of a
// pair of files stacked side by side, or one of them with the other half black), and the view the user turns.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/projection_params.dart';
import 'package:immich_mobile/desktop/video/raw_two_streams.dart';
import 'package:immich_mobile/desktop/video/render/plugin_renderer.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:media_kit_video/media_kit_video.dart';

// Example A of the projections design (an X3 file, both lenses side by side), as raw_video_plan_test.dart has it
const _exampleA =
    '{"version":2,"kind":"dualFisheye","layout":"sideBySide","camera":"Insta360 X3","frameWidth":3840,'
    '"frameHeight":1920,"tracks":[{"file":0,"videoTrack":0,"trackId":1,"width":3840,"height":1920,"codec":"hvc1",'
    '"codecs":"hvc1.1.6.L153","bitDepth":8}],"secondUrl":null,"secondFallbackUrl":null,"trackOrder":null,'
    '"trackOrderSource":"single","calibrationSource":"file","gravitySource":"imu","model":"mei","canvasSquare":5952.0,'
    '"downBody":[0.989208,-0.08083,-0.122207],"maxTheta":100.0,"blendStart":85.0,"blendEnd":95.0,"lenses":['
    '{"texture":0,"region":[0.0,0.0,0.5,1.0],"cx":2967.48,"cy":2999.85,"fx":4627.54,"fy":4627.46,"xi":1.94817,'
    '"k1":0.38808271,"k2":1.29547262,"k3":-3.96876335,"k4":0.0,"k5":0.0,"p1":0.0017832,"p2":-0.00158561,'
    '"yaw":-0.029,"pitch":-0.038,"roll":89.51,'
    '"viewToLens":[-0.997338,0.072447,-0.008257,0.072914,0.989925,-0.121374,-0.00062,-0.121653,-0.992573]},'
    '{"texture":0,"region":[0.5,0.0,0.5,1.0],"cx":8933.2,"cy":2998.62,"fx":4615.53,"fy":4615.53,"xi":1.94817,'
    '"k1":0.39306432,"k2":1.25673521,"k3":-3.90715361,"k4":0.0,"k5":0.0,"p1":-0.00147705,"p2":0.00090004,'
    '"yaw":-0.03,"pitch":-0.086,"roll":89.487,'
    '"viewToLens":[0.995908,-0.089867,0.009548,0.090361,0.988507,-0.121201,0.001453,0.121568,0.992582]}]}';

// Example C (an X3 pair: one file per lens, the second through the bridge)
const _exampleC =
    '{"version":2,"kind":"dualFisheye","layout":"twoFiles","camera":"Insta360 X3","frameWidth":5760,'
    '"frameHeight":2880,"tracks":[{"file":0,"videoTrack":0,"trackId":1,"width":2880,"height":2880,"codec":"hvc1",'
    '"codecs":"hvc1.1.6.L153","bitDepth":8},{"file":1,"videoTrack":0,"trackId":1,"width":2880,"height":2880,'
    '"codec":"hvc1","codecs":"hvc1.1.6.L153","bitDepth":8}],'
    '"secondUrl":"http://127.0.0.1:40213/tok/share-1/DCIM/Camera01/VID_20240908_193126_00_004.insv",'
    '"secondFallbackUrl":null,"trackOrder":[1,0],"trackOrderSource":"fileName","calibrationSource":"file",'
    '"gravitySource":"imu","model":"mei","canvasSquare":5952.0,"downBody":[0.989208,-0.08083,-0.122207],'
    '"maxTheta":100.0,"blendStart":85.0,"blendEnd":95.0,"lenses":['
    '{"texture":1,"region":[0.0,0.0,1.0,1.0],"cx":2967.48,"cy":2999.85,"fx":4627.54,"fy":4627.46,"xi":1.94817,'
    '"k1":0.38808271,"k2":1.29547262,"k3":-3.96876335,"k4":0.0,"k5":0.0,"p1":0.0017832,"p2":-0.00158561,'
    '"yaw":-0.029,"pitch":-0.038,"roll":89.51,'
    '"viewToLens":[-0.997338,0.072447,-0.008257,0.072914,0.989925,-0.121374,-0.00062,-0.121653,-0.992573]},'
    '{"texture":0,"region":[0.0,0.0,1.0,1.0],"cx":8933.2,"cy":2998.62,"fx":4615.53,"fy":4615.53,"xi":1.94817,'
    '"k1":0.39306432,"k2":1.25673521,"k3":-3.90715361,"k4":0.0,"k5":0.0,"p1":-0.00147705,"p2":0.00090004,'
    '"yaw":-0.03,"pitch":-0.086,"roll":89.487,'
    '"viewToLens":[0.995908,-0.089867,0.009548,0.090361,0.988507,-0.121201,0.001453,0.121568,0.992582]}]}';

// Example E (a GoPro MAX 2 file, two EAC tracks)
const _exampleE =
    '{"version":2,"kind":"eacGoPro","layout":"twoTracks","camera":"GoPro MAX 2","frameWidth":7680,'
    '"frameHeight":3840,"tracks":[{"file":0,"videoTrack":0,"trackId":1,"width":5952,"height":1920,"codec":"hvc1",'
    '"codecs":"hvc1.2.4.L153","bitDepth":10},{"file":0,"videoTrack":1,"trackId":6,"width":5952,"height":1920,'
    '"codec":"hvc1","codecs":"hvc1.2.4.L153","bitDepth":10}],"secondUrl":null,"secondFallbackUrl":null,'
    '"trackOrder":null,"trackOrderSource":"goPro","calibrationSource":"trackGeometry","gravitySource":"none",'
    '"face":1920,"overlap":96,"half":1008,"middle":2016,"right":3936,'
    '"viewToCamera":[1.0,0.0,0.0,0.0,-1.0,0.0,0.0,0.0,1.0],"faces":['
    '{"texture":0,"slot":0,"forward":[-1,0,0],"right":[0,0,1],"down":[0,-1,0]},'
    '{"texture":0,"slot":1,"forward":[0,0,1],"right":[1,0,0],"down":[0,-1,0]},'
    '{"texture":0,"slot":2,"forward":[1,0,0],"right":[0,0,-1],"down":[0,-1,0]},'
    '{"texture":1,"slot":0,"forward":[0,-1,0],"right":[0,0,-1],"down":[-1,0,0]},'
    '{"texture":1,"slot":1,"forward":[0,0,-1],"right":[0,1,0],"down":[-1,0,0]},'
    '{"texture":1,"slot":2,"forward":[0,1,0],"right":[0,0,1],"down":[-1,0,0]}]}';

void main() {
  group('an equirectangular video', () {
    test('mono over the whole sphere: the whole frame, all of it', () {
      final params = ProjectionParams.fromOpen(layout: StereoLayout.mono, coverage: SphereCoverage.full);
      expect(params.isRaw, isFalse);
      expect(params.rawStreams, isNull);
      final projection = params.toPlugin();
      expect(projection.kind, ProjectionKind.equirect);
      expect(projection.eye, [0, 0, 1, 1]);
      expect(projection.crop, [0, 0, 1, 1]);
    });

    test('3D top and bottom in VR180: the left eye on top, the front half of the sphere', () {
      final projection = ProjectionParams.fromOpen(
        layout: StereoLayout.topBottom,
        coverage: SphereCoverage.half,
      ).toPlugin();
      expect(projection.eye, [0, 0, 1, 0.5]);
      expect(projection.crop, [0.25, 0, 0.5, 1]);
    });

    test('the 3D cycle and the 180/360 switch change the projection, not the video', () {
      const params = ProjectionParams();
      final sideBySide = params.copyWith(layout: params.layout.next.next);
      expect(sideBySide.layout, StereoLayout.leftRight);
      expect(sideBySide.toPlugin().eye, [0, 0, 0.5, 1]);
      final half = sideBySide.copyWith(coverage: SphereCoverage.half);
      expect(half.coverage, SphereCoverage.half);
      expect(half.layout, StereoLayout.leftRight);
      expect(half, isNot(sideBySide));
      expect(half.copyWith(coverage: SphereCoverage.full), sideBySide);
    });
  });

  group('a raw camera file from the rawProjection JSON', () {
    test('both lenses side by side in one track: stitched, one stream, both lenses', () {
      final params = ProjectionParams.fromOpen(
        layout: StereoLayout.topBottom,
        coverage: SphereCoverage.half,
        rawProjection: _exampleA,
      );
      expect(params.isRaw, isTrue);
      // One picture over the whole sphere, whatever the guess said
      expect((params.layout, params.coverage), (StereoLayout.mono, SphereCoverage.full));
      expect(params.rawStreams!.twoStreams, isFalse);
      final projection = params.toPlugin();
      expect(projection.kind, ProjectionKind.fisheyePair);
      expect(projection.tracks, 1);
      expect(projection.streamsEnabled, [1, 1]);
      expect(projection.uniforms['uModel'], [0]);
      expect(projection.uniforms['uRegion1'], [0.5, 0, 0.5, 1]);
    });

    test('a pair of files stacked: both lenses in the frame, the regions rewritten into its halves', () {
      final params = ProjectionParams.fromOpen(
        layout: StereoLayout.mono,
        coverage: SphereCoverage.full,
        rawProjection: _exampleC,
      );
      expect(params.rawStreams!.twoStreams, isTrue);
      final projection = params.toPlugin();
      expect(projection.kind, ProjectionKind.fisheyePair);
      expect(projection.tracks, 1, reason: 'one stacked frame');
      expect(projection.streamsEnabled, [1, 1]);
      // trackOrder [1, 0]: lens 0 lives in the second stream, so in the right half of the stacked frame
      expect(projection.uniforms['uRegion0'], [0.5, 0, 0.5, 1]);
      expect(projection.uniforms['uRegion1'], [0, 0, 0.5, 1]);
      expect(projection.uniforms['uTexOf0'], [0]);
      expect(projection.uniforms['uTexOf1'], [0]);
    });

    test('a pair of files, one stream decoded: its lens shows, the other is off', () {
      final params = ProjectionParams.fromOpen(
        layout: StereoLayout.mono,
        coverage: SphereCoverage.full,
        rawProjection: _exampleC,
      );
      final projection = params.toPlugin(frame: const RawFrame.streams([0]));
      expect(projection.tracks, 1, reason: 'the frame holds the one decoded stream');
      expect(projection.streamsEnabled, [1, 0]);
      // Lens 1 lives in stream 0 here (trackOrder [1, 0]): that is the lens that shows
      expect(projection.uniforms['uTexOf1'], [0]);
      expect(projection.uniforms['uRegion1'], [0, 0, 1, 1]);
      expect(projection.uniforms['uTexOf0'], [1]);
    });

    test('two EAC tracks of a GoPro stacked: the pass cuts the frame in two', () {
      final params = ProjectionParams.fromOpen(
        layout: StereoLayout.mono,
        coverage: SphereCoverage.full,
        rawProjection: _exampleE,
      );
      final projection = params.toPlugin();
      expect(projection.kind, ProjectionKind.eacPair);
      expect(projection.tracks, 2);
      expect(projection.streamsEnabled, [1, 1]);
    });

    test('a raw file keeps its own projection through the 3D cycle', () {
      final params = ProjectionParams.fromOpen(
        layout: StereoLayout.mono,
        coverage: SphereCoverage.full,
        rawProjection: _exampleA,
      );
      expect(identical(params.copyWith(layout: StereoLayout.topBottom), params), isTrue);
    });

    test('a JSON that is not an object, or without tracks, is refused', () {
      expect(
        () => ProjectionParams.fromOpen(layout: StereoLayout.mono, coverage: SphereCoverage.full, rawProjection: '[]'),
        throwsFormatException,
      );
      final noTracks = ProjectionParams.fromOpen(
        layout: StereoLayout.mono,
        coverage: SphereCoverage.full,
        rawProjection: _exampleA.replaceFirst(RegExp(r'"tracks":\[.*?\],"secondUrl"'), '"tracks":[],"secondUrl"'),
      );
      expect(() => noTracks.rawStreams, throwsFormatException);
      expect(noTracks.toPlugin, throwsFormatException);
    });
  });

  group('the view', () {
    test('a drag moves the picture with the pointer: right turns the view left, down looks up', () {
      const view = ViewAngles(yaw: 10, pitch: 0, fov: 90);
      final dragged = view.dragged(const Offset(100, 50), 900);
      // 90 degrees over 900 pixels: 0.1 degree a pixel
      expect(dragged.yaw, closeTo(0, 1e-9));
      expect(dragged.pitch, closeTo(5, 1e-9));
      expect(dragged.fov, 90);
      expect(view.dragged(const Offset(10, 10), 0), view);
    });

    test('yaw wraps around, pitch stops at the poles, the field of view at its limits', () {
      expect(const ViewAngles(yaw: 190).normalized().yaw, closeTo(-170, 1e-9));
      expect(const ViewAngles(yaw: -540).normalized().yaw, closeTo(-180, 1e-9));
      expect(const ViewAngles(pitch: 120).normalized().pitch, 90);
      expect(const ViewAngles().zoomed(0.01).fov, ViewAngles.minFov);
      expect(const ViewAngles().zoomed(10).fov, ViewAngles.maxFov);
      expect(const ViewAngles(fov: 90).zoomed(0.5).fov, 45);
    });

    test('the plugin gets the same angles', () {
      expect(const ViewAngles(yaw: 12, pitch: -3, fov: 70).toPlugin(), const PluginView(yaw: 12, pitch: -3, fov: 70));
    });

    test('after a drag the view slows down the same way whatever the frame rate, then stops', () {
      const start = ViewAngles();
      const velocity = Offset(90, 0);
      // One step of 0.2 s, or ten of 0.02 s, travel the same way
      final one = sphereInertiaStep(start, velocity, 0.2)!;
      var many = (view: start, velocity: velocity);
      for (var i = 0; i < 10; i++) {
        many = sphereInertiaStep(many.view, many.velocity, 0.02)!;
      }
      expect(many.view.yaw, closeTo(one.view.yaw, 1e-6));
      expect(one.velocity.dx, lessThan(velocity.dx));
      expect(sphereInertiaStep(start, const Offset(1, 1), 0.016), isNull, reason: 'too slow to go on');
      // At a pole only the yaw keeps turning
      final atPole = sphereInertiaStep(const ViewAngles(pitch: 89), const Offset(30, 300), 0.1)!;
      expect(atPole.view.pitch, 90);
      expect(atPole.velocity.dy, 0);
    });
  });
}
