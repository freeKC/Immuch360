// The tensors that go in and out of ONNX Runtime (design-final 2026-10-27, section 10.1 point 3, lot C1). Phase 1 ran
// one float32 image in and one float32 map out; the models of phases 2 and 3 take and give more: MoGe-2 ViT-S an image
// and a number of tokens as an int64 scalar (shape []), four float32 maps out; LaMa an image and a mask; the MI-GAN
// pipeline bytes in and bytes out. A tensor here is its shape and its values in the order of the tensor (the last
// dimension varies fastest), of one of the three element types the app gives and reads.

import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/ort/ort_api_bindings.dart' as ort;

/// The element types of the tensors the app gives to ONNX Runtime and reads from it
enum OrtElementType {
  float32(ort.ONNXTensorElementDataType.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, 4),
  uint8(ort.ONNXTensorElementDataType.ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8, 1),
  int64(ort.ONNXTensorElementDataType.ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, 8);

  const OrtElementType(this.onnx, this.bytes);

  /// Its ONNXTensorElementDataType
  final int onnx;

  /// The bytes of one value
  final int bytes;

  /// The type of [onnx] (an ONNXTensorElementDataType), null for one the app does not read
  static OrtElementType? of(int onnx) {
    for (final type in values) {
      if (type.onnx == onnx) {
        return type;
      }
    }
    return null;
  }
}

/// The number of values a tensor of [shape] holds: 1 for a scalar (shape []). Throws [ArgumentError] for a negative
/// dimension.
int elementCountOf(List<int> shape) {
  var count = 1;
  for (final dimension in shape) {
    if (dimension < 0) {
      throw ArgumentError('A tensor of shape $shape: a dimension cannot be negative');
    }
    count *= dimension;
  }
  return count;
}

/// An input or an output of a model: its name, its element type (ONNXTensorElementDataType) and its shape, -1 for a
/// dimension the model leaves free
class OrtTensorSpec {
  const OrtTensorSpec(this.name, this.elementType, this.shape);

  final String name;
  final int elementType;
  final List<int> shape;

  bool get isFloat => elementType == ort.ONNXTensorElementDataType.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT;

  /// Its element type, null for one the app does not read
  OrtElementType? get type => OrtElementType.of(elementType);

  @override
  String toString() => '$name $shape';
}

/// A tensor: its [shape], its element [type] and its values in the order of the tensor. Throws [ArgumentError] when
/// the values are not as many as the shape says.
class OrtTensor {
  /// A float32 tensor, the kind phase 1 gives and reads
  OrtTensor(List<int> shape, Float32List values) : this._(shape, OrtElementType.float32, values, values.length);

  /// A tensor of bytes (the image and the mask of the MI-GAN pipeline)
  OrtTensor.uint8(List<int> shape, Uint8List values) : this._(shape, OrtElementType.uint8, values, values.length);

  /// A tensor of 64 bit integers
  OrtTensor.int64(List<int> shape, Int64List values) : this._(shape, OrtElementType.int64, values, values.length);

  /// One 64 bit integer of shape [] (the num_tokens of MoGe)
  OrtTensor.int64Scalar(int value) : this.int64(const [], Int64List.fromList([value]));

  OrtTensor._(List<int> shape, this.type, this.data, int length) : shape = List.unmodifiable(shape) {
    final count = elementCountOf(shape);
    if (count != length) {
      throw ArgumentError('A tensor of shape $shape holds $count values, not $length');
    }
  }

  final List<int> shape;
  final OrtElementType type;

  /// The values: a Float32List, a Uint8List or an Int64List, as [type] says
  final TypedData data;

  int get elementCount => data.lengthInBytes ~/ type.bytes;

  /// The values of a float32 tensor. Throws [StateError] for another type.
  Float32List get values => switch (data) {
    final Float32List values => values,
    _ => throw StateError('A tensor of ${type.name} has no float32 values'),
  };

  /// The values of a uint8 tensor. Throws [StateError] for another type.
  Uint8List get bytes => switch (data) {
    final Uint8List bytes => bytes,
    _ => throw StateError('A tensor of ${type.name} has no uint8 values'),
  };

  /// The values of an int64 tensor. Throws [StateError] for another type.
  Int64List get integers => switch (data) {
    final Int64List integers => integers,
    _ => throw StateError('A tensor of ${type.name} has no int64 values'),
  };

  /// The bytes of the values, as ONNX Runtime holds them (little endian on every computer the app runs on)
  Uint8List get rawBytes => data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

  /// A tensor of [type] and [shape] whose values are a copy of [raw]
  factory OrtTensor.copyOf(OrtElementType type, List<int> shape, Uint8List raw) {
    final copy = Uint8List.fromList(raw);
    return switch (type) {
      OrtElementType.float32 => OrtTensor(shape, copy.buffer.asFloat32List()),
      OrtElementType.uint8 => OrtTensor.uint8(shape, copy),
      OrtElementType.int64 => OrtTensor.int64(shape, copy.buffer.asInt64List()),
    };
  }

  @override
  String toString() => 'OrtTensor(${type.name} $shape)';
}
