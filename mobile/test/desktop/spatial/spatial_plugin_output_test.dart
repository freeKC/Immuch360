// The Spatial passes of one player (lib/desktop/spatial/spatial_plugin_output.dart) over a fake plugin: attached with
// mpv's frame kept at the video's shape, at the plugin's default frame for a flat video and at renderer C's start tier
// of the GPU for a 360° one; the viewpoint and the view go to the plugin at most once per frame, the newest, and a
// call that fails is not sent again at each frame; a new look is a new setup of the same passes; the window's size is
// merged while a border is dragged; detach turns them off and gives mpv its letterbox back.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/spatial/spatial_plugin_output.dart';
import 'package:immich_mobile/desktop/video/render/plugin_renderer.dart';
import 'package:media_kit_video/media_kit_video.dart';

const _nvidia = 'ANGLE (NVIDIA, NVIDIA GeForce RTX 4060 Laptop GPU (0x000028E0) Direct3D11 vs_5_0 ps_5_0, D3D11)';

class _Channel implements SpatialChannel {
  final setups = <SpatialSetup>[];
  final viewpoints = <double>[];
  final views = <(PluginView, bool)>[];
  final calls = <String>[];
  bool failViewpoints = false;
  String glRenderer = _nvidia;

  @override
  Future<ProjectionResult> enable(int handle, SpatialSetup setup) async {
    calls.add('enable');
    setups.add(setup);
    return ProjectionResult(ok: true, clientVersion: 3, glRenderer: glRenderer, outputWidth: 1, outputHeight: 1);
  }

  @override
  Future<ProjectionResult> disable(int handle) async {
    calls.add('disable');
    return const ProjectionResult(ok: true);
  }

  @override
  Future<bool> setViewpoint(int handle, double viewpoint) async {
    viewpoints.add(viewpoint);
    if (failViewpoints) {
      throw StateError('no video output');
    }
    return true;
  }

  @override
  Future<bool> setView(int handle, PluginView view, {required bool sharp}) async {
    views.add((view, sharp));
    return true;
  }

  @override
  Future<bool> setDebug(int handle, {required bool disparityMap}) async => true;

  @override
  Future<SpatialStats?> stats(int handle, {bool probe = false}) async => null;
}

void main() {
  late _Channel channel;
  late List<String> mpv;
  late SpatialPluginOutput output;

  // Made in the test's own zone: its futures then complete as the test pumps
  void make() {
    channel = _Channel();
    mpv = [];
    output = SpatialPluginOutput(
      handle: () async => 7,
      setMpvProperty: (name, value) async => mpv.add('$name=$value'),
      channel: channel,
      resizeDelay: const Duration(milliseconds: 50),
      settleDelay: const Duration(milliseconds: 50),
    );
  }

  testWidgets('a flat video: the plugin default frame, the box of the window, the viewpoint it starts from', (
    tester,
  ) async {
    make();
    final result = await output.attach(
      look: const SpatialLook(layout: SpatialLayout.topBottom),
      outputSize: const Size(1920, 1080),
      viewpoint: 0.3,
    );
    expect(result.ok, isTrue);
    expect(mpv, ['keepaspect=no']);
    final setup = channel.setups.single;
    expect(setup.layout, SpatialLayout.topBottom);
    expect(setup.projection, SpatialProjection.flat);
    expect(setup.viewpoint, 0.3);
    expect((setup.maxFrameWidth, setup.maxFramePixels), (3840, 3840 * 2160));
    expect((setup.outputWidth, setup.outputHeight), (1920, 1080));
    await tester.pump();
    expect(channel.viewpoints, isEmpty, reason: 'the setup carried it');
    await output.detach();
    expect(channel.calls.last, 'disable');
    expect(mpv.last, 'keepaspect=yes');
  });

  testWidgets('a 360° video takes the start tier of the GPU, set again once the plugin named it', (tester) async {
    make();
    await output.attach(
      look: const SpatialLook(projection: SpatialProjection.equirect, halfSphere: true),
      outputSize: const Size(1280, 720),
    );
    expect(channel.setups, hasLength(2));
    expect(channel.setups.first.maxFrameWidth, 3840);
    expect(channel.setups.last.maxFrameWidth, PluginTier.full.maxFrameWidth, reason: 'a dedicated GPU');
    expect(channel.setups.last.halfSphere, isTrue);
    output.setView(const PluginView(yaw: 30), moving: true);
    await tester.pump();
    expect(channel.views.last, (const PluginView(yaw: 30), false));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump();
    expect(channel.views.last, (const PluginView(yaw: 30), true), reason: 'sharp once at rest');
    await output.dispose();
  });

  testWidgets('the viewpoint goes once per frame, the newest, and a failed call is not repeated', (tester) async {
    make();
    await output.attach(look: const SpatialLook(), outputSize: const Size(1280, 720));
    output
      ..setViewpoint(0.2)
      ..setViewpoint(0.4)
      ..setViewpoint(0.7);
    await tester.pump();
    expect(channel.viewpoints, [0.7]);
    output.setViewpoint(0.7);
    await tester.pump();
    expect(channel.viewpoints, [0.7], reason: 'the same viewpoint is not sent again');
    output.setViewpoint(2);
    await tester.pump();
    expect(channel.viewpoints.last, 1.0, reason: 'kept between the two cameras');
    channel.failViewpoints = true;
    output.setViewpoint(0.5);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(channel.viewpoints.where((value) => value == 0.5), hasLength(1));
    await output.dispose();
  });

  testWidgets('a new look and a new window size are new setups of the same passes', (tester) async {
    make();
    await output.attach(look: const SpatialLook(), outputSize: const Size(1280, 720));
    expect(await output.setLook(const SpatialLook(layout: SpatialLayout.sideBySideSwapped)), isTrue);
    expect(channel.setups.last.layout, SpatialLayout.sideBySideSwapped);
    final before = channel.setups.length;
    output
      ..setOutputSize(const Size(1300, 720))
      ..setOutputSize(const Size(1400, 760))
      ..setOutputSize(const Size(1500, 800));
    await tester.pump(const Duration(milliseconds: 100));
    expect(channel.setups.length - before, 1, reason: 'merged');
    expect((channel.setups.last.outputWidth, channel.setups.last.outputHeight), (1500, 800));
    expect(mpv.where((value) => value.startsWith('keepaspect')), ['keepaspect=no'], reason: 'nothing of mpv');
    await output.dispose();
  });
}
