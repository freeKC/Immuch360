import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
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
    bitDepth: Int64,
    transferCharacteristics: Int64,
    instances: Int64,
    completion: @escaping (Result<DecodeVerdict, Error>) -> Void
  ) {
    // VideoToolbox publishes no frame rate limit: the sizes of the table are low enough for 60 frames per second,
    // so the frame rate only counts for several streams, against the pixel rate the native player uses
    let verdict = VideoDecoderSupport.verdict(
      codec: codec, codecs: codecs, width: width, height: height, bitDepth: bitDepth,
      transfer: transferCharacteristics)
    let known = VideoDecoderCodec(name: codec) ?? codecs.flatMap { VideoDecoderCodec(codecs: $0) }
    completion(
      .success(
        VideoDecoderSupport.verdict(
          verdict, codec: known, instances: instances, width: width, height: height, frameRate: frameRate)))
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
        maxFrameRate: 0,
        profiles: VideoDecoderSupport.profiles(of: decoder)
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

  /// A9 and A9X devices (iOS 15 and iPadOS 16 still run there) decode 8 bit HEVC in hardware, 10 bit in software
  private static let a9Models: Set<String> = [
    "iPhone8,1", "iPhone8,2", "iPhone8,4", "iPad6,3", "iPad6,4", "iPad6,7", "iPad6,8", "iPad6,11", "iPad6,12",
  ]
  private static let isA9: Bool = {
    var info = utsname()
    uname(&info)
    let machine = withUnsafeBytes(of: &info.machine) { bytes in
      String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    return VideoDecoderSupport.a9Models.contains(machine)
  }()

  /// The profiles the decoders page shows for [decoder]: what the decoders of Apple chips take, VideoToolbox does
  /// not list them
  static func profiles(of decoder: VideoDecoderLimit) -> [String] {
    switch decoder.codec {
    case .h264:
      return ["Baseline", "Main", "High"]
    case .hevc:
      return decoder.hardware && isA9 ? ["Main"] : ["Main", "Main 10"]
    case .av1:
      return ["Main 8", "Main 10"]
    case .vp9:
      return []
    }
  }

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
  /// first of the two the table knows decides. [bitDepth] is the bits per luma sample and [transfer] the ITU-T H.273
  /// transfer (16 PQ, 18 HLG), each 0 when unknown; the profile of [codecs] tells the bit depth too.
  static func verdict(
    codec name: String, codecs: String?, width: Int64, height: Int64, bitDepth: Int64 = 0, transfer: Int64 = 0
  ) -> DecodeVerdict {
    if let codec = VideoDecoderCodec(name: name) ?? codecs.flatMap({ VideoDecoderCodec(codecs: $0) }) {
      let depth = max(bitDepth, codecs.flatMap { codecsBitDepth(codec, codecs: $0) } ?? 0)
      if codec == .h264 {
        var profile = codecs.flatMap { highAvcProfile(codecs: $0) }
        if profile == nil && depth >= 10 {
          profile = "High 10"
        }
        if let profile {
          return DecodeVerdict(
            supported: false, hardware: false, maxWidth: 0, maxHeight: 0,
            reason: "H.264 10 bit is not decoded on iOS", profile: profile, missingProfile: profile)
        }
      }
      return verdict(codec, width: width, height: height, bitDepth: depth, transfer: transfer)
    }
    return verdictOutsideTable(name: name, codecs: codecs)
  }

  /// The name of an H.264 profile of more than 8 bit 4:2:0 in [codecs] ("avc1.6E0033" is High 10), which no decoder
  /// of iOS takes; nil for the others
  private static func highAvcProfile(codecs: String) -> String? {
    let parts = codecs.split(separator: ",").first?.trimmingCharacters(in: .whitespaces).split(separator: ".") ?? []
    guard parts.count > 1, parts[1].count >= 2 else { return nil }
    switch parts[1].prefix(2).uppercased() {
    case "6E":
      return "High 10"
    case "7A":
      return "High 4:2:2"
    case "F4":
      return "High 4:4:4"
    default:
      return nil
    }
  }

  /// The bit depth the profile of [codecs] implies: 10 for HEVC Main 10 ("hvc1.2.4.L153") and H.264 High 10
  /// ("avc1.6E0033"), nil when it does not tell
  private static func codecsBitDepth(_ codec: VideoDecoderCodec, codecs: String) -> Int64? {
    let parts = codecs.split(separator: ",").first?.trimmingCharacters(in: .whitespaces).split(separator: ".") ?? []
    guard parts.count > 1 else { return nil }
    switch codec {
    case .hevc:
      // The profile space comes as a letter before the profile number: "A2" is profile 2 too
      let profile = parts[1].drop(while: { "ABCabc".contains($0) })
      return profile == "2" ? 10 : nil
    case .h264:
      return highAvcProfile(codecs: codecs) == "High 10" ? 10 : nil
    case .av1, .vp9:
      return nil
    }
  }

  /// Whether the best decoder of [codec] takes a [width] x [height] frame of [bitDepth] bits per luma sample (0 when
  /// unknown). An unknown size (0) never counts as too large, as on Android. 10 bit HEVC runs in software on A9 chips,
  /// held to 1080p like any software decoder; [transfer] (16 PQ) only names the profile, the verdict stays the same.
  static func verdict(
    _ codec: VideoDecoderCodec, width: Int64, height: Int64, bitDepth: Int64 = 0, transfer: Int64 = 0
  ) -> DecodeVerdict {
    let tenBitHevc = codec == .hevc && bitDepth >= 10
    let profile: String? = tenBitHevc ? (transfer == 16 ? "Main 10 HDR10" : "Main 10") : nil
    var candidate = decoder(for: codec)
    if tenBitHevc, let hardware = candidate, hardware.hardware, isA9 {
      candidate = VideoDecoderLimit(codec: codec, hardware: false, maxWidth: 1920, maxHeight: 1080)
    }
    guard let best = candidate else {
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
        reason: "\(codec.displayName) of unknown size, \(kind) decoder up to \(limit)",
        profile: profile
      )
    }
    let fits = best.fits(width: width, height: height)
    let relation = fits ? "within" : "above"
    return DecodeVerdict(
      supported: fits,
      hardware: best.hardware,
      maxWidth: best.maxWidth,
      maxHeight: best.maxHeight,
      reason: "\(codec.displayName) \(width)x\(height) \(relation) the \(kind) decoder (up to \(limit))",
      profile: profile
    )
  }

  /// The verdict for [instances] streams of [codec] at [width] x [height] decoded at once (the two lenses of a raw
  /// 360° video) at [frameRate] frames per second (0 when unknown, read as 30), from [single], the verdict for one:
  /// VideoToolbox tells no instance count, so the streams share the [pixelRate] of the codec. The rule of
  /// [verdict(forLensFormats:frameRate:)], so that Flutter warns before the player opens where the player itself
  /// would. One stream, an unknown size or a codec outside the table keeps [single].
  static func verdict(
    _ single: DecodeVerdict, codec: VideoDecoderCodec?, instances: Int64, width: Int64, height: Int64,
    frameRate: Double
  ) -> DecodeVerdict {
    guard instances > 1, single.supported, width > 0, height > 0, let codec else {
      return single
    }
    return pixelRateVerdict(
      single, codec: codec, streams: Int(instances), width: width, height: height,
      pixels: Double(instances) * Double(width) * Double(height), frameRate: frameRate)
  }

  /// [answer] once [pixels] per frame, of [streams] streams of [codec] (the first one [width] x [height]), are
  /// measured at [frameRate] (0 when unknown, read as 30) against the [pixelRate] of the codec
  private static func pixelRateVerdict(
    _ answer: DecodeVerdict, codec: VideoDecoderCodec, streams: Int, width: Int64, height: Int64, pixels: Double,
    frameRate: Double
  ) -> DecodeVerdict {
    let fps = frameRate.isFinite && frameRate >= 1 ? frameRate : 30
    let rate = pixels * fps
    let budget = pixelRate(codec, hardware: answer.hardware)
    var result = answer
    result.supported = rate <= budget
    let relation = result.supported ? "within" : "above"
    result.reason =
      "\(streams) x \(codec.displayName) \(width)x\(height) at \(Int(fps.rounded())) fps: "
      + "\(Int((rate / 1_000_000).rounded())) Mpx/s \(relation) the \(Int((budget / 1_000_000).rounded())) Mpx/s of "
      + "this device"
    return result
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

  /// The verdict for a video track, from its format description: the codec type, the coded size, the bit depth and
  /// the transfer. A codec outside the table counts as supported: AVPlayer tries it, and a failure plays the fallback
  /// stream.
  static func verdict(for format: CMFormatDescription) -> DecodeVerdict {
    let codecType = CMFormatDescriptionGetMediaSubType(format)
    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
    let width = Int64(dimensions.width)
    let height = Int64(dimensions.height)
    let bits =
      (CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent)
        as? NSNumber)?.int64Value ?? 0
    let function =
      CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
    // As ITU-T H.273 numbers them, like the probe of the Flutter side
    let transfer: Int64
    if function == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) {
      transfer = 18
    } else if function == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) {
      transfer = 16
    } else if function == (kCVImageBufferTransferFunction_ITU_R_709_2 as String) {
      transfer = 1
    } else {
      transfer = 0
    }
    guard let codec = VideoDecoderCodec(codecType: codecType) else {
      return DecodeVerdict(
        supported: true,
        hardware: false,
        maxWidth: 0,
        maxHeight: 0,
        reason: "\(fourCharacterCode(codecType)) \(width)x\(height) is outside the decoder table"
      )
    }
    if codec == .h264 && bits >= 10 {
      return DecodeVerdict(
        supported: false, hardware: false, maxWidth: 0, maxHeight: 0,
        reason: "H.264 10 bit is not decoded on iOS", profile: "High 10", missingProfile: "High 10")
    }
    return verdict(codec, width: width, height: height, bitDepth: bits, transfer: transfer)
  }

  /// The GPU family of the device, which tells the generation of its video decoder: 7 from the A14, 5 from the A12,
  /// 0 before or without Metal
  private static let gpuFamily: Int = {
    guard let device = MTLCreateSystemDefaultDevice() else { return 0 }
    if device.supportsFamily(.apple7) {
      return 7
    }
    if device.supportsFamily(.apple5) {
      return 5
    }
    return 0
  }()

  /// The pixels per second the decoder of [codec] keeps up with, all streams together: a table like the one of the
  /// sizes, not a measurement, that the device tests of the raw 360° player adjust
  static func pixelRate(_ codec: VideoDecoderCodec, hardware: Bool) -> Double {
    guard hardware else {
      return 1920 * 1080 * 30
    }
    switch codec {
    case .h264:
      return 4096 * 2304 * 60
    case .hevc, .av1:
      if gpuFamily >= 7 {
        return 8192 * 4320 * 30
      }
      if gpuFamily >= 5 {
        return 4096 * 2160 * 60
      }
      return 3840 * 2160 * 30
    case .vp9:
      return 0
    }
  }

  /// The verdict for the lens tracks of a raw 360° video decoded at once, at [frameRate] frames per second (0 when
  /// unknown, read as 30): each one must pass [verdict(for:)], the first refusal is the answer; then their pixels
  /// per second together must stay within [pixelRate] of the codec of the first one.
  static func verdict(forLensFormats formats: [CMFormatDescription], frameRate: Float) -> DecodeVerdict {
    var single: DecodeVerdict?
    for format in formats {
      let answer = verdict(for: format)
      guard answer.supported else {
        return answer
      }
      if single == nil {
        single = answer
      }
    }
    guard let first = formats.first, let answer = single,
      let codec = VideoDecoderCodec(codecType: CMFormatDescriptionGetMediaSubType(first))
    else {
      return single
        ?? DecodeVerdict(supported: true, hardware: false, maxWidth: 0, maxHeight: 0, reason: "no lens track")
    }
    var pixels: Double = 0
    for format in formats {
      let dimensions = CMVideoFormatDescriptionGetDimensions(format)
      pixels += Double(dimensions.width) * Double(dimensions.height)
    }
    let dimensions = CMVideoFormatDescriptionGetDimensions(first)
    return pixelRateVerdict(
      answer, codec: codec, streams: formats.count, width: Int64(dimensions.width), height: Int64(dimensions.height),
      pixels: pixels, frameRate: Double(frameRate))
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
