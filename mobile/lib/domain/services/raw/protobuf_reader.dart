// The protobuf wire format, read without a schema: the metadata of an Insta360 trailer and the records of the camd box
// of a DJI Osmo 360 file are protobuf messages whose field numbers the parsers know, and nothing else of protobuf is
// needed to read them.
//
// Pure Dart.

import 'dart:convert';
import 'dart:typed_data';

/// Protobuf wire types: a varint, 8 bytes (a double), a length and its bytes (a string, a message, packed values), 4
/// bytes (a float)
const protoVarint = 0;
const protoFixed64 = 1;
const protoLengthDelimited = 2;
const protoFixed32 = 5;

/// A field of a protobuf message: its number, its wire type, and its value: the integer of a varint, the bytes of the
/// other wire types (8 for a 64 bit field, 4 for a 32 bit one)
class ProtoField {
  const ProtoField(this.number, this.wireType, {this.integer = 0, this.bytes});

  final int number;
  final int wireType;

  /// Value of a varint; a negative int32 or int64 reads as its two's complement, as protobuf writes it
  final int integer;

  /// Payload of the wire types 1, 2 and 5
  final Uint8List? bytes;

  /// The UTF-8 text of a length delimited field, null for another wire type
  String? get string => wireType == protoLengthDelimited ? utf8.decode(bytes!, allowMalformed: true) : null;

  /// The value as a number whatever its encoding: a varint, a float or a double
  double? get asDouble => switch (wireType) {
    protoVarint => integer.toDouble(),
    protoFixed32 => ByteData.sublistView(bytes!).getFloat32(0, Endian.little),
    protoFixed64 => ByteData.sublistView(bytes!).getFloat64(0, Endian.little),
    _ => null,
  };

  /// The float of a 32 bit field, null for another wire type
  double? get float32 => wireType == protoFixed32 ? ByteData.sublistView(bytes!).getFloat32(0, Endian.little) : null;

  @override
  String toString() => 'ProtoField($number, wire $wireType, ${bytes == null ? integer : '${bytes!.length} bytes'})';
}

/// The fields of the protobuf message [bytes], in their order. A truncated field, or a group (wire types 3 and 4, long
/// deprecated and not in these messages), ends the message with a [FormatException].
Iterable<ProtoField> protoFields(Uint8List bytes) sync* {
  var offset = 0;

  int varint() {
    var value = 0;
    for (var shift = 0; shift < 64; shift += 7) {
      if (offset >= bytes.length) {
        throw const FormatException('Truncated varint');
      }
      final byte = bytes[offset++];
      value |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) {
        return value;
      }
    }
    throw const FormatException('Varint too long');
  }

  Uint8List take(int length) {
    if (length < 0 || offset + length > bytes.length) {
      throw const FormatException('Truncated field');
    }
    final field = Uint8List.sublistView(bytes, offset, offset + length);
    offset += length;
    return field;
  }

  while (offset < bytes.length) {
    final key = varint();
    final number = key >> 3;
    final wireType = key & 7;
    yield switch (wireType) {
      protoVarint => ProtoField(number, wireType, integer: varint()),
      protoFixed64 => ProtoField(number, wireType, bytes: take(8)),
      protoLengthDelimited => ProtoField(number, wireType, bytes: take(varint())),
      protoFixed32 => ProtoField(number, wireType, bytes: take(4)),
      _ => throw FormatException('Unsupported wire type $wireType'),
    };
  }
}

/// The fields of the protobuf message [bytes], stopping silently at the first damaged one: a record cut by the end of
/// the bytes read keeps the fields before it
List<ProtoField> protoFieldsLenient(Uint8List bytes) {
  final fields = <ProtoField>[];
  try {
    for (final field in protoFields(bytes)) {
      fields.add(field);
    }
  } on FormatException {
    // The fields read so far stay
  }
  return fields;
}

/// The payload of the first length delimited field at each step of [path] from the message [bytes] ([2, 6] is the
/// calibration message of the config of a DJI camd box); null when a step is missing
Uint8List? protoPath(Uint8List bytes, List<int> path) {
  var message = bytes;
  for (final number in path) {
    Uint8List? next;
    try {
      for (final field in protoFields(message)) {
        if (field.number == number && field.wireType == protoLengthDelimited) {
          next = field.bytes;
          break;
        }
      }
    } on FormatException {
      // A damaged message has no further field to give
    }
    if (next == null) {
      return null;
    }
    message = next;
  }
  return message;
}

/// The little endian floats packed in the payload of a length delimited field; trailing bytes that make no whole float
/// are left out
List<double> protoPackedFloats(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  return [for (var offset = 0; offset + 4 <= bytes.length; offset += 4) data.getFloat32(offset, Endian.little)];
}
