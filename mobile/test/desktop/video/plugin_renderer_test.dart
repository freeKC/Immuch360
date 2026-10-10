// Renderer C of the 360 player (plugin_renderer.dart, DP1 of 2026-10-09): what the plugin is given, without the
// plugin. The uniforms of the stitch from the rawProjection JSON, against the values RawStitchUniforms.kt computes
// for the phones; the eye and the part of the sphere of each layout and coverage; the start tier per GPU, from what
// DXGI says of the GPU in use when it is the one ANGLE draws on (an Intel Arc built into the processor is not a card),
// else from its name; and the rules for the player: one view per Flutter frame however many events come, never a second view while the plugin has
// not answered the first, the sharper filter once the view rests, window sizes merged, a tier change at most once a
// second, mpv's keepaspect set and given back.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/render/plugin_renderer.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immuch_desktop_video/immuch_desktop_video.dart';
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

const _intel = 'ANGLE (Intel, Intel(R) UHD Graphics (0x0000A788) Direct3D11 vs_5_0 ps_5_0, D3D11)';
const _nvidia = 'ANGLE (NVIDIA, NVIDIA GeForce RTX 4060 Laptop GPU (0x000028E0) Direct3D11 vs_5_0 ps_5_0, D3D11)';
// The GPU of a Core Ultra 7 155H (Meteor Lake), built into the processor
const _arcIntegrated = 'ANGLE (Intel, Intel(R) Arc(TM) Graphics (0x00007D55) Direct3D11 vs_5_0 ps_5_0, D3D11)';

GpuAdapter _adapter(String name, int deviceId, {required bool integrated}) => GpuAdapter.fromJson({
  'name': name,
  'vendorId': 0x8086,
  'deviceId': deviceId,
  'integrated': integrated,
  'dedicatedMB': integrated ? 128 : 16384,
});

class _Call {
  _Call(this.name, [this.setup, this.view, this.sharp]);

  final String name;
  final ProjectionSetup? setup;
  final PluginView? view;
  final bool? sharp;

  @override
  String toString() => '$name${view == null ? '' : ' $view sharp $sharp'}';
}

class _FakeChannel implements PluginChannel {
  _FakeChannel({this.glRenderer = _intel, this.refuse});

  final String glRenderer;

  /// Why the plugin refuses an enable, null while it accepts
  String? refuse;
  final calls = <_Call>[];

  /// When set, setView waits for it: the plugin has not answered yet
  Completer<void>? holdViews;

  List<_Call> named(String name) => calls.where((call) => call.name == name).toList();

  @override
  Future<ProjectionResult> enable(int handle, ProjectionSetup setup) async {
    // Not expect(): this runs in the renderer's own callbacks, where the test's guarded calls may be under way
    if (handle != 42) {
      throw StateError('handle $handle');
    }
    calls.add(_Call('enable', setup));
    if (refuse != null) {
      return ProjectionResult(ok: false, reason: refuse, clientVersion: 2, glRenderer: glRenderer);
    }
    return ProjectionResult(
      ok: true,
      clientVersion: 3,
      glRenderer: glRenderer,
      outputWidth: setup.outputWidth,
      outputHeight: setup.outputHeight,
    );
  }

  @override
  Future<ProjectionResult> disable(int handle) async {
    calls.add(_Call('disable'));
    return const ProjectionResult(ok: true);
  }

  @override
  Future<bool> setView(int handle, PluginView view, {required bool sharp}) async {
    calls.add(_Call('view', null, view, sharp));
    await holdViews?.future;
    return true;
  }

  @override
  Future<ProjectionStats?> stats(int handle, {bool probe = false}) async => const ProjectionStats(
    enabled: true,
    frames: 3,
    redraws: 0,
    failed: 0,
    frameMs: [],
    redrawMs: [],
    lockedMs: [],
    frameWidth: 4096,
    frameHeight: 2048,
  );
}

List<double> _transpose(List<double> rowMajor) => [for (var i = 0; i < 9; i++) rowMajor[(i % 3) * 3 + i ~/ 3]];

void main() {
  group('the stitch uniforms from the rawProjection JSON', () {
    test('a fisheye pair side by side: what RawStitchUniforms.fisheye gives the phones', () {
      final json = jsonDecode(_exampleA) as Map<String, Object?>;
      final uniforms = rawStitchUniforms(json);
      final lenses = json['lenses']! as List;
      final lens0 = lenses[0] as Map<String, Object?>;
      final lens1 = lenses[1] as Map<String, Object?>;

      expect(uniforms['uViewToLens0'], _transpose((lens0['viewToLens']! as List).cast<double>()));
      expect(uniforms['uViewToLens1'], _transpose((lens1['viewToLens']! as List).cast<double>()));
      expect(uniforms['uIntr0'], [4627.54, 4627.46, 2967.48, 2999.85]);
      // Lens-local: lens 1's cx minus one canvas square
      expect(uniforms['uIntr1']![2], closeTo(8933.2 - 5952.0, 1e-9));
      expect(uniforms['uK0'], [0.38808271, 1.29547262, -3.96876335, 0.0]);
      expect(uniforms['uX0'], [0.0, 1.94817, 0.0017832, -0.00158561], reason: 'k5, xi, p1, p2');
      expect(uniforms['uRegion1'], [0.5, 0.0, 0.5, 1.0]);
      expect(uniforms['uTexOf0'], [0.0]);
      expect(uniforms['uTexOf1'], [0.0]);
      expect(uniforms['uEquidistantFocal0'], [0.0], reason: 'Mei');
      expect(uniforms['uModel'], [0.0]);
      expect(uniforms['uSquare'], [5952.0]);
      expect(uniforms['uTheta']![0], closeTo(100 * math.pi / 180, 1e-12));
      expect(uniforms['uTheta']![1], closeTo(85 * math.pi / 180, 1e-12));
      expect(uniforms['uTheta']![2], closeTo(95 * math.pi / 180, 1e-12));
      expect(uniforms.keys.where((name) => name.startsWith('uHalfTexel')), isEmpty, reason: 'the pass computes them');
    });

    test('the projection of a side by side file has one stream, of a stacked pair two', () {
      expect(PluginProjection.raw(_exampleA).tracks, 1);
      expect(PluginProjection.raw(_exampleA).kind, ProjectionKind.fisheyePair);
      final eac = PluginProjection.raw(_exampleE, streamsEnabled: const [true, false]);
      expect(eac.kind, ProjectionKind.eacPair);
      expect(eac.tracks, 2);
      expect(eac.streamsEnabled, [1.0, 0.0], reason: 'one lens mode: the second stream is not decoded');
    });

    test('an equidistant pair: the focal is the radius over its angle, in radians', () {
      final json = jsonDecode(_exampleA) as Map<String, Object?>;
      json['model'] = 'equidistant';
      for (final lens in (json['lenses']! as List).cast<Map<String, Object?>>()) {
        lens
          ..remove('fx')
          ..remove('fy')
          ..remove('xi')
          ..['radius'] = 2900.0
          ..['radiusTheta'] = 100.0;
      }
      final uniforms = rawStitchUniforms(json);
      expect(uniforms['uModel'], [1.0]);
      expect(uniforms['uEquidistantFocal0']![0], closeTo(2900 / (100 * math.pi / 180), 1e-9));
      expect(uniforms['uIntr0']!.take(2), [0.0, 0.0], reason: 'no fx and fy in an equidistant JSON');
    });

    test('a GoPro EAC pair: what RawStitchUniforms.eac gives the phones', () {
      final uniforms = rawStitchUniforms(jsonDecode(_exampleE) as Map<String, Object?>);
      expect(uniforms['uViewToCamera'], _transpose(const [1.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0]));
      // Rows right, down, forward of face 0
      expect(uniforms['uFace0'], _transpose(const [0.0, 0.0, 1.0, 0.0, -1.0, 0.0, -1.0, 0.0, 0.0]));
      expect(uniforms['uFaceSlot3'], [1.0, 0.0]);
      expect(uniforms['uEac'], [1920.0, 1008.0, 96.0, 2016.0]);
      expect(uniforms['uEacRight'], [3936.0]);
      expect(uniforms['uTrackSize'], [3936.0 + 2 * 1008.0, 1920.0], reason: 'the left slot, the middle, the right');
    });

    test('a JSON the pass cannot draw is refused with the reason', () {
      expect(() => rawStitchUniforms({'version': 1}), throwsFormatException);
      final json = jsonDecode(_exampleA) as Map<String, Object?>;
      json['model'] = 'scaramuzza';
      expect(() => rawStitchUniforms(json), throwsFormatException);
      expect(() => PluginProjection.raw('[]'), throwsFormatException);
    });
  });

  group('equirectangular frames', () {
    test('the eye and the part of the sphere of each layout and coverage', () {
      final mono = PluginProjection.equirect();
      expect(mono.kind, ProjectionKind.equirect);
      expect(mono.eye, [0.0, 0.0, 1.0, 1.0]);
      expect(mono.crop, [0.0, 0.0, 1.0, 1.0]);

      final topBottom = PluginProjection.equirect(layout: StereoLayout.topBottom);
      expect(topBottom.eye, [0.0, 0.0, 1.0, 0.5], reason: 'the left eye on top, as the phones show it');
      expect(PluginProjection.equirect(layout: StereoLayout.topBottom, eye: PluginEye.right).eye, [0.0, 0.5, 1.0, 0.5]);

      final vr180 = PluginProjection.equirect(layout: StereoLayout.leftRight, coverage: SphereCoverage.half);
      expect(vr180.eye, [0.0, 0.0, 0.5, 1.0]);
      expect(vr180.crop, [0.25, 0.0, 0.5, 1.0], reason: 'the front half of the sphere, black behind');
      expect(PluginProjection.equirect(layout: StereoLayout.leftRight, eye: PluginEye.right).eye, [0.5, 0.0, 0.5, 1.0]);
    });
  });

  test('a dedicated GPU starts at the full size, an integrated or unknown one at 2880', () {
    expect(PluginTier.startFor(_nvidia), PluginTier.full);
    expect(PluginTier.startFor('ANGLE (AMD, AMD Radeon RX 7600 Direct3D11 vs_5_0 ps_5_0, D3D11)'), PluginTier.full);
    expect(PluginTier.startFor('ANGLE (Intel, Intel(R) Arc(TM) A770 Graphics Direct3D11)'), PluginTier.full);
    expect(PluginTier.startFor(_intel), PluginTier.w2880);
    expect(
      PluginTier.startFor('ANGLE (AMD, AMD Radeon(TM) Graphics Direct3D11 vs_5_0 ps_5_0, D3D11)'),
      PluginTier.w2880,
    );
    expect(PluginTier.startFor(null), PluginTier.w2880);
    // Without DXGI's answer, the names: an Arc is a card only with a card's model number
    expect(PluginTier.startFor(_arcIntegrated), PluginTier.w2880);
    expect(PluginTier.startFor('ANGLE (Intel, Intel(R) Arc(TM) 140V GPU (0x000064A0) Direct3D11)'), PluginTier.w2880);
    expect(
      PluginTier.startFor('ANGLE (Intel, Intel(R) Arc(TM) B580 Graphics (0x0000E20B) Direct3D11)'),
      PluginTier.full,
    );
    expect(PluginTier.startFor('ANGLE (Intel, Intel(R) Arc(TM) A370M Graphics Direct3D11)'), PluginTier.full);
    expect(PluginTier.startFor('ANGLE (Intel, Intel(R) Arc(TM) Pro A60 Graphics Direct3D11)'), PluginTier.full);
    expect(PluginTier.full.lower, PluginTier.w4096);
    expect(PluginTier.w2880.lower, isNull);
    expect(PluginTier.w4096.maxFramePixels * 4 / (1 << 20), closeTo(32, 0.1), reason: '33.5 MB, 32 MiB');
  });

  test('DXGI decides when its GPU is the one ANGLE draws on', () {
    final integratedArc = _adapter('Intel(R) Arc(TM) Graphics', 0x7d55, integrated: true);
    expect(PluginTier.startFor(_arcIntegrated, adapter: integratedArc), PluginTier.w2880);
    final card = _adapter('Intel(R) Arc(TM) A770 Graphics', 0x56a0, integrated: false);
    expect(
      PluginTier.startFor('ANGLE (Intel, Intel(R) Arc(TM) A770 Graphics (0x000056A0) Direct3D11)', adapter: card),
      PluginTier.full,
    );
    // An unknown name DXGI calls dedicated
    expect(
      PluginTier.startFor(
        'ANGLE (Moore, MTT S80 (0x00000100) Direct3D11)',
        adapter: _adapter('MTT S80', 0x100, integrated: false),
      ),
      PluginTier.full,
    );
    // Another GPU than ANGLE's (the per app preference changed since the app started): the names decide
    expect(PluginTier.startFor(_nvidia, adapter: integratedArc), PluginTier.full);
    expect(PluginTier.startFor(_intel, adapter: card), PluginTier.w2880);
  });

  group('the player', () {
    late _FakeChannel channel;
    late List<String> mpv;
    late DateTime clock;

    PluginRenderer renderer({String glRenderer = _intel, String? refuse, GpuAdapter? adapter}) {
      channel = _FakeChannel(glRenderer: glRenderer, refuse: refuse);
      mpv = [];
      clock = DateTime(2026, 10, 9, 12);
      return PluginRenderer(
        handle: () async => 42,
        setMpvProperty: (name, value) async => mpv.add('$name=$value'),
        channel: channel,
        adapter: adapter == null ? null : () async => adapter,
        now: () => clock,
      );
    }

    testWidgets('attach on an integrated GPU: one call at 2880, the output capped at 1440 lines, keepaspect off', (
      tester,
    ) async {
      final plugin = renderer();
      final attached = await plugin.attach(projection: PluginProjection.equirect(), outputSize: const Size(3200, 2000));
      expect(attached.ok, isTrue);
      expect(attached.tier, PluginTier.w2880);
      expect(attached.glRenderer, _intel);
      final enables = channel.named('enable');
      expect(enables, hasLength(1));
      final setup = enables.single.setup!;
      expect(setup.maxFrameWidth, 2880);
      expect(setup.maxFramePixels, 2880 * 1440);
      expect((setup.outputWidth, setup.outputHeight, setup.maxOutputHeight), (3200, 2000, 1440));
      expect(mpv, ['keepaspect=no']);
      expect(plugin.attached, isTrue);

      await tester.pump();
      expect(channel.named('view'), hasLength(1), reason: 'the first view is sent with the first frame');
      expect(channel.named('view').single.sharp, isTrue);
    });

    testWidgets('attach on a dedicated GPU: the full size, chosen before any frame is drawn', (tester) async {
      final plugin = renderer(glRenderer: _nvidia);
      final attached = await plugin.attach(projection: PluginProjection.equirect(), outputSize: const Size(1920, 1080));
      expect(attached.tier, PluginTier.full);
      expect(channel.named('enable').map((call) => call.setup!.maxFrameWidth), [2880, 8192]);
    });

    testWidgets('a Core Ultra laptop: its Arc built into the processor starts at 2880, as DXGI says', (tester) async {
      final plugin = renderer(
        glRenderer: _arcIntegrated,
        adapter: _adapter('Intel(R) Arc(TM) Graphics', 0x7d55, integrated: true),
      );
      final attached = await plugin.attach(projection: PluginProjection.equirect(), outputSize: const Size(1920, 1080));
      expect(attached.tier, PluginTier.w2880);
      expect(channel.named('enable').map((call) => call.setup!.maxFrameWidth), [2880]);
    });

    testWidgets('a refused attach of the next file: the plugin is flat again, and no view is sent', (tester) async {
      final plugin = renderer();
      await plugin.attach(projection: PluginProjection.equirect(), outputSize: const Size(800, 600));
      expect(plugin.attached, isTrue);
      channel.refuse = 'program: link failed';
      final again = await plugin.attach(projection: PluginProjection.equirect(), outputSize: const Size(800, 600));
      expect(again.ok, isFalse);
      expect(plugin.attached, isFalse);
      await tester.pump();
      channel.calls.clear();
      plugin.setView(const PluginView(yaw: 10));
      await tester.pump();
      expect(channel.named('view'), isEmpty);
    });

    testWidgets('a refused attach leaves the player as it was', (tester) async {
      final plugin = renderer(refuse: 'OpenGL ES 2.0 context: renderer C needs ES 3.0');
      final attached = await plugin.attach(projection: PluginProjection.equirect(), outputSize: const Size(800, 600));
      expect(attached.ok, isFalse);
      expect(attached.reason, contains('ES 2.0'));
      expect(plugin.attached, isFalse);
      expect(mpv, ['keepaspect=no', 'keepaspect=yes']);
      plugin.setView(const PluginView(yaw: 10));
      await tester.pump();
      expect(channel.named('view'), isEmpty);
    });

    testWidgets('a drag sends one view per frame, the newest, bilinear, then the sharp one once it rests', (
      tester,
    ) async {
      final plugin = renderer();
      await plugin.attach(projection: PluginProjection.equirect(), outputSize: const Size(1600, 900));
      await tester.pump();
      channel.calls.clear();

      for (var i = 1; i <= 10; i++) {
        plugin.setView(PluginView(yaw: i.toDouble(), pitch: 5, fov: 80));
      }
      expect(channel.named('view'), isEmpty, reason: 'nothing before the frame');
      await tester.pump(const Duration(milliseconds: 16));
      expect(channel.named('view').map((call) => (call.view!.yaw, call.sharp)), [(10.0, false)]);

      plugin.setView(const PluginView(yaw: 11, pitch: 5, fov: 80));
      plugin.setView(const PluginView(yaw: 12, pitch: 5, fov: 80));
      await tester.pump(const Duration(milliseconds: 16));
      expect(channel.named('view').map((call) => call.view!.yaw), [10.0, 12.0]);

      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 16));
      expect(channel.named('view').last.view!.yaw, 12.0);
      expect(channel.named('view').last.sharp, isTrue, reason: 'at rest after the settle delay');
      expect(channel.named('view'), hasLength(3));

      // The same view at rest again: nothing to send
      plugin.setView(const PluginView(yaw: 12, pitch: 5, fov: 80), moving: false);
      await tester.pump(const Duration(milliseconds: 16));
      expect(channel.named('view'), hasLength(3));
      expect(mpv, ['keepaspect=no'], reason: 'nothing of mpv changes during a drag');
    });

    testWidgets('no second view while the plugin has not answered the first', (tester) async {
      final plugin = renderer();
      await plugin.attach(projection: PluginProjection.equirect(), outputSize: const Size(1600, 900));
      await tester.pump();
      channel.calls.clear();
      channel.holdViews = Completer<void>();

      plugin.setView(const PluginView(yaw: 1));
      await tester.pump(const Duration(milliseconds: 16));
      for (var frame = 0; frame < 5; frame++) {
        plugin.setView(PluginView(yaw: 2.0 + frame));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(channel.named('view').map((call) => call.view!.yaw), [1.0]);

      channel.holdViews!.complete();
      channel.holdViews = null;
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(channel.named('view').map((call) => call.view!.yaw), [1.0, 6.0], reason: 'then the newest only');
      await tester.pump(const Duration(milliseconds: 200));
    });

    testWidgets('window sizes are merged into one new output, the frame and the tier untouched', (tester) async {
      final plugin = renderer();
      await plugin.attach(projection: PluginProjection.equirect(), outputSize: const Size(1600, 900));
      channel.calls.clear();

      for (var width = 1601; width <= 1650; width += 7) {
        plugin.setOutputSize(Size(width.toDouble(), 900));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(channel.named('enable'), isEmpty);
      await tester.pump(const Duration(milliseconds: 120));
      final enables = channel.named('enable');
      expect(enables, hasLength(1));
      expect(enables.single.setup!.outputWidth, 1650);
      expect(enables.single.setup!.maxFrameWidth, 2880);
    });

    testWidgets('a tier changes at most once a second once a frame was drawn', (tester) async {
      final plugin = renderer(glRenderer: _nvidia);
      await plugin.attach(projection: PluginProjection.equirect(), outputSize: const Size(1600, 900));
      await plugin.stats();
      channel.calls.clear();

      expect(await plugin.setTier(PluginTier.w4096), isTrue);
      expect(plugin.tier, PluginTier.w4096);
      clock = clock.add(const Duration(milliseconds: 400));
      expect(await plugin.setTier(PluginTier.w2880), isFalse, reason: 'mpv would draw its frame again');
      expect(plugin.tier, PluginTier.w4096);
      clock = clock.add(const Duration(milliseconds: 700));
      expect(await plugin.setTier(PluginTier.w2880), isTrue);
      expect(channel.named('enable').map((call) => call.setup!.maxFrameWidth), [4096, 2880]);
    });

    testWidgets('another layout changes the pass only, and detach gives the player back', (tester) async {
      final plugin = renderer();
      await plugin.attach(projection: PluginProjection.equirect(), outputSize: const Size(1600, 900));
      channel.calls.clear();

      expect(await plugin.setProjection(PluginProjection.equirect(layout: StereoLayout.topBottom)), isTrue);
      expect(channel.named('enable').single.setup!.eye, [0.0, 0.0, 1.0, 0.5]);

      await plugin.detach();
      expect(channel.named('disable'), hasLength(1));
      expect(mpv, ['keepaspect=no', 'keepaspect=yes']);
      expect(plugin.attached, isFalse);
      plugin.setView(const PluginView(yaw: 30));
      await tester.pump();
      expect(channel.named('view'), isEmpty);
    });
  });
}
