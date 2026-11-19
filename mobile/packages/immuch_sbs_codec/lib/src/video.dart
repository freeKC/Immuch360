part of '../immuch_sbs_codec.dart';

/// The frame work of the 3D videos in Rust (rust/src/video.rs, .github/desktop/ai/make_relief_video_golden.py): the
/// input of Video Depth Anything, the histogram of the cut detector, the right eye of relief-v1 with percentiles given
/// from outside, the soft floating window and half side by side. One per job: its native buffers grow to the largest
/// call and are reused, then given back by [dispose]. Every call copies its inputs in and its results out, so the
/// caller's lists stay plain Dart lists. Synchronous, for the isolate of the job.
final class NativeVideoFrames {
  NativeVideoFrames() {
    _ensureAvailable();
  }

  final _error = malloc<Uint8>(_errorCapacity);
  final _filled = malloc<Uint64>();
  final _bins = malloc<Double>(64);
  final _bytes = _Buffer<Uint8>(malloc);
  final _bytes2 = _Buffer<Uint8>(malloc);
  final _holes = _Buffer<Uint8>(malloc);
  final _floats = _Buffer<Float>(malloc);
  final _doubles = _Buffer<Double>(malloc);
  var _disposed = false;

  void _alive() {
    if (_disposed) {
      throw StateError('These NativeVideoFrames were given back');
    }
  }

  /// [rgb] (a frame of [width] x [height] RGB bytes) as the model's input of [outWidth] x [outHeight], channels first,
  /// into [out]
  void vdaInput(Uint8List rgb, int width, int height, Float32List out, int outWidth, int outHeight) {
    _alive();
    final frame = _bytes.copyIn(rgb);
    final input = _floats.grow(out.length);
    _check(
      iscVdaInput(frame, rgb.length, width, height, input, out.length, outWidth, outHeight, _error, _errorCapacity),
      _error,
    );
    out.setAll(0, input.asTypedList(out.length));
  }

  /// The 64 bins of the luma of [rgb] at 320 x 180
  Float64List lumaHistogram(Uint8List rgb, int width, int height) {
    _alive();
    final frame = _bytes.copyIn(rgb);
    _check(iscLumaHist64(frame, rgb.length, width, height, _bins, _error, _errorCapacity), _error);
    return Float64List.fromList(_bins.asTypedList(64));
  }

  /// Writes the right eye into the right half of [sbs] (2 [width] x [height] RGB bytes, the frame in its left half)
  /// from [depth] ([depthWidth] x [depthHeight]) normalised between [p2] and [p98]; [holes] (width x height) gets 1
  /// for each filled pixel. Returns how many were filled.
  int reliefEye(
    Uint8List sbs,
    int width,
    int height,
    Float64List depth,
    int depthWidth,
    int depthHeight, {
    required double p2,
    required double p98,
    required double parallax,
    required double convergence,
    int threads = 2,
    Uint8List? holes,
  }) {
    _alive();
    final frame = _bytes.copyIn(sbs);
    final map = _doubles.grow(depth.length);
    map.asTypedList(depth.length).setAll(0, depth);
    final mask = holes == null ? nullptr : _holes.grow(holes.length);
    _check(
      iscReliefV1Eye(
        frame,
        sbs.length,
        width,
        height,
        map,
        depth.length,
        depthWidth,
        depthHeight,
        p2,
        p98,
        parallax,
        convergence,
        threads,
        mask,
        holes?.length ?? 0,
        _filled,
        _error,
        _errorCapacity,
      ),
      _error,
    );
    sbs.setAll(0, frame.asTypedList(sbs.length));
    if (holes != null) {
      holes.setAll(0, mask.asTypedList(holes.length));
    }
    return _filled.value;
  }

  /// Fades [band] columns at both edges of each eye of [sbs] to black
  void edgeFade(Uint8List sbs, int width, int height, int band) {
    _alive();
    final frame = _bytes.copyIn(sbs);
    _check(iscEdgeFade(frame, sbs.length, width, height, band, _error, _errorCapacity), _error);
    sbs.setAll(0, frame.asTypedList(sbs.length));
  }

  /// Both eyes of [sbs] squeezed to half their width into [out] ([width] x [height] RGB bytes)
  void halfSbs(Uint8List sbs, int width, int height, Uint8List out) {
    _alive();
    final frame = _bytes.copyIn(sbs);
    final half = _bytes2.grow(out.length);
    _check(iscHalfSbs(frame, sbs.length, width, height, half, out.length, _error, _errorCapacity), _error);
    out.setAll(0, half.asTypedList(out.length));
  }

  /// Gives the native buffers back; nothing works afterwards
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    malloc
      ..free(_error)
      ..free(_filled)
      ..free(_bins);
    _bytes.free();
    _bytes2.free();
    _holes.free();
    _floats.free();
    _doubles.free();
  }
}

/// The band of the soft floating window of an eye [width] wide: ceil(parallax * width * max(c, 1 - c)) + 2, at most
/// width / 2
int nativeEdgeBand(double parallax, int width, double convergence) {
  _ensureAvailable();
  return iscEdgeBand(parallax, width, convergence);
}

/// A native buffer that grows to the largest length asked and keeps it
final class _Buffer<T extends SizedNativeType> {
  _Buffer(this._allocator);

  final Allocator _allocator;
  Pointer<T> _pointer = nullptr;
  int _length = 0;

  Pointer<T> grow(int length) {
    if (length > _length) {
      free();
      try {
        _pointer = _allocator.allocate<T>(length * _sizeOf());
      } on ArgumentError catch (error) {
        throw NativeCodecException(NativeCodecStatus.outOfMemory, 'no memory for $length values: ${error.message}');
      }
      _length = length;
    }
    return _pointer;
  }

  int _sizeOf() => switch (T) {
    const (Uint8) => 1,
    const (Float) => 4,
    const (Double) => 8,
    _ => throw UnsupportedError('$T'),
  };

  void free() {
    if (_pointer != nullptr) {
      _allocator.free(_pointer);
      _pointer = nullptr;
      _length = 0;
    }
  }
}

extension on _Buffer<Uint8> {
  Pointer<Uint8> copyIn(Uint8List bytes) {
    final pointer = grow(bytes.length);
    pointer.asTypedList(bytes.length).setAll(0, bytes);
    return pointer;
  }
}
