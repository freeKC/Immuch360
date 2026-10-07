// What the QuickTime file of a clip needs from the H.264 stream of a camera: the size of the picture and the profile,
// read from the sequence parameter set (ITU-T H.264 7.3.2.1.1), and the avcC record of the sample entry
// (ISO/IEC 14496-15 5.3.3.1) made of the first SPS and PPS.

import 'dart:typed_data';

/// What a sequence parameter set says
class H264Sps {
  const H264Sps({
    required this.profileIdc,
    required this.constraintFlags,
    required this.levelIdc,
    required this.width,
    required this.height,
    required this.chromaFormatIdc,
    required this.bitDepthLumaMinus8,
    required this.bitDepthChromaMinus8,
  });

  final int profileIdc;
  final int constraintFlags;
  final int levelIdc;

  /// The size of the picture once cropped
  final int width;
  final int height;
  final int chromaFormatIdc;
  final int bitDepthLumaMinus8;
  final int bitDepthChromaMinus8;

  /// The profiles whose avcC carries the chroma format and the bit depths
  bool get hasHighProfileFields => const {100, 110, 122, 144}.contains(profileIdc);
}

/// The SPS of the NAL unit [nal] (header byte included), null when it cannot be read
H264Sps? parseH264Sps(Uint8List nal) {
  if (nal.length < 4 || (nal[0] & 0x1f) != 7) {
    return null;
  }
  try {
    final bits = _BitReader(_unescape(Uint8List.sublistView(nal, 1)));
    final profile = bits.read(8);
    final constraints = bits.read(8);
    final level = bits.read(8);
    bits.ue(); // seq_parameter_set_id
    var chroma = 1;
    var lumaDepth = 0;
    var chromaDepth = 0;
    var separateColourPlane = false;
    if (const {100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135}.contains(profile)) {
      chroma = bits.ue();
      if (chroma == 3) {
        separateColourPlane = bits.read(1) == 1;
      }
      lumaDepth = bits.ue();
      chromaDepth = bits.ue();
      bits.read(1); // qpprime_y_zero_transform_bypass_flag
      if (bits.read(1) == 1) {
        // seq_scaling_matrix_present_flag: the lists are skipped
        for (var i = 0; i < (chroma == 3 ? 12 : 8); i++) {
          if (bits.read(1) == 1) {
            _skipScalingList(bits, i < 6 ? 16 : 64);
          }
        }
      }
    }
    bits.ue(); // log2_max_frame_num_minus4
    final pocType = bits.ue();
    if (pocType == 0) {
      bits.ue(); // log2_max_pic_order_cnt_lsb_minus4
    } else if (pocType == 1) {
      bits.read(1); // delta_pic_order_always_zero_flag
      bits.se(); // offset_for_non_ref_pic
      bits.se(); // offset_for_top_to_bottom_field
      final cycle = bits.ue();
      for (var i = 0; i < cycle; i++) {
        bits.se();
      }
    }
    bits.ue(); // max_num_ref_frames
    bits.read(1); // gaps_in_frame_num_value_allowed_flag
    final widthInMbs = bits.ue() + 1;
    final heightInMapUnits = bits.ue() + 1;
    final frameMbsOnly = bits.read(1) == 1;
    if (!frameMbsOnly) {
      bits.read(1); // mb_adaptive_frame_field_flag
    }
    bits.read(1); // direct_8x8_inference_flag
    var cropLeft = 0;
    var cropRight = 0;
    var cropTop = 0;
    var cropBottom = 0;
    if (bits.read(1) == 1) {
      cropLeft = bits.ue();
      cropRight = bits.ue();
      cropTop = bits.ue();
      cropBottom = bits.ue();
    }
    final arrayType = separateColourPlane ? 0 : chroma;
    final cropUnitX = arrayType == 0 ? 1 : (arrayType == 3 ? 1 : 2);
    final cropUnitY = (arrayType == 0 ? 1 : (arrayType == 1 ? 2 : 1)) * (frameMbsOnly ? 1 : 2);
    final width = widthInMbs * 16 - cropUnitX * (cropLeft + cropRight);
    final height = (frameMbsOnly ? 1 : 2) * heightInMapUnits * 16 - cropUnitY * (cropTop + cropBottom);
    if (width <= 0 || height <= 0) {
      return null;
    }
    return H264Sps(
      profileIdc: profile,
      constraintFlags: constraints,
      levelIdc: level,
      width: width,
      height: height,
      chromaFormatIdc: chroma,
      bitDepthLumaMinus8: lumaDepth,
      bitDepthChromaMinus8: chromaDepth,
    );
  } on RangeError {
    return null;
  }
}

void _skipScalingList(_BitReader bits, int size) {
  var last = 8;
  var next = 8;
  for (var j = 0; j < size; j++) {
    if (next != 0) {
      next = (last + bits.se() + 256) % 256;
    }
    last = next == 0 ? last : next;
  }
}

/// The avcC record of [sps] and [pps] (NAL units with their header bytes), lengths of 4 bytes
Uint8List h264AvcC(Uint8List sps, Uint8List pps, H264Sps parsed) {
  final out = BytesBuilder(copy: false)
    ..add([1, sps[1], sps[2], sps[3], 0xff, 0xe1, sps.length >> 8, sps.length & 0xff])
    ..add(sps)
    ..add([1, pps.length >> 8, pps.length & 0xff])
    ..add(pps);
  if (parsed.hasHighProfileFields) {
    out.add([
      0xfc | (parsed.chromaFormatIdc & 0x3),
      0xf8 | (parsed.bitDepthLumaMinus8 & 0x7),
      0xf8 | (parsed.bitDepthChromaMinus8 & 0x7),
      0,
    ]);
  }
  return out.takeBytes();
}

/// The RBSP of a NAL unit payload: the emulation prevention bytes (00 00 03) taken out
Uint8List _unescape(Uint8List data) {
  final out = BytesBuilder(copy: false);
  var zeros = 0;
  for (final byte in data) {
    if (zeros >= 2 && byte == 3) {
      zeros = 0;
      continue;
    }
    out.addByte(byte);
    zeros = byte == 0 ? zeros + 1 : 0;
  }
  return out.takeBytes();
}

class _BitReader {
  _BitReader(this._data);

  final Uint8List _data;
  int _position = 0;

  int read(int count) {
    var value = 0;
    for (var i = 0; i < count; i++) {
      final byte = _data[_position >> 3];
      value = (value << 1) | ((byte >> (7 - (_position & 7))) & 1);
      _position++;
    }
    return value;
  }

  /// Unsigned exp-Golomb
  int ue() {
    var zeros = 0;
    while (read(1) == 0) {
      zeros++;
      if (zeros > 31) {
        throw RangeError('An exp-Golomb code too long');
      }
    }
    return (1 << zeros) - 1 + read(zeros);
  }

  /// Signed exp-Golomb
  int se() {
    final value = ue();
    return value.isOdd ? (value + 1) ~/ 2 : -(value ~/ 2);
  }
}
