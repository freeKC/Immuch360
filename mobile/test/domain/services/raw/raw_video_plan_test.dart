// The plans of the raw videos and their rawProjection JSON version 2 (docs/18-design-projections-and-parsers.md,
// sections 3 and 7.2): the exact strings of the examples of section 3.5, the rules of section 3.4, and the decisions
// of the resolver for every layout.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/raw/dji_osv.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/raw/gopro_eac.dart';
import 'package:immich_mobile/domain/services/raw/insta360_trailer.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/raw/raw_video_plan.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

import '../../../fixtures/raw/insta360.stub.dart';

// Example A: gravity of the trailer, and the rotations section 3.5 gives for it (six decimals)
const _x3DownBody = [0.989208, -0.08083, -0.122207];
const _x3ViewToLens0 = [-0.997338, 0.072447, -0.008257, 0.072914, 0.989925, -0.121374, -0.00062, -0.121653, -0.992573];
const _x3ViewToLens1 = [0.995908, -0.089867, 0.009548, 0.090361, 0.988507, -0.121201, 0.001453, 0.121568, 0.992582];

DualFisheyeLens _lens(DualFisheyeLens lens, {List<double>? viewToLens}) => DualFisheyeLens(
  cx: lens.cx,
  cy: lens.cy,
  yaw: lens.yaw,
  pitch: lens.pitch,
  roll: lens.roll,
  xi: lens.xi,
  fx: lens.fx,
  fy: lens.fy,
  k1: lens.k1,
  k2: lens.k2,
  k3: lens.k3,
  k4: lens.k4,
  k5: lens.k5,
  p1: lens.p1,
  p2: lens.p2,
  radius: lens.radius,
  viewToLens: viewToLens ?? lens.viewToLens,
);

/// The X3 calibration of example A, its rotations as section 3.5 writes them when [given]
DualFisheyeCalibration _x3({bool given = true, Insta360LayoutHints? hints}) {
  final parsed = parseInsta360OffsetV3(x3OffsetV3)!;
  return parsed.copyWith(
    lenses: [
      _lens(parsed.lenses[0], viewToLens: given ? _x3ViewToLens0 : null),
      _lens(parsed.lenses[1], viewToLens: given ? _x3ViewToLens1 : null),
    ],
    downBody: _x3DownBody,
    cameraModel: 'Insta360 X3',
    gravity: GravitySource.imu,
    layoutHints: hints,
  );
}

/// The illustrative X5 calibration of example B, its trailer saying track 0 holds lens 1
DualFisheyeCalibration _x5({Insta360LayoutHints? hints = const Insta360LayoutHints(trackOrder: 1)}) {
  DualFisheyeLens lens(int index) => DualFisheyeLens(
    cx: 2688.0 + index * 5376,
    cy: 2688,
    yaw: 0,
    pitch: 0,
    roll: 90,
    xi: 1.95,
    fx: 4180,
    fy: 4180,
    k1: 0.39,
    k2: 1.28,
    k3: -3.94,
  );
  return DualFisheyeCalibration(
    model: DualFisheyeModel.mei,
    lenses: [lens(0), lens(1)],
    canvasSquare: 5376,
    cameraModel: 'Insta360 X5',
    gravity: GravitySource.imu,
    layoutHints: hints,
  );
}

/// The Osmo 360 calibration of example D, with its values as section 3.5 writes them
DualFisheyeCalibration _osmo360() => const DualFisheyeCalibration(
  model: DualFisheyeModel.kannalaBrandt,
  lenses: [
    DualFisheyeLens(
      cx: 1920.85339355,
      cy: 1916.73022461,
      fx: 1046.37927246,
      fy: 1046.16796875,
      k1: 0.068134,
      k2: -0.013797,
      k3: 0.0117944,
      k4: -0.00733225,
      k5: 0.00104408,
      yaw: 179.5457,
      pitch: 90.616882,
      roll: -1.3556259,
      viewToLens: [-0.999691, -0.023657, 0.007672, -0.023572, 0.999662, 0.010951, -0.007928, 0.010766, -0.999911],
    ),
    DualFisheyeLens(
      cx: 5750.76611328,
      cy: 1916.24243164,
      fx: 1048.02502441,
      fy: 1047.87451172,
      k1: 0.0644356,
      k2: -0.00886799,
      k3: 0.00849704,
      k4: -0.00639127,
      k5: 0.00095551,
      yaw: -0.52270812,
      pitch: 90.597488,
      roll: 0.40385118,
      viewToLens: [0.999933, -0.007031, -0.009205, 0.007135, 0.999911, 0.011292, 0.009124, -0.011357, 0.999894],
    ),
  ],
  canvasSquare: 3840,
  cameraModel: 'Osmo 360',
  maxTheta: 94,
  blendStart: 87,
  blendEnd: 93,
);

/// A video track of [width] x [height]
ProbedTrack _video(
  int index, {
  int? trackId,
  int width = 3840,
  int height = 3840,
  String codecs = 'hvc1.1.6.L183',
  int bitDepth = 8,
  int? durationMs,
}) => ProbedTrack(
  index: index,
  trackId: trackId ?? index + 1,
  handlerType: 'vide',
  handlerName: 'VideoHandler',
  codec: 'hvc1',
  codecs: codecs,
  codedWidth: width,
  codedHeight: height,
  frameRate: 30,
  durationMs: durationMs,
  bitDepth: bitDepth,
);

SphericalProbe _probe(List<ProbedTrack> tracks) => SphericalProbe(tracks: tracks);

/// The calibrations the resolver is given: [insta360] by key, else [fallback]; [dji] for every DJI file
class _Calibrations implements RawVideoCalibrations {
  _Calibrations({this.insta360 = const {}, this.fallback, this.dji});

  final Map<String, DualFisheyeCalibration> insta360;
  final DualFisheyeCalibration? fallback;
  final DualFisheyeCalibration? dji;
  final asked = <String>[];

  @override
  Future<DualFisheyeCalibration> forInput(RawVideoInput input, {int? frameSquare}) async {
    asked.add(input.key);
    return insta360[input.key] ?? fallback ?? nominalX3(frameSquare ?? 2880);
  }

  @override
  Future<DualFisheyeCalibration> forDji(RawVideoInput input) async {
    asked.add('dji:${input.key}');
    return dji ?? nominalOsmo360();
  }
}

RawVideoInput _input(
  String name, {
  String? key,
  String? url,
  String? originalUrl,
  String? fallbackUrl,
  SphericalProbe? probe,
  int? width,
  int? height,
}) => RawVideoInput(
  name: name,
  key: key ?? name,
  url: url ?? 'file:///$name',
  originalUrl: originalUrl,
  fallbackUrl: fallbackUrl,
  open: () async => null,
  probe: probe,
  width: width,
  height: height,
);

RawVideoResolver _resolver(RawVideoCalibrations calibrations, {bool twoStreams = true}) => RawVideoResolver(
  calibrations: calibrations,
  support: RawVideoPlaybackSupport(twoStreams: twoStreams),
);

Future<RawVideoInput?> _noSibling(String name) async => null;

// The JSON strings of section 3.5, written as the design shows them, line breaks and indentation aside
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

const _exampleB =
    '{"version":2,"kind":"dualFisheye","layout":"twoTracks","camera":"Insta360 X5","frameWidth":7680,'
    '"frameHeight":3840,"tracks":[{"file":0,"videoTrack":0,"trackId":1,"width":3840,"height":3840,"codec":"hvc1",'
    '"codecs":"hvc1.1.6.L183","bitDepth":8},{"file":0,"videoTrack":1,"trackId":2,"width":3840,"height":3840,'
    '"codec":"hvc1","codecs":"hvc1.1.6.L183","bitDepth":8}],"secondUrl":null,"secondFallbackUrl":null,'
    '"trackOrder":[1,0],"trackOrderSource":"field80","calibrationSource":"file","gravitySource":"imu","model":"mei",'
    '"canvasSquare":5376.0,"downBody":[1.0,0.0,0.0],"maxTheta":100.0,"blendStart":85.0,"blendEnd":95.0,"lenses":['
    '{"texture":1,"region":[0.0,0.0,1.0,1.0],"cx":2688.0,"cy":2688.0,"fx":4180.0,"fy":4180.0,"xi":1.95,'
    '"k1":0.39,"k2":1.28,"k3":-3.94,"k4":0.0,"k5":0.0,"p1":0.0,"p2":0.0,"yaw":0.0,"pitch":0.0,"roll":90.0,'
    '"viewToLens":[-1.0,0.0,0.0,0.0,1.0,0.0,0.0,0.0,-1.0]},'
    '{"texture":0,"region":[0.0,0.0,1.0,1.0],"cx":8064.0,"cy":2688.0,"fx":4180.0,"fy":4180.0,"xi":1.95,'
    '"k1":0.39,"k2":1.28,"k3":-3.94,"k4":0.0,"k5":0.0,"p1":0.0,"p2":0.0,"yaw":0.0,"pitch":0.0,"roll":90.0,'
    '"viewToLens":[1.0,0.0,0.0,0.0,1.0,0.0,0.0,0.0,1.0]}]}';

// Example C with the lens values of example A in full
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

const _exampleD =
    '{"version":2,"kind":"dualFisheye","layout":"twoTracks","camera":"Osmo 360","frameWidth":7680,'
    '"frameHeight":3840,"tracks":[{"file":0,"videoTrack":0,"trackId":1,"width":3840,"height":3840,"codec":"hvc1",'
    '"codecs":"hvc1.2.4.H156","bitDepth":10},{"file":0,"videoTrack":1,"trackId":2,"width":3840,"height":3840,'
    '"codec":"hvc1","codecs":"hvc1.2.4.H156","bitDepth":10}],"secondUrl":null,"secondFallbackUrl":null,'
    '"trackOrder":[0,1],"trackOrderSource":"dji","calibrationSource":"file","gravitySource":"none",'
    '"model":"kannalaBrandt","canvasSquare":3840.0,"downBody":[1.0,0.0,0.0],"maxTheta":94.0,"blendStart":87.0,'
    '"blendEnd":93.0,"lenses":['
    '{"texture":0,"region":[0.0,0.0,1.0,1.0],"cx":1920.85339355,"cy":1916.73022461,"fx":1046.37927246,'
    '"fy":1046.16796875,"k1":0.068134,"k2":-0.013797,"k3":0.0117944,"k4":-0.00733225,"k5":0.00104408,"p1":0.0,'
    '"p2":0.0,"yaw":179.5457,"pitch":90.616882,"roll":-1.3556259,'
    '"viewToLens":[-0.999691,-0.023657,0.007672,-0.023572,0.999662,0.010951,-0.007928,0.010766,-0.999911]},'
    '{"texture":1,"region":[0.0,0.0,1.0,1.0],"cx":5750.76611328,"cy":1916.24243164,"fx":1048.02502441,'
    '"fy":1047.87451172,"k1":0.0644356,"k2":-0.00886799,"k3":0.00849704,"k4":-0.00639127,"k5":0.00095551,'
    '"p1":0.0,"p2":0.0,"yaw":-0.52270812,"pitch":90.597488,"roll":0.40385118,'
    '"viewToLens":[0.999933,-0.007031,-0.009205,0.007135,0.999911,0.011292,0.009124,-0.011357,0.999894]}]}';

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
  group('rawProjection version 2', () {
    test('example A: an X3 4K file, both lenses side by side', () async {
      final plan = await _resolver(_Calibrations(fallback: _x3())).resolve(
        kind: RawMediaKind.insta360Video,
        input: _input(
          'VID_20240908_133036_00_002.insv',
          probe: _probe([_video(0, width: 3840, height: 1920, codecs: 'hvc1.1.6.L153')]),
        ),
        findSibling: _noSibling,
      );

      expect(plan.toNativeJson(), _exampleA);
    });

    test('example B: an X5, two tracks in one file, field 80 = 1', () async {
      final plan = await _resolver(_Calibrations(fallback: _x5())).resolve(
        kind: RawMediaKind.insta360Video,
        input: _input('VID_20250501_101010_00_004.insv', probe: _probe([_video(0), _video(1)])),
        findSibling: _noSibling,
      );

      expect(plan.toNativeJson(), _exampleB);
    });

    test('example C: an X3 5.7K split pair opened from its _10_ file, the calibration of its _00_ file', () async {
      const folder = 'http://127.0.0.1:40213/tok/share-1/DCIM/Camera01';
      final calibrations = _Calibrations(
        insta360: {'VID_20240908_193126_00_004.insv': _x3()},
        fallback: nominalX3(2880),
      );
      SphericalProbe probe() => _probe([_video(0, width: 2880, height: 2880, codecs: 'hvc1.1.6.L153')]);

      final plan = await _resolver(calibrations).resolve(
        kind: RawMediaKind.insta360Video,
        input: _input(
          'VID_20240908_193126_10_004.insv',
          url: '$folder/VID_20240908_193126_10_004.insv',
          probe: probe(),
        ),
        findSibling: (name) async => _input(name, url: '$folder/$name', probe: probe()),
      );

      expect(plan.toNativeJson(), _exampleC);
      expect(plan.url, '$folder/VID_20240908_193126_10_004.insv');
    });

    test('example D: a DJI Osmo 360 .OSV', () async {
      final plan = await _resolver(_Calibrations(dji: _osmo360())).resolve(
        kind: RawMediaKind.djiVideo,
        input: _input(
          'CAM_20250715191201_0003_D.OSV',
          probe: _probe([
            _video(0, codecs: 'hvc1.2.4.H156', bitDepth: 10),
            _video(1, codecs: 'hvc1.2.4.H156', bitDepth: 10),
          ]),
        ),
        findSibling: _noSibling,
      );

      expect(plan.toNativeJson(), _exampleD);
    });

    test('example E: a GoPro MAX 2, 10 bit; the MAX with its own geometry and quarter turn', () async {
      ProbedTrack eac(int index, int trackId, int width, int height) =>
          _video(index, trackId: trackId, width: width, height: height, codecs: 'hvc1.2.4.L153', bitDepth: 10);
      final resolver = _resolver(_Calibrations());

      final max2 = await resolver.resolve(
        kind: RawMediaKind.goProVideo,
        input: _input('GS010001.360', probe: _probe([eac(0, 1, 5952, 1920), eac(5, 6, 5952, 1920)])),
        findSibling: _noSibling,
      );
      final max = await resolver.resolve(
        kind: RawMediaKind.goProVideo,
        input: _input('GS010013.360', probe: _probe([eac(0, 1, 4096, 1344), eac(5, 6, 4096, 1344)])),
        findSibling: _noSibling,
      );

      expect(max2.toNativeJson(), _exampleE);
      final json = jsonDecode(max.toNativeJson()) as Map;
      expect(json['camera'], 'GoPro MAX');
      expect([json['face'], json['overlap'], json['half'], json['middle'], json['right']], [1344, 32, 688, 1376, 2720]);
      expect((json['frameWidth'], json['frameHeight']), (5376, 2688));
      expect(json['viewToCamera'], [0, 1, 0, 1, 0, 0, 0, 0, 1]);
      expect(max.toNativeJson(), contains('"viewToCamera":[0.0,1.0,0.0,1.0,0.0,0.0,0.0,0.0,1.0]'));
    });

    test('computes the rotations of example A from the lens poses and the gravity of the trailer', () {
      final plan = RawVideoPlan(
        kind: RawMediaKind.insta360Video,
        layout: RawVideoLayout.sideBySide,
        tracks: const [RawVideoTrack(file: 0, videoTrack: 0, width: 3840, height: 1920)],
        calibration: _x3(given: false),
        textureOfLens: const [0, 0],
        url: 'file:///a.insv',
        trackOrderSource: 'single',
      );

      final lenses = (jsonDecode(plan.toNativeJson()) as Map)['lenses'] as List;
      for (final (i, expected) in [_x3ViewToLens0, _x3ViewToLens1].indexed) {
        final values = (lenses[i] as Map)['viewToLens'] as List;
        for (var k = 0; k < 9; k++) {
          expect(values[k] as double, closeTo(expected[k], 1e-5), reason: 'lens $i, value $k');
        }
      }
    });

    test('writes numbers with at most 8 decimals, whole numbers with one, never a negative zero', () {
      expect(formatRawProjectionNumber(5952), '5952.0');
      expect(formatRawProjectionNumber(0.38808271), '0.38808271');
      expect(formatRawProjectionNumber(-0.08083), '-0.08083');
      expect(formatRawProjectionNumber(1920.8533935546875), '1920.85339355');
      expect(formatRawProjectionNumber(6.123233995736766e-17), '0.0');
      expect(formatRawProjectionNumber(-6.123233995736766e-17), '0.0');
      expect(formatRawProjectionNumber(-1), '-1.0');
      expect(
        encodeRawProjection({
          'a': 1,
          'b': 1.0,
          'c': null,
          'd': 'x"y',
          'e': [true],
        }),
        '{"a":1,"b":1.0,"c":null,"d":"x\\"y","e":[true]}',
      );
    });
  });

  group('rawProjectionViolation', () {
    Map<String, Object?> sample(String json) => (jsonDecode(json) as Map).cast<String, Object?>();
    Map<String, Object?> lens(Map<String, Object?> json, int index) =>
        (json['lenses']! as List)[index] as Map<String, Object?>;

    test('accepts the examples', () {
      for (final example in [_exampleA, _exampleB, _exampleC, _exampleD, _exampleE]) {
        expect(rawProjectionViolation(sample(example)), isNull);
      }
    });

    test('refuses each broken rule of section 3.4', () {
      final cases = <String, void Function(Map<String, Object?> json)>{
        'version': (json) => json['version'] = 1,
        'kind': (json) => json['kind'] = 'cubeMap',
        'layout': (json) => json['layout'] = 'threeFiles',
        'track count': (json) => (json['tracks']! as List).add((json['tracks']! as List).first),
        'file': (json) => ((json['tracks']! as List).first as Map)['file'] = 2,
        'second file without a URL': (json) => ((json['tracks']! as List).first as Map)['file'] = 1,
        'lens count': (json) => (json['lenses']! as List).removeLast(),
        'texture': (json) => lens(json, 0)['texture'] = 1,
        'region': (json) => lens(json, 0)['region'] = [0.6, 0.0, 0.5, 1.0],
        'canvas': (json) => json['canvasSquare'] = 0,
        'Mei fx': (json) => lens(json, 1)['fx'] = 0,
        'xi': (json) => lens(json, 1)['xi'] = -0.5,
        'determinant': (json) => lens(json, 0)['viewToLens'] = [2, 0, 0, 0, 1, 0, 0, 0, 1],
        'nine numbers': (json) => lens(json, 0)['viewToLens'] = [1, 0, 0, 0, 1, 0, 0, 0],
        'blend order': (json) => json['blendStart'] = 96,
        'max theta': (json) => json['maxTheta'] = 200,
        'not a number': (json) => lens(json, 0)['cy'] = 'x',
      };
      for (final MapEntry(key: rule, value: breakIt) in cases.entries) {
        final json = sample(_exampleA);
        breakIt(json);
        expect(rawProjectionViolation(json), isNotNull, reason: rule);
      }
      final kb = sample(_exampleD);
      lens(kb, 0)['fy'] = -1;
      expect(rawProjectionViolation(kb), isNotNull, reason: 'Kannala-Brandt focal length');
      final equidistant = sample(_exampleA)..['model'] = 'equidistant';
      expect(rawProjectionViolation(equidistant), isNotNull, reason: 'an equidistant lens without radius');
      lens(equidistant, 0)['radius'] = 2900;
      lens(equidistant, 1)['radius'] = 2900;
      expect(rawProjectionViolation(equidistant), isNull);
      final splitWithoutUrl = sample(_exampleC)..['secondUrl'] = '';
      expect(rawProjectionViolation(splitWithoutUrl), isNotNull, reason: 'second URL');
    });

    test('refuses a broken EAC geometry', () {
      final cases = <String, void Function(Map<String, Object?> json)>{
        'middle': (json) => json['middle'] = 2000,
        'right': (json) => json['right'] = 3900,
        'track width': (json) => ((json['tracks']! as List).first as Map)['width'] = 5888,
        'track height': (json) => ((json['tracks']! as List).last as Map)['height'] = 1344,
        'faces': (json) => (json['faces']! as List).removeLast(),
        'slot': (json) => ((json['faces']! as List).last as Map)['slot'] = 1,
        'layout': (json) => json['layout'] = 'twoFiles',
        'view to camera': (json) => json['viewToCamera'] = [1, 0, 0],
      };
      for (final MapEntry(key: rule, value: breakIt) in cases.entries) {
        final json = sample(_exampleE);
        breakIt(json);
        expect(rawProjectionViolation(json), isNotNull, reason: rule);
      }
    });

    test('toNativeJson throws rather than write a JSON a player would refuse', () {
      final plan = RawVideoPlan(
        kind: RawMediaKind.insta360Video,
        layout: RawVideoLayout.twoTracks,
        tracks: const [RawVideoTrack(file: 0, videoTrack: 0), RawVideoTrack(file: 0, videoTrack: 1)],
        calibration: _x3(),
        textureOfLens: const [0, 2],
        url: 'file:///a.insv',
        trackOrderSource: 'default',
      );

      expect(plan.violation, contains('texture 2'));
      expect(plan.toNativeJson, throwsStateError);
    });
  });

  group('RawVideoResolver', () {
    test('two square tracks: lens order from field 80, else 131, else track 0 is lens 0', () async {
      Future<RawVideoPlan> resolve(Insta360LayoutHints? hints) =>
          _resolver(_Calibrations(fallback: _x5(hints: hints))).resolve(
            kind: RawMediaKind.insta360Video,
            input: _input('VID_00_004.insv', probe: _probe([_video(0), _video(1)])),
            findSibling: _noSibling,
          );

      final field80 = await resolve(const Insta360LayoutHints(trackOrder: 1));
      final field80Lens0 = await resolve(const Insta360LayoutHints(trackOrder: 2));
      final field131 = await resolve(const Insta360LayoutHints(trackOrder: 0, streamLayout: 4));
      final none = await resolve(null);

      expect(field80.layout, RawVideoLayout.twoTracks);
      expect(
        [field80.textureOfLens, field80Lens0.textureOfLens, field131.textureOfLens, none.textureOfLens],
        [
          [1, 0],
          [0, 1],
          [1, 0],
          [0, 1],
        ],
      );
      expect(
        [field80.trackOrderSource, field80Lens0.trackOrderSource, field131.trackOrderSource, none.trackOrderSource],
        ['field80', 'field80', 'field131', 'default'],
      );
      expect(field80.outputSize, (width: 7680, height: 3840));
    });

    test('one side by side track: the transcoded stream stays the fallback', () async {
      final plan = await _resolver(_Calibrations()).resolve(
        kind: RawMediaKind.insta360Video,
        input: _input(
          'VID_00_002.insv',
          url: 'https://server/transcoded',
          originalUrl: 'https://server/original',
          fallbackUrl: 'https://server/transcoded',
          probe: _probe([_video(0, width: 5760, height: 2880)]),
        ),
        findSibling: _noSibling,
      );

      expect(
        (plan.layout, plan.url, plan.fallbackUrl),
        (RawVideoLayout.sideBySide, 'https://server/transcoded', 'https://server/transcoded'),
      );
      expect(plan.trackOrder, isNull);
    });

    test('a side by side file without probe: the size of the server, else the frame of the canvas', () async {
      final resolver = _resolver(_Calibrations(fallback: _x3()));

      final sized = await resolver.resolve(
        kind: RawMediaKind.insta360Video,
        input: _input('VID_00_002.insv', width: 5760, height: 2880),
        findSibling: _noSibling,
      );
      final unknown = await resolver.resolve(
        kind: RawMediaKind.insta360Video,
        input: _input('VID_00_002.insv'),
        findSibling: _noSibling,
      );

      expect((sized.layout, sized.outputSize), (RawVideoLayout.sideBySide, (width: 5760, height: 2880)));
      expect((unknown.layout, unknown.outputSize), (RawVideoLayout.sideBySide, (width: 11904, height: 5952)));
      expect(jsonDecode(unknown.toNativeJson())['tracks'], [
        {
          'file': 0,
          'videoTrack': 0,
          'trackId': null,
          'width': null,
          'height': null,
          'codec': null,
          'codecs': null,
          'bitDepth': null,
        },
      ]);
    });

    test('two tracks from the server: the original, without fallback', () async {
      final plan = await _resolver(_Calibrations(fallback: _x5())).resolve(
        kind: RawMediaKind.insta360Video,
        input: _input(
          'VID_00_004.insv',
          url: 'https://server/transcoded',
          originalUrl: 'https://server/original',
          fallbackUrl: 'https://server/transcoded',
          probe: _probe([_video(0), _video(1)]),
        ),
        findSibling: _noSibling,
      );

      expect(plan.url, 'https://server/original');
      expect(plan.fallbackUrl, isNull);
    });

    group('split pairs', () {
      SphericalProbe square({int size = 2880, int? durationMs}) =>
          _probe([_video(0, width: size, height: size, durationMs: durationMs)]);

      test('from either file: the lens of its name, the other file as file 1', () async {
        final calibrations = _Calibrations(insta360: {'VID_20240908_193126_00_004.insv': _x3()});
        Future<RawVideoPlan> open(String name) => _resolver(calibrations).resolve(
          kind: RawMediaKind.insta360Video,
          input: _input(name, probe: square()),
          findSibling: (sibling) async => _input(sibling, probe: square()),
        );

        final fromFirst = await open('VID_20240908_193126_00_004.insv');
        final fromSecond = await open('VID_20240908_193126_10_004.insv');

        expect(fromFirst.layout, RawVideoLayout.twoFiles);
        expect(
          [fromFirst.textureOfLens, fromFirst.trackOrder],
          [
            [0, 1],
            [0, 1],
          ],
        );
        expect(fromFirst.secondUrl, 'file:///VID_20240908_193126_10_004.insv');
        expect(
          [fromSecond.textureOfLens, fromSecond.trackOrder],
          [
            [1, 0],
            [1, 0],
          ],
        );
        expect(fromSecond.secondUrl, 'file:///VID_20240908_193126_00_004.insv');
        expect([fromFirst.tracks[1].file, fromSecond.tracks[1].file], [1, 1]);
        // The calibration of the first lens file either way
        expect(fromFirst.calibration?.cameraModel, 'Insta360 X3');
        expect(fromSecond.calibration?.cameraModel, 'Insta360 X3');
        expect(fromSecond.outputSize, (width: 5760, height: 2880));
      });

      test('no other file: the name looked for', () async {
        await expectLater(
          _resolver(_Calibrations()).resolve(
            kind: RawMediaKind.insta360Video,
            input: _input('VID_20240908_193126_10_004.insv', probe: square()),
            findSibling: _noSibling,
          ),
          throwsA(
            isA<RawVideoUnsupportedException>()
                .having((e) => e.reason, 'reason', RawUnsupportedReason.siblingMissing)
                .having((e) => e.siblingName, 'siblingName', 'VID_20240908_193126_00_004.insv'),
          ),
        );
      });

      test('another file that does not fit counts as missing: another size, duration or recording', () async {
        Future<Object?> open({
          SphericalProbe? sibling,
          Map<String, DualFisheyeCalibration> calibrations = const {},
        }) async {
          try {
            await _resolver(_Calibrations(insta360: calibrations)).resolve(
              kind: RawMediaKind.insta360Video,
              input: _input('VID_10_004.insv', probe: square(durationMs: 60000)),
              findSibling: (name) async => _input(name, probe: sibling ?? square(durationMs: 60000)),
            );
            return null;
          } on RawVideoUnsupportedException catch (error) {
            return error.reason;
          }
        }

        expect(await open(sibling: square(size: 1440, durationMs: 60000)), RawUnsupportedReason.siblingMissing);
        expect(await open(sibling: square(durationMs: 120000)), RawUnsupportedReason.siblingMissing);
        expect(await open(sibling: square(durationMs: 60033)), isNull, reason: 'one frame apart');
        expect(await open(sibling: _probe(const [])), RawUnsupportedReason.siblingMissing);
        DualFisheyeCalibration of(String identity) => _x3(hints: Insta360LayoutHints(groupIdentity: identity));
        expect(
          await open(calibrations: {'VID_00_004.insv': of('A'), 'VID_10_004.insv': of('B')}),
          RawUnsupportedReason.siblingMissing,
        );
        expect(await open(calibrations: {'VID_00_004.insv': of('A'), 'VID_10_004.insv': of('A')}), isNull);
        // The X4 writes the path of each file: the two files of one recording differ by their lens marker only
        const first = '/DCIM/Camera01/VID_20240101_120000_00_004.insv';
        expect(
          await open(
            calibrations: {
              'VID_00_004.insv': of(first),
              'VID_10_004.insv': of('/DCIM/Camera01/VID_20240101_120000_10_004.insv'),
            },
          ),
          isNull,
        );
        expect(
          await open(
            calibrations: {
              'VID_00_004.insv': of(first),
              'VID_10_004.insv': of('/DCIM/Camera01/VID_20240101_130000_10_005.insv'),
            },
          ),
          RawUnsupportedReason.siblingMissing,
        );
      });

      test('takes the calibration of the second file when the first gives only the nominal values', () async {
        final plan =
            await _resolver(
              _Calibrations(insta360: {'VID_00_004.insv': nominalX3(2880), 'VID_10_004.insv': _x3()}),
            ).resolve(
              kind: RawMediaKind.insta360Video,
              input: _input('VID_00_004.insv', probe: square()),
              findSibling: (name) async => _input(name, probe: square()),
            );

        expect(plan.calibration?.source, DualFisheyeSource.file);
      });

      test('a square file of no pair, or a pair where the players lack two streams, has no layout', () async {
        Future<Object?> reason(String name, {bool twoStreams = true}) async {
          try {
            await _resolver(_Calibrations(), twoStreams: twoStreams).resolve(
              kind: RawMediaKind.insta360Video,
              input: _input(name, probe: square()),
              findSibling: (sibling) async => _input(sibling, probe: square()),
            );
            return null;
          } on RawVideoUnsupportedException catch (error) {
            return error.reason;
          }
        }

        expect(await reason('VID_004.insv'), RawUnsupportedReason.unknownLayout);
        expect(await reason('VID_00_004.insv', twoStreams: false), RawUnsupportedReason.unknownLayout);
        expect(await reason('VID_00_004.insv'), isNull);
      });

      test('from the server: the choice of the opened file mirrored, and no fallback unless both have one', () async {
        Future<RawVideoPlan> open({String? siblingFallback}) => _resolver(_Calibrations()).resolve(
          kind: RawMediaKind.insta360Video,
          input: _input(
            'VID_10_004.insv',
            url: 'https://server/a/playback',
            originalUrl: 'https://server/a/original',
            fallbackUrl: 'https://server/a/playback',
            probe: square(),
          ),
          findSibling: (name) async => _input(
            name,
            url: 'https://server/b/playback',
            originalUrl: 'https://server/b/original',
            fallbackUrl: siblingFallback,
            probe: square(),
          ),
        );

        final both = await open(siblingFallback: 'https://server/b/playback');
        final one = await open();

        expect(
          (both.url, both.fallbackUrl, both.secondUrl, both.secondFallbackUrl),
          (
            'https://server/a/playback',
            'https://server/a/playback',
            'https://server/b/playback',
            'https://server/b/playback',
          ),
        );
        expect([one.fallbackUrl, one.secondFallbackUrl], [null, null]);
        expect(one.secondUrl, 'https://server/b/playback');
      });
    });

    test('GoPro: two EAC tracks, else no layout', () async {
      Future<Object?> open(List<ProbedTrack> tracks, {bool twoStreams = true}) async {
        try {
          final plan = await _resolver(_Calibrations(), twoStreams: twoStreams).resolve(
            kind: RawMediaKind.goProVideo,
            input: _input('GS010013.360', originalUrl: 'https://server/original', probe: _probe(tracks)),
            findSibling: _noSibling,
          );
          return plan;
        } on RawVideoUnsupportedException catch (error) {
          return error.reason;
        }
      }

      final plan =
          (await open([_video(0, width: 4096, height: 1344), _video(5, width: 4096, height: 1344)]))! as RawVideoPlan;
      expect(
        (plan.kind, plan.layout, plan.eac, plan.url),
        (
          RawMediaKind.goProVideo,
          RawVideoLayout.twoTracks,
          const GoProEacGeometry(trackWidth: 4096, trackHeight: 1344),
          'https://server/original',
        ),
      );
      expect(plan.fallbackUrl, isNull);
      expect(await open([_video(0), _video(1)]), RawUnsupportedReason.unknownLayout);
      expect(await open([_video(0, width: 4096, height: 1344)]), RawUnsupportedReason.unknownLayout);
      expect(
        await open([_video(0, width: 4096, height: 1344), _video(5, width: 4096, height: 1344)], twoStreams: false),
        RawUnsupportedReason.unknownLayout,
      );
    });

    test('DJI: two square tracks with the calibration of the camd box, else its nominal values', () async {
      final osv = _probe([_video(0), _video(1)]);
      final read = await _resolver(_Calibrations(dji: _osmo360())).resolve(
        kind: RawMediaKind.djiVideo,
        input: _input('CAM_0003_D.OSV', probe: osv),
        findSibling: _noSibling,
      );
      final nominal = await _resolver(_Calibrations()).resolve(
        kind: RawMediaKind.djiVideo,
        input: _input('CAM_0003_D.OSV', probe: osv),
        findSibling: _noSibling,
      );

      expect(
        (read.calibration?.model, read.calibration?.source),
        (DualFisheyeModel.kannalaBrandt, DualFisheyeSource.file),
      );
      expect(read.textureOfLens, [0, 1]);
      expect(read.trackOrderSource, 'dji');
      expect(nominal.calibration?.source, DualFisheyeSource.nominal);
      expect(rawProjectionViolation(nominal.toNativeMap()), isNull);
      await expectLater(
        _resolver(_Calibrations()).resolve(
          kind: RawMediaKind.djiVideo,
          input: _input('CAM_0003_D.OSV', probe: _probe([_video(0)])),
          findSibling: _noSibling,
        ),
        throwsA(isA<RawVideoUnsupportedException>()),
      );
      await expectLater(
        _resolver(_Calibrations(), twoStreams: false).resolve(
          kind: RawMediaKind.djiVideo,
          input: _input('CAM_0003_D.OSV', probe: osv),
          findSibling: _noSibling,
        ),
        throwsA(isA<RawVideoUnsupportedException>()),
      );
    });

    test('reads the tracks of a file the input comes without, and closes it', () async {
      final file = Uint8List.fromList(List.filled(10, 0));
      var closed = false;
      final input = RawVideoInput(
        name: 'GS010013.360',
        key: 'share:GS010013.360',
        url: 'file:///GS010013.360',
        open: () async =>
            (size: file.length, read: (int offset, int length) async => file, close: () async => closed = true),
        probe: const SphericalProbe(),
      );
      final resolver = RawVideoResolver(
        calibrations: _Calibrations(),
        support: const RawVideoPlaybackSupport(twoStreams: true),
        probeFile: (read) async => _probe([_video(0, width: 4096, height: 1344), _video(5, width: 4096, height: 1344)]),
      );

      final plan = await resolver.resolve(kind: RawMediaKind.goProVideo, input: input, findSibling: _noSibling);

      expect(plan.eac?.face, 1344);
      expect(closed, isTrue);
    });

    test('photos are no business of the resolver', () async {
      await expectLater(
        _resolver(
          _Calibrations(),
        ).resolve(kind: RawMediaKind.insta360Photo, input: _input('IMG_001.insp'), findSibling: _noSibling),
        throwsArgumentError,
      );
    });

    test('moves an Insta360 calibration into the window of the sensor its video frames show', () async {
      const window = (areaWidth: 5952, areaHeight: 5952, width: 5760, height: 5760, offsetX: 0, offsetY: 0);
      final plan =
          await _resolver(
            _Calibrations(
              fallback: _x3(given: false, hints: const Insta360LayoutHints(videoWindow: window)),
            ),
          ).resolve(
            kind: RawMediaKind.insta360Video,
            input: _input('VID_00_002.insv', probe: _probe([_video(0, width: 1024, height: 512)])),
            findSibling: _noSibling,
          );

      expect(plan.calibration?.canvasSquare, 5760);
      expect(plan.calibration?.lenses[0].cx, closeTo(2871.48, 1e-9));
    });
  });

  group('calibrationInVideoWindow', () {
    test('maps the lens centres of an X3 video where its frames show them (docs/18-test-media.md, F1)', () {
      const window = (areaWidth: 5952, areaHeight: 5952, width: 5760, height: 5760, offsetX: 0, offsetY: 0);
      final calibration = calibrationInVideoWindow(
        parseInsta360OffsetV3(x3OffsetV3)!.copyWith(layoutHints: const Insta360LayoutHints(videoWindow: window)),
      );
      const scale = 512 / 5760;
      final [lens0, lens1] = calibration.lenses;

      expect(calibration.canvasSquare, 5760);
      expect(lens0.cx * scale, closeTo(255.243, 1e-3));
      expect(lens0.cy * scale, closeTo(258.120, 1e-3));
      expect((lens1.cx - 5760) * scale, closeTo(256.462, 1e-3));
      expect(lens1.cy * scale, closeTo(258.011, 1e-3));
      expect(lens0.fx! * scale, closeTo(411.337, 1e-3));
    });

    test('maps an X4 whose lenses own areas of 8000 x 6000 on the canvas (F2)', () {
      const window = (areaWidth: 8000, areaHeight: 6000, width: 5632, height: 5632, offsetX: 0, offsetY: 0);
      DualFisheyeLens lens(double cx) =>
          DualFisheyeLens(cx: cx, cy: 3000, yaw: 0, pitch: 0, roll: 90, xi: 1.95, fx: 4600, fy: 4600);
      final calibration = calibrationInVideoWindow(
        DualFisheyeCalibration(
          model: DualFisheyeModel.mei,
          lenses: [lens(4000), lens(12000)],
          canvasSquare: 6000,
          layoutHints: const Insta360LayoutHints(videoWindow: window),
        ),
      );
      const scale = 3840 / 5632;

      expect(scale, closeTo(0.6818182, 1e-7));
      expect(calibration.lenses[0].cx * scale, closeTo(1920, 1e-9));
      expect((calibration.lenses[1].cx - calibration.canvasSquare) * scale, closeTo(1920, 1e-9));
      expect(calibration.lenses[1].cy * scale, closeTo(1920, 1e-9));
    });

    test('leaves a calibration without window, or whose canvas the window does not fit', () {
      final x3 = parseInsta360OffsetV3(x3OffsetV3)!;
      const photoWindow = (areaWidth: 5952, areaHeight: 5952, width: 5984, height: 5984, offsetX: 0, offsetY: 0);
      const video = (areaWidth: 5952, areaHeight: 5952, width: 5760, height: 5760, offsetX: 0, offsetY: 0);

      expect(calibrationInVideoWindow(x3), same(x3));
      final larger = x3.copyWith(layoutHints: const Insta360LayoutHints(videoWindow: photoWindow));
      expect(calibrationInVideoWindow(larger), same(larger));
      final nominal = nominalX3(2880).copyWith(layoutHints: const Insta360LayoutHints(videoWindow: video));
      expect(calibrationInVideoWindow(nominal), same(nominal), reason: 'nominal values are in frame pixels');
    });
  });

  test('splitRecordingIdentity gives both files of a split pair one recording, whatever their lens marker', () {
    expect(
      splitRecordingIdentity('/DCIM/Camera01/VID_20240101_120000_10_004.insv'),
      '/dcim/camera01/vid_20240101_120000_00_004.insv',
    );
    expect(
      splitRecordingIdentity(r'\DCIM\Camera01\VID_20240101_120000_10_004.insv'),
      r'\dcim\camera01\vid_20240101_120000_00_004.insv',
    );
    expect(splitRecordingIdentity('VID_20240101_120000_10_004.insv'), 'vid_20240101_120000_00_004.insv');
    expect(splitRecordingIdentity(x5GroupIdentity), x5GroupIdentity.toLowerCase(), reason: 'no file name');
    expect(
      splitRecordingIdentity('/DCIM/Camera01/VID_20240101_120000_10_004.insv'),
      isNot(splitRecordingIdentity('/DCIM/Camera02/VID_20240101_120000_00_004.insv')),
      reason: 'another folder',
    );
  });

  group('rawVideoLikelyPlayable', () {
    const can = RawVideoPlaybackSupport(twoStreams: true);
    const cannot = RawVideoPlaybackSupport(twoStreams: false);
    bool playable(
      RawMediaKind kind,
      String name, {
      SphericalProbe? probe,
      Set<String> folder = const {},
      RawVideoPlaybackSupport support = can,
    }) => rawVideoLikelyPlayable(kind: kind, name: name, probe: probe, folderNames: folder, support: support);
    final square = _probe([_video(0, width: 2880, height: 2880)]);
    final twoTracks = _probe([_video(0), _video(1)]);
    final sideBySide = _probe([_video(0, width: 5760, height: 2880)]);

    test('a file of a split pair: only next to its other file, and with two streams', () {
      const name = 'VID_20240908_193126_10_004.insv';
      const folder = {'vid_20240908_193126_00_004.insv', name};

      expect(playable(RawMediaKind.insta360Video, name, probe: square, folder: folder), isTrue);
      expect(playable(RawMediaKind.insta360Video, name, folder: folder), isTrue, reason: 'no probe, a split name');
      expect(playable(RawMediaKind.insta360Video, name, probe: square), isFalse, reason: 'alone in its folder');
      expect(playable(RawMediaKind.insta360Video, name, probe: square, folder: folder, support: cannot), isFalse);
      expect(playable(RawMediaKind.insta360Video, 'VID_004.insv', probe: square), isFalse, reason: 'no pair name');
    });

    test('two tracks, GoPro and DJI need two streams; side by side and unknown files are likely', () {
      expect(playable(RawMediaKind.insta360Video, 'VID_00_004.insv', probe: twoTracks), isTrue);
      expect(playable(RawMediaKind.insta360Video, 'VID_00_004.insv', probe: twoTracks, support: cannot), isFalse);
      expect(playable(RawMediaKind.goProVideo, 'GS010013.360', support: cannot), isFalse);
      expect(playable(RawMediaKind.djiVideo, 'CAM_0003_D.OSV', support: cannot), isFalse);
      expect(playable(RawMediaKind.djiVideo, 'CAM_0003_D.OSV'), isTrue);
      expect(playable(RawMediaKind.goProVideo, 'GS010013.360', probe: twoTracks), isFalse, reason: 'no EAC tracks');
      expect(playable(RawMediaKind.insta360Video, 'VID_00_002.insv', probe: sideBySide, support: cannot), isTrue);
      expect(playable(RawMediaKind.insta360Video, 'VID_002.insv', support: cannot), isTrue);
      expect(playable(RawMediaKind.insta360Photo, 'IMG_001.insp', support: cannot), isTrue);
    });

    test('a DJI file or two square Insta360 tracks only as two squares of the same size, as the resolver', () {
      final unequal = _probe([_video(0), _video(1, width: 2880, height: 2880)]);
      final wide = _probe([_video(0, width: 3840, height: 1920), _video(1, width: 3840, height: 1920)]);
      final one = _probe([_video(0)]);

      expect(playable(RawMediaKind.djiVideo, 'CAM_0003_D.OSV', probe: twoTracks), isTrue);
      expect(playable(RawMediaKind.djiVideo, 'CAM_0003_D.OSV', probe: unequal), isFalse);
      expect(playable(RawMediaKind.djiVideo, 'CAM_0003_D.OSV', probe: wide), isFalse);
      expect(playable(RawMediaKind.djiVideo, 'CAM_0003_D.OSV', probe: one), isFalse);
      expect(playable(RawMediaKind.djiVideo, 'CAM_0003_D.OSV', probe: _probe([])), isTrue, reason: 'no track listed');
      expect(playable(RawMediaKind.insta360Video, 'VID_00_004.insv', probe: unequal), isFalse);
    });

    test('agrees with the resolver on the files it refuses for their tracks', () async {
      final resolver = RawVideoResolver(
        calibrations: _Calibrations(),
        support: const RawVideoPlaybackSupport(twoStreams: true),
      );
      for (final (kind, name) in [
        (RawMediaKind.djiVideo, 'CAM_0003_D.OSV'),
        (RawMediaKind.insta360Video, 'VID_00_004.insv'),
      ]) {
        final probe = _probe([_video(0), _video(1, width: 2880, height: 2880)]);
        expect(playable(kind, name, probe: probe), isFalse);
        await expectLater(
          resolver.resolve(
            kind: kind,
            input: _input(name, probe: probe),
            findSibling: (_) async => null,
          ),
          throwsA(isA<RawVideoUnsupportedException>()),
        );
      }
    });
  });

  test('RawVideoUnsupportedException tells the file, the reason and the name looked for', () {
    const error = RawVideoUnsupportedException(
      'VID_10_004.insv',
      RawUnsupportedReason.siblingMissing,
      siblingName: 'VID_00_004.insv',
      detail: 'not found',
    );

    expect(error.toString(), allOf(contains('VID_10_004.insv'), contains('siblingMissing'), contains('VID_00_004')));
  });
}
