// The DJI link page: what it shows of a device that cannot read a remote controller at all, of a link that is open,
// of the counters, and of an exported capture. The safety banner is there in every one of those states.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/pages/drone/dji_link.page.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_tile.widget.dart';
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

DjiLinkCounters _counters({int unknownChannelFrames = 0, int headerCrcFailures = 0}) => DjiLinkCounters(
  envelopeFrames: 12,
  envelopeBytes: 4096,
  payloadBytes: 3900,
  discardedBytes: 7,
  resynchronisations: 1,
  unknownChannelFrames: unknownChannelFrames,
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

DjiLinkSnapshot _snapshot({
  DjiLinkState state = DjiLinkState.accessoryOpen,
  String? detail,
  DjiLinkAccessory? accessory,
  int? firstByteMs,
  int captureBytes = 0,
  List<DjiLinkFrame> frames = const [],
  List<DjiLinkChannel> channels = const [],
  List<DjiLinkTelemetryRow> telemetry = const [],
  DjiLinkCounters? counters,
  DjiLinkSticks? sticks,
}) => DjiLinkSnapshot(
  state: state,
  detail: detail,
  accessory: accessory,
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
    capacityBytes: 8 * 1024 * 1024,
  ),
  sticks: sticks ?? _sticks(),
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
    expect(api.starts, 0);
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
        detail: 'the liveness probe returns; nothing has answered yet',
        accessory: DjiLinkAccessory(manufacturer: 'DJI', model: 'com.dji.logiclink', description: ' RC'),
      ),
    );

    await pumpPage(tester, api);

    expect(find.text('linkUsable'), findsOneWidget);
    expect(find.text('never'), findsOneWidget);
    expect(find.text('the liveness probe returns; nothing has answered yet'), findsOneWidget);
    expect(find.textContaining('com.dji.logiclink'), findsOneWidget);
    expect(find.textContaining('Nothing is written for the first 20 seconds'), findsOneWidget);
  });

  testWidgets('a refused permission is a state of its own, with the banner still there', (tester) async {
    final api = _FakeApi(snapshot: _snapshot(state: DjiLinkState.permissionDenied));

    await pumpPage(tester, api);

    expect(find.text('permissionDenied'), findsOneWidget);
    expect(find.byKey(const Key('dji_link_safety')), findsOneWidget);
  });

  testWidgets('counters, channels and frames are shown as they are', (tester) async {
    final api = _FakeApi(
      snapshot: _snapshot(
        counters: _counters(unknownChannelFrames: 2, headerCrcFailures: 5),
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
            name: 'common OSD push, the main flight state message',
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
    expect(find.textContaining('set 3 id 67'), findsWidgets);
    expect(find.textContaining('common OSD push'), findsOneWidget);
    expect(find.textContaining('No field of a message is read'), findsOneWidget);
  });

  testWidgets('the export is refused while nothing was captured, and shows where it went afterwards', (tester) async {
    final api = _FakeApi(snapshot: _snapshot(captureBytes: 0));

    await pumpPage(tester, api);

    final exportButton = find.byKey(const Key('dji_link_capture_export'));
    expect(tester.widget<FilledButton>(exportButton).onPressed, isNull);

    api.snapshotValue = _snapshot(captureBytes: 4096);
    await tester.tap(find.byKey(const Key('dji_link_capture_start')));
    await tester.pumpAndSettle();
    expect(api.captureStarts, 1);

    await tester.enterText(find.byKey(const Key('dji_link_capture_notes')), 'original cable, top port, props off');
    await tester.pumpAndSettle();
    await tester.tap(exportButton);
    await tester.pumpAndSettle();

    expect(api.exports.single.note, 'original cable, top port, props off');
    expect(find.byKey(const Key('dji_link_capture_exported')), findsOneWidget);
    expect(find.textContaining('dji-link-20261022-120000.bin'), findsOneWidget);
    expect(find.textContaining('a1b2c3'), findsOneWidget);
  });

  testWidgets('a snapshot pushed by the native side reaches the page', (tester) async {
    final api = _FakeApi();

    final listener = await pumpPage(tester, api);
    expect(listener, isNotNull);
    expect(find.text('accessoryOpen'), findsOneWidget);

    listener!.snapshotChanged(_snapshot(state: DjiLinkState.aircraftLinked, firstByteMs: 120));
    await tester.pumpAndSettle();

    expect(find.text('aircraftLinked'), findsOneWidget);
    expect(find.text('120 ms'), findsOneWidget);
  });

  testWidgets('the sticks are drawn and say why they are held at neutral', (tester) async {
    final api = _FakeApi(
      snapshot: _snapshot(sticks: _sticks(sampleAgeMs: 10, reasons: const ['LINK_NOT_LINKED', 'TRIGGERS_RELEASED'])),
    );

    await pumpPage(tester, api);

    expect(find.byKey(const Key('dji_link_sticks')), findsOneWidget);
    expect(find.textContaining('the send path is off in this build'), findsOneWidget);
    expect(find.textContaining('LINK_NOT_LINKED'), findsOneWidget);
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
