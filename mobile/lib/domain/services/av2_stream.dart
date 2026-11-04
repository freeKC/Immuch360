// The AV2 files Immuch360 Desktop plays (store/m2/av2-2026-11-02/plan-2026-11-02.md, sections 1.2 and 2.1): an IVF
// file whose four characters are AV02, as the reference encoder avmenc writes it, or a Section 5 stream of OBUs
// (.obu). Read without decoding anything: the app cuts the file into temporal units, finds the random access points in
// the OBU headers alone, and feeds the units to its companion immuch360-av2, which decodes them and serves the
// pictures to the player.
//
// An OBU of AV2 is its size in LEB128, which counts the header, then a header byte: the extension flag (bit 7), the
// type (bits 2 to 6) and the temporal layer (bits 0 and 1), and a second header byte when the extension flag is set
// (common/obudec.c of AVM v1.0.0, tools/input/parse.h of dav2d). A temporal unit starts at each temporal delimiter
// (type 2), whatever the IVF packets hold: avmenc puts several units in one packet (82 packets for the 151 frames of
// WorldCup). Each unit of the files of avmenc shows one frame: the six streams of the measure have as many units as
// decoded frames (151, 150, 64, 60, 51, 51), so unit k gives picture k of the companion's y4m. Unit k is not the frame
// it codes, though: avmenc codes each group of six frames as 0, 5, 2, 1, 3, 4, and the decoders give the frames back in
// the order of display (fixtures of lot AD0, mobile/test/fixtures/av2/FIXTURES.md). A random access point is a unit
// that holds a CLOSED_LOOP_KEY OBU; its display index is its unit index, and the pts of its IVF packet.
//
// An AV1 stream starts with an OBU header instead: 0x12 0x00 for its temporal delimiter, which read as AV2 is an OBU of
// type 0, which does not exist. An IVF says its codec in its four characters (AV01 for AV1, VP90 for VP9).
//
// Pure Dart, without Flutter: the fake companion of the tests is compiled from it (test/desktop/video/fakes).

import 'dart:math' as math;
import 'dart:typed_data';

/// The bytes of the start of a file that tell an AV2 stream: the IVF header, or the first OBUs of a Section 5 stream
const av2HeadLength = 32;

/// The frame rate given to a stream that does not say its own (a Section 5 stream: AV2 puts its timing in an optional
/// CONTENT_INTERPRETATION OBU, which this version does not read, and avmenc writes none by default)
const av2DefaultFrameRate = (numerator: 30, denominator: 1);

/// Reads up to [length] bytes of a file from [offset]: fewer at the end of the file, none past it
typedef Av2ByteReader = Future<Uint8List> Function(int offset, int length);

/// The types of the OBUs of AV2 that the app reads (table 6.1 of the specification v1.0.0, avm_codec.h of AVM v1.0.0)
abstract final class Av2ObuType {
  static const sequenceHeader = 1;
  static const temporalDelimiter = 2;
  static const multiFrameHeader = 3;
  static const closedLoopKey = 4;
  static const openLoopKey = 5;
  static const regularTileGroup = 7;
  static const regularTip = 14;
  static const layerConfigurationRecord = 16;
  static const atlasSegment = 17;
  static const operatingPointSet = 18;
  static const multiStreamDecoderOperation = 20;
  static const rasFrame = 21;
  static const contentInterpretation = 24;
  static const padding = 25;

  /// The OBUs the probe of dav2d lets through between the first temporal delimiter and the sequence header
  static const beforeSequenceHeader = {
    layerConfigurationRecord,
    atlasSegment,
    operatingPointSet,
    multiStreamDecoderOperation,
  };
}

/// The container of an AV2 file
enum Av2Container {
  /// An IVF file (DKIF, AV02): a 32-byte header, then packets of a 12-byte header and their OBUs
  ivf,

  /// A Section 5 stream: OBUs end to end, from a temporal delimiter
  obu,
}

/// What the first bytes of a file say of an AV2 stream ([readAv2Head]): its container and, for an IVF, the frame size,
/// the time base and the number of frames of its header
class Av2Head {
  const Av2Head.ivf({
    required int this.width,
    required int this.height,
    required int this.rate,
    required int this.scale,
    required int this.framesInHeader,
    required this.headerLength,
  }) : container = Av2Container.ivf;

  const Av2Head.obu()
    : container = Av2Container.obu,
      width = null,
      height = null,
      rate = null,
      scale = null,
      framesInHeader = null,
      headerLength = 0;

  final Av2Container container;

  /// The frame size the IVF header gives; null for a Section 5 stream (the companion's probe tells it)
  final int? width;
  final int? height;

  /// The time base of the IVF header: [rate] / [scale] frames per second for the files of avmenc (30/1, 60000/1001)
  final int? rate;
  final int? scale;

  /// The number of frames the IVF header says (a copy cut short keeps the number of the whole file)
  final int? framesInHeader;

  /// The bytes before the first packet (32 for an IVF), 0 for a Section 5 stream
  final int headerLength;

  /// The frame rate of the IVF header, null when it does not give one between 1 and 1000 frames per second
  ({int numerator, int denominator})? get frameRate {
    final numerator = rate;
    final denominator = scale;
    if (numerator == null || denominator == null || numerator <= 0 || denominator <= 0) {
      return null;
    }
    final fps = numerator / denominator;
    return fps >= 1 && fps <= 1000 ? (numerator: numerator, denominator: denominator) : null;
  }

  @override
  bool operator ==(Object other) =>
      other is Av2Head &&
      other.container == container &&
      other.width == width &&
      other.height == height &&
      other.rate == rate &&
      other.scale == scale &&
      other.framesInHeader == framesInHeader &&
      other.headerLength == headerLength;

  @override
  int get hashCode => Object.hash(container, width, height, rate, scale, framesInHeader, headerLength);

  @override
  String toString() => container == Av2Container.ivf
      ? 'Av2Head(ivf ${width}x$height, $rate/$scale, $framesInHeader frames)'
      : 'Av2Head(obu)';
}

/// Why a file is not an AV2 stream this version reads
enum Av2Refusal {
  /// An IVF of AV1 (AV01)
  av1,

  /// An IVF of another codec (VP90, VP80...)
  otherCodec,

  /// Neither an IVF nor AV2 OBUs, or too short to tell
  notAv2,
}

/// A file that is not an AV2 stream this version reads, [reason] says why; [fourcc] is the code of an IVF
class Av2FormatException implements Exception {
  const Av2FormatException(this.reason, {this.fourcc});

  final Av2Refusal reason;
  final String? fourcc;

  @override
  String toString() => 'Av2FormatException(${reason.name}${fourcc == null ? '' : ' $fourcc'})';
}

/// Whether [bytes], the first bytes of a file ([av2HeadLength] are enough), start an AV2 stream, and what they say;
/// null for anything else: an IVF of another codec, AV1 OBUs, random bytes, too few bytes. This is what the badge of a
/// thumbnail asks: the scan reads the head of each .ivf and .obu once and writes the answer into the index.
Av2Head? readAv2Head(List<int> bytes) {
  try {
    return _head(bytes);
  } on Av2FormatException {
    return null;
  }
}

/// The head of an AV2 stream, or the reason it is none
Av2Head _head(List<int> bytes) {
  if (bytes.length >= 4 && bytes[0] == 0x44 && bytes[1] == 0x4b && bytes[2] == 0x49 && bytes[3] == 0x46) {
    if (bytes.length < av2HeadLength) {
      throw const Av2FormatException(Av2Refusal.notAv2);
    }
    final fourcc = String.fromCharCodes([
      for (var i = 8; i < 12; i++) bytes[i] >= 0x20 && bytes[i] < 0x7f ? bytes[i] : 0x3f,
    ]);
    if (fourcc != 'AV02') {
      throw Av2FormatException(fourcc == 'AV01' ? Av2Refusal.av1 : Av2Refusal.otherCodec, fourcc: fourcc);
    }
    final headerLength = _le16(bytes, 6);
    if (headerLength < av2HeadLength) {
      throw Av2FormatException(Av2Refusal.notAv2, fourcc: fourcc);
    }
    return Av2Head.ivf(
      width: _le16(bytes, 12),
      height: _le16(bytes, 14),
      rate: _le32(bytes, 16),
      scale: _le32(bytes, 20),
      framesInHeader: _le32(bytes, 24),
      headerLength: headerLength,
    );
  }
  // A Section 5 stream: a temporal delimiter first, whose size is its header alone, then the sequence header, which
  // only the layer and operating point OBUs may come before (the probe of dav2d, tools/input/section5.c)
  final first = _obuHeaderAt(bytes, 0);
  if (first == null || first.type != Av2ObuType.temporalDelimiter || first.size != first.headerBytes) {
    throw const Av2FormatException(Av2Refusal.notAv2);
  }
  var at = first.end;
  var seen = 0;
  while (true) {
    final next = _obuHeaderAt(bytes, at);
    if (next == null) {
      // The bytes end before the next OBU header: one OBU after the delimiter is needed to tell
      if (seen == 0) {
        throw const Av2FormatException(Av2Refusal.notAv2);
      }
      return const Av2Head.obu();
    }
    seen++;
    if (next.type == Av2ObuType.sequenceHeader) {
      return const Av2Head.obu();
    }
    if (!Av2ObuType.beforeSequenceHeader.contains(next.type)) {
      throw const Av2FormatException(Av2Refusal.notAv2);
    }
    at = next.end;
  }
}

/// One OBU header: its size (header included), the bytes of its size field and of its header, its type, and where
/// it ends
typedef _ObuHeader = ({int size, int sizeBytes, int headerBytes, int type, int end});

/// Why no OBU header was read
enum _ObuProblem {
  /// The bytes stop inside the size or the header
  short,

  /// A size of more than 8 bytes, or one that cannot hold the header (0)
  invalid,
}

/// The OBU header in [bytes] at [offset], or why there is none
({_ObuHeader? header, _ObuProblem? problem}) _readObuHeader(List<int> bytes, int offset) {
  var value = 0;
  var sizeBytes = 0;
  for (var i = 0; ; i++) {
    if (i == 8) {
      return (header: null, problem: _ObuProblem.invalid);
    }
    if (offset + i >= bytes.length) {
      return (header: null, problem: _ObuProblem.short);
    }
    final byte = bytes[offset + i];
    value |= (byte & 0x7f) << (7 * i);
    if (byte & 0x80 == 0) {
      sizeBytes = i + 1;
      break;
    }
  }
  if (offset + sizeBytes >= bytes.length) {
    return (header: null, problem: _ObuProblem.short);
  }
  final first = bytes[offset + sizeBytes];
  final headerBytes = first & 0x80 != 0 ? 2 : 1;
  if (value < headerBytes) {
    return (header: null, problem: _ObuProblem.invalid);
  }
  return (
    header: (
      size: value,
      sizeBytes: sizeBytes,
      headerBytes: headerBytes,
      type: (first >> 2) & 0x1f,
      end: offset + sizeBytes + value,
    ),
    problem: null,
  );
}

/// The OBU header in [bytes] at [offset], null when there is none
_ObuHeader? _obuHeaderAt(List<int> bytes, int offset) => _readObuHeader(bytes, offset).header;

int _le16(List<int> bytes, int offset) => bytes[offset] | bytes[offset + 1] << 8;

int _le32(List<int> bytes, int offset) => _le16(bytes, offset) | _le16(bytes, offset + 2) << 16;

/// One temporal unit: the OBUs from a temporal delimiter to the next one, contiguous in the file, the record the
/// companion is fed with
class Av2Unit {
  const Av2Unit({required this.index, required this.offset, required this.length, required this.obuTypes, this.packet});

  /// Its rank in the file, which is the rank of the picture it gives
  final int index;

  /// Where it starts in the file (the size of its temporal delimiter) and its bytes
  final int offset;
  final int length;

  /// The types of its OBUs, in order (2 first)
  final List<int> obuTypes;

  /// The IVF packet that holds it, null in a Section 5 stream
  final int? packet;

  /// Whether a decoder may start here: the unit holds a CLOSED_LOOP_KEY OBU, after which no frame needs an earlier one
  bool get isAccessPoint => obuTypes.contains(Av2ObuType.closedLoopKey);

  /// Whether it holds an OPEN_LOOP_KEY or a RAS_FRAME OBU: not an access point until the companion has shown that no
  /// frame before it comes out (plan 2.1, point 1)
  bool get hasOpenKey => obuTypes.contains(Av2ObuType.openLoopKey) || obuTypes.contains(Av2ObuType.rasFrame);

  @override
  bool operator ==(Object other) =>
      other is Av2Unit &&
      other.index == index &&
      other.offset == offset &&
      other.length == length &&
      other.packet == packet &&
      _sameTypes(other.obuTypes, obuTypes);

  @override
  int get hashCode => Object.hash(index, offset, length, packet, Object.hashAll(obuTypes));

  @override
  String toString() => 'Av2Unit($index at $offset, $length bytes, packet $packet, types $obuTypes)';
}

bool _sameTypes(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

/// One packet of an IVF file
class Av2Packet {
  const Av2Packet({required this.offset, required this.size, required this.pts, required this.complete});

  /// Where its 12-byte header starts
  final int offset;

  /// The bytes its header announces, its OBUs
  final int size;

  /// The display index of the first frame that comes out once it is decoded (avmenc), not the frame its first unit
  /// codes
  final int pts;

  /// Whether the file holds all of it
  final bool complete;

  @override
  bool operator ==(Object other) =>
      other is Av2Packet &&
      other.offset == offset &&
      other.size == size &&
      other.pts == pts &&
      other.complete == complete;

  @override
  int get hashCode => Object.hash(offset, size, pts, complete);

  @override
  String toString() => 'Av2Packet(at $offset, $size bytes, pts $pts${complete ? '' : ', cut'})';
}

/// How the reading of a file ended
enum Av2IndexEnd {
  /// At the end of the file, every unit whole
  complete,

  /// The file stops inside a unit or a packet, as a copy that was interrupted: the units before are whole
  cut,

  /// An OBU whose size runs past its packet, a packet that does not start with a temporal delimiter, a size of 0: the
  /// rest of the file is not read, the units before are whole
  damaged,
}

/// The temporal units of an AV2 file and its random access points, read from the OBU headers alone
class Av2Index {
  const Av2Index({
    required this.head,
    required this.fileLength,
    required this.units,
    required this.packets,
    required this.end,
    required this.endOffset,
    this.hasContentInterpretation = false,
  });

  final Av2Head head;
  final int fileLength;

  /// The whole units, in the order of the file
  final List<Av2Unit> units;

  /// The packets of an IVF file, the one cut short included; empty for a Section 5 stream
  final List<Av2Packet> packets;

  final Av2IndexEnd end;

  /// Where the reading stopped: the end of the last whole unit for a cut or damaged file, the file length otherwise
  final int endOffset;

  /// Whether a CONTENT_INTERPRETATION OBU was seen (colour description and timing of AV2), which this version does not
  /// read
  final bool hasContentInterpretation;

  /// The number of pictures the companion serves: one per whole unit
  int get frameCount => units.length;

  /// The units a decoder may start at (CLOSED_LOOP_KEY), in order
  List<int> get accessPoints => [
    for (final unit in units)
      if (unit.isAccessPoint) unit.index,
  ];

  /// Whether the stream starts at an access point, as the companion requires (its index starts at unit 0)
  bool get startsWithAccessPoint => units.isNotEmpty && units.first.isAccessPoint;

  /// For an IVF cut short: the frames that play from the start without a gap, which is the pts of the first packet cut
  /// short (the whole units of that packet code frames after the missing ones: 7 of the 8 whole units of the cut
  /// fixture); null for a whole file or a Section 5 stream, where nothing tells it without decoding
  int? get framesBeforeCut {
    if (end == Av2IndexEnd.complete) {
      return null;
    }
    for (final packet in packets) {
      if (!packet.complete) {
        return packet.pts;
      }
    }
    return null;
  }

  /// The frame rate the y4m header gives: the time base of the IVF header, else [av2DefaultFrameRate]
  ({int numerator, int denominator}) get frameRate => head.frameRate ?? av2DefaultFrameRate;

  /// Whether [frameRate] comes from the file
  bool get frameRateKnown => head.frameRate != null;

  /// The access point at or before [frame], where a decoder starts to give it; 0 when there is none before it
  int accessPointBefore(int frame) {
    var found = 0;
    for (final unit in units) {
      if (unit.index > frame) {
        break;
      }
      if (unit.isAccessPoint) {
        found = unit.index;
      }
    }
    return found;
  }

  @override
  String toString() =>
      'Av2Index($head, ${units.length} units, access points $accessPoints, ${end.name} at $endOffset of $fileLength)';
}

/// Reads the temporal units of the AV2 file of [fileLength] bytes that [read] reads, from its OBU headers only: the
/// bytes of a large OBU are skipped, so a file of a share costs a few reads of [window] bytes per second of video.
/// Throws an [Av2FormatException] for a file that is not an AV2 stream (AV1 or VP9 in IVF, random bytes).
Future<Av2Index> indexAv2Stream(Av2ByteReader read, int fileLength, {int window = 64 * 1024}) async {
  final source = _Window(read, fileLength, math.max(window, av2HeadLength));
  final start = await source.bytes(0, math.min(av2HeadLength, fileLength));
  if (start == null) {
    throw const Av2FormatException(Av2Refusal.notAv2);
  }
  final head = _head(start);
  final units = <Av2Unit>[];
  final packets = <Av2Packet>[];
  var contentInterpretation = false;

  // The OBUs of [start, end) cut into units, [packet] for an IVF; [whole] when the file holds all the bytes of the
  // span (a Section 5 stream: the rest of the file). Null when the span ends whole, else how the reading ends.
  Future<Av2IndexEnd?> span(int start, int end, {int? packet, required bool whole}) async {
    var at = start;
    int? open;
    final types = <int>[];
    void close(int until) {
      final offset = open;
      if (offset != null) {
        units.add(
          Av2Unit(
            index: units.length,
            offset: offset,
            length: until - offset,
            obuTypes: List.unmodifiable(types),
            packet: packet,
          ),
        );
        types.clear();
        open = null;
      }
    }

    // What a span that stops early means: the file ends there (a copy cut short), or the bytes contradict themselves
    // inside a packet the file holds whole
    Av2IndexEnd stopped({required bool short}) =>
        short && (packet == null || !whole) ? Av2IndexEnd.cut : Av2IndexEnd.damaged;

    while (at < end) {
      final read = await source.obuHeader(at, end);
      final header = read.header;
      if (header == null) {
        return stopped(short: read.problem == _ObuProblem.short);
      }
      if (header.end > end) {
        // Its bytes run past the packet, or past the end of the file
        return stopped(short: true);
      }
      if (header.type == Av2ObuType.temporalDelimiter) {
        close(at);
        open = at;
      } else if (open == null) {
        // A packet that does not start with a temporal delimiter: units split across packets are no stream avmenc
        // writes
        return Av2IndexEnd.damaged;
      }
      if (header.type == Av2ObuType.contentInterpretation) {
        contentInterpretation = true;
      }
      types.add(header.type);
      at = header.end;
    }
    if (whole) {
      close(at);
      return null;
    }
    // A packet cut short: its last unit may miss OBUs, the ones before it are whole
    return Av2IndexEnd.cut;
  }

  var ending = Av2IndexEnd.complete;
  if (head.container == Av2Container.obu) {
    ending = await span(0, fileLength, whole: true) ?? Av2IndexEnd.complete;
  } else {
    var at = head.headerLength;
    while (at < fileLength) {
      final packetHeader = await source.bytes(at, 12);
      if (packetHeader == null) {
        ending = Av2IndexEnd.cut;
        break;
      }
      final size = _le32(packetHeader, 0);
      final pts = _le32(packetHeader, 4) + _le32(packetHeader, 8) * 0x100000000;
      final complete = at + 12 + size <= fileLength;
      packets.add(Av2Packet(offset: at, size: size, pts: pts, complete: complete));
      final result = await span(
        at + 12,
        math.min(at + 12 + size, fileLength),
        packet: packets.length - 1,
        whole: complete,
      );
      if (result != null) {
        ending = result;
        break;
      }
      at += 12 + size;
    }
  }
  final endOffset = ending == Av2IndexEnd.complete
      ? fileLength
      : units.isEmpty
      ? head.headerLength
      : units.last.offset + units.last.length;
  return Av2Index(
    head: head,
    fileLength: fileLength,
    units: List.unmodifiable(units),
    packets: List.unmodifiable(packets),
    end: ending,
    endOffset: endOffset,
    hasContentInterpretation: contentInterpretation,
  );
}

/// The bytes of a file read through a window that follows the reading: the small OBUs of a unit come in one read, a
/// large one is skipped
class _Window {
  _Window(this._read, this._length, this._size);

  final Av2ByteReader _read;
  final int _length;
  final int _size;
  var _start = 0;
  var _bytes = Uint8List(0);

  /// [count] bytes from [offset], null when the file ends first
  Future<Uint8List?> bytes(int offset, int count) async {
    if (offset + count > _length) {
      return null;
    }
    if (offset < _start || offset + count > _start + _bytes.length) {
      _start = offset;
      _bytes = await _read(offset, math.min(math.max(_size, count), _length - offset));
      if (_bytes.length < count) {
        return null;
      }
    }
    return Uint8List.sublistView(_bytes, offset - _start, offset - _start + count);
  }

  /// The OBU header at [offset], read within [end] (a size takes 8 bytes at most, the header 2)
  Future<({_ObuHeader? header, _ObuProblem? problem})> obuHeader(int offset, int end) async {
    final bytes = await this.bytes(offset, math.min(10, end - offset));
    if (bytes == null) {
      return (header: null, problem: _ObuProblem.short);
    }
    final read = _readObuHeader(bytes, 0);
    final header = read.header;
    if (header == null) {
      return read;
    }
    return (
      header: (
        size: header.size,
        sizeBytes: header.sizeBytes,
        headerBytes: header.headerBytes,
        type: header.type,
        end: offset + header.end,
      ),
      problem: null,
    );
  }
}
