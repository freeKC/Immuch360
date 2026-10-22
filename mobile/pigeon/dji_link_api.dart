import 'package:pigeon/pigeon.dart';

// Android only (phones and the Meta Quest build): the DJI link diagnostics, behind Settings, Advanced, "DJI link
// diagnostics (experimental)". The native side opens a DJI remote controller plugged into this device as a USB
// accessory, reads what arrives, parses it and counts everything. Nothing on this API sends a flight command: the
// only bytes written are the one byte liveness probe the USB transport itself needs, which is counted on the page.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/dji_link_api.g.dart',
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/djilink/DjiLink.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.djilink'),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
/// Where the link is. Each step is a different claim: an open accessory is not a controller that answered, which is
/// not an aircraft that is linked, and none of them is authority over an aircraft.
enum DjiLinkState {
  absent,
  accessoryDetected,
  permissionPending,
  permissionDenied,
  accessoryOpen,
  linkUsable,
  controllerIdentified,
  aircraftLinked,
  videoReady,
  telemetryReady,
  linkLost,
  recovering,
  unsupportedTransport,
  unsupportedProtocol,
}

/// Whether a hardware profile can do something. [supported] is impossible to reach without an observation on named
/// hardware, so a fresh profile is [unknown] everywhere.
enum DjiLinkSupport { unknown, unsupported, supported }

/// What a video payload looks like, with no codec named
enum DjiLinkProbeVerdict { noData, noStartCodes, startCodesSeen }

/// What this device can do about a USB accessory, read on the device itself
class DjiLinkEnvironment {
  const DjiLinkEnvironment({
    required this.deviceManufacturer,
    required this.deviceModel,
    required this.buildFingerprint,
    required this.androidRelease,
    required this.sdkInt,
    required this.appVersion,
    required this.flavour,
    required this.hasAccessoryFeature,
    required this.hasHostFeature,
    required this.accessoryNodeExists,
    required this.accessoryNodeWritable,
    required this.futureUsbLibraryPresent,
    required this.adbEnabled,
    required this.usbStateKnown,
    required this.usbConnected,
    required this.usbConfigured,
    required this.usbAccessoryMode,
    required this.usbAdbFunction,
    required this.djiApplicationInstalled,
    required this.accessoriesListed,
    required this.transportPossible,
    this.chargeCurrentMicroAmps,
  });

  final String deviceManufacturer;
  final String deviceModel;
  final String buildFingerprint;
  final String androidRelease;
  final int sdkInt;
  final String appVersion;
  final String flavour;

  /// android.hardware.usb.accessory; false means no application on this device can take this path at all
  final bool hasAccessoryFeature;
  final bool hasHostFeature;
  final bool accessoryNodeExists;
  final bool accessoryNodeWritable;
  final bool futureUsbLibraryPresent;

  /// An adb session holds the USB gadget, which matters when the cable is the only port
  final bool adbEnabled;
  final bool usbStateKnown;
  final bool usbConnected;
  final bool usbConfigured;
  final bool usbAccessoryMode;
  final bool usbAdbFunction;

  /// Only one application at a time can hold the accessory
  final bool djiApplicationInstalled;
  final int accessoriesListed;
  final bool transportPossible;
  final int? chargeCurrentMicroAmps;
}

/// The accessory strings as they were read, with nothing renamed
class DjiLinkAccessory {
  const DjiLinkAccessory({this.manufacturer, this.model, this.description, this.version, this.serial});

  final String? manufacturer;
  final String? model;
  final String? description;
  final String? version;
  final String? serial;
}

class DjiLinkCapability {
  const DjiLinkCapability({required this.name, required this.support, this.provenance});

  final String name;
  final DjiLinkSupport support;

  /// The observation this answer rests on; null while the answer is unknown
  final String? provenance;
}

/// A controller and aircraft pair as this application knows it. Matching an accessory selects a label and nothing
/// else: a profile never grants a capability.
class DjiLinkProfile {
  const DjiLinkProfile({required this.id, required this.label, required this.capabilities, this.note});

  final String id;
  final String label;
  final List<DjiLinkCapability> capabilities;
  final String? note;
}

/// Everything thrown away or not understood, which on this hardware is the evidence
class DjiLinkCounters {
  const DjiLinkCounters({
    required this.envelopeFrames,
    required this.envelopeBytes,
    required this.payloadBytes,
    required this.discardedBytes,
    required this.resynchronisations,
    required this.unknownChannelFrames,
    required this.oversizeRejections,
    required this.incompleteTimeouts,
    required this.controlFrames,
    required this.headerCrcFailures,
    required this.frameCrcFailures,
    required this.lengthRejections,
    required this.unsupportedEncryption,
    required this.knownPairs,
    required this.unknownPairs,
    required this.aircraftSideFrames,
    required this.controllerSideFrames,
    required this.ambiguousSideFrames,
    required this.keepAliveExceptions,
  });

  final int envelopeFrames;
  final int envelopeBytes;
  final int payloadBytes;
  final int discardedBytes;
  final int resynchronisations;
  final int unknownChannelFrames;
  final int oversizeRejections;
  final int incompleteTimeouts;
  final int controlFrames;
  final int headerCrcFailures;
  final int frameCrcFailures;
  final int lengthRejections;
  final int unsupportedEncryption;
  final int knownPairs;
  final int unknownPairs;
  final int aircraftSideFrames;
  final int controllerSideFrames;
  final int ambiguousSideFrames;
  final int keepAliveExceptions;
}

class DjiLinkChannel {
  const DjiLinkChannel({
    required this.channel,
    required this.role,
    required this.envelopes,
    required this.bytes,
    required this.largestPayload,
    required this.lastArrivalMs,
    required this.firstArrivalMs,
    this.cameraType,
  });

  final int channel;

  /// control, video, payload, reserved or unknown
  final String role;
  final int envelopes;
  final int bytes;
  final int largestPayload;
  final int lastArrivalMs;
  final int firstArrivalMs;

  /// Filled only from a camera video stream information message, never guessed
  final int? cameraType;
}

class DjiLinkPair {
  const DjiLinkPair({
    required this.commandSet,
    required this.commandId,
    required this.count,
    required this.lastLength,
    required this.lastSeenMs,
    this.setName,
    this.messageName,
  });

  final int commandSet;
  final int commandId;
  final int count;
  final int lastLength;
  final int lastSeenMs;
  final String? setName;
  final String? messageName;
}

class DjiLinkFrame {
  const DjiLinkFrame({
    required this.atMs,
    required this.channel,
    required this.commandSet,
    required this.commandId,
    required this.isAcknowledgement,
    required this.ackPolicy,
    required this.senderType,
    required this.receiverType,
    required this.sequence,
    required this.length,
    required this.encryption,
    required this.preview,
  });

  final int atMs;
  final int channel;
  final int commandSet;
  final int commandId;
  final bool isAcknowledgement;
  final int ackPolicy;
  final int senderType;
  final int receiverType;
  final int sequence;
  final int length;

  /// Anything but zero is an encryption this application does not read; its body is never shown
  final int encryption;
  final String preview;
}

/// One telemetry identifier as it was seen. No field of the body is read: the layouts are not established for any
/// aircraft this application has met, and an invented unit in front of a pilot would be worse than no number.
class DjiLinkTelemetryRow {
  const DjiLinkTelemetryRow({
    required this.commandSet,
    required this.commandId,
    required this.count,
    required this.lastLength,
    required this.ratePerSecond,
    required this.preview,
    this.name,
  });

  final int commandSet;
  final int commandId;
  final int count;
  final int lastLength;
  final double ratePerSecond;
  final String preview;
  final String? name;
}

class DjiLinkVideo {
  const DjiLinkVideo({
    required this.verdict,
    required this.payloads,
    required this.payloadsStartingWithStartCode,
    required this.startCodesSeen,
    required this.unitTypes,
    required this.sawH264ParameterSets,
    required this.sawH265ParameterSets,
    required this.channels,
  });

  final DjiLinkProbeVerdict verdict;
  final int payloads;
  final int payloadsStartingWithStartCode;
  final int startCodesSeen;

  /// The unit types seen after a start code, as text, read both ways and said to be read both ways
  final String unitTypes;
  final bool sawH264ParameterSets;
  final bool sawH265ParameterSets;
  final List<DjiLinkVideoChannel> channels;
}

class DjiLinkVideoChannel {
  const DjiLinkVideoChannel({
    required this.channel,
    required this.fragments,
    required this.bytes,
    required this.largestFragment,
    required this.gaps,
    required this.longestGapMs,
  });

  final int channel;
  final int fragments;
  final int bytes;
  final int largestFragment;
  final int gaps;
  final int longestGapMs;
}

/// The sticks as the application reads them, and whether anything would be allowed to leave. In stage 1 nothing is:
/// [sendPathEnabled] is false in every release.
class DjiLinkSticks {
  const DjiLinkSticks({
    required this.kind,
    required this.throttle,
    required this.yaw,
    required this.pitch,
    required this.roll,
    required this.triggersHeld,
    required this.armed,
    required this.neutralised,
    required this.reasons,
    required this.sendPathEnabled,
    this.sampleAgeMs,
    this.armingCountdownMs,
  });

  /// gamepad, controllerPose or openXr
  final String kind;
  final double throttle;
  final double yaw;
  final double pitch;
  final double roll;
  final bool triggersHeld;
  final bool armed;
  final bool neutralised;

  /// The dead man signals that hold the sticks at neutral right now
  final List<String> reasons;
  final bool sendPathEnabled;
  final int? sampleAgeMs;
  final int? armingCountdownMs;
}

class DjiLinkCapture {
  const DjiLinkCapture({
    required this.recording,
    required this.totalBytes,
    required this.droppedBytes,
    required this.records,
    required this.capacityBytes,
  });

  final bool recording;
  final int totalBytes;
  final int droppedBytes;
  final int records;
  final int capacityBytes;
}

/// What the pilot typed about the bench, kept in the exported header beside the bytes
class DjiLinkExportNotes {
  const DjiLinkExportNotes({this.cable, this.port, this.remoteState, this.aircraftState, this.note});

  final String? cable;
  final String? port;
  final String? remoteState;
  final String? aircraftState;
  final String? note;
}

/// Where an export went. Three files: the bytes, the read and write boundaries, and the header with the digest.
class DjiLinkExport {
  const DjiLinkExport({
    required this.ok,
    required this.bytes,
    this.binPath,
    this.indexPath,
    this.headerPath,
    this.sha256,
    this.error,
  });

  final bool ok;
  final int bytes;
  final String? binPath;
  final String? indexPath;
  final String? headerPath;
  final String? sha256;
  final String? error;
}

class DjiLinkReplayResult {
  const DjiLinkReplayResult({
    required this.ok,
    required this.readsReplayed,
    required this.bytesReplayed,
    required this.usedIndex,
    this.error,
    this.counters,
    this.channels,
    this.frames,
    this.telemetry,
    this.video,
  });

  final bool ok;
  final int readsReplayed;
  final int bytesReplayed;
  final bool usedIndex;
  final String? error;
  final DjiLinkCounters? counters;
  final List<DjiLinkChannel>? channels;
  final List<DjiLinkFrame>? frames;
  final List<DjiLinkTelemetryRow>? telemetry;
  final DjiLinkVideo? video;
}

/// Everything the page shows, in one answer
class DjiLinkSnapshot {
  const DjiLinkSnapshot({
    required this.state,
    required this.probesSent,
    required this.probeFailures,
    required this.consecutiveProbeFailures,
    required this.lastProbeCallMs,
    required this.bytesRead,
    required this.bytesWritten,
    required this.reads,
    required this.writes,
    required this.attempts,
    required this.quietWindowMs,
    required this.aircraftLinked,
    required this.counters,
    required this.channels,
    required this.pairs,
    required this.frames,
    required this.telemetry,
    required this.video,
    required this.capture,
    required this.sticks,
    this.detail,
    this.accessory,
    this.profile,
    this.firstByteMs,
    this.openSinceMs,
    this.chargeCurrentMicroAmps,
  });

  final DjiLinkState state;
  final String? detail;
  final DjiLinkAccessory? accessory;
  final DjiLinkProfile? profile;

  /// Time between the open and the first byte read; null while no byte has arrived, which is a result of its own
  final int? firstByteMs;
  final int? openSinceMs;
  final int probesSent;
  final int probeFailures;
  final int consecutiveProbeFailures;

  /// How long the last probe call itself took: a long call says the remote is not reading our endpoint
  final int lastProbeCallMs;
  final int bytesRead;
  final int bytesWritten;
  final int reads;
  final int writes;
  final int attempts;

  /// Milliseconds after an open during which this application writes nothing at all
  final int quietWindowMs;
  final bool aircraftLinked;
  final int? chargeCurrentMicroAmps;
  final DjiLinkCounters counters;
  final List<DjiLinkChannel> channels;
  final List<DjiLinkPair> pairs;
  final List<DjiLinkFrame> frames;
  final List<DjiLinkTelemetryRow> telemetry;
  final DjiLinkVideo video;
  final DjiLinkCapture capture;
  final DjiLinkSticks sticks;
}

@HostApi()
abstract class DjiLinkApi {
  /// What this device can do about a USB accessory. Answers on a device with no accessory feature too.
  DjiLinkEnvironment readEnvironment();

  /// Starts looking for an accessory and reading what arrives. Sends nothing but the liveness probe, and nothing at
  /// all for the first [DjiLinkSnapshot.quietWindowMs].
  void start();

  void stop();

  /// Another attempt without unplugging anything
  void retry();

  DjiLinkSnapshot snapshot();

  void startCapture();

  void stopCapture();

  void clearCapture();

  /// Writes the capture to the downloads folder: the bytes, the boundaries and the header with the digest
  @async
  DjiLinkExport exportCapture(DjiLinkExportNotes notes);

  /// Reads a capture file back through the same codecs, with no hardware
  @async
  DjiLinkReplayResult replayCapture(String path);
}

@FlutterApi()
abstract class DjiLinkEvents {
  void snapshotChanged(DjiLinkSnapshot snapshot);
}
