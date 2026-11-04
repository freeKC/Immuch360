/// Immuch360: what the native player measures of its link while it loads a video (Android: PlayerLink.kt), sent twice
/// a second while it waits or loads. [waiting]: it waits for media before it plays (Media3's buffering), at the start
/// or after a stall ([rebuffering]); [aheadMs] of media loaded ahead of the position; [bytesPerSecond] the link
/// brought over the last seconds while the player wanted more, against the [neededBytesPerSecond] the video consumes
/// (both null until known); [sinceProgressMs] since the last 16 KiB arrived (null before the first read); [targetMs]
/// of media the player waits for before it plays (0 when it does not wait), [minimumHeldMs] since the least it plays
/// with is there (null while it is not); [loading] whether it wants more; [receivedBytes] since the video loaded.
class NativeVideoLink {
  const NativeVideoLink({
    required this.waiting,
    this.rebuffering = false,
    this.aheadMs = 0,
    this.bytesPerSecond,
    this.neededBytesPerSecond,
    this.sinceProgressMs,
    this.targetMs = 0,
    this.minimumHeldMs,
    this.loading = false,
    this.receivedBytes = 0,
    this.network = false,
    this.framesPerSecond,
    this.neededFramesPerSecond,
  });

  final bool waiting;
  final bool rebuffering;
  final int aheadMs;
  final int? bytesPerSecond;
  final int? neededBytesPerSecond;
  final int? sinceProgressMs;
  final int targetMs;
  final int? minimumHeldMs;
  final bool loading;
  final int receivedBytes;

  /// Whether the player read the video over the network (a server, the media bridge of a share)
  final bool network;

  /// The link is a decoder rather than the network (the AV2 videos of the computers, decoded by the processor): the
  /// pictures it decodes per second, null until measured, against those the video needs at the speed it plays
  final double? framesPerSecond;
  final double? neededFramesPerSecond;

  /// Whether the link is a decoder, see [framesPerSecond]
  bool get isDecoder => neededFramesPerSecond != null;

  /// Media seconds the link brings per second: [bytesPerSecond] over [neededBytesPerSecond] (or the frames of a
  /// decoder over those the video needs), null when either is unknown
  double? get ratio {
    if (isDecoder) {
      final fps = framesPerSecond;
      final needed = neededFramesPerSecond!;
      return fps == null || needed <= 0 ? null : fps / needed;
    }
    final rate = bytesPerSecond;
    final need = neededBytesPerSecond;
    if (rate == null || need == null || need <= 0) {
      return null;
    }
    return rate / need;
  }

  /// The link as the native player sends it, see PlayerLink.snapshot; a negative number is an unknown value
  factory NativeVideoLink.fromMap(Map<Object?, Object?> map) {
    int? known(String key) {
      final value = map[key];
      return value is num && value >= 0 ? value.toInt() : null;
    }

    return NativeVideoLink(
      waiting: map['waiting'] == true,
      rebuffering: map['rebuffering'] == true,
      aheadMs: known('aheadMs') ?? 0,
      bytesPerSecond: known('rate'),
      neededBytesPerSecond: known('need'),
      sinceProgressMs: known('sinceProgressMs'),
      targetMs: known('targetMs') ?? 0,
      minimumHeldMs: known('minimumHeldMs'),
      loading: map['loading'] == true,
      receivedBytes: known('receivedBytes') ?? 0,
      network: map['network'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NativeVideoLink &&
      other.waiting == waiting &&
      other.rebuffering == rebuffering &&
      other.aheadMs == aheadMs &&
      other.bytesPerSecond == bytesPerSecond &&
      other.neededBytesPerSecond == neededBytesPerSecond &&
      other.sinceProgressMs == sinceProgressMs &&
      other.targetMs == targetMs &&
      other.minimumHeldMs == minimumHeldMs &&
      other.loading == loading &&
      other.receivedBytes == receivedBytes &&
      other.network == network &&
      other.framesPerSecond == framesPerSecond &&
      other.neededFramesPerSecond == neededFramesPerSecond;

  @override
  int get hashCode => Object.hash(
        waiting,
        rebuffering,
        aheadMs,
        bytesPerSecond,
        neededBytesPerSecond,
        sinceProgressMs,
        targetMs,
        minimumHeldMs,
        loading,
        receivedBytes,
        network,
        framesPerSecond,
        neededFramesPerSecond,
      );

  @override
  String toString() => 'NativeVideoLink(waiting: $waiting${rebuffering ? ' after a stall' : ''}, ahead $aheadMs ms, '
      '$bytesPerSecond of $neededBytesPerSecond B/s, ${sinceProgressMs ?? '-'} ms since progress, '
      'target $targetMs ms, loading: $loading, $receivedBytes B'
      '${isDecoder ? ', decoding $framesPerSecond of $neededFramesPerSecond fps' : ''})';
}
