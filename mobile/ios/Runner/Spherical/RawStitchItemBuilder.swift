import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Metal

/// How the compositor gets its sources: from the tracks of the opened asset itself (one demuxer, the file read once),
/// or from an AVMutableComposition with one track per source (two files, or the fallback of direct)
enum RawStitchMode: String {
  case direct
  case composition
}

/// A player item that plays a raw recording stitched, and what the player needs to watch it
struct RawStitchItem {
  let item: AVPlayerItem
  let mode: RawStitchMode
  let instruction: RawStitchInstruction
  /// The tracks of the item's asset the compositor reads, in the order of the geometry's tracks
  let sourceTrackIDs: [CMPersistentTrackID]
  /// The formats of those tracks, for the decoder verdict
  let formats: [CMFormatDescription]
  let frameRate: Float
  let frameDuration: CMTime
  /// [0] in use, then the smaller ones the GPU valve may take
  let renderSizes: [CGSize]
}

/// The size of the stitched frames: a device tier from its GPU family and memory, and a pixel rate budget
enum RawStitchOutput {
  struct Tier {
    let maxWidth: Int
    let pixelRate: Double
    let name: String
  }

  /// high: A14 and later (GPU family apple7) with 6 GB; medium: A12 and later (apple5) with 4 GB; low: the others.
  /// A 5760x2880 BGRA frame is 66 MB and AVFoundation keeps several in flight, hence the memory.
  static var current: Tier {
    let low = Tier(maxWidth: 2880, pixelRate: 130e6, name: "low")
    guard let device = RawStitchRenderer.shared?.device else { return low }
    let memory = ProcessInfo.processInfo.physicalMemory
    if device.supportsFamily(.apple7) && memory >= 5_500_000_000 {
      return Tier(maxWidth: 5760, pixelRate: 520e6, name: "high")
    }
    if device.supportsFamily(.apple5) && memory >= 3_500_000_000 {
      return Tier(maxWidth: 3840, pixelRate: 260e6, name: "medium")
    }
    return low
  }

  static let ladder = [5760, 4800, 3840, 3200, 2880, 2560, 1920, 1440, 1024]

  /// The render sizes worth trying, largest first: the first one within the tier's pixel rate at [frameRate] is used,
  /// the next ones are the steps of the GPU valve. Widths are multiples of 32, heights half of them.
  static func sizes(naturalWidth: Int, frameRate: Float, tier: Tier) -> [CGSize] {
    let fps = frameRate.isFinite && frameRate >= 1 ? Double(min(frameRate, 120)) : 30
    let cap = max(256, min(tier.maxWidth, naturalWidth / 32 * 32))
    let widths = [cap] + ladder.filter { $0 < cap }
    let first =
      widths.firstIndex { Double($0) * Double($0 / 2) * fps <= tier.pixelRate } ?? (widths.count - 1)
    return widths[first...].map { CGSize(width: $0, height: $0 / 2) }
  }
}

/// Builds the player item of a stitched raw recording (docs 18-design-ios-two-track.md section 6): finds the track of
/// each source of the geometry, plays the opened asset directly when it can, else an AVMutableComposition, and gives
/// the item a video composition with RawStitchCompositor. Every await is an async property load.
@MainActor
enum RawStitchItemBuilder {
  /// A source track, with what was loaded of it
  private struct Source {
    let track: AVAssetTrack
    /// 0 for the main asset, 1 for the second file of a pair
    let file: Int
    let format: CMFormatDescription
    let size: CGSize
    /// False for a track the file marks disabled (tkhd flags), as the second lens of an Osmo 360 .OSV
    let enabled: Bool
  }

  /// [mainAsset] is the URL the player was given (or its transcoded stream), [secondAsset] the second file of a pair.
  /// [allowDirect] is false on the retry after a failure of the direct mode.
  static func build(
    geometry: RawStitchGeometry,
    mainAsset: AVURLAsset,
    secondAsset: AVURLAsset?,
    allowDirect: Bool
  ) async throws -> RawStitchItem {
    var sources: [Source] = []
    for (index, track) in geometry.tracks.enumerated() {
      let asset: AVURLAsset
      if track.file == 1 {
        guard let secondAsset else {
          throw RawStitchError(reason: "track \(index) is in the second file, which has no URL")
        }
        asset = secondAsset
      } else {
        asset = mainAsset
      }
      sources.append(try await Self.source(track, index: index, in: asset))
    }
    if sources.count == 2 && geometry.layout != .twoFiles && sources[0].track.trackID == sources[1].track.trackID {
      throw RawStitchError(reason: "both sources are track \(sources[0].track.trackID)")
    }

    let lead = sources[0].track
    let nominalRate = (try? await lead.load(.nominalFrameRate)) ?? 0
    let frameRate: Float = nominalRate.isFinite && nominalRate >= 1 ? nominalRate : 30
    var frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate.rounded())))
    // The shortest sample gives the exact period of a 29.97 or 59.94 fps recording; one short sample (a cut, the last
    // frame) would ask the compositor for more frames than the recording has
    if let minimum = try? await lead.load(.minFrameDuration), minimum.isNumeric, minimum.seconds > 0,
      abs(minimum.seconds * Double(frameRate) - 1) <= 0.2
    {
      frameDuration = minimum
    }

    var direct = allowDirect && geometry.layout != .twoFiles
    if direct && sources.contains(where: { !$0.enabled }) {
      // A disabled lens track may stay undecoded even once enabled on the player item, a composition track is always
      // enabled
      direct = false
    }
    if direct && sources.count == 2 {
      // Tracks of one alternate group play one at a time: the composition takes them apart
      let groups = (try? await mainAsset.load(.trackGroups)) ?? []
      let ids = Set(sources.map { $0.track.trackID })
      for group in groups where ids.isSubset(of: Set(group.trackIDs.map { $0.int32Value })) {
        direct = false
      }
    }

    let asset: AVAsset
    let duration: CMTime
    let sourceTrackIDs: [CMPersistentTrackID]
    if direct {
      asset = mainAsset
      duration = try await mainAsset.load(.duration)
      sourceTrackIDs = sources.map { $0.track.trackID }
    } else {
      let timeline = try await Self.composition(
        sources, layout: geometry.layout, mainAsset: mainAsset, secondAsset: secondAsset)
      asset = timeline.composition
      duration = timeline.duration
      sourceTrackIDs = timeline.trackIDs
    }
    guard duration.isNumeric, duration.seconds > 0 else {
      throw RawStitchError(reason: "the recording has no duration")
    }

    let instruction = RawStitchInstruction(
      timeRange: CMTimeRange(start: .zero, duration: duration), sourceTrackIDs: sourceTrackIDs, geometry: geometry)
    let tier = RawStitchOutput.current
    let renderSizes = RawStitchOutput.sizes(
      naturalWidth: Self.naturalWidth(geometry, sizes: sources.map { $0.size }), frameRate: frameRate, tier: tier)
    // Not checked with isValid(for:timeRange:validationDelegate:), which loads the tracks synchronously on the main
    // thread: AVFoundation fails the item of an invalid composition, and the player moves to its next source
    let stitching = Self.videoComposition(
      instruction: instruction, renderSize: renderSizes[0], frameDuration: frameDuration)
    let item = AVPlayerItem(asset: asset)
    item.videoComposition = stitching
    item.seekingWaitsForVideoCompositionRendering = true
    print("RawStitch: \(tier.name) tier, \(String(format: "%.2f", frameRate)) fps")
    return RawStitchItem(
      item: item,
      mode: direct ? .direct : .composition,
      instruction: instruction,
      sourceTrackIDs: sourceTrackIDs,
      formats: sources.map { $0.format },
      frameRate: frameRate,
      frameDuration: frameDuration,
      renderSizes: renderSizes
    )
  }

  /// The video composition of [instruction] at [renderSize]: the valve of the player makes another one, smaller, for
  /// the same item
  static func videoComposition(
    instruction: RawStitchInstruction, renderSize: CGSize, frameDuration: CMTime
  ) -> AVMutableVideoComposition {
    let composition = AVMutableVideoComposition()
    composition.customVideoCompositorClass = RawStitchCompositor.self
    composition.instructions = [instruction]
    composition.renderSize = renderSize
    composition.frameDuration = frameDuration
    if let first = instruction.sourceTrackIDs.first {
      composition.sourceTrackIDForFrameTiming = first
    }
    composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
    return composition
  }

  /// The track of [track] in [asset]: the video track whose track ID is the tkhd track_ID of the JSON, else the
  /// video track at its index (video tracks in track ID order, as the moov box lists them)
  private static func source(_ track: RawStitchGeometry.Track, index: Int, in asset: AVURLAsset) async throws
    -> Source
  {
    let videoTracks = try await asset.loadTracks(withMediaType: .video).sorted { $0.trackID < $1.trackID }
    var found: AVAssetTrack?
    if let trackId = track.trackId {
      found = videoTracks.first { $0.trackID == trackId }
    }
    if found == nil && track.videoTrack < videoTracks.count {
      found = videoTracks[track.videoTrack]
    }
    guard let found else {
      throw RawStitchError(
        reason: "source \(index) (track ID \(track.trackId.map { String($0) } ?? "none"), video track "
          + "\(track.videoTrack)) is not among the \(videoTracks.count) video tracks of file \(track.file)")
    }
    guard let format = try await found.load(.formatDescriptions).first else {
      throw RawStitchError(reason: "source \(index) has no format description")
    }
    let size = try await found.load(.naturalSize)
    let enabled = try await found.load(.isEnabled)
    return Source(track: found, file: track.file, format: format, size: size, enabled: enabled)
  }

  /// One composition track per source from time zero, and one audio track. The tracks of one file keep the timeline
  /// they share: each gives the span where all of them have media. Each file of a pair starts at the start of its
  /// track, for the length of the shorter one.
  private static func composition(
    _ sources: [Source], layout: RawStitchSpec.Layout, mainAsset: AVURLAsset, secondAsset: AVURLAsset?
  ) async throws -> (composition: AVMutableComposition, duration: CMTime, trackIDs: [CMPersistentTrackID]) {
    let composition = AVMutableComposition()
    var ranges: [CMTimeRange] = []
    for source in sources {
      ranges.append(try await source.track.load(.timeRange))
    }
    // The time of each source that the composition's time zero shows
    let starts: [CMTime]
    let duration: CMTime
    if layout == .twoFiles {
      starts = ranges.map { $0.start }
      duration = ranges.dropFirst().reduce(ranges[0].duration) { CMTimeMinimum($0, $1.duration) }
    } else {
      let start = ranges.dropFirst().reduce(ranges[0].start) { CMTimeMaximum($0, $1.start) }
      let end = ranges.dropFirst().reduce(ranges[0].end) { CMTimeMinimum($0, $1.end) }
      starts = ranges.map { _ in start }
      duration = CMTimeSubtract(end, start)
    }
    guard duration.isNumeric, duration.seconds > 0 else {
      throw RawStitchError(reason: "the sources have no common duration")
    }
    var trackIDs: [CMPersistentTrackID] = []
    for (source, start) in zip(sources, starts) {
      guard
        let track = composition.addMutableTrack(
          withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
      else {
        throw RawStitchError(reason: "no composition track")
      }
      try track.insertTimeRange(CMTimeRange(start: start, duration: duration), of: source.track, at: .zero)
      trackIDs.append(track.trackID)
    }

    // The sound of the first file that has one, on the timeline of the video of that file; a failure leaves the video
    // without sound
    var audio = await stereoAudioTrack(of: mainAsset)
    var audioFile = 0
    if audio == nil, let secondAsset {
      audio = await stereoAudioTrack(of: secondAsset)
      audioFile = 1
    }
    if let audio {
      do {
        let range = try await audio.load(.timeRange)
        let videoStart = zip(sources, starts).first { $0.0.file == audioFile }?.1 ?? starts[0]
        let from = CMTimeMaximum(videoStart, range.start)
        let to = CMTimeMinimum(CMTimeAdd(videoStart, duration), range.end)
        let length = CMTimeSubtract(to, from)
        if length.isNumeric && length.seconds > 0,
          let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        {
          try track.insertTimeRange(
            CMTimeRange(start: from, duration: length), of: audio, at: CMTimeSubtract(from, videoStart))
        }
      } catch {
        print("RawStitch: the stitched video plays without sound: \(error)")
      }
    }
    return (composition: composition, duration: duration, trackIDs: trackIDs)
  }

  /// The first audio track of [asset] with at most two channels, else its first one (a GoPro ambisonic track of four
  /// channels is never picked while a stereo one exists); nil without audio
  private static func stereoAudioTrack(of asset: AVAsset) async -> AVAssetTrack? {
    guard let tracks = try? await asset.loadTracks(withMediaType: .audio), let first = tracks.first else {
      return nil
    }
    for track in tracks {
      guard let formats = try? await track.load(.formatDescriptions), let format = formats.first,
        let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)
      else {
        continue
      }
      if description.pointee.mChannelsPerFrame <= 2 {
        return track
      }
    }
    return first
  }

  /// The width of the stitched frame worth drawing: a side by side frame as wide as it is, two fisheye squares of H
  /// side by side (2 H), four EAC faces of F around (4 F); never more than the frame width Flutter gives
  private static func naturalWidth(_ geometry: RawStitchGeometry, sizes: [CGSize]) -> Int {
    var width: Int
    if geometry.projection == .eac {
      width = 4 * Int(sizes[0].height)
    } else if sizes.count == 1 {
      width = Int(sizes[0].width)
    } else {
      width = 2 * Int(min(sizes[0].height, sizes[1].height))
    }
    if geometry.frameWidth > 0 {
      width = min(width, geometry.frameWidth)
    }
    return width
  }
}
