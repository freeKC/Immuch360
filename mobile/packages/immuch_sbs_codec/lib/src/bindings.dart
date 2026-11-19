// The C functions of rust/src/lib.rs, written by hand: a few functions do not need ffigen. The asset is the library
// hook/build.dart builds under the name src/bindings.dart; on a target it does not build for (the phones, the Quest,
// iOS, another processor) the first call throws an ArgumentError, which immuch_sbs_codec.dart turns into "not
// available".
@DefaultAsset('package:immuch_sbs_codec/src/bindings.dart')
library;

import 'dart:ffi';

@Native<Uint32 Function()>(symbol: 'isc_abi_version')
external int iscAbiVersion();

@Native<Pointer<Uint8> Function(Pointer<Size>)>(symbol: 'isc_licenses')
external Pointer<Uint8> iscLicenses(Pointer<Size> outLength);

@Native<
  Int32 Function(
    Pointer<Uint8>,
    Size,
    Pointer<Uint32>,
    Pointer<Uint32>,
    Pointer<Pointer<Uint8>>,
    Pointer<Size>,
    Pointer<Pointer<Uint8>>,
    Pointer<Size>,
    Pointer<Uint8>,
    Size,
  )
>(symbol: 'isc_decode')
external int iscDecode(
  Pointer<Uint8> jpeg,
  int jpegLength,
  Pointer<Uint32> outWidth,
  Pointer<Uint32> outHeight,
  Pointer<Pointer<Uint8>> outRgba,
  Pointer<Size> outRgbaLength,
  Pointer<Pointer<Uint8>> outIcc,
  Pointer<Size> outIccLength,
  Pointer<Uint8> error,
  int errorCapacity,
);

@Native<
  Int32 Function(
    Pointer<Uint8>,
    Size,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Pointer<Uint8>,
    Size,
    Pointer<Uint8>,
    Size,
    Pointer<Uint8>,
    Size,
    Pointer<Pointer<Uint8>>,
    Pointer<Size>,
    Pointer<Uint8>,
    Size,
  )
>(symbol: 'isc_encode')
external int iscEncode(
  Pointer<Uint8> rgba,
  int rgbaLength,
  int width,
  int height,
  int quality,
  int subsampling,
  Pointer<Uint8> exif,
  int exifLength,
  Pointer<Uint8> xmp,
  int xmpLength,
  Pointer<Uint8> icc,
  int iccLength,
  Pointer<Pointer<Uint8>> outJpeg,
  Pointer<Size> outJpegLength,
  Pointer<Uint8> error,
  int errorCapacity,
);

@Native<Void Function(Pointer<Uint8>, Size)>(symbol: 'isc_free')
external void iscFree(Pointer<Uint8> data, int length);

// The frame work of the 3D videos (rust/src/video.rs): each reads and writes the caller's memory only

@Native<
  Int32 Function(Pointer<Uint8>, Size, Uint32, Uint32, Pointer<Float>, Size, Uint32, Uint32, Pointer<Uint8>, Size)
>(symbol: 'isc_vda_input')
external int iscVdaInput(
  Pointer<Uint8> rgb,
  int rgbLength,
  int width,
  int height,
  Pointer<Float> out,
  int outLength,
  int outWidth,
  int outHeight,
  Pointer<Uint8> error,
  int errorCapacity,
);

@Native<Int32 Function(Pointer<Uint8>, Size, Uint32, Uint32, Pointer<Double>, Pointer<Uint8>, Size)>(
  symbol: 'isc_luma_hist64',
)
external int iscLumaHist64(
  Pointer<Uint8> rgb,
  int rgbLength,
  int width,
  int height,
  Pointer<Double> out,
  Pointer<Uint8> error,
  int errorCapacity,
);

@Native<
  Int32 Function(
    Pointer<Uint8>,
    Size,
    Uint32,
    Uint32,
    Pointer<Double>,
    Size,
    Uint32,
    Uint32,
    Double,
    Double,
    Double,
    Double,
    Uint32,
    Pointer<Uint8>,
    Size,
    Pointer<Uint64>,
    Pointer<Uint8>,
    Size,
  )
>(symbol: 'isc_relief_v1_eye')
external int iscReliefV1Eye(
  Pointer<Uint8> sbs,
  int sbsLength,
  int width,
  int height,
  Pointer<Double> depth,
  int depthLength,
  int depthWidth,
  int depthHeight,
  double p2,
  double p98,
  double parallax,
  double convergence,
  int threads,
  Pointer<Uint8> holes,
  int holesLength,
  Pointer<Uint64> outFilled,
  Pointer<Uint8> error,
  int errorCapacity,
);

@Native<Uint32 Function(Double, Uint32, Double)>(symbol: 'isc_edge_band')
external int iscEdgeBand(double parallax, int width, double convergence);

@Native<Int32 Function(Pointer<Uint8>, Size, Uint32, Uint32, Uint32, Pointer<Uint8>, Size)>(symbol: 'isc_edge_fade')
external int iscEdgeFade(
  Pointer<Uint8> sbs,
  int sbsLength,
  int width,
  int height,
  int band,
  Pointer<Uint8> error,
  int errorCapacity,
);

@Native<Int32 Function(Pointer<Uint8>, Size, Uint32, Uint32, Pointer<Uint8>, Size, Pointer<Uint8>, Size)>(
  symbol: 'isc_half_sbs',
)
external int iscHalfSbs(
  Pointer<Uint8> sbs,
  int sbsLength,
  int width,
  int height,
  Pointer<Uint8> out,
  int outLength,
  Pointer<Uint8> error,
  int errorCapacity,
);
