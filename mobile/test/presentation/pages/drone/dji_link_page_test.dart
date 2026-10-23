// The DJI link page: what it shows of a device that cannot read a remote controller at all, of a link that is open,
// of the counters, of an exported capture, of the live picture and its counters, of the flight and battery values,
// of "Your hardware" and of a capture being played. The safety banner is there in every one of those states.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/pages/drone/dji_link.page.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_video.widget.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';

import '../../../unit/presentation/presentation_context.dart';

DjiLinkEnvironment _environment({bool accessoryFeature = true, bool djiInstalled = false}) => DjiLinkEnvironment(
  deviceManufacturer: 'Oculus',
  deviceModel: 'Quest 3',
  buildFingerprint: 'oculus/hollywood/hollywood:14/UP1A/1234:user/release-keys',
  androidRelease: '14',
  sdkInt: 34,
  appVersion: '3.3.0',
  flavour: 'quest',
  hasAccessoryFeature: accessoryFeature,
  hasHostFeature: true,
  accessoryNodeExists: accessoryFeature,
  accessoryNodeWritable: accessoryFeature,
  futureUsbLibraryPresent: false,
  adbEnabled: true,
  usbStateKnown: true,
  usbConnected: true,
  usbConfigured: false,
  usbAccessoryMode: false,
  usbAdbFunction: true,
  djiApplicationInstalled: djiInstalled,
  accessoriesListed: 0,
  transportPossible: accessoryFeature,
  chargeCurrentMicroAmps: -250000,
);

DjiLinkCounters _counters({
  int unknownChannelFrames = 0,
  int unknownChannelRejections = 0,
  int headerCrcFailures = 0,
}) => DjiLinkCounters(
  envelopeFrames: 12,
  envelopeBytes: 4096,
  payloadBytes: 3900,
  discardedBytes: 7,
  resynchronisations: 1,
  unknownChannelFrames: unknownChannelFrames,
  unknownChannelRejections: unknownChannelRejections,
  oversizeRejections: 0,
  incompleteTimeouts: 0,
  controlFrames: 9,
  headerCrcFailures: headerCrcFailures,
  frameCrcFailures: 0,
  lengthRejections: 0,
  unsupportedEncryption: 0,
  knownPairs: 8,
  unknownPairs: 1,
  aircraftSideFrames: 5,
  controllerSideFrames: 4,
  ambiguousSideFrames: 0,
  keepAliveExceptions: 0,
);

DjiLinkSticks _sticks({int? sampleAgeMs, List<String> reasons = const []}) => DjiLinkSticks(
  kind: 'gamepad',
  throttle: 0,
  yaw: 0,
  pitch: 0,
  roll: 0,
  triggersHeld: false,
  armed: false,
  neutralised: true,
  reasons: reasons,
  sendPathEnabled: false,
  sampleAgeMs: sampleAgeMs,
);

DjiLinkCrc _crc({int? headerSeedCandidate, int headerSeedVotes = 0, int headerFailuresVoting = 0}) => DjiLinkCrc(
  headerParameters: 'crc8-r8c-77',
  frameParameters: 'crc16-r8408-3692',
  headerSeedCandidate: headerSeedCandidate,
  headerSeedVotes: headerSeedVotes,
  headerFailuresVoting: headerFailuresVoting,
  frameSeedVotes: 0,
  frameFailuresVoting: 0,
);

DjiLinkDecode _decode({
  DjiLinkVideoState state = DjiLinkVideoState.decoding,
  String? failure,
  DjiLinkDescriptionSource source = DjiLinkDescriptionSource.profile,
  String? switchReason,
  int? keyPictureAgoMs,
  int? lastOutputAgoMs = 40,
}) => DjiLinkDecode(
  state: state,
  failure: failure,
  codec: 'h265',
  width: 1920,
  height: 1080,
  profileName: 'Main',
  highTier: true,
  levelName: '5.0',
  descriptionSource: source,
  decoderName: 'c2.android.hevc.decoder',
  decoderHardware: false,
  choice: DjiLinkDecoderChoice.automatic,
  lowLatency: true,
  switches: 1,
  switchReason: switchReason,
  unitsIn: 336,
  queued: 330,
  decoded: 320,
  shown: 300,
  droppedAtDisplay: 20,
  overruns: 0,
  tooLarge: 0,
  unitsWithoutDescription: 29,
  errors: 0,
  picturesPerSecond: 30,
  megabitsPerSecond: 4.8,
  decodeLastMs: 6.1,
  decodeMedianMs: 5.5,
  decodeP95Ms: 9.25,
  inProcessMedianMs: 0.12,
  inProcessP95Ms: 0.4,
  firstPictureMs: 180,
  lostPictures: 0,
  encoderRestarts: 1,
  keyPictures: 1,
  keyPictureAgoMs: keyPictureAgoMs,
  lastOutputAgoMs: lastOutputAgoMs,
);

DjiLinkTelemetry _telemetry({bool stale = false}) => DjiLinkTelemetry(
  aircraftPresent: true,
  remotePresent: true,
  layoutMismatches: 0,
  flight: DjiLinkFlight(
    ageMs: stale ? 4200 : 80,
    stale: stale,
    heightM: -0.5,
    speedsMps: const [0.4, -0.4, 0],
    pitchDeg: -11,
    rollDeg: 26.9,
    headingDeg: 126.8,
    mode: 12,
    inAir: true,
    motorsOn: true,
    motorTimeS: 38.7,
    satellites: 0,
    groundHeightM: 0.9,
    evidence: DjiLinkEvidence.publicAndCapture,
  ),
  battery: DjiLinkBattery(
    ageMs: 300,
    stale: false,
    percent: 38,
    volts: 6.18,
    amps: -7.256,
    remainingMah: 582,
    fullMah: 1525,
    temperatureC: 26.9,
    cells: 2,
    status: '0000000000000000',
    evidence: DjiLinkEvidence.publicAndCapture,
  ),
  link: DjiLinkLinkInfo(
    signalAircraftSide: 90,
    signalRemoteSide: 90,
    liveRateMbps: 5.9,
    aircraftClockMs: 92757,
    clockJitterP95Ms: 40,
    clockDriftMs: 10,
    ageMs: 20,
  ),
  remoteBatteryPercent: 50,
  unanswered: [
    DjiLinkRequestRow(
      senderType: 3,
      senderIndex: 0,
      commandSet: 3,
      commandId: 143,
      ackPolicy: 2,
      count: 119,
      repeats: 49,
    ),
  ],
);

DjiLinkSnapshot _snapshot({
  DjiLinkState state = DjiLinkState.accessoryOpen,
  DjiLinkReason? reason,
  String? detail,
  DjiLinkAccessory? accessory,
  DjiLinkProfile? profile,
  bool probesHalted = false,
  DjiLinkCrc? crc,
  int? firstByteMs,
  int captureBytes = 0,
  List<DjiLinkFrame> frames = const [],
  List<DjiLinkChannel> channels = const [],
  List<DjiLinkTelemetryRow> telemetry = const [],
  DjiLinkCounters? counters,
  DjiLinkSticks? sticks,
  DjiLinkDecode? decode,
  DjiLinkTelemetry? telemetryValues,
  DjiLinkSource? source,
  DjiLinkAccessory? lastAccessory,
  String? boundProfileId,
}) => DjiLinkSnapshot(
  state: state,
  reason: reason,
  detail: detail,
  accessory: accessory,
  profile: profile,
  probesHalted: probesHalted,
  opens: 1,
  crc: crc ?? _crc(),
  firstByteMs: firstByteMs,
  probesSent: 3,
  probeFailures: 1,
  consecutiveProbeFailures: 0,
  lastProbeCallMs: 4,
  bytesRead: 4096,
  bytesWritten: 3,
  reads: 2,
  writes: 3,
  attempts: 1,
  quietWindowMs: 20000,
  aircraftLinked: false,
  counters: counters ?? _counters(),
  channels: channels,
  pairs: const [],
  frames: frames,
  telemetry: telemetry,
  video: DjiLinkVideo(
    verdict: DjiLinkProbeVerdict.noData,
    payloads: 0,
    payloadsStartingWithStartCode: 0,
    startCodesSeen: 0,
    unitTypes: '',
    sawH264ParameterSets: false,
    sawH265ParameterSets: false,
    channels: const [],
  ),
  capture: DjiLinkCapture(
    recording: captureBytes > 0,
    totalBytes: captureBytes,
    droppedBytes: 0,
    records: captureBytes > 0 ? 4 : 0,
    capacityBytes: 16 * 1024 * 1024,
    headBytes: 4 * 1024 * 1024,
  ),
  sticks: sticks ?? _sticks(),
  videoDecode: decode,
  telemetryValues: telemetryValues,
  source: source,
  lastAccessory: lastAccessory,
  boundProfileId: boundProfileId,
);

final _profiles = [
  DjiLinkProfile(id: 'rc-n3-neo2', label: 'DJI RC-N3 with a Neo 2 and the Digital Transceiver', capabilities: const []),
  DjiLinkProfile(id: 'rc-2', label: 'DJI RC 2', capabilities: const []),
];

final _export20261023 = DjiLinkCaptureFile(
  name: 'dji-link-20261023-102731',
  binUri: 'content://media/external/downloads/101',
  indexUri: 'content://media/external/downloads/102',
  bytes: 8388608,
  modifiedMs: 1792744042188,
  origin: 'export',
);

class _FakeApi extends Fake implements DjiLinkApi {
  _FakeApi({DjiLinkEnvironment? environment, DjiLinkSnapshot? snapshot})
    : environment = environment ?? _environment(),
      snapshotValue = snapshot ?? _snapshot();

  DjiLinkEnvironment environment;
  DjiLinkSnapshot snapshotValue;
  DjiLinkExport exportResult = DjiLinkExport(
    ok: true,
    bytes: 4096,
    binPath: 'Download/Immuch360/dji-link/dji-link-20261022-120000.bin',
    indexPath: 'Download/Immuch360/dji-link/dji-link-20261022-120000.idx.csv',
    headerPath: 'Download/Immuch360/dji-link/dji-link-20261022-120000.json',
    sha256: 'a1b2c3',
  );

  int starts = 0;
  int stops = 0;
  int retries = 0;
  int captureStarts = 0;
  final exports = <DjiLinkExportNotes>[];
  final bindings = <String?>[];
  final choices = <DjiLinkDecoderChoice>[];
  final played = <(String, int)>[];
  int playbackStops = 0;
  int pickerOpens = 0;
  List<DjiLinkCaptureFile> captures = [];
  DjiLinkCaptureFile? chosen;
  String? playOutcome;

  @override
  Future<DjiLinkEnvironment> readEnvironment() async => environment;

  @override
  Future<void> start() async => starts += 1;

  @override
  Future<void> stop() async => stops += 1;

  @override
  Future<void> retry() async => retries += 1;

  @override
  Future<DjiLinkSnapshot> snapshot() async => snapshotValue;

  @override
  Future<void> startCapture() async => captureStarts += 1;

  @override
  Future<void> stopCapture() async {}

  @override
  Future<void> clearCapture() async {}

  @override
  Future<DjiLinkExport> exportCapture(DjiLinkExportNotes notes) async {
    exports.add(notes);
    return exportResult;
  }

  @override
  Future<List<DjiLinkProfile>> profiles() async => _profiles;

  @override
  Future<void> bindProfile(String? profileId) async => bindings.add(profileId);

  @override
  Future<void> setDecoderChoice(DjiLinkDecoderChoice choice) async => choices.add(choice);

  @override
  Future<List<DjiLinkCaptureFile>> listCaptures() async => captures;

  @override
  Future<DjiLinkCaptureFile?> chooseCaptureFiles() async {
    pickerOpens += 1;
    return chosen;
  }

  @override
  Future<String?> playCapture(String binUri, String indexUri, int startAtMs) async {
    played.add((binUri, startAtMs));
    return playOutcome;
  }

  @override
  Future<void> stopPlayback() async => playbackStops += 1;
}

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  Future<DjiLinkEvents?> pumpPage(WidgetTester tester, _FakeApi api) async {
    DjiLinkEvents? listener;
    // The page is a long list and the test viewport is 800 by 600: a tall surface builds every section, so that a
    // section that stopped showing fails here rather than hiding behind a scroll
    await tester.binding.setSurfaceSize(const Size(1000, 6000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpTestWidget(
      context,
      const DjiLinkPage(),
      overrides: [
        djiLinkApiProvider.overrideWithValue(api),
        djiLinkEventsSetUpProvider.overrideWithValue((events) => listener = events),
        // No platform view under flutter test: a placeholder stands where the picture is
        djiLinkVideoViewBuilderProvider.overrideWithValue(
          () => const ColoredBox(key: Key('dji_link_video_placeholder'), color: Colors.black),
        ),
      ],
      // The first frame shows the indeterminate indicator of a page that is still asking the device: settling waits
      // for an animation that only ends once the answers are in
      expectSettle: false,
    );
    await tester.pump();
    await tester.pumpAndSettle();
    return listener;
  }

  testWidgets('says plainly when this device cannot be a USB accessory, and offers nothing to start', (tester) async {
    final api = _FakeApi(environment: _environment(accessoryFeature: false));

    await pumpPage(tester, api);

    expect(find.byKey(const Key('dji_link_no_transport')), findsOneWidget);
    expect(find.byKey(const Key('dji_link_safety')), findsOneWidget);
    expect(find.byKey(const Key('dji_link_link')), findsNothing);
    expect(find.byKey(const Key('dji_link_retry')), findsNothing);
    expect(find.byKey(const Key('dji_link_capture_start')), findsNothing);
    expect(api.starts, 0);
    // A capture can still be played here, which measures the decoder of a headset with no remote at all
    expect(find.byKey(const Key('dji_link_video_panel')), findsOneWidget);
    expect(find.byKey(const Key('dji_link_flight_note')), findsOneWidget);
    expect(find.byKey(const Key('dji_link_play')), findsOneWidget);
  });

  testWidgets('shows what this device can do about a USB accessory', (tester) async {
    final api = _FakeApi(environment: _environment(djiInstalled: true));

    await pumpPage(tester, api);

    expect(find.byKey(const Key('dji_link_environment')), findsOneWidget);
    expect(find.text('USB accessory feature'), findsOneWidget);
    expect(find.text('Quest 3'), findsNothing, reason: 'the model is a label of its own row');
    expect(find.textContaining('oculus/hollywood'), findsOneWidget);
    expect(find.text('DJI application installed'), findsOneWidget);
    expect(api.starts, 1);
  });

  testWidgets('a link that never gave a byte says so', (tester) async {
    final api = _FakeApi(
      snapshot: _snapshot(
        state: DjiLinkState.linkUsable,
        reason: DjiLinkReason.probeReturns,
        accessory: DjiLinkAccessory(manufacturer: 'DJI', model: 'com.dji.logiclink', description: ' RC'),
      ),
    );

    await pumpPage(tester, api);

    expect(find.text('Link takes bytes'), findsOneWidget);
    expect(find.text('never'), findsOneWidget);
    expect(find.text('The liveness probe returns. Nothing has answered yet.'), findsOneWidget);
    expect(find.textContaining('com.dji.logiclink'), findsOneWidget);
    expect(find.textContaining('Nothing is written for the first 20 seconds'), findsOneWidget);
  });

  testWidgets('a refused permission is a state of its own, with the banner still there', (tester) async {
    final api = _FakeApi(
      snapshot: _snapshot(state: DjiLinkState.permissionDenied, reason: DjiLinkReason.permissionRefused),
    );

    await pumpPage(tester, api);

    expect(find.text('USB permission refused'), findsOneWidget);
    expect(find.textContaining('It is asked again only when you tap Try again'), findsOneWidget);
    expect(find.byKey(const Key('dji_link_safety')), findsOneWidget);

    await tester.tap(find.byKey(const Key('dji_link_retry')));
    await tester.pumpAndSettle();
    expect(api.retries, 1);
  });

  testWidgets('a technical word from the native side follows the sentence of the reason', (tester) async {
    final api = _FakeApi(
      snapshot: _snapshot(
        state: DjiLinkState.permissionDenied,
        reason: DjiLinkReason.permissionRequestFailed,
        detail: 'SecurityException',
      ),
    );

    await pumpPage(tester, api);

    expect(find.text('The USB permission could not be asked for. (SecurityException)'), findsOneWidget);
  });

  testWidgets('an accessory nobody has described is named by its strings, and a blocked probe is said', (tester) async {
    final api = _FakeApi(
      snapshot: _snapshot(
        state: DjiLinkState.accessoryOpen,
        reason: DjiLinkReason.writeBlocked,
        probesHalted: true,
        accessory: DjiLinkAccessory(manufacturer: 'Acme', model: 'Bridge'),
        profile: DjiLinkProfile(
          id: 'observed-acme-bridge-none',
          label: 'Accessory not described yet: Acme Bridge',
          capabilities: [DjiLinkCapability(name: 'VIDEO_DECODE', support: DjiLinkSupport.unknown)],
        ),
      ),
    );

    await pumpPage(tester, api);

    expect(find.text('Accessory not described yet: Acme Bridge'), findsOneWidget);
    expect(find.text('Decode the video'), findsOneWidget);
    expect(find.byKey(const Key('dji_link_probes_halted')), findsOneWidget);
    expect(find.textContaining('Probing stopped; reading goes on.'), findsOneWidget);
  });

  testWidgets('counters, channels and frames are shown as they are', (tester) async {
    final api = _FakeApi(
      snapshot: _snapshot(
        counters: _counters(unknownChannelFrames: 2, unknownChannelRejections: 3, headerCrcFailures: 5),
        crc: _crc(headerSeedCandidate: 0x21, headerSeedVotes: 5, headerFailuresVoting: 6),
        channels: [
          DjiLinkChannel(
            channel: 22345,
            role: 'control',
            envelopes: 9,
            bytes: 300,
            largestPayload: 64,
            lastArrivalMs: 1000,
            firstArrivalMs: 900,
          ),
        ],
        frames: [
          DjiLinkFrame(
            atMs: 1000,
            channel: 22345,
            commandSet: 3,
            commandId: 67,
            isAcknowledgement: false,
            ackPolicy: 0,
            senderType: 3,
            receiverType: 2,
            sequence: 12,
            length: 20,
            encryption: 0,
            preview: '01 02 03',
          ),
        ],
        telemetry: [
          DjiLinkTelemetryRow(
            commandSet: 3,
            commandId: 67,
            count: 9,
            lastLength: 20,
            ratePerSecond: 10,
            preview: '01 02 03',
          ),
        ],
      ),
    );

    await pumpPage(tester, api);

    expect(find.byKey(const Key('dji_link_channels')), findsOneWidget);
    expect(find.byKey(const Key('dji_link_counters')), findsOneWidget);
    expect(find.textContaining('22345 control'), findsOneWidget);
    expect(find.text('Header checksum failures'), findsOneWidget);
    expect(find.text('5'), findsWidgets);
    expect(find.text('False sync patterns refused on an undescribed channel'), findsOneWidget);
    expect(find.text('3'), findsWidgets);
    expect(find.text('set 3 id 67'), findsOneWidget, reason: 'a telemetry row is its numbers, with no name');
    expect(find.textContaining('channel 22345, set 3 id 67, request'), findsOneWidget);
    expect(find.textContaining('Fields are read in the Flight and battery section'), findsOneWidget);
    expect(find.byKey(const Key('dji_link_crc')), findsOneWidget);
    expect(find.text('crc8-r8c-77 crc16-r8408-3692'), findsOneWidget);
    expect(find.text('0x21, 5 of 6 failures'), findsOneWidget);
  });

  testWidgets('with nothing captured the export writes the header alone and says so', (tester) async {
    final api = _FakeApi(snapshot: _snapshot(captureBytes: 0))
      ..exportResult = DjiLinkExport(
        ok: true,
        bytes: 0,
        headerPath: '/storage/emulated/0/Android/data/app/files/dji-link/dji-link-20261022-120000.json',
        sha256: 'e3b0c4',
        headerOnly: true,
      );

    await pumpPage(tester, api);

    expect(find.byKey(const Key('dji_link_capture_privacy')), findsOneWidget);
    final exportButton = find.byKey(const Key('dji_link_capture_export'));
    expect(tester.widget<FilledButton>(exportButton).onPressed, isNotNull);
    await tester.tap(exportButton);
    await tester.pumpAndSettle();

    expect(api.exports, hasLength(1));
    expect(find.byKey(const Key('dji_link_capture_header_only')), findsOneWidget);
    expect(find.textContaining('dji-link-20261022-120000.json'), findsOneWidget);
    expect(find.byKey(const Key('dji_link_capture_exported')), findsNothing);
  });

  testWidgets('a capture is exported with the note and shows where it went', (tester) async {
    final api = _FakeApi(snapshot: _snapshot(captureBytes: 0));

    await pumpPage(tester, api);

    final exportButton = find.byKey(const Key('dji_link_capture_export'));
    api.snapshotValue = _snapshot(captureBytes: 4096);
    await tester.tap(find.byKey(const Key('dji_link_capture_start')));
    await tester.pumpAndSettle();
    expect(api.captureStarts, 1);

    await tester.enterText(find.byKey(const Key('dji_link_capture_notes')), 'props off, indoors');
    await tester.pumpAndSettle();
    await tester.tap(exportButton);
    await tester.pumpAndSettle();

    expect(api.exports.single.note, 'props off, indoors');
    expect(find.byKey(const Key('dji_link_capture_exported')), findsOneWidget);
    expect(find.textContaining('dji-link-20261022-120000.bin'), findsOneWidget);
    expect(find.textContaining('a1b2c3'), findsOneWidget);
  });

  testWidgets('a snapshot pushed by the native side reaches the page', (tester) async {
    final api = _FakeApi();

    final listener = await pumpPage(tester, api);
    expect(listener, isNotNull);
    expect(find.text('Accessory open'), findsOneWidget);

    listener!.snapshotChanged(_snapshot(state: DjiLinkState.aircraftLinked, firstByteMs: 120));
    await tester.pumpAndSettle();

    expect(find.text('Aircraft frames arrive'), findsOneWidget);
    expect(find.text('120 ms'), findsOneWidget);
  });

  testWidgets('the sticks are drawn and say why they are held at neutral', (tester) async {
    final api = _FakeApi(
      snapshot: _snapshot(sticks: _sticks(sampleAgeMs: 10, reasons: const ['LINK_NOT_LINKED', 'TRIGGERS_RELEASED'])),
    );

    await pumpPage(tester, api);

    expect(find.byKey(const Key('dji_link_sticks')), findsOneWidget);
    expect(find.textContaining('the send path is off in this build'), findsOneWidget);
    expect(find.text('Held at neutral: no aircraft link, triggers released'), findsOneWidget);
    expect(find.text('Yaw and throttle'), findsOneWidget);
  });

  testWidgets('the video panel shows each state, the counters, the decoder and where the description came from', (
    tester,
  ) async {
    final states = {
      DjiLinkVideoState.waitingForVideo: 'Waiting for video from the remote.',
      DjiLinkVideoState.waitingForDescription:
          'Video arrives. Waiting for the description of the stream before decoding.',
      DjiLinkVideoState.building: 'Joined a running stream: the picture builds up over a few seconds.',
      DjiLinkVideoState.decoding: 'Decoding',
      DjiLinkVideoState.hidden: 'Decoding goes on while the panel is hidden.',
      DjiLinkVideoState.failed: 'This device could not decode the video (no-decoder).',
      DjiLinkVideoState.h264NotDecoded: 'H.264 video: recognised, not decoded in this version.',
    };
    final api = _FakeApi(snapshot: _snapshot(decode: _decode()));
    final listener = await pumpPage(tester, api);

    for (final entry in states.entries) {
      listener!.snapshotChanged(
        _snapshot(
          decode: _decode(state: entry.key, failure: entry.key == DjiLinkVideoState.failed ? 'no-decoder' : null),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget, reason: '${entry.key}');
      // The privacy line goes with the panel whatever its state
      expect(find.byKey(const Key('dji_link_video_private')), findsOneWidget);
    }

    listener!.snapshotChanged(_snapshot(decode: _decode(switchReason: 'noOutputAfterJoin', keyPictureAgoMs: 2500)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_link_video_placeholder')), findsOneWidget);
    expect(find.text('H.265, 1920 x 1080, Main High tier level 5.0'), findsOneWidget);
    expect(find.text('from the capture of 23 October 2026 (RC-N3 with Neo 2)'), findsOneWidget);
    expect(find.text('c2.android.hevc.decoder, software'), findsOneWidget);
    expect(find.text('336 in, 320 decoded, 300 shown, 20 skipped'), findsOneWidget);
    expect(find.text('last 6.1 ms, median 5.5 ms, 95 % 9.3 ms'), findsOneWidget);
    expect(find.text('2.5 s ago'), findsOneWidget);
    expect(find.byKey(const Key('dji_link_video_switch_reason')), findsOneWidget);
    expect(find.text('30 pictures/s, 4.8 Mbit/s, 5.5 ms'), findsOneWidget);

    await tester.tap(find.byKey(const Key('dji_link_video_choice_software')));
    await tester.pumpAndSettle();
    expect(api.choices, [DjiLinkDecoderChoice.software]);
  });

  testWidgets('the picture is drawn only while pictures come out of the decoder, black otherwise', (tester) async {
    final api = _FakeApi(snapshot: _snapshot(decode: _decode(lastOutputAgoMs: null)));
    final listener = await pumpPage(tester, api);

    expect(find.byKey(const Key('dji_link_video_placeholder')), findsNothing);
    listener!.snapshotChanged(_snapshot(decode: _decode(lastOutputAgoMs: 120)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_link_video_placeholder')), findsOneWidget);
    // The stream stopped: no stale picture, and no transparent surface showing what was drawn before
    listener.snapshotChanged(_snapshot(decode: _decode(lastOutputAgoMs: 5000)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_link_video_placeholder')), findsNothing);
  });

  testWidgets('the full screen route shows the picture alone and Back leaves it', (tester) async {
    final api = _FakeApi(snapshot: _snapshot(decode: _decode()));
    await pumpPage(tester, api);

    await tester.tap(find.byKey(const Key('dji_link_video_full_screen')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_link_video_full_screen_route')), findsOneWidget);
    expect(find.byKey(const Key('dji_link_video_placeholder')), findsWidgets);

    await tester.tap(find.byKey(const Key('dji_link_video_leave_full_screen')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_link_video_full_screen_route')), findsNothing);
    expect(find.byKey(const Key('dji_link_video_panel')), findsOneWidget);
  });

  testWidgets('the flight and battery values come with their units, how they are known and the note', (tester) async {
    final api = _FakeApi(snapshot: _snapshot(telemetryValues: _telemetry()));
    final listener = await pumpPage(tester, api);

    expect(find.byKey(const Key('dji_link_flight_note')), findsOneWidget);
    expect(find.text('-0.5 m'), findsOneWidget);
    expect(find.text('126.8 °'), findsOneWidget);
    expect(find.text('12, automatic landing'), findsOneWidget);
    expect(find.text('38.7 s'), findsOneWidget);
    expect(find.text('Speeds (candidate)'), findsOneWidget);
    expect(find.text('38 %'), findsOneWidget);
    expect(find.text('6.180 V'), findsOneWidget);
    expect(find.text('-7.256 A'), findsOneWidget);
    expect(find.text('582 of 1525 mAh'), findsOneWidget);
    expect(find.text('Remote battery (candidate)'), findsOneWidget);
    expect(find.text('aircraft side 90, remote side 90'), findsOneWidget);
    expect(find.text('public layout and the 23 October capture'), findsWidgets);
    expect(find.text('119, 49 repeated'), findsOneWidget);
    expect(find.byKey(const Key('dji_link_stale')), findsNothing);

    listener!.snapshotChanged(_snapshot(telemetryValues: _telemetry(stale: true)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_link_stale')), findsOneWidget);
    expect(find.textContaining('no update for 4.2 s'), findsOneWidget);

    listener.snapshotChanged(_snapshot());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_link_flight_note')), findsOneWidget, reason: 'the note stays in every state');
    expect(find.text('No flight data has arrived.'), findsOneWidget);
  });

  testWidgets('"Your hardware" lists the starting profiles and binds the strings to one', (tester) async {
    final api = _FakeApi(
      snapshot: _snapshot(
        lastAccessory: DjiLinkAccessory(manufacturer: 'DJI', model: 'RC-N3 model string', description: 'remote'),
      ),
    );
    await pumpPage(tester, api);

    expect(find.byKey(const Key('dji_link_hardware')), findsOneWidget);
    expect(find.textContaining('RC-N3 model string'), findsOneWidget);
    expect(find.byKey(const Key('dji_link_usb_mode_hint')), findsOneWidget);
    await tester.tap(find.byKey(const Key('dji_link_hardware_choice')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DJI RC-N3 with a Neo 2 and the Digital Transceiver').last);
    await tester.pumpAndSettle();
    expect(api.bindings, ['rc-n3-neo2']);
  });

  testWidgets('without any accessory strings there is nothing to bind', (tester) async {
    await pumpPage(tester, _FakeApi());

    expect(find.byKey(const Key('dji_link_hardware_choice')), findsNothing);
    expect(find.text('No accessory strings have been read yet: plug the remote in first.'), findsOneWidget);
  });

  testWidgets('the bench chips fill the header of the export', (tester) async {
    final api = _FakeApi(snapshot: _snapshot(captureBytes: 4096));
    await pumpPage(tester, api);

    expect(find.text('The first 4 MiB of a session are kept, and the last 16 MiB.'), findsOneWidget);
    expect(find.textContaining('the video of the drone'), findsOneWidget);
    for (final chip in ['cable_original', 'port_top', 'remote_on', 'aircraft_motorsOff']) {
      await tester.tap(find.byKey(Key('dji_link_bench_$chip')));
      await tester.pumpAndSettle();
    }
    // A second tap takes a chip off again
    await tester.tap(find.byKey(const Key('dji_link_bench_port_bottom')));
    await tester.tap(find.byKey(const Key('dji_link_bench_port_bottom')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dji_link_capture_export')));
    await tester.pumpAndSettle();

    final notes = api.exports.single;
    expect(notes.cable, 'original');
    expect(notes.port, isNull);
    expect(notes.remoteState, 'on');
    expect(notes.aircraftState, 'motorsOff');
  });

  testWidgets('a capture of the list plays from the second asked, and stops', (tester) async {
    final api = _FakeApi(snapshot: _snapshot(state: DjiLinkState.absent))..captures = [_export20261023];
    final listener = await pumpPage(tester, api);

    expect(find.text('dji-link-20261023-102731'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('dji_link_play_start_at')), '1.5');
    await tester.tap(find.byKey(const Key('dji_link_play_dji-link-20261023-102731')));
    await tester.pumpAndSettle();
    expect(api.played, [('content://media/external/downloads/101', 1500)]);

    listener!.snapshotChanged(
      _snapshot(
        state: DjiLinkState.absent,
        source: DjiLinkSource(replay: true, playing: true, name: 'dji-link-20261023-102731', positionMs: 3200),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Playing dji-link-20261023-102731, 3.2 s'), findsOneWidget);
    await tester.tap(find.byKey(const Key('dji_link_play_stop')));
    await tester.pumpAndSettle();
    expect(api.playbackStops, 1);
  });

  testWidgets('files chosen in the picker play, and a pair that does not match is said', (tester) async {
    final api = _FakeApi(snapshot: _snapshot(state: DjiLinkState.absent));
    await pumpPage(tester, api);

    expect(find.byKey(const Key('dji_link_play_none')), findsOneWidget);
    await tester.tap(find.byKey(const Key('dji_link_play_choose')));
    await tester.pumpAndSettle();
    expect(api.pickerOpens, 1);
    expect(find.text('Choose a .bin file and the .idx.csv file of the same capture.'), findsOneWidget);

    api.chosen = _export20261023;
    await tester.tap(find.byKey(const Key('dji_link_play_choose')));
    await tester.pumpAndSettle();
    expect(api.played.single.$1, 'content://media/external/downloads/101');
  });

  testWidgets('a damaged or oversize capture is refused with its reason, and a failed playback says where it stopped', (
    tester,
  ) async {
    final api = _FakeApi(snapshot: _snapshot(state: DjiLinkState.absent))
      ..captures = [_export20261023]
      ..playOutcome = 'damaged';
    final listener = await pumpPage(tester, api);

    await tester.tap(find.byKey(const Key('dji_link_play_dji-link-20261023-102731')));
    await tester.pumpAndSettle();
    expect(find.textContaining('has lines that do not fit its file, so it was not played'), findsOneWidget);

    api.playOutcome = 'tooLarge';
    await tester.tap(find.byKey(const Key('dji_link_play_dji-link-20261023-102731')));
    await tester.pumpAndSettle();
    expect(find.textContaining('larger than 64 MB, so it was not played'), findsOneWidget);

    listener!.snapshotChanged(
      _snapshot(
        state: DjiLinkState.absent,
        source: DjiLinkSource(
          replay: true,
          playing: false,
          name: 'dji-link-20261023-102731',
          positionMs: 4100,
          failure: 'IllegalArgumentException',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        'dji-link-20261023-102731 stopped at 4.1 s on an error (IllegalArgumentException). The capture may be damaged.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('dji_link_playing')), findsNothing, reason: 'a failed playback did not play to its end');
  });

  testWidgets('a capture is not played while a remote holds the cable', (tester) async {
    final api = _FakeApi(snapshot: _snapshot(state: DjiLinkState.aircraftLinked))..captures = [_export20261023];
    await pumpPage(tester, api);

    expect(find.byKey(const Key('dji_link_play_busy')), findsOneWidget);
    final play = tester.widget<IconButton>(find.byKey(const Key('dji_link_play_dji-link-20261023-102731')));
    expect(play.onPressed, isNull);
    final choose = tester.widget<OutlinedButton>(find.byKey(const Key('dji_link_play_choose')));
    expect(choose.onPressed, isNull);
  });

  testWidgets('a catalogued message is named in the identifier table', (tester) async {
    final api = _FakeApi(
      snapshot: _snapshot(
        telemetry: [
          DjiLinkTelemetryRow(
            commandSet: 3,
            commandId: 67,
            count: 113,
            lastLength: 85,
            ratePerSecond: 10,
            preview: '00 00',
            name: 'flightData',
          ),
        ],
      ),
    );
    await pumpPage(tester, api);

    expect(find.text('set 3 id 67 flight data'), findsOneWidget);
  });

  group('the tile of the Network shares page', () {
    /// The tile on an Android device with the setting [enabled], in the TV layout when [tv]
    List<Override> android({bool enabled = true, bool tv = false}) => [
      appConfigProvider.overrideWithValue(AppConfig(djiLinkEnabled: enabled)),
      tvModeProvider.overrideWithValue(tv),
    ];

    Future<bool> shownOnAndroid(WidgetTester tester, List<Override> overrides) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await tester.pumpTestWidget(
          context,
          const Scaffold(body: Column(children: [DjiLinkTile()])),
          overrides: overrides,
        );
        await tester.pumpAndSettle();
        return find.byKey(const Key('dji_link_tile')).evaluate().isNotEmpty;
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    testWidgets('shows on an Android device with the default settings, untouched', (tester) async {
      expect(
        await shownOnAndroid(tester, [
          appConfigProvider.overrideWithValue(const AppConfig()),
          tvModeProvider.overrideWithValue(false),
        ]),
        isTrue,
      );
      expect(find.text('DJI link'), findsOneWidget);
    });

    testWidgets('is hidden with the setting off', (tester) async {
      expect(await shownOnAndroid(tester, android(enabled: false)), isFalse);
    });

    testWidgets('is hidden in the TV layout whatever the setting', (tester) async {
      expect(await shownOnAndroid(tester, android(tv: true)), isFalse);
    });

    testWidgets('is hidden off Android whatever the setting', (tester) async {
      // Under flutter test the target platform is Android unless it is said otherwise, so a computer is said here
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await tester.pumpTestWidget(
          context,
          const Scaffold(body: Column(children: [DjiLinkTile()])),
          overrides: [
            appConfigProvider.overrideWithValue(const AppConfig(djiLinkEnabled: true)),
            tvModeProvider.overrideWithValue(false),
          ],
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('dji_link_tile')), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
