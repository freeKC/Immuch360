import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Answers Flutter's questions about the video decoders of the device, from the table of [VideoDecoderSupport].
/// Pigeon calls it on the main thread and the answers come at once, on that thread: the table only asks
/// VideoToolbox whether a codec has a hardware decoder, once per codec for the life of the app.
class VideoDecoderApiImpl: VideoDecoderApi {
  func canDecode(
    codec: String,
    codecs: String?,
    width: Int64,
    height: Int64,
    frameRate: Double,
    completion: @escaping (Result<DecodeVerdict, Error>) -> Void
  ) {
    // VideoToolbox publishes no frame rate limit: the sizes of the table are low enough for 60 frames per second,
    // so the frame rate does not change the verdict
    completion(.success(VideoDecoderSupport.verdict(codec: codec, codecs: codecs, width: width, height: height)))
  }

  func listDecoders(completion: @escaping (Result<[DecoderInfo], Error>) -> Void) {
    let decoders = VideoDecoderSupport.decoders.map { decoder in
      DecoderInfo(
        name: decoder.name,
        codec: decoder.codec.mimeType,
        hardware: decoder.hardware,
        maxWidth: decoder.maxWidth,
        maxHeight: decoder.maxHeight,
        // VideoToolbox does not tell
        maxFrameRate: 0
      )
    }
    completion(.success(decoders))
  }
}

/// The codecs of the decoder table, whatever name a question from Flutter or a video file gives them
enum VideoDecoderCodec: CaseIterable {
  case h264
  case hevc
  case av1
  case vp9

  /// Every spelling of a codec the table knows, lowercased: MIME types without their "video/" (as Android names
  /// them), sample entries of MP4 files, and the codec names the server reports. Dolby Vision over HEVC decodes
  /// with the HEVC decoder.
  private static let names: [String: VideoDecoderCodec] = [
    "avc": .h264,
    "avc1": .h264,
    "avc3": .h264,
    "h264": .h264,
    "h.264": .h264,
    "hevc": .hevc,
    "hvc1": .hevc,
    "hev1": .hevc,
    "h265": .hevc,
    "h.265": .hevc,
    "dvh1": .hevc,
    "dvhe": .hevc,
    "av1": .av1,
    "av01": .av1,
    "vp9": .vp9,
    "vp09": .vp9,
    "x-vnd.on2.vp9": .vp9,
  ]

  /// What is left around a name: spaces, and the quotes of a codecs="..." parameter
  private static let trimmed = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))

  /// The name for the logs and the decoders page
  var displayName: String {
    switch self {
    case .h264:
      return "H.264"
    case .hevc:
      return "HEVC"
    case .av1:
      return "AV1"
    case .vp9:
      return "VP9"
    }
  }

  /// The MIME type, as Android names the codec: Flutter shows both platforms the same way
  var mimeType: String {
    switch self {
    case .h264:
      return "video/avc"
    case .hevc:
      return "video/hevc"
    case .av1:
      return "video/av01"
    case .vp9:
      return "video/x-vnd.on2.vp9"
    }
  }

  /// [name] as Flutter gives it: a MIME type ("video/avc"), a sample entry ("hvc1"), an RFC 6381 string
  /// ("hvc1.2.4.L153.B0") or a codec name from the server ("h264", "hevc")
  init?(name: String) {
    var key = name.trimmingCharacters(in: Self.trimmed).lowercased()
    if key.hasPrefix("video/") {
      key.removeFirst("video/".count)
    }
    if let codec = Self.names[key] {
      self = codec
      return
    }
    // An RFC 6381 string: the sample entry comes before the first dot, the profile and the level after it
    guard let entry = key.split(separator: ".").first, let codec = Self.names[String(entry)] else {
      return nil
    }
    self = codec
  }

  /// The first codec the table knows in an RFC 6381 list, such as "avc1.640033, mp4a.40.2"
  init?(codecs: String) {
    for entry in codecs.split(separator: ",") {
      if let codec = VideoDecoderCodec(name: String(entry)) {
        self = codec
        return
      }
    }
    return nil
  }

  /// The codec of a video format description, from its four character code
  init?(codecType: CMVideoCodecType) {
    self.init(name: VideoDecoderSupport.fourCharacterCode(codecType))
  }
}

/// The best decoder of a codec on this device, and the largest frame it takes
struct VideoDecoderLimit {
  let codec: VideoDecoderCodec
  let hardware: Bool
  /// The largest landscape frame: a portrait one is measured long side against [maxWidth], short side against
  /// [maxHeight], as on Android
  let maxWidth: Int64
  let maxHeight: Int64

  /// The name on the decoders page. iOS has no public list of its decoders and their names, VideoToolbox is
  /// what decodes every codec here.
  var name: String {
    "VideoToolbox \(codec.displayName)"
  }

  func fits(width: Int64, height: Int64) -> Bool {
    max(width, height) <= maxWidth && min(width, height) <= maxHeight
  }
}

/// What this device decodes, for Flutter (see [VideoDecoderApiImpl]) and for the native players, which play the
/// server's transcoded stream instead of an original above it.
///
/// iOS does not tell the largest frame of its decoders the way Android's MediaCodecList does: VideoToolbox only says
/// whether a codec has a hardware decoder. The sizes come from a conservative table instead. H.264 goes up to level
/// 5.2 (4096 x 2304), HEVC and AV1 up to 8192 x 4320 where the hardware decodes them, and a software decoder (the
/// simulator, a device without the hardware one) is held to 1080p. AV1 has no software decoder on iOS, and AVPlayer
/// does not play VP9.
enum VideoDecoderSupport {
  // Asked once each: the answer does not change while the app runs
  private static let hardwareH264 = VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)
  private static let hardwareHEVC = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
  private static let hardwareAV1: Bool = {
    // The first Apple chips with an AV1 decoder (A17 Pro, M3) came with iOS 17, earlier systems never report one
    guard #available(iOS 17.0, *) else { return false }
    return VTIsHardwareDecodeSupported(VideoDecoderSupport.av1CodecType)
  }()

  // 'av01', spelled out: kCMVideoCodecType_AV1 is missing from older SDKs
  private static let av1CodecType: CMVideoCodecType = 0x6176_3031

  /// The best decoder of each codec this device decodes, for the decoders page
  static var decoders: [VideoDecoderLimit] {
    VideoDecoderCodec.allCases.compactMap { VideoDecoderSupport.decoder(for: $0) }
  }

  /// The best decoder of [codec] on this device, nil when it has none
  static func decoder(for codec: VideoDecoderCodec) -> VideoDecoderLimit? {
    switch codec {
    case .h264:
      // Level 5.2, the largest H.264 frame the decoders of iPhones and iPads are known to keep up with
      return hardwareH264
        ? VideoDecoderLimit(codec: codec, hardware: true, maxWidth: 4096, maxHeight: 2304)
        : VideoDecoderLimit(codec: codec, hardware: false, maxWidth: 1920, maxHeight: 1080)
    case .hevc:
      return hardwareHEVC
        ? VideoDecoderLimit(codec: codec, hardware: true, maxWidth: 8192, maxHeight: 4320)
        : VideoDecoderLimit(codec: codec, hardware: false, maxWidth: 1920, maxHeight: 1080)
    case .av1:
      return hardwareAV1 ? VideoDecoderLimit(codec: codec, hardware: true, maxWidth: 8192, maxHeight: 4320) : nil
    case .vp9:
      return nil
    }
  }

  /// The answer to Flutter: [name] is the codec as Flutter knows it, [codecs] the RFC 6381 string when known, the
  /// first of the two the table knows decides
  static func verdict(codec name: String, codecs: String?, width: Int64, height: Int64) -> DecodeVerdict {
    if let codec = VideoDecoderCodec(name: name) ?? codecs.flatMap({ VideoDecoderCodec(codecs: $0) }) {
      return verdict(codec, width: width, height: height)
    }
    return verdictOutsideTable(name: name, codecs: codecs)
  }

  /// Whether the best decoder of [codec] takes a [width] x [height] frame. An unknown size (0) never counts as too
  /// large, as on Android.
  static func verdict(_ codec: VideoDecoderCodec, width: Int64, height: Int64) -> DecodeVerdict {
    guard let best = decoder(for: codec) else {
      let reason =
        codec == .vp9
        ? "AVPlayer does not play VP9 on iOS"
        : "no \(codec.displayName) decoder on this device"
      return DecodeVerdict(supported: false, hardware: false, maxWidth: 0, maxHeight: 0, reason: reason)
    }
    let kind = best.hardware ? "hardware" : "software"
    let limit = "\(best.maxWidth)x\(best.maxHeight)"
    guard width > 0, height > 0 else {
      return DecodeVerdict(
        supported: true,
        hardware: best.hardware,
        maxWidth: best.maxWidth,
        maxHeight: best.maxHeight,
        reason: "\(codec.displayName) of unknown size, \(kind) decoder up to \(limit)"
      )
    }
    let fits = best.fits(width: width, height: height)
    let relation = fits ? "within" : "above"
    return DecodeVerdict(
      supported: fits,
      hardware: best.hardware,
      maxWidth: best.maxWidth,
      maxHeight: best.maxHeight,
      reason: "\(codec.displayName) \(width)x\(height) \(relation) the \(kind) decoder (up to \(limit))"
    )
  }

  /// A codec outside the table (ProRes, MPEG-4 Part 2...): AVFoundation tells whether it plays such a stream at
  /// all, without a word on the size
  private static func verdictOutsideTable(name: String, codecs: String?) -> DecodeVerdict {
    let description = codecs.map { "\(name) (\($0))" } ?? name
    var mimeType = name
    if let codecs, !codecs.isEmpty {
      mimeType = "video/mp4; codecs=\"\(codecs)\""
    } else if !name.contains("/") {
      mimeType = "video/mp4; codecs=\"\(name)\""
    }
    let playable = !name.isEmpty && AVURLAsset.isPlayableExtendedMIMEType(mimeType)
    let reason =
      playable
      ? "\(description) is outside the decoder table, AVFoundation plays it (size not checked)"
      : "unknown codec \(description)"
    return DecodeVerdict(supported: playable, hardware: false, maxWidth: 0, maxHeight: 0, reason: reason)
  }

  /// The verdict for a video track, from its format description: the codec type and the coded size. A codec
  /// outside the table counts as supported: AVPlayer tries it, and a failure plays the fallback stream.
  static func verdict(for format: CMFormatDescription) -> DecodeVerdict {
    let codecType = CMFormatDescriptionGetMediaSubType(format)
    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
    let width = Int64(dimensions.width)
    let height = Int64(dimensions.height)
    guard let codec = VideoDecoderCodec(codecType: codecType) else {
      return DecodeVerdict(
        supported: true,
        hardware: false,
        maxWidth: 0,
        maxHeight: 0,
        reason: "\(fourCharacterCode(codecType)) \(width)x\(height) is outside the decoder table"
      )
    }
    return verdict(codec, width: width, height: height)
  }

  /// The verdict for the first video track of [asset], once its format description is loaded. Nil without a video
  /// track or when the file cannot be read, a failure the player reports on its own.
  @MainActor
  static func verdict(of asset: AVAsset) async -> DecodeVerdict? {
    guard let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first,
      let formats = try? await track.load(.formatDescriptions), let format = formats.first
    else {
      return nil
    }
    return verdict(for: format)
  }

  /// The format description of the first video track of [asset], nil without a video track or when the file
  /// cannot be read
  @MainActor
  static func videoFormat(of asset: AVAsset) async -> CMFormatDescription? {
    guard let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first,
      let formats = try? await track.load(.formatDescriptions)
    else {
      return nil
    }
    return formats.first
  }

  /// The translated "switched to the transcoded stream" message of the app with its placeholders filled from
  /// [format]: "{codec}" becomes the codec name (H.264, HEVC, AV1, or the four character code), "{width}" and
  /// "{height}" the coded size. Without a format (the original failed before its tracks were known), the
  /// parenthesis that holds them is dropped so that no placeholder shows.
  static func switchedMessage(_ template: String, format: CMFormatDescription?) -> String {
    guard let format else {
      return template.replacingOccurrences(
        of: #"\s*\([^()]*\{codec\}[^()]*\)"#, with: "", options: .regularExpression)
    }
    let codecType = CMFormatDescriptionGetMediaSubType(format)
    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
    let codecName = VideoDecoderCodec(codecType: codecType)?.displayName ?? fourCharacterCode(codecType)
    return template
      .replacingOccurrences(of: "{codec}", with: codecName)
      .replacingOccurrences(of: "{width}", with: String(dimensions.width))
      .replacingOccurrences(of: "{height}", with: String(dimensions.height))
  }

  /// "avc1" for kCMVideoCodecType_H264: the four bytes of the code, most significant first
  static func fourCharacterCode(_ code: FourCharCode) -> String {
    let bytes: [UInt8] = [
      UInt8(truncatingIfNeeded: code >> 24),
      UInt8(truncatingIfNeeded: code >> 16),
      UInt8(truncatingIfNeeded: code >> 8),
      UInt8(truncatingIfNeeded: code),
    ]
    return String(decoding: bytes, as: UTF8.self)
  }
}
