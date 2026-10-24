import 'package:pigeon/pigeon.dart';

// Android only (phones and the Meta Quest build): the DJI live video and its diagnostics, behind Settings, Advanced,
// "DJI live video (experimental)". The native side opens a DJI remote controller plugged into this device as a USB
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

/// Why the link is in its state. The page turns each one into a sentence of its own language.
enum DjiLinkReason {
  noAccessoryFeature,
  noUsbService,
  looking,
  nothingListed,
  listed,

  /// A fresh plug: the system chooser may be on screen, so the permission is asked after a short wait
  waitingForChooser,
  permissionAsked,
  permissionRequestFailed,

  /// Asked again only by the retry button or a new plug
  permissionRefused,
  openFailed,
  opened,
  probeReturns,
  probesFailed,

  /// A probe write did not return: the remote is not reading this endpoint, and probing stopped
  writeBlocked,
  detached,
  streamEnded,
  readsFailed,
  writesFailed,
  pageClosed,
  framesParse,
  aircraftFrames,

  /// Pictures came out of the decoder in the last two seconds
  videoDecoded,
}

/// Whether a hardware profile can do something. [supported] is impossible to reach without an observation on named
/// hardware, so a fresh profile is [unknown] everywhere.
enum DjiLinkSupport { unknown, unsupported, supported }

/// What a video payload looks like. A codec is named only once the stream itself showed it: H.265 from its parameter
/// sets or the delimiter signature of the 23 October 2026 capture, H.264 from its own sequence parameter set.
enum DjiLinkProbeVerdict { noData, noStartCodes, startCodesSeen, h265, h264 }

/// Where the live picture stands
enum DjiLinkVideoState {
  waitingForVideo,
  waitingForDescription,

  /// Joined a running stream: no key picture yet, the picture builds up
  building,
  decoding,

  /// Decoding goes on while no video panel is shown
  hidden,
  failed,

  /// H.264 recognised, not decoded in this stage
  h264NotDecoded,
}

/// Where the stream description in use came from
enum DjiLinkDescriptionSource { none, session, cache, profile }

/// The pilot's choice of decoder; automatic is the default
enum DjiLinkDecoderChoice { automatic, hardware, software }

/// How a telemetry value is known
enum DjiLinkEvidence {
  /// A public layout and the 23 October capture agree
  publicAndCapture,

  /// The capture alone shows what the field is
  capture,

  /// A reading that fits and was never checked against a reference
  candidate,
}

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
  const DjiLinkCapability({
    required this.name,
    required this.support,
    this.provenance,
    this.observedOn,
    this.observedDate,
    this.observed,
  });

  final String name;

  /// The answer on this device: unknown anywhere but on the device and flavour of the observation
  final DjiLinkSupport support;

  /// The observation this answer rests on; null while nothing was observed
  final String? provenance;

  /// The device and flavour the observation was made on ("Samsung SM-S926B, phone"), so that a phone result is never
  /// read as a headset one; null for an observation made on no device, such as an offline decode
  final String? observedOn;
  final String? observedDate;

  /// One line of what was observed
  final String? observed;
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
    required this.unknownChannelRejections,
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
    this.paddingBytes = 0,
  });

  final int envelopeFrames;
  final int envelopeBytes;
  final int payloadBytes;
  final int discardedBytes;
  final int resynchronisations;
  final int unknownChannelFrames;

  /// Headers on an undescribed channel met while resynchronising, refused as a likely false sync
  final int unknownChannelRejections;
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

  /// Zero bytes after control envelopes up to a multiple of 512, consumed in sync: padding, not a discard
  final int paddingBytes;
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
    this.messageName,
  });

  final int commandSet;
  final int commandId;
  final int count;
  final int lastLength;
  final int lastSeenMs;

  /// Only once a capture of owned hardware has shown what the message carries; null until then
  final String? messageName;
}

/// The checksum parameters in use, and the seeds the checksum failures vote for. On noise the votes spread; real
/// frames whose seed differs from the notes pile their votes on one value, which a replay can then try.
class DjiLinkCrc {
  const DjiLinkCrc({
    required this.headerParameters,
    required this.frameParameters,
    required this.headerSeedVotes,
    required this.headerFailuresVoting,
    required this.frameSeedVotes,
    required this.frameFailuresVoting,
    this.headerSeedCandidate,
    this.frameSeedCandidate,
  });

  final String headerParameters;
  final String frameParameters;
  final int? headerSeedCandidate;
  final int headerSeedVotes;
  final int headerFailuresVoting;
  final int? frameSeedCandidate;
  final int frameSeedVotes;
  final int frameFailuresVoting;
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

/// The video panel: the state, the codec and the stream description, the decoder, and the counters of the path from
/// the cable to the screen
class DjiLinkDecode {
  const DjiLinkDecode({
    required this.state,
    required this.codec,
    required this.descriptionSource,
    required this.choice,
    required this.lowLatency,
    required this.switches,
    required this.unitsIn,
    required this.queued,
    required this.decoded,
    required this.shown,
    required this.droppedAtDisplay,
    required this.overruns,
    required this.tooLarge,
    required this.unitsWithoutDescription,
    required this.errors,
    required this.picturesPerSecond,
    required this.megabitsPerSecond,
    required this.lostPictures,
    required this.encoderRestarts,
    required this.keyPictures,
    this.unitsDropped = 0,
    this.failure,
    this.width,
    this.height,
    this.profileName,
    this.highTier,
    this.levelName,
    this.decoderName,
    this.decoderHardware,
    this.switchReason,
    this.decodeLastMs,
    this.decodeMedianMs,
    this.decodeP95Ms,
    this.inProcessMedianMs,
    this.inProcessP95Ms,
    this.firstPictureMs,
    this.keyPictureAgoMs,
    this.lastOutputAgoMs,
  });

  final DjiLinkVideoState state;

  /// A short code when the decoder failed: no-decoder, configuration-refused, error-<code>
  final String? failure;

  /// h265, h264 or unknown
  final String codec;
  final int? width;
  final int? height;
  final String? profileName;
  final bool? highTier;
  final String? levelName;
  final DjiLinkDescriptionSource descriptionSource;
  final String? decoderName;
  final bool? decoderHardware;
  final DjiLinkDecoderChoice choice;

  /// The configuration the decoder accepted asked for low latency
  final bool lowLatency;
  final int switches;

  /// Why the last switch to software happened: noOutputAfterJoin, hardwareRetryFailed, fatalErrors
  final String? switchReason;
  final int unitsIn;
  final int queued;
  final int decoded;
  final int shown;
  final int droppedAtDisplay;
  final int overruns;

  /// Pictures the queue in front of the decoder dropped: past its bound, or at a flush when it could not keep up
  final int unitsDropped;
  final int tooLarge;
  final int unitsWithoutDescription;
  final int errors;
  final double picturesPerSecond;
  final double megabitsPerSecond;
  final double? decodeLastMs;
  final double? decodeMedianMs;
  final double? decodeP95Ms;
  final double? inProcessMedianMs;
  final double? inProcessP95Ms;
  final int? firstPictureMs;
  final int lostPictures;
  final int encoderRestarts;
  final int keyPictures;
  final int? keyPictureAgoMs;
  final int? lastOutputAgoMs;
}

/// The flight data group, read from the link with layouts that fit the 23 October 2026 capture. Not a flight
/// instrument: nothing here has been compared with DJI Fly yet.
class DjiLinkFlight {
  const DjiLinkFlight({
    required this.ageMs,
    required this.stale,
    required this.heightM,
    required this.speedsMps,
    required this.pitchDeg,
    required this.rollDeg,
    required this.headingDeg,
    required this.mode,
    required this.inAir,
    required this.motorsOn,
    required this.motorTimeS,
    required this.satellites,
    required this.groundHeightM,
    required this.evidence,
  });

  final int ageMs;
  final bool stale;
  final double heightM;
  final List<double> speedsMps;
  final double pitchDeg;
  final double rollDeg;
  final double headingDeg;
  final int mode;
  final bool inAir;
  final bool motorsOn;
  final double motorTimeS;
  final int satellites;
  final double groundHeightM;
  final DjiLinkEvidence evidence;
}

class DjiLinkBattery {
  const DjiLinkBattery({
    required this.ageMs,
    required this.stale,
    required this.percent,
    required this.volts,
    required this.amps,
    required this.remainingMah,
    required this.fullMah,
    required this.temperatureC,
    required this.cells,
    required this.status,
    required this.evidence,
  });

  final int ageMs;
  final bool stale;
  final int percent;
  final double volts;
  final double amps;
  final int remainingMah;
  final int fullMah;
  final double temperatureC;
  final int cells;

  /// The status bits, hexadecimal
  final String status;
  final DjiLinkEvidence evidence;
}

class DjiLinkGimbal {
  const DjiLinkGimbal({
    required this.ageMs,
    required this.stale,
    required this.headingDeg,
    required this.headingFineDeg,
    required this.angle1Deg,
    required this.angle2Deg,
    required this.quaternion,
    required this.evidence,
  });

  final int ageMs;
  final bool stale;
  final double headingDeg;
  final double headingFineDeg;
  final double angle1Deg;
  final double angle2Deg;

  /// w, x, y, z
  final List<double> quaternion;
  final DjiLinkEvidence evidence;
}

class DjiLinkLinkInfo {
  const DjiLinkLinkInfo({
    this.signalAircraftSide,
    this.signalRemoteSide,
    this.liveRateMbps,
    this.aircraftClockMs,
    this.clockJitterP95Ms,
    this.clockDriftMs,
    this.ageMs,
    this.stale = false,
  });

  final int? signalAircraftSide;
  final int? signalRemoteSide;
  final double? liveRateMbps;
  final int? aircraftClockMs;
  final double? clockJitterP95Ms;
  final double? clockDriftMs;

  /// Age of the aircraft clock, the most frequent of these
  final int? ageMs;
  final bool stale;
}

/// Requests of one sender and pair that wait for an answer this application never gives
class DjiLinkRequestRow {
  const DjiLinkRequestRow({
    required this.senderType,
    required this.senderIndex,
    required this.commandSet,
    required this.commandId,
    required this.ackPolicy,
    required this.count,
    required this.repeats,
  });

  final int senderType;
  final int senderIndex;
  final int commandSet;
  final int commandId;
  final int ackPolicy;
  final int count;
  final int repeats;
}

/// The flight and battery section
class DjiLinkTelemetry {
  const DjiLinkTelemetry({
    required this.aircraftPresent,
    required this.remotePresent,
    required this.layoutMismatches,
    required this.unanswered,
    this.flight,
    this.battery,
    this.gimbal,
    this.link,
    this.remoteBatteryPercent,
    this.remoteBatteryStale = false,
    this.remoteBatteryAgeMs,
  });

  final bool aircraftPresent;
  final bool remotePresent;
  final int layoutMismatches;
  final DjiLinkFlight? flight;
  final DjiLinkBattery? battery;
  final DjiLinkGimbal? gimbal;
  final DjiLinkLinkInfo? link;

  /// A candidate: the byte that fits, to check against DJI Fly
  final int? remoteBatteryPercent;
  final bool remoteBatteryStale;

  /// Milliseconds since the remote battery was last read, as the other groups carry their age
  final int? remoteBatteryAgeMs;
  final List<DjiLinkRequestRow> unanswered;
}

/// Where the page's video and telemetry come from: the cable, a capture being played, or a phone's relay
class DjiLinkSource {
  const DjiLinkSource({
    required this.replay,
    required this.playing,
    this.name,
    this.positionMs,
    this.durationMs,
    this.failure,
    this.relay = false,
    this.phoneName,
    this.loop = false,
  });

  final bool replay;
  final bool playing;
  final String? name;
  final int? positionMs;
  final int? durationMs;

  /// The kind of the error that ended the playback early (a damaged capture), or null
  final String? failure;

  /// The picture and the values come from a phone's relay (a headset receiving)
  final bool relay;
  final String? phoneName;

  /// The capture being played starts again at its start second when it ends
  final bool loop;
}

/// Where a headset stands with the phone it receives from
enum DjiRelayReceiveState {
  idle,
  connecting,
  checkingCode,
  receiving,

  /// The connection was lost: trying again
  lost,

  /// The phone refused the code, or made a new one: the code is asked again
  wrongCode,

  /// The phone already sends to four headsets: trying again every 10 s
  full,

  /// Too many wrong codes from this address: trying again every 10 s
  blocked,
  otherVersion,

  /// The phone did not prove the code: nothing it sends is shown
  phoneUnproven,

  /// A remote is open on this device's cable
  busy,
}

/// One headset the phone sends to
class DjiRelayHeadsetRow {
  const DjiRelayHeadsetRow({
    required this.address,
    required this.connectedForMs,
    required this.droppedUnits,
    required this.megabitsPerSecond,
    this.name,
    this.picturesShownPerSecond,
    this.relayDelayMs,
  });

  final String address;
  final String? name;
  final int connectedForMs;

  /// From its pings: pictures it showed per second over its last 10 s
  final double? picturesShownPerSecond;

  /// From its pings: how long after this phone it receives the pictures
  final double? relayDelayMs;
  final int droppedUnits;
  final double megabitsPerSecond;
}

/// "Send to a headset" on the phone
class DjiRelaySending {
  const DjiRelaySending({
    required this.on,
    required this.sending,
    required this.headsets,
    required this.refusedProofs,
    required this.unexpectedRecords,
    required this.wifiLowLatencyHeld,
    required this.unitsDropped,
    this.port,
  });

  final bool on;
  final int? port;

  /// cable, replay or none
  final String sending;
  final List<DjiRelayHeadsetRow> headsets;
  final int refusedProofs;
  final int unexpectedRecords;
  final bool wifiLowLatencyHeld;
  final int unitsDropped;
}

/// "Receive from a phone" on a headset, with the latency of the way from the phone, in milliseconds
class DjiRelayReceiving {
  const DjiRelayReceiving({
    required this.state,
    required this.phoneSource,
    required this.replay,
    required this.failures,
    required this.units,
    required this.lostOnWifi,
    required this.receivedPerSecond,
    required this.decodedPerSecond,
    required this.shownPerSecond,
    required this.lostOnRadio,
    this.phoneName,
    this.phoneId,
    this.host,
    this.port,
    this.replayName,
    this.replayPositionMs,
    this.reconnectInMs,
    this.relayDelayMedianMs,
    this.relayDelayP95Ms,
    this.phoneQueueMedianMs,
    this.networkMedianMs,
    this.networkP95Ms,
    this.clockUncertaintyMs,
    this.arrivalSpreadMedianMs,
    this.phoneInProcessMedianMs,
    this.phoneDecodeMedianMs,
    this.receiveToPictureMs,
    this.behindPhoneMs,
    this.lastPictureAgoMs,
  });

  final DjiRelayReceiveState state;
  final String? phoneName;
  final String? phoneId;
  final String? host;
  final int? port;

  /// What the phone sends: cable, replay or none
  final String phoneSource;
  final bool replay;
  final String? replayName;
  final int? replayPositionMs;
  final int? reconnectInMs;

  /// Connection attempts that failed in a row
  final int failures;
  final int units;

  /// Pictures the phone dropped for this headset because the Wi-Fi could not keep up
  final int lostOnWifi;

  /// Phone receive time to the record complete here, median and 95th percentile; null while the clocks are measured
  final double? relayDelayMedianMs;
  final double? relayDelayP95Ms;

  /// The part of the phone: the last fragment to the start of the write
  final double? phoneQueueMedianMs;

  /// The part of the network: the start of the write to the record complete here
  final double? networkMedianMs;
  final double? networkP95Ms;
  final double? clockUncertaintyMs;
  final double? arrivalSpreadMedianMs;

  /// The phone's own in process and decode medians, from its telemetry
  final double? phoneInProcessMedianMs;
  final double? phoneDecodeMedianMs;

  /// Relay delay plus this device's in process and decode medians
  final double? receiveToPictureMs;

  /// How long after the phone's own screen this device shows a picture
  final double? behindPhoneMs;
  final int? lastPictureAgoMs;
  final double receivedPerSecond;
  final double decodedPerSecond;
  final double shownPerSecond;

  /// Pictures lost on the radio, from the picture counter, as on the phone
  final int lostOnRadio;
}

/// What "Send to a headset" starts with: the code, the names the welcome and the announcement carry, the notification
class DjiRelayStart {
  const DjiRelayStart({
    required this.code,
    required this.phoneName,
    required this.notificationTitle,
    required this.notificationText,
    required this.stopLabel,
    required this.channelName,
    this.phoneId,
  });

  final String code;
  final String phoneName;
  final String? phoneId;
  final String notificationTitle;
  final String notificationText;
  final String stopLabel;
  final String channelName;
}

/// A capture that can be played: an export of this app, a pair of files in its replay folder, or chosen in the picker
class DjiLinkCaptureFile {
  const DjiLinkCaptureFile({
    required this.name,
    required this.binUri,
    required this.indexUri,
    required this.bytes,
    required this.modifiedMs,
    required this.origin,
  });

  final String name;
  final String binUri;
  final String indexUri;
  final int bytes;
  final int modifiedMs;

  /// export, replayFolder or chosen
  final String origin;
}

/// A USB accessory as the system lists it: no serial, no permission, nothing opened
class DjiLinkPluggedAccessory {
  const DjiLinkPluggedAccessory({this.manufacturer, this.model, this.description, this.version});

  final String? manufacturer;
  final String? model;
  final String? description;
  final String? version;
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
    this.headBytes = 0,
  });

  final bool recording;
  final int totalBytes;
  final int droppedBytes;
  final int records;

  /// The tail: the last bytes of a session
  final int capacityBytes;

  /// The head: the first bytes of a session, kept whatever its length
  final int headBytes;
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
    this.headerOnly = false,
    this.repeated = false,
    this.nothing = false,
    this.controlBinPath,
  });

  final bool ok;
  final int bytes;
  final String? binPath;
  final String? indexPath;
  final String? headerPath;
  final String? sha256;
  final String? error;

  /// Nothing was captured, so only the header with this device and its USB environment was written
  final bool headerOnly;

  /// Nothing new since the last export: no file was written, and the paths are those of the last export
  final bool repeated;

  /// A reception record with nothing received: no file was written
  final bool nothing;

  /// Every control frame of the session, beside the bytes of its head and its tail
  final String? controlBinPath;
}

/// Where an obstacle is, in a top view with the nose up. No side is known from our captures yet: the alert names one
/// only once a capture proves which index of the drone's ring is its nose.
enum DjiObstacleSide { ahead, behind, left, right, above }

/// What the obstacle alert decided (ObstacleAlert on the native side, the same on the phone and the headset). It is
/// information for the pilot, never an action: nothing here reaches the remote or the drone.
class DjiObstacleDecision {
  const DjiObstacleDecision({
    required this.on,
    required this.stopped,
    required this.listening,
    required this.beepIntervalMs,
    this.distanceM,
    this.side,
  });

  /// The alert shows: something is close on a side other than below
  final bool on;

  /// The obstacle data stopped while the alert was on: for a few seconds the banner says so, with no sound
  final bool stopped;

  /// The alert is offered and its data is fresh: the glyph shows, never meaning the way is clear
  final bool listening;

  /// 0 when silent
  final int beepIntervalMs;
  final double? distanceM;
  final DjiObstacleSide? side;
}

/// The values a pilot reads, sent ten times a second while a screen with the picture is in front (flightChanged), and
/// in every snapshot. A value whose group is stale, or never came, is null: nothing draws an old number as current.
/// Which of them may show, and where, is decided by the gate of dji_live_fields.dart, not here.
class DjiLiveFrame {
  const DjiLiveFrame({
    required this.atMs,
    required this.alert,
    this.droneBatteryPercent,
    this.batteryVolts,
    this.batteryTemperatureC,
    this.motorTimeS,
    this.motorsOn,
    this.headingDeg,
    this.heightM,
    this.verticalSpeedMps,
    this.speedMps,
    this.distanceBelowM,
    this.obstacleM,
    this.remoteBatteryPercent,
    this.signal,
    this.signalBars,
    this.linkRateMbps,
    this.satellites,
    this.landing = false,
  });

  /// This device's monotonic clock when the frame was built
  final int atMs;
  final DjiObstacleDecision alert;
  final int? droneBatteryPercent;
  final double? batteryVolts;
  final double? batteryTemperatureC;
  final double? motorTimeS;
  final bool? motorsOn;
  final double? headingDeg;

  /// Above the take off point, positive up
  final double? heightM;

  /// Positive climbing
  final double? verticalSpeedMps;

  /// Over the ground; null while the motors are off, when the drone holds a stale value
  final double? speedMps;

  /// Only while the motors run; null when the sensor reads nothing
  final double? distanceBelowM;

  /// The nearest distance of the obstacle ring, only while the motors run; null when no sector reads anything
  final double? obstacleM;
  final int? remoteBatteryPercent;
  final int? signal;
  final int? signalBars;
  final double? linkRateMbps;
  final int? satellites;

  /// Flight mode 12, the automatic landing
  final bool landing;
}

class DjiLinkReplayResult {
  const DjiLinkReplayResult({
    required this.ok,
    required this.readsReplayed,
    required this.bytesReplayed,
    required this.usedIndex,
    required this.opens,
    this.error,
    this.crc,
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

  /// Open markers met in the index; each one restarted the parsers
  final int opens;
  final String? error;
  final DjiLinkCrc? crc;
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
    required this.probesHalted,
    required this.opens,
    required this.crc,
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
    this.reason,
    this.detail,
    this.accessory,
    this.profile,
    this.firstByteMs,
    this.openSinceMs,
    this.chargeCurrentMicroAmps,
    this.videoDecode,
    this.telemetryValues,
    this.source,
    this.lastAccessory,
    this.lastAccessoryAtMs,
    this.boundProfileId,
    this.relaySending,
    this.relayReceiving,
    this.flightViewFailed = false,
    this.liveFrame,
  });

  final DjiLinkState state;
  final DjiLinkReason? reason;

  /// One technical word that goes with [reason], such as the name of an exception; null most of the time
  final String? detail;
  final DjiLinkAccessory? accessory;
  final DjiLinkProfile? profile;

  /// Time between the open and the first byte read; null while no byte has arrived, which is a result of its own
  final int? firstByteMs;
  final int? openSinceMs;
  final int probesSent;
  final int probeFailures;
  final int consecutiveProbeFailures;

  /// A probe write blocked, so no further probe is queued on this descriptor
  final bool probesHalted;

  /// Descriptors opened since the page started
  final int opens;

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
  final DjiLinkCrc crc;
  final List<DjiLinkChannel> channels;
  final List<DjiLinkPair> pairs;
  final List<DjiLinkFrame> frames;
  final List<DjiLinkTelemetryRow> telemetry;
  final DjiLinkVideo video;
  final DjiLinkCapture capture;
  final DjiLinkSticks sticks;

  /// The video panel; null before the page session made one
  final DjiLinkDecode? videoDecode;

  /// The flight and battery section
  final DjiLinkTelemetry? telemetryValues;
  final DjiLinkSource? source;

  /// The last accessory strings read on the port, kept after the unplug
  final DjiLinkAccessory? lastAccessory;
  final int? lastAccessoryAtMs;

  /// The profile the pilot bound these accessory strings to, if any
  final String? boundProfileId;

  /// "Send to a headset", on a phone
  final DjiRelaySending? relaySending;

  /// "Receive from a phone"; null until this device tried to receive
  final DjiRelayReceiving? relayReceiving;

  /// The last flight view could not set its scene up and went back to the window
  final bool flightViewFailed;

  /// The values a pilot reads, as the ten a second frames give them
  final DjiLiveFrame? liveFrame;
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

  /// Writes the capture to the downloads folder: the bytes, the boundaries and the header with the digest. With
  /// nothing captured, the header alone.
  @async
  DjiLinkExport exportCapture(DjiLinkExportNotes notes);

  /// Reads a capture file back through the same codecs, with no hardware. A seed given for either checksum replaces
  /// the one of the notes, so that a candidate the live page voted for can be tried on the same bytes.
  @async
  DjiLinkReplayResult replayCapture(String path, int? headerCrcSeed, int? frameCrcSeed);

  /// Automatic, hardware or software: the running decoder stops and the next picture starts one of that kind
  void setDecoderChoice(DjiLinkDecoderChoice choice);

  /// The captures this app can play, newest first: its exports and the files of its replay folder
  @async
  List<DjiLinkCaptureFile> listCaptures();

  /// The system picker, several files at once: a .bin and its .idx.csv. Null when nothing usable was chosen.
  @async
  DjiLinkCaptureFile? chooseCaptureFiles();

  /// Plays a capture through the same pipeline as the cable, paced by its index, from [startAtMs], again from there
  /// at each end with [loop]. Null when it started; otherwise a code: busy (an accessory is open), unreadable, empty.
  @async
  String? playCapture(String binUri, String indexUri, int startAtMs, bool loop);

  void stopPlayback();

  /// Binds the accessory strings in use, or the last ones seen, to a starting profile; null forgets the binding.
  /// It names the hardware and changes nothing in what the link does.
  void bindProfile(String? profileId);

  /// The profiles the pilot can choose under "Your hardware"
  List<DjiLinkProfile> profiles();

  /// The USB accessories the system lists right now, without a permission and without opening anything
  List<DjiLinkPluggedAccessory> pluggedAccessories();

  /// "Send to a headset": the relay listens on the local network (8362, else a free port) and the foreground service
  /// keeps the phone sending with its screen locked. Returns the port, 0 when it could not start. Nothing a headset
  /// sends reaches the remote: the relay takes a hello, pings and a bye, and nothing else.
  @async
  int startRelay(DjiRelayStart start);

  void stopRelay();

  /// "New code": every headset is told and must prove the new code
  void setRelayCode(String code);

  /// The text of the notification, with the number of headsets
  void updateRelayNotification(String text);

  /// "Receive from a phone": null when it started; otherwise badHost, badCode, busy (a remote is open on this
  /// device's cable) or sending (this device sends to headsets)
  String? connectRelay(String host, int port, String code, String? phoneId, String headsetName);

  void disconnectRelay();

  /// The flight view of the Quest, with the texts of its panel; false off Horizon OS or while no picture comes
  bool openFlightView(Map<String, String> labels);

  /// "Open this screen when the remote is plugged in", kept by the native side, off by default. With it on and the
  /// setting on, the entry that puts this application in Android's question for a plugged DJI remote stays enabled
  /// when the link ends. It decides which application Android offers for the cable, and nothing else.
  void setOpenOnPlug(bool on);

  bool openOnPlug();

  /// Settings, Advanced, "DJI live video (experimental)": with it off, plugging the remote never opens the app
  void setLiveSettingOn(bool on);

  /// True once after the plug of a remote brought this application forward through its attach entry
  bool takeAttachLaunch();

  /// A screen with the picture is in front (the live screen, the watch page) or not: while it is, the values come ten
  /// times a second in flightChanged, and the obstacle sound may play
  void setFrameStream(bool on);

  /// Whether the gate offers the obstacle alert, and whether its sound is on. The alert only reads, decides, draws and
  /// beeps on this device: it never sends anything to the remote or the drone.
  void setObstacleAlert(bool offered, bool sound);

  /// Three beeps of the obstacle sound, to check the volume before take off
  void playObstacleTest();

  /// The media volume, which the obstacle sound follows, is at zero
  bool mediaVolumeOff();

  /// A headset writes what it received from the phone and how it decoded it: the relay records with their times, the
  /// receiver's and the decoder's counters. Nothing is written when nothing was received.
  @async
  DjiLinkExport exportReception();
}

@FlutterApi()
abstract class DjiLinkEvents {
  void snapshotChanged(DjiLinkSnapshot snapshot);

  /// Stop in the notification of "Send to a headset": the relay stopped, the announcement must stop too
  void relayStopRequested();

  /// The values a pilot reads, at most ten times a second and only while setFrameStream is on
  void flightChanged(DjiLiveFrame frame);
}
