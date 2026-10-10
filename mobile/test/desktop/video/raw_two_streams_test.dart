// Raw files of two streams on the computers (raw_two_streams.dart, design 2.5): the lens regions of the plan rewritten
// into the frame mpv draws (both streams stacked by hstack, one stream alone, the LRV copy with both lenses side by
// side), the hstack graph and mpv's track ids, the stream one lens mode shows, the fallback chain in the phones'
// order (RawPlaybackPlanner.kt) with the LRV copy of design 2.5 before the frame unstitched, and where the LRV copy is
// looked for.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/raw_two_streams.dart';
import 'package:media_kit_video/media_kit_video.dart';

const _bridgeSecond = 'http://127.0.0.1:40213/tok/share-1/DCIM/Camera01/VID_20240908_193126_10_004.insv';
const _bridgeFirst = 'http://127.0.0.1:40213/tok/share-1/DCIM/Camera01/VID_20240908_193126_00_004.insv';

Map<String, Object?> _track(int file, int videoTrack, {int? width = 2880, int? height = 2880, String codec = 'avc1'}) =>
    {
      'file': file,
      'videoTrack': videoTrack,
      'trackId': videoTrack + 1,
      'width': width,
      'height': height,
      'codec': codec,
      'codecs': codec == 'avc1' ? 'avc1.640033' : 'hvc1.1.6.L153',
      'bitDepth': 8,
    };

Map<String, Object?> _lens(int texture, List<double> region, double z) => {
  'texture': texture,
  'region': region,
  'cx': 2967.48,
  'cy': 2999.85,
  'fx': 4627.54,
  'fy': 4627.46,
  'xi': 1.94817,
  'k1': 0.388,
  'k2': 1.295,
  'k3': -3.968,
  'k4': 0.0,
  'k5': 0.0,
  'p1': 0.0,
  'p2': 0.0,
  'viewToLens': [z, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, z],
};

/// A fisheye pair: lens i in texture [textures][i], lens 1 facing the front of the view (as example C of the
/// projections design, an X3 pair whose file opened holds lens 1)
Map<String, Object?> _fisheye({
  String layout = 'twoFiles',
  List<Map<String, Object?>>? tracks,
  List<int> textures = const [1, 0],
  List<List<double>>? regions,
  String? secondUrl = _bridgeSecond,
  String? secondFallbackUrl,
}) => {
  'version': 2,
  'kind': 'dualFisheye',
  'layout': layout,
  'camera': 'Insta360 X3',
  'tracks': tracks ?? [_track(0, 0), _track(layout == 'twoFiles' ? 1 : 0, layout == 'twoFiles' ? 0 : 1)],
  'secondUrl': secondUrl,
  'secondFallbackUrl': secondFallbackUrl,
  'model': 'mei',
  'canvasSquare': 5952.0,
  'maxTheta': 100.0,
  'blendStart': 85.0,
  'blendEnd': 95.0,
  'lenses': [
    _lens(textures[0], regions?[0] ?? const [0.0, 0.0, 1.0, 1.0], -0.99),
    _lens(textures[1], regions?[1] ?? const [0.0, 0.0, 1.0, 1.0], 0.99),
  ],
};

/// The two EAC tracks of a GoPro, its forward face (slot 1 of track 0) along the view's forward
Map<String, Object?> _eac() => {
  'version': 2,
  'kind': 'eacGoPro',
  'layout': 'twoTracks',
  'tracks': [_track(0, 0, width: 4096, height: 1344, codec: 'hvc1'), _track(0, 1, width: 4096, height: 1344)],
  'secondUrl': null,
  'secondFallbackUrl': null,
  'face': 1344,
  'overlap': 64,
  'half': 704,
  'middle': 1408,
  'right': 2688,
  'viewToCamera': [1.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0],
  'faces': [
    {
      'texture': 0,
      'slot': 0,
      'forward': [-1, 0, 0],
      'right': [0, 0, 1],
      'down': [0, -1, 0],
    },
    {
      'texture': 0,
      'slot': 1,
      'forward': [0, 0, 1],
      'right': [1, 0, 0],
      'down': [0, -1, 0],
    },
    {
      'texture': 0,
      'slot': 2,
      'forward': [1, 0, 0],
      'right': [0, 0, -1],
      'down': [0, -1, 0],
    },
    {
      'texture': 1,
      'slot': 0,
      'forward': [0, -1, 0],
      'right': [0, 0, -1],
      'down': [-1, 0, 0],
    },
    {
      'texture': 1,
      'slot': 1,
      'forward': [0, 0, -1],
      'right': [0, 1, 0],
      'down': [-1, 0, 0],
    },
    {
      'texture': 1,
      'slot': 2,
      'forward': [0, 1, 0],
      'right': [0, 0, 1],
      'down': [-1, 0, 0],
    },
  ],
};

List<Object?> _regions(Map<String, Object?> json) => [
  for (final lens in json['lenses']! as List) (lens as Map)['region'],
];

List<Object?> _textures(Map<String, Object?> json) => [
  for (final lens in json['lenses']! as List) (lens as Map)['texture'],
];

void main() {
  group('the lens regions rewritten into the frame mpv draws', () {
    test('an X3 pair stacked by hstack: each lens in the half of its stream, all in texture 0', () {
      final raw = RawStreams.fromJson(_fisheye());
      final rewritten = rewriteRawRegions(raw, const RawFrame.streams([0, 1]));
      // Lens 0 lives in stream 1 (the right half), lens 1 in stream 0 (the left half)
      expect(_regions(rewritten.json), [
        [0.5, 0.0, 0.5, 1.0],
        [0.0, 0.0, 0.5, 1.0],
      ]);
      expect(_textures(rewritten.json), [0, 0]);
      expect(rewritten.enabled, [true, true]);
      expect(rewritten.streamsInFrame, 1);
      // Nothing else of the plan changes: the calibration, the tracks, the other file
      expect(rewritten.json['canvasSquare'], 5952.0);
      expect(rewritten.json['secondUrl'], _bridgeSecond);
      expect(((rewritten.json['lenses']! as List).first as Map)['cx'], 2967.48);
      // The plan itself is left as it was
      expect(_regions(raw.json).first, [0.0, 0.0, 1.0, 1.0]);
    });

    test('streams of two widths: each stream takes its share of the frame, a partial region scales with it', () {
      final raw = RawStreams.fromJson(
        _fisheye(
          layout: 'twoTracks',
          tracks: [_track(0, 0, width: 3000, height: 1000), _track(0, 1, width: 1000, height: 1000)],
          textures: const [0, 1],
          regions: const [
            [0.0, 0.0, 1.0, 1.0],
            [0.1, 0.2, 0.5, 0.6],
          ],
        ),
      );
      final rewritten = rewriteRawRegions(raw, const RawFrame.streams([0, 1]));
      final regions = _regions(rewritten.json);
      expect(regions[0], [0.0, 0.0, 0.75, 1.0]);
      final second = regions[1]! as List<Object?>;
      expect(second[0]! as double, closeTo(0.775, 1e-12));
      expect(second.sublist(1), [0.2, 0.125, 0.6]);
    });

    test('widths not known: the streams share the frame equally, as hstack of one camera gives', () {
      final raw = RawStreams.fromJson(
        _fisheye(
          layout: 'twoTracks',
          tracks: [_track(0, 0, width: null, height: null), _track(0, 1, width: null, height: null)],
          textures: const [0, 1],
        ),
      );
      expect(_regions(rewriteRawRegions(raw, const RawFrame.streams([0, 1])).json), [
        [0.0, 0.0, 0.5, 1.0],
        [0.5, 0.0, 0.5, 1.0],
      ]);
    });

    test('one stream decoded: its lens fills the frame, the other lens goes to texture 1, which is off', () {
      final raw = RawStreams.fromJson(_fisheye());
      final rewritten = rewriteRawRegions(raw, const RawFrame.streams([1]));
      // Stream 1 holds lens 0
      expect(_textures(rewritten.json), [0, 1]);
      expect(_regions(rewritten.json)[0], [0.0, 0.0, 1.0, 1.0]);
      expect(rewritten.enabled, [true, false]);
      expect(rewritten.streamsInFrame, 1);
    });

    test('the LRV copy: lens i in half i, whatever stream the original had it in', () {
      final raw = RawStreams.fromJson(_fisheye());
      final rewritten = rewriteRawRegions(raw, const RawFrame.lensesSideBySide());
      expect(_regions(rewritten.json), [
        [0.0, 0.0, 0.5, 1.0],
        [0.5, 0.0, 0.5, 1.0],
      ]);
      expect(_textures(rewritten.json), [0, 0]);
      expect(rewritten.enabled, [true, true]);
    });

    test('a side by side file is left as the camera has it', () {
      final json = _fisheye(
        layout: 'sideBySide',
        tracks: [_track(0, 0, width: 5760, height: 2880)],
        textures: const [0, 0],
        regions: const [
          [0.0, 0.0, 0.5, 1.0],
          [0.5, 0.0, 0.5, 1.0],
        ],
        secondUrl: null,
      );
      final rewritten = rewriteRawRegions(RawStreams.fromJson(json), const RawFrame.streams([0]));
      expect(_regions(rewritten.json), _regions(json));
      expect(_textures(rewritten.json), [0, 0]);
    });

    test('the uniforms of the stitch pass follow the rewrite', () {
      final projection = rawProjectionFor(RawStreams.fromJson(_fisheye()), const RawFrame.streams([0, 1]));
      expect(projection.kind, ProjectionKind.fisheyePair);
      expect(projection.tracks, 1);
      expect(projection.streamsEnabled, [1, 1]);
      expect(projection.uniforms['uRegion0'], [0.5, 0, 0.5, 1]);
      expect(projection.uniforms['uRegion1'], [0, 0, 0.5, 1]);
      expect(projection.uniforms['uTexOf0'], [0]);
      expect(projection.uniforms['uTexOf1'], [0]);
      final one = rawProjectionFor(RawStreams.fromJson(_fisheye()), const RawFrame.streams([0]));
      expect(one.streamsEnabled, [1, 0]);
      expect(one.uniforms['uTexOf1'], [0]);
      expect(one.uniforms['uTexOf0'], [1]);
    });

    test(
      'the EAC tracks of a GoPro: stacked as they are, cut in two by the pass; one track alone becomes texture 0',
      () {
        final raw = RawStreams.fromJson(_eac());
        final stacked = rewriteRawRegions(raw, const RawFrame.streams([0, 1]));
        expect(stacked.streamsInFrame, 2);
        expect(stacked.json['faces'], raw.json['faces']);
        final second = rewriteRawRegions(raw, const RawFrame.streams([1]));
        expect([for (final face in second.json['faces']! as List) (face as Map)['texture']], [1, 1, 1, 0, 0, 0]);
        expect(second.enabled, [true, false]);
        expect(second.streamsInFrame, 1);
        expect(() => rewriteRawRegions(raw, const RawFrame.lensesSideBySide()), throwsFormatException);
        expect(rawProjectionFor(raw, const RawFrame.streams([0, 1])).tracks, 2);
      },
    );

    test('a frame of a stream the JSON does not have is refused', () {
      expect(
        () => rewriteRawRegions(RawStreams.fromJson(_fisheye()), const RawFrame.streams([2])),
        throwsFormatException,
      );
    });
  });

  group('the streams of the JSON', () {
    test('hstack in the order of the JSON\'s tracks, the external file\'s track after the file\'s own', () {
      final pair = RawStreams.fromJson(_fisheye());
      expect(pair.twoFiles, isTrue);
      expect(pair.hstackGraph, '[vid1] [vid2] hstack [vo]');
      final x4 = RawStreams.fromJson(
        _fisheye(
          layout: 'twoTracks',
          tracks: [
            _track(0, 1, codec: 'hvc1'),
            _track(0, 0, codec: 'hvc1'),
          ],
        ),
      );
      expect(x4.hstackGraph, '[vid2] [vid1] hstack [vo]');
      expect(x4.videoTrackAlone(0), 2);
    });

    test('one lens shows the stream of the lens facing the front, from its own file', () {
      final pair = RawStreams.fromJson(_fisheye());
      // Lens 1 faces the front and lives in stream 0, the file opened
      expect(pair.primaryStream, 0);
      expect(pair.urlOfStream(0, _bridgeFirst), _bridgeFirst);
      expect(pair.urlOfStream(1, _bridgeFirst), _bridgeSecond);
      final swapped = RawStreams.fromJson(_fisheye(textures: const [0, 1]));
      expect(swapped.primaryStream, 1);
      expect(swapped.streamOfFirstFile, 0);
      expect(RawStreams.fromJson(_eac()).primaryStream, 0);
    });

    test('frames of two heights cannot be stacked; unknown heights are tried', () {
      expect(
        RawStreams.fromJson(_fisheye(tracks: [_track(0, 0), _track(1, 0, width: 1920, height: 1920)])).stackable,
        isFalse,
      );
      expect(RawStreams.fromJson(_fisheye(tracks: [_track(0, 0), _track(1, 0, height: null)])).stackable, isTrue);
    });

    test('a JSON without readable tracks is refused', () {
      expect(() => RawStreams.fromJson(const {'layout': 'twoTracks', 'tracks': []}), throwsFormatException);
      expect(
        () => RawStreams.fromJson(const {
          'layout': 'twoTracks',
          'tracks': [
            {'file': 0},
          ],
        }),
        throwsFormatException,
      );
    });
  });

  group('the fallback chain, in the phones\' order', () {
    const original = '/videos/VID_20240908_193126_00_004.insv';
    const transcoded = 'http://127.0.0.1:40213/tok/server/a/transcoded';
    const transcodedSecond = 'http://127.0.0.1:40213/tok/server/b/transcoded';
    const lrv = '/videos/LRV_20240908_193126_11_004.lrv';
    const stack = (hwdec: 'no', reason: 'measured');
    const none = (hwdec: null, reason: 'too slow');

    RawPlaybackChain pairChain({String? fallback = transcoded, String? lowResolution = lrv}) => RawPlaybackChain(
      raw: RawStreams.fromJson(_fisheye(secondFallbackUrl: fallback == null ? null : transcodedSecond)),
      url: original,
      fallbackUrl: fallback,
      lowResolutionUrl: lowResolution,
    );

    test('a side by side file is one frame, and its failures are the route\'s own', () {
      final chain = RawPlaybackChain(
        raw: RawStreams.fromJson(
          _fisheye(layout: 'sideBySide', tracks: [_track(0, 0, width: 5760)], textures: const [0, 0], secondUrl: null),
        ),
        url: original,
        fallbackUrl: transcoded,
      );
      final step = chain.initial(stack);
      expect((step.mode, '${step.streams}', step.url), (RawMode.stitched, '[0]', original));
      expect(chain.afterFailure(step), isNull);
    });

    test('two streams the switch keeps up with: stacked, the other file as an external track', () {
      final step = pairChain().initial(stack);
      expect(step.mode, RawMode.stacked);
      expect(step.streams, [0, 1]);
      expect((step.url, step.externalUrl, step.hwdec, step.notice), (original, _bridgeSecond, 'no', null));
      expect(step.frame, const RawFrame.streams([0, 1]));
      // A two track file has nothing to load beside it
      final x4 = RawPlaybackChain(
        raw: RawStreams.fromJson(_fisheye(layout: 'twoTracks', textures: const [0, 1])),
        url: original,
      ).initial(stack);
      expect((x4.mode, x4.externalUrl), (RawMode.stacked, null));
    });

    test('two streams the switch refuses: one lens, the one facing the front, with the decoder message', () {
      final step = pairChain().initial(none);
      expect((step.mode, '${step.streams}', step.notice), (RawMode.oneLens, '[0]', RawNotice.oneLensDecoder));
      expect(step.url, original);
      expect(step.frame, const RawFrame.streams([0]));
      // The lens facing the front in the other file: that file opens alone
      final other = RawPlaybackChain(
        raw: RawStreams.fromJson(_fisheye(textures: const [0, 1])),
        url: original,
      ).initial(none);
      expect(('${other.streams}', other.url), ('[1]', _bridgeSecond));
    });

    test('a pair without its other file, or of two heights: one lens from the start', () {
      final alone = RawPlaybackChain(raw: RawStreams.fromJson(_fisheye(secondUrl: null)), url: original).initial(stack);
      expect((alone.mode, '${alone.streams}', alone.notice), (RawMode.oneLens, '[0]', RawNotice.oneLensFile));
      final heights = RawPlaybackChain(
        raw: RawStreams.fromJson(_fisheye(tracks: [_track(0, 0), _track(1, 0, height: 1440)])),
        url: original,
      ).initial(stack);
      expect((heights.mode, heights.notice), (RawMode.oneLens, RawNotice.oneLensDecoder));
    });

    test('a stack measured too slow: the next decoding path, then one lens', () {
      final chain = pairChain();
      final first = chain.initial(stack);
      final copy = chain.afterSlowStack(first, (hwdec: 'd3d11va-copy', reason: 'not measured yet'))!;
      expect((copy.mode, copy.hwdec, copy.externalUrl), (RawMode.stacked, 'd3d11va-copy', _bridgeSecond));
      final one = chain.afterSlowStack(copy, none)!;
      expect((one.mode, one.notice), (RawMode.oneLens, RawNotice.oneLensDecoder));
      expect(chain.afterSlowStack(one, stack), isNull, reason: 'only a stack is measured so');
    });

    test('a stack that fails: one lens of the file opened when the other file cannot be read', () {
      final chain = pairChain();
      final first = chain.initial(stack);
      final unreadable = chain.afterFailure(first, externalReadable: false)!;
      expect(
        (unreadable.mode, '${unreadable.streams}', unreadable.notice),
        (RawMode.oneLens, '[0]', RawNotice.oneLensFile),
      );
      final decoders = chain.afterFailure(first)!;
      expect((decoders.mode, decoders.notice), (RawMode.oneLens, RawNotice.oneLensDecoder));
    });

    test(
      'the whole ladder of a pair: two lenses, one lens, the transcoded pair, the LRV copy, unstitched, the error',
      () {
        final chain = pairChain();
        final steps = <RawStep>[chain.initial(stack)];
        for (var next = chain.afterFailure(steps.last); next != null; next = chain.afterFailure(steps.last)) {
          steps.add(next);
        }
        expect(
          [for (final step in steps) (step.mode, step.notice, step.url)],
          [
            (RawMode.stacked, null, original),
            (RawMode.oneLens, RawNotice.oneLensDecoder, original),
            (RawMode.stacked, null, transcoded),
            (RawMode.stitched, RawNotice.lowResolutionCopy, lrv),
            (RawMode.unstitched, RawNotice.unstitched, original),
          ],
        );
        // The transcoded pair stacks both transcoded files, its decoding path chosen when it opens
        expect((steps[2].externalUrl, steps[2].fromFallback, steps[2].hwdec), (transcodedSecond, true, null));
        expect(steps[3].frame, const RawFrame.lensesSideBySide());
        expect(steps[4].frame, isNull);
      },
    );

    test('without transcoded streams nor LRV copy: one lens, then the frame unstitched', () {
      final chain = pairChain(fallback: null, lowResolution: null);
      final one = chain.afterFailure(chain.initial(stack))!;
      final last = chain.afterFailure(one)!;
      expect((last.mode, last.notice, last.url), (RawMode.unstitched, RawNotice.unstitched, original));
      expect(chain.afterFailure(last), isNull);
    });

    test('a two track file: its transcoded stream holds one lens, so it plays unstitched, then the LRV copy', () {
      final chain = RawPlaybackChain(
        raw: RawStreams.fromJson(_fisheye(layout: 'twoTracks', textures: const [0, 1])),
        url: original,
        fallbackUrl: transcoded,
        lowResolutionUrl: lrv,
      );
      final one = chain.initial(none);
      final next = chain.afterFailure(one)!;
      expect(
        (next.mode, next.url, next.fromFallback, next.notice),
        (RawMode.unstitched, transcoded, true, RawNotice.unstitched),
      );
      final lowResolution = chain.afterFailure(next)!;
      expect((lowResolution.url, lowResolution.lowResolution), (lrv, true));
    });

    test('the transcoded pair too slow stacked: the LRV copy', () {
      final chain = pairChain();
      final transcodedPair = chain.afterFailure(chain.afterFailure(chain.initial(stack))!)!;
      final next = chain.afterSlowStack(transcodedPair.withHwdec('no'), none)!;
      expect((next.mode, next.lowResolution), (RawMode.stitched, true));
    });

    test('a GoPro has no LRV copy to stitch', () {
      final chain = RawPlaybackChain(raw: RawStreams.fromJson(_eac()), url: original, lowResolutionUrl: lrv);
      final last = chain.afterFailure(chain.initial(none))!;
      expect(last.mode, RawMode.unstitched);
    });

    test('a step says nothing of its URLs in the logs: a bridge URL carries its token', () {
      final step = pairChain().initial(stack);
      expect('$step', isNot(contains('tok')));
      expect('$step', contains('external file'));
    });
  });

  group('the LRV copy next to the file', () {
    test('the names the camera gives it', () {
      expect(lowResolutionNamesOf('VID_20240908_193126_00_004.insv'), [
        'LRV_20240908_193126_11_004.lrv',
        'LRV_20240908_193126_01_004.lrv',
      ]);
      expect(lowResolutionNamesOf('VID_20240908_193126_10_004.insv').first, 'LRV_20240908_193126_11_004.lrv');
      expect(lowResolutionNamesOf('PRO_VID_20240908_193126_00_004(1).insv').first, 'LRV_20240908_193126_11_004.lrv');
      expect(lowResolutionNamesOf('GS010001.360'), isEmpty);
      expect(lowResolutionNamesOf('VID_20240908_193126_00_004.mp4'), isEmpty);
    });

    test('next to a path, a file URI and a bridge URL; never for a URL of the server', () {
      expect(
        lowResolutionCandidates(r'D:\Insta\VID_20240908_193126_00_004.insv').first,
        r'D:\Insta\LRV_20240908_193126_11_004.lrv',
      );
      expect(
        lowResolutionCandidates('/home/u/VID_20240908_193126_00_004.insv').first,
        '/home/u/LRV_20240908_193126_11_004.lrv',
      );
      expect(
        lowResolutionCandidates('file:///D:/Insta%20360/VID_20240908_193126_00_004.insv').first,
        'file:///D:/Insta%20360/LRV_20240908_193126_11_004.lrv',
      );
      expect(
        lowResolutionCandidates(_bridgeFirst).first,
        'http://127.0.0.1:40213/tok/share-1/DCIM/Camera01/LRV_20240908_193126_11_004.lrv',
      );
      expect(lowResolutionCandidates('https://photos.example.org/api/assets/1234/video/playback'), isEmpty);
    });

    test('the first candidate that can be read', () async {
      final asked = <String>[];
      final found = await findLowResolutionCopy(
        '/v/VID_20240908_193126_00_004.insv',
        readable: (url) async {
          asked.add(url);
          return url.contains('_01_');
        },
      );
      expect(found, '/v/LRV_20240908_193126_01_004.lrv');
      expect(asked, hasLength(2));
      expect(await findLowResolutionCopy('/v/clip.mp4', readable: (_) async => true), isNull);
    });

    test('a file of this computer that exists, a bridge URL that answers', () async {
      final folder = Directory.systemTemp.createTempSync('raw_two_streams_test');
      addTearDown(() => folder.deleteSync(recursive: true));
      final file = File('${folder.path}/LRV_20240908_193126_11_004.lrv')..writeAsBytesSync([0]);
      expect(await rawUrlReadable(file.path), isTrue);
      expect(await rawUrlReadable(file.uri.toString()), isTrue);
      expect(await rawUrlReadable('${folder.path}/missing.lrv'), isFalse);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response.statusCode = request.uri.path.endsWith('.lrv') ? 200 : 404;
        unawaited(request.response.close());
      });
      expect(await rawUrlReadable('http://127.0.0.1:${server.port}/tok/s/LRV_1.lrv'), isTrue);
      expect(await rawUrlReadable('http://127.0.0.1:${server.port}/tok/s/VID_1.insv'), isFalse);
    });
  });
}
