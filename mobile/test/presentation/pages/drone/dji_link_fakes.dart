// The fakes of the DJI live video tests: the native side of the link, the device side of the relay, and the
// snapshots they answer with. The values are those of FreeKC's RC-N3 and Neo 2 captures of 23 October 2026.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/network/network_discovery_probes.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/providers/drone/dji_relay.provider.dart';

DjiLinkEnvironment fakeEnvironment({
  bool accessoryFeature = true,
  bool djiInstalled = false,
  String flavour = 'quest',
}) => DjiLinkEnvironment(
  deviceManufacturer: 'Oculus',
  deviceModel: 'Quest 3',
  buildFingerprint: 'oculus/hollywood/hollywood:14/UP1A/1234:user/release-keys',
  androidRelease: '14',
  sdkInt: 34,
  appVersion: '3.3.0',
  flavour: flavour,
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

DjiLinkCounters fakeCounters({
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

DjiLinkSticks fakeSticks({int? sampleAgeMs, List<String> reasons = const []}) => DjiLinkSticks(
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

DjiLinkCrc fakeCrc({int? headerSeedCandidate, int headerSeedVotes = 0, int headerFailuresVoting = 0}) => DjiLinkCrc(
  headerParameters: 'crc8-r8c-77',
  frameParameters: 'crc16-r8408-3692',
  headerSeedCandidate: headerSeedCandidate,
  headerSeedVotes: headerSeedVotes,
  headerFailuresVoting: headerFailuresVoting,
  frameSeedVotes: 0,
  frameFailuresVoting: 0,
);

DjiLinkDecode fakeDecode({
  DjiLinkVideoState state = DjiLinkVideoState.decoding,
  String? failure,
  DjiLinkDescriptionSource source = DjiLinkDescriptionSource.profile,
  String? switchReason,
  int? keyPictureAgoMs,
  int? lastOutputAgoMs = 40,
  int unitsDropped = 0,
  double picturesPerSecond = 30,
  int lostPictures = 0,
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
  unitsDropped: unitsDropped,
  tooLarge: 0,
  unitsWithoutDescription: 29,
  errors: 0,
  picturesPerSecond: picturesPerSecond,
  megabitsPerSecond: 4.8,
  decodeLastMs: 6.1,
  decodeMedianMs: 5.5,
  decodeP95Ms: 9.25,
  inProcessMedianMs: 0.12,
  inProcessP95Ms: 0.4,
  firstPictureMs: 180,
  lostPictures: lostPictures,
  encoderRestarts: 1,
  keyPictures: 1,
  keyPictureAgoMs: keyPictureAgoMs,
  lastOutputAgoMs: lastOutputAgoMs,
);

DjiLinkTelemetry fakeTelemetry({
  bool stale = false,
  bool batteryStale = false,
  int percent = 38,
  double motorTimeS = 38.7,
  bool aircraftPresent = true,
  bool remoteBatteryStale = false,
}) => DjiLinkTelemetry(
  aircraftPresent: aircraftPresent,
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
    motorTimeS: motorTimeS,
    satellites: 0,
    groundHeightM: 0.9,
    evidence: DjiLinkEvidence.publicAndCapture,
  ),
  battery: DjiLinkBattery(
    ageMs: batteryStale ? 6200 : 300,
    stale: batteryStale,
    percent: percent,
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
  remoteBatteryStale: remoteBatteryStale,
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

/// One arc of the obstacle ring at [distanceM] with the default distances (3.0 m and 1.0 m), on the side [centreDeg]
/// (null for the even glow), as ObstacleRing makes it
DjiObstacleArc fakeArc(double distanceM, {double? centreDeg}) {
  final strength = ((3.0 - distanceM) / 2.0).clamp(0.0, 1.0);
  final amber = [0xFF, 0xB3, 0x00];
  final red = [0xE5, 0x39, 0x35];
  final channels = [for (var i = 0; i < 3; i++) (amber[i] + (red[i] - amber[i]) * strength).round()];
  return DjiObstacleArc(
    centreDeg: centreDeg,
    distanceM: distanceM,
    strength: strength,
    opacity: 0.15 + 0.55 * strength,
    argb: 0xFF000000 | channels[0] << 16 | channels[1] << 8 | channels[2],
  );
}

/// What the obstacle ring decided: nothing unless said otherwise. With [arcs], the ring shows; [stopped] turns them
/// white and faint, as the native side does once the data stopped.
DjiObstacleDecision fakeDecision({
  bool on = false,
  bool stopped = false,
  bool listening = false,
  List<DjiObstacleArc> arcs = const [],
}) {
  final even = arcs.isEmpty || arcs.first.centreDeg == null;
  final shown = stopped
      ? [
          for (final arc in arcs)
            DjiObstacleArc(
              centreDeg: arc.centreDeg,
              distanceM: arc.distanceM,
              strength: arc.strength,
              opacity: 0.25,
              argb: 0xFFFFFFFF,
            ),
        ]
      : arcs;
  final nearest = arcs.isEmpty ? null : arcs.map((arc) => arc.distanceM).reduce((a, b) => a < b ? a : b);
  final tick = !on || nearest == null || nearest > 2.0
      ? 0
      : nearest >= 1.0
      ? (250 + (nearest - 1.0) * 750).round()
      : 150;
  return DjiObstacleDecision(
    on: on,
    stopped: stopped,
    listening: listening || on,
    even: even,
    arcs: shown,
    nearestM: nearest,
    tickIntervalMs: tick,
  );
}

/// The values a pilot reads, as the native side sends them: those of the 24 October flight (34 %, 0:41) and, for the
/// values our captures only make likely, those of the 23 October landing. A null is a group that is stale.
DjiLiveFrame fakeFrame({
  int atMs = 1000,
  int? percent = 34,
  double? motorTimeS = 41.6,
  bool? motorsOn = false,
  double? headingDeg = 126.8,
  double? heightM = -0.5,
  double? verticalSpeedMps = -0.2,
  double? speedMps,
  double? distanceBelowM,
  double? obstacleM,
  int? remoteBatteryPercent = 50,
  int? signal = 90,
  int? signalBars = 5,
  double? linkRateMbps = 5.9,
  double? batteryVolts = 6.18,
  double? batteryTemperatureC = 26.9,
  int? satellites = 0,
  bool landing = false,
  DjiObstacleDecision? alert,
}) => DjiLiveFrame(
  atMs: atMs,
  alert: alert ?? fakeDecision(),
  droneBatteryPercent: percent,
  batteryVolts: batteryVolts,
  batteryTemperatureC: batteryTemperatureC,
  motorTimeS: motorTimeS,
  motorsOn: motorsOn,
  headingDeg: headingDeg,
  heightM: heightM,
  verticalSpeedMps: verticalSpeedMps,
  speedMps: speedMps,
  distanceBelowM: distanceBelowM,
  obstacleM: obstacleM,
  remoteBatteryPercent: remoteBatteryPercent,
  signal: signal,
  signalBars: signalBars,
  linkRateMbps: linkRateMbps,
  satellites: satellites,
  landing: landing,
);

DjiLinkSnapshot fakeSnapshot({
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
  DjiRelaySending? relaySending,
  DjiRelayReceiving? relayReceiving,
  DjiLiveFrame? liveFrame,
}) => DjiLinkSnapshot(
  state: state,
  reason: reason,
  detail: detail,
  accessory: accessory,
  profile: profile,
  probesHalted: probesHalted,
  opens: 1,
  crc: crc ?? fakeCrc(),
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
  counters: counters ?? fakeCounters(),
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
  sticks: sticks ?? fakeSticks(),
  videoDecode: decode,
  telemetryValues: telemetryValues,
  source: source,
  lastAccessory: lastAccessory,
  boundProfileId: boundProfileId,
  relaySending: relaySending,
  relayReceiving: relayReceiving,
  liveFrame: liveFrame,
);

DjiRelayReceiving fakeReceiving({
  DjiRelayReceiveState state = DjiRelayReceiveState.receiving,
  String phoneSource = 'replay',
  int? lastPictureAgoMs = 40,
  int lostOnWifi = 0,
  int? reconnectInMs,
  double? relayDelayMedianMs = 14,
  int failures = 0,
}) => DjiRelayReceiving(
  state: state,
  phoneName: 'Galaxy S24+',
  phoneId: '3f9c0a1b2c3d4e5f',
  host: '192.168.1.21',
  port: 8362,
  phoneSource: phoneSource,
  replay: phoneSource == 'replay',
  replayName: 'dji-link-20261023-102731',
  replayPositionMs: 4100,
  reconnectInMs: reconnectInMs,
  failures: failures,
  units: 300,
  lostOnWifi: lostOnWifi,
  relayDelayMedianMs: relayDelayMedianMs,
  relayDelayP95Ms: 22,
  phoneQueueMedianMs: 1,
  networkMedianMs: 13,
  networkP95Ms: 21,
  clockUncertaintyMs: 2,
  arrivalSpreadMedianMs: 22,
  phoneInProcessMedianMs: 0.4,
  phoneDecodeMedianMs: 9,
  receiveToPictureMs: 24,
  behindPhoneMs: 15,
  lastPictureAgoMs: lastPictureAgoMs,
  receivedPerSecond: 30,
  decodedPerSecond: 30,
  shownPerSecond: 29,
  lostOnRadio: 0,
);

DjiRelaySending fakeSending({String sending = 'none', List<DjiRelayHeadsetRow> headsets = const []}) => DjiRelaySending(
  on: true,
  port: 8362,
  sending: sending,
  headsets: headsets,
  refusedProofs: 2,
  unexpectedRecords: 0,
  wifiLowLatencyHeld: true,
  unitsDropped: 0,
);

/// The device side of the relay: the announcement, the browser, the secure storage and the screen, all in memory
class FakeRelayEnvironment {
  final announced = <(String, int, Map<String, String>)>[];
  int announcementsStopped = 0;
  final screen = <bool>[];
  final secrets = <String, String>{};
  // Lives as long as the test: the page's browser listens to it until it is disposed
  // ignore: close_sinks
  final browsed = StreamController<MdnsService>.broadcast();
  int notificationAsks = 0;
  final codes = ['K7M2Q9XRTH', 'ABCDEFGHJK', 'MNPQRSTUVW'];

  /// The ids of the TVs added on the phone, in order
  final screenIds = ['a1b2c3d4e5f60718', 'b2c3d4e5f6071829', 'c3d4e5f60718293a'];

  /// The announcement fails, as on a network without multicast: a headset then types the address
  bool advertiseFails = false;

  /// When set, the device name is answered only once the test completes it: the page can close in between
  Completer<String>? nameGate;

  DjiRelayEnvironment build() => DjiRelayEnvironment(
    advertise: (name, port, attributes) async {
      if (advertiseFails) {
        throw StateError('no multicast here');
      }
      announced.add((name, port, attributes));
      return () async => announcementsStopped += 1;
    },
    browse: (until) => browsed.stream,
    lookup: (host) async => null,
    localAddresses: () async => const [DjiRelayAddress('192.168.1.23'), DjiRelayAddress('192.168.43.1', hotspot: true)],
    deviceName: () => nameGate?.future ?? Future.value('Galaxy S24+'),
    installId: () async => '3f9c0a1b2c3d4e5f',
    readSecret: (key) async => secrets[key],
    writeSecret: (key, value) async => secrets[key] = value,
    deleteSecret: (key) async => secrets.remove(key),
    keepScreenOn: (on) async => screen.add(on),
    askNotifications: () async => notificationAsks += 1,
    newCode: () => codes.removeAt(0),
    newScreenId: () => screenIds.removeAt(0),
    nowMs: () => 1792862400000,
  );
}

MdnsService fakeAnnounced(
  String host,
  Map<String, String> attributes, {
  int port = 8362,
  String name = 'Immuch360 on Galaxy S24+',
}) => MdnsService(name: name, type: '_immuch360-pair._tcp', host: host, port: port, attributes: attributes);

const fakeDroneTxt = {'v': '1', 'kind': 'drone', 'rv': '1', 'id': '3f9c0a1b2c3d4e5f'};

final fakeProfiles = [
  DjiLinkProfile(id: 'rc-n3-neo2', label: 'DJI RC-N3 with a Neo 2 and the Digital Transceiver', capabilities: const []),
  DjiLinkProfile(id: 'rc-2', label: 'DJI RC 2', capabilities: const []),
];

final fakeExport20261023 = DjiLinkCaptureFile(
  name: 'dji-link-20261023-102731',
  binUri: 'content://media/external/downloads/101',
  indexUri: 'content://media/external/downloads/102',
  bytes: 8388608,
  modifiedMs: 1792744042188,
  origin: 'export',
);

class FakeDjiLinkApi extends Fake implements DjiLinkApi {
  FakeDjiLinkApi({DjiLinkEnvironment? environment, DjiLinkSnapshot? snapshot})
    : environment = environment ?? fakeEnvironment(),
      snapshotValue = snapshot ?? fakeSnapshot();

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

  /// Thrown by [start] while set, as a native side that cannot start
  Error? startError;

  @override
  Future<void> start() async {
    starts += 1;
    if (startError case final Error error) {
      throw error;
    }
  }

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
  Future<void> clearCapture() async => clears += 1;

  @override
  Future<DjiLinkExport> exportCapture(DjiLinkExportNotes notes) async {
    exports.add(notes);
    await exportGate?.future;
    return exportResult;
  }

  @override
  Future<List<DjiLinkProfile>> profiles() async => fakeProfiles;

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
  Future<String?> playCapture(String binUri, String indexUri, int startAtMs, bool loop) async {
    played.add((binUri, startAtMs));
    loops.add(loop);
    return playOutcome;
  }

  @override
  Future<void> stopPlayback() async => playbackStops += 1;

  final loops = <bool>[];
  final relayStarts = <DjiRelayStart>[];
  int relayStops = 0;
  final relayCodes = <String>[];
  final notifications = <String>[];
  final connects = <(String, int, String, String?, String)>[];
  int disconnects = 0;
  final flightViews = <Map<String, String>>[];
  int relayPort = 8362;
  String? connectOutcome;

  @override
  Future<int> startRelay(DjiRelayStart start) async {
    relayStarts.add(start);
    return relayPort;
  }

  @override
  Future<void> stopRelay() async => relayStops += 1;

  @override
  Future<void> setRelayCode(String code) async => relayCodes.add(code);

  /// setRelayScreenCodes, in order: the TVs the phone's relay welcomes
  final relayScreenCodes = <List<DjiRelayScreenCode>>[];

  @override
  Future<void> setRelayScreenCodes(List<DjiRelayScreenCode> codes) async => relayScreenCodes.add(codes);

  @override
  Future<void> updateRelayNotification(String text) async => notifications.add(text);

  @override
  Future<String?> connectRelay(String host, int port, String code, String? phoneId, String headsetName) async {
    connects.add((host, port, code, phoneId, headsetName));
    return connectOutcome;
  }

  @override
  Future<void> disconnectRelay() async => disconnects += 1;

  @override
  Future<bool> openFlightView(Map<String, String> labels) async {
    flightViews.add(labels);
    return true;
  }

  /// "Open this screen when the remote is plugged in", as the native side keeps it
  bool openOnPlugValue = false;
  final openOnPlugSets = <bool>[];
  final liveSettingSets = <bool>[];
  bool attachLaunch = false;
  int clears = 0;

  @override
  Future<void> setOpenOnPlug(bool on) async {
    openOnPlugSets.add(on);
    openOnPlugValue = on;
  }

  @override
  Future<bool> openOnPlug() async => openOnPlugValue;

  @override
  Future<void> setLiveSettingOn(bool on) async => liveSettingSets.add(on);

  @override
  Future<bool> takeAttachLaunch() async {
    final launched = attachLaunch;
    attachLaunch = false;
    return launched;
  }

  /// setFrameStream, in order
  final frameStreams = <bool>[];

  /// setObstacleRing, in order
  final obstacleRings = <DjiObstacleRingSettings>[];
  int obstacleTests = 0;
  int obstacleSamples = 0;

  /// The native side refuses the sample (the motors run)
  bool sampleRefused = false;
  bool vibrator = true;
  bool volumeOff = false;
  int receptionExports = 0;
  DjiLinkExport receptionResult = DjiLinkExport(
    ok: true,
    bytes: 2048,
    binPath: 'Download/Immuch360/dji-link/dji-relay-20261024-171200.bin',
    indexPath: 'Download/Immuch360/dji-link/dji-relay-20261024-171200.idx.csv',
    headerPath: 'Download/Immuch360/dji-link/dji-relay-20261024-171200.json',
    sha256: 'd4e5f6',
  );

  /// While set, an export waits for it: three taps can land while the first one runs
  Completer<void>? exportGate;

  @override
  Future<void> setFrameStream(bool on) async => frameStreams.add(on);

  @override
  Future<void> setObstacleRing(DjiObstacleRingSettings settings) async => obstacleRings.add(settings);

  @override
  Future<void> playObstacleTest() async => obstacleTests += 1;

  @override
  Future<bool> showObstacleSample() async {
    if (sampleRefused) {
      return false;
    }
    obstacleSamples += 1;
    return true;
  }

  @override
  Future<bool> hasVibrator() async => vibrator;

  @override
  Future<bool> mediaVolumeOff() async => volumeOff;

  @override
  Future<DjiLinkExport> exportReception() async {
    receptionExports += 1;
    return receptionResult;
  }
}
