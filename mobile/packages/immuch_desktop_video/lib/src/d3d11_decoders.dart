// What the hardware video decoder of a GPU of this computer takes, read by the plugin's DLL from Direct3D 11 (Windows
// only, windows/immuch_desktop_video.cpp): the GPU, its decoder profiles with the output formats and the frame sizes
// each takes, and the frame rate Direct3D 12 tells where the driver answers it. The DLL is called in a background
// isolate: a probe makes Direct3D devices and asks the driver about each size, tens to hundreds of milliseconds.

import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';

/// A GPU as DXGI lists it. [integrated] when it shares the system memory (an Intel UHD, for one), as
/// Direct3D tells it (unified memory architecture).
class GpuAdapter {
  const GpuAdapter({
    required this.index,
    required this.name,
    required this.vendorId,
    required this.deviceId,
    required this.driver,
    required this.dedicatedMB,
    required this.sharedMB,
    required this.integrated,
    required this.software,
  });

  factory GpuAdapter.fromJson(Map<String, Object?> json) => GpuAdapter(
    index: (json['index'] as num?)?.toInt() ?? -1,
    name: json['name'] as String? ?? '',
    vendorId: (json['vendorId'] as num?)?.toInt() ?? 0,
    deviceId: (json['deviceId'] as num?)?.toInt() ?? 0,
    driver: json['driver'] as String? ?? '',
    dedicatedMB: (json['dedicatedMB'] as num?)?.toInt() ?? 0,
    sharedMB: (json['sharedMB'] as num?)?.toInt() ?? 0,
    integrated: json['integrated'] == true,
    software: json['software'] == true,
  );

  /// Its place in DXGI's list, -1 for the default adapter (the GPU the app renders and decodes on)
  final int index;
  final String name;
  final int vendorId;
  final int deviceId;

  /// The driver version ("32.0.16.1656"), empty when Windows does not tell it
  final String driver;
  final int dedicatedMB;
  final int sharedMB;
  final bool integrated;
  final bool software;

  /// The GPU and its driver, without the name: what a measure of the decoder holds for (a driver update may change
  /// what the decoder keeps up with)
  String get key =>
      '${vendorId.toRadixString(16).padLeft(4, '0')}:${deviceId.toRadixString(16).padLeft(4, '0')}:$driver';

  @override
  String toString() => 'GpuAdapter($name, $key, ${integrated ? 'integrated' : 'dedicated'})';
}

/// A frame size checked against a decoder profile: [accepted] when the driver has a decoder configuration for it
typedef CheckedSize = ({int width, int height, bool accepted});

/// A decoder profile of the GPU: its [guid] (see d3d11ProfileInfo), the output formats it writes ("NV12", "P010"),
/// the format its sizes were checked with ([sizeFormat]), the [sizes] checked, and the frame rate Direct3D 12 gives
/// at the largest of them ([maxFrameRate], null when not asked or when the driver does not tell)
class D3D11DecoderProfile {
  const D3D11DecoderProfile({
    required this.guid,
    required this.formats,
    this.sizeFormat,
    this.sizes = const [],
    this.maxFrameRate,
    this.rateUntold = false,
  });

  factory D3D11DecoderProfile.fromJson(Map<String, Object?> json) {
    final rate = json['rate'];
    final rateMap = rate is Map<String, Object?> ? rate : null;
    final untold = rateMap?['untold'] == true;
    final max = (rateMap?['max'] as num?)?.toInt() ?? 0;
    return D3D11DecoderProfile(
      guid: json['guid'] as String? ?? '',
      formats: [for (final format in json['formats'] as List? ?? const []) '$format'],
      sizeFormat: json['sizeFormat'] as String?,
      sizes: [
        for (final entry in json['sizes'] as List? ?? const [])
          if (entry is List && entry.length == 3)
            (width: (entry[0] as num).toInt(), height: (entry[1] as num).toInt(), accepted: entry[2] == 1),
      ],
      maxFrameRate: rateMap == null || untold || max <= 0 ? null : max.toDouble(),
      rateUntold: untold,
    );
  }

  final String guid;
  final List<String> formats;
  final String? sizeFormat;
  final List<CheckedSize> sizes;
  final double? maxFrameRate;

  /// The driver accepted a frame rate no decoder reaches: it does not check rates
  final bool rateUntold;

  /// Whether the driver takes [width] x [height] (a coded size, see [codedSize]), null when that size was not checked
  bool? accepts(int width, int height) {
    for (final size in sizes) {
      if (size.width == width && size.height == height) {
        return size.accepted;
      }
    }
    return null;
  }

  /// The largest size accepted, by area; null when none was
  CheckedSize? get largest {
    CheckedSize? best;
    for (final size in sizes) {
      if (size.accepted && (best == null || size.width * size.height > best.width * best.height)) {
        best = size;
      }
    }
    return best;
  }

  @override
  String toString() => 'D3D11DecoderProfile($guid, $formats, largest $largest)';
}

/// What a probe found on a GPU: the [adapter], its decoder [profiles], whether Direct3D 12 answered for the rates
/// ([d3d12]), and [error] when the GPU has no video decoder the probe could open
class D3D11DecoderProbe {
  const D3D11DecoderProbe({this.adapter, this.profiles = const [], this.d3d12 = false, this.error});

  factory D3D11DecoderProbe.fromJson(Map<String, Object?> json) {
    final adapter = json['adapter'];
    return D3D11DecoderProbe(
      adapter: adapter is Map<String, Object?> ? GpuAdapter.fromJson(adapter) : null,
      profiles: [
        for (final profile in json['profiles'] as List? ?? const [])
          if (profile is Map<String, Object?>) D3D11DecoderProfile.fromJson(profile),
      ],
      d3d12: json['d3d12'] == true,
      error: json['error'] as String?,
    );
  }

  final GpuAdapter? adapter;
  final List<D3D11DecoderProfile> profiles;
  final bool d3d12;
  final String? error;

  D3D11DecoderProfile? profile(String guid) {
    for (final profile in profiles) {
      if (profile.guid == guid) {
        return profile;
      }
    }
    return null;
  }

  @override
  String toString() => 'D3D11DecoderProbe($adapter, ${profiles.length} profiles${error == null ? '' : ', $error'})';
}

/// The size FFmpeg asks a Direct3D decoder about for a frame of [width] x [height] of [codec] (a MIME type): its coded
/// size (d3d11va_get_decoder_configuration in dxva2.c), whole macroblocks of 16 lines for H.264, MPEG-2 and VC-1
/// (1920 x 1080 is coded 1920 x 1088), blocks of 8 for HEVC, VP9 and AV1
({int width, int height}) codedSize(String codec, int width, int height) {
  final block = switch (codec) {
    'video/hevc' || 'video/av01' || 'video/x-vnd.on2.vp9' => 8,
    _ => 16,
  };
  int up(int value) => (value + block - 1) ~/ block * block;
  return (width: up(width), height: up(height));
}

/// The frame sizes the decoders page is given, by area: the common sizes of cameras and 360° videos, up to 16K
const ladderSizes = [
  (1920, 1088),
  (3840, 2160),
  (4096, 2304),
  (4096, 4096),
  (5760, 2880),
  (7680, 3840),
  (7680, 4320),
  (8192, 4320),
  (8192, 8192),
  (16384, 8192),
  (16384, 16384),
];

typedef _ProbeNative =
    Int32 Function(
      Int32 adapter,
      Pointer<Utf8> filter,
      Pointer<Int32> sizes,
      Int32 sizeCount,
      Int32 checkRates,
      Pointer<Utf8> out,
      Int32 capacity,
    );
typedef _Probe =
    int Function(
      int adapter,
      Pointer<Utf8> filter,
      Pointer<Int32> sizes,
      int sizeCount,
      int checkRates,
      Pointer<Utf8> out,
      int capacity,
    );
typedef _CountNative = Int32 Function();
typedef _Count = int Function();

/// The calls into the plugin's DLL
abstract final class D3D11Decoders {
  /// The DLL Flutter bundles next to the executable
  static const libraryName = 'immuch_desktop_video.dll';

  /// The decoders of the adapter at [adapter] in DXGI's list, or for -1 of the default adapter (the GPU the app's
  /// video renders and decodes on). Only the profiles of [profiles] (GUIDs) get [sizes] checked, all when null;
  /// [rates] asks Direct3D 12 for the frame rate at the largest size of each. [library] is the path of the DLL, its
  /// name next to the executable by default (the tests give the build folder). Runs in a background isolate.
  static Future<D3D11DecoderProbe> probe({
    int adapter = -1,
    Iterable<String>? profiles,
    Iterable<(int, int)> sizes = const [],
    bool rates = false,
    String library = libraryName,
  }) {
    final filter = profiles?.join(',') ?? '';
    final pairs = [
      for (final (width, height) in sizes) ...[width, height],
    ];
    return Isolate.run(() => probeNow(adapter: adapter, filter: filter, sizes: pairs, rates: rates, library: library));
  }

  /// [probe] on the calling thread; [sizes] as a flat list of widths and heights
  static D3D11DecoderProbe probeNow({
    required int adapter,
    required String filter,
    required List<int> sizes,
    required bool rates,
    required String library,
  }) {
    final call = DynamicLibrary.open(library).lookupFunction<_ProbeNative, _Probe>('immuch_dv_probe');
    final filterText = filter.toNativeUtf8();
    final sizeArray = calloc<Int32>(math.max(1, sizes.length));
    var capacity = 64 * 1024;
    try {
      for (var i = 0; i < sizes.length; i++) {
        sizeArray[i] = sizes[i];
      }
      while (true) {
        final out = calloc<Uint8>(capacity);
        try {
          final length = call(adapter, filterText, sizeArray, sizes.length ~/ 2, rates ? 1 : 0, out.cast(), capacity);
          if (length < capacity) {
            final json = jsonDecode(utf8.decode(out.asTypedList(length)));
            return D3D11DecoderProbe.fromJson(json as Map<String, Object?>);
          }
          capacity = length + 1;
        } finally {
          calloc.free(out);
        }
      }
    } finally {
      calloc.free(filterText);
      calloc.free(sizeArray);
    }
  }

  /// The adapters DXGI lists (GPUs, the software renderer, virtual display adapters)
  static int adapterCount({String library = libraryName}) =>
      DynamicLibrary.open(library).lookupFunction<_CountNative, _Count>('immuch_dv_adapter_count')();
}
