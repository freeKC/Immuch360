import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// The one instruction of a stitched raw video: its time range, the tracks of its sources in the order of the
/// geometry's tracks (one for a side by side frame), and the geometry
final class RawStitchInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
  let timeRange: CMTimeRange
  let enablePostProcessing: Bool = false
  // Every composition time gives another frame: AVFoundation must not reuse an output
  let containsTweening: Bool = true
  let requiredSourceTrackIDs: [NSValue]?
  let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
  let sourceTrackIDs: [CMPersistentTrackID]
  let geometry: RawStitchGeometry

  init(timeRange: CMTimeRange, sourceTrackIDs: [CMPersistentTrackID], geometry: RawStitchGeometry) {
    self.timeRange = timeRange
    self.sourceTrackIDs = sourceTrackIDs
    self.geometry = geometry
    let unique = Array(Set(sourceTrackIDs)).sorted()
    requiredSourceTrackIDs = unique.map { NSNumber(value: $0) }
    super.init()
  }
}

/// What the player reads once a second: frames rendered, the mean GPU time of the last 60, and how many requests in a
/// row lacked a source frame
final class RawStitchStatistics: @unchecked Sendable {
  struct Snapshot {
    let frames: Int
    let meanGpuMs: Double
    let missingSourceStreak: Int
  }

  private static let window = 60

  private let lock = NSLock()
  private var gpuMs: [Double] = []
  private var frames = 0
  private var missingSourceStreak = 0

  func record(gpuMs value: Double?, missingSource: Bool) {
    lock.lock()
    defer { lock.unlock() }
    frames += 1
    missingSourceStreak = missingSource ? missingSourceStreak + 1 : 0
    if let value, value.isFinite, value >= 0 {
      gpuMs.append(value)
      if gpuMs.count > Self.window {
        gpuMs.removeFirst(gpuMs.count - Self.window)
      }
    }
  }

  func snapshot() -> Snapshot {
    lock.lock()
    defer { lock.unlock() }
    let mean = gpuMs.isEmpty ? 0 : gpuMs.reduce(0, +) / Double(gpuMs.count)
    return Snapshot(frames: frames, meanGpuMs: mean, missingSourceStreak: missingSourceStreak)
  }

  /// After a change of the render size: the times of the larger frames tell nothing more
  func reset() {
    lock.lock()
    defer { lock.unlock() }
    gpuMs.removeAll()
    frames = 0
    missingSourceStreak = 0
  }
}

// The type of the pixel buffer attributes of AVVideoCompositing: Sendable values from the iOS 18 SDK. The SDK decides,
// not the compiler; the compiler version stands for it because Xcode 16 brought both, and Codemagic builds with the
// latest Xcode (xcode: latest in codemagic.yaml, Xcode 26 and its SDK). A Swift 6 compiler with an older SDK would
// need the other branch.
#if compiler(>=6.0)
  typealias RawStitchBufferAttributes = [String: any Sendable]
#else
  typealias RawStitchBufferAttributes = [String: Any]
#endif

/// Stitches each frame of a raw two lens recording into an equirectangular frame (see RawStitchRenderer).
/// AVFoundation creates it from the video composition of RawStitchItemBuilder and calls it on its own threads; the
/// requests are encoded one after the other on renderQueue, the GPU work completes asynchronously.
///
/// The sources come as 8 bit biplanar 4:2:0 buffers: AVFoundation converts 10 bit and HDR sources (Osmo 360 Main 10,
/// X6 HLG) to them and to the BT.709 colour of the composition before startRequest, as this compositor declares no
/// HDR nor wide colour support.
final class RawStitchCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
  let statistics = RawStitchStatistics()
  private let renderQueue = DispatchQueue(label: "app.immuch360.rawstitch")
  private let cancelLock = NSLock()
  private var cancelling = false
  // Used on renderQueue only
  private var textureCache: CVMetalTextureCache?

  var sourcePixelBufferAttributes: RawStitchBufferAttributes? {
    [
      kCVPixelBufferPixelFormatTypeKey as String: [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      ],
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
    ]
  }

  var requiredPixelBufferAttributesForRenderContext: RawStitchBufferAttributes {
    [
      kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
    ]
  }

  // Each request reads its own render context: nothing to keep here
  func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

  func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
    let request = asyncVideoCompositionRequest
    renderQueue.async { [self] in
      if isCancelling() {
        request.finishCancelledRequest()
        return
      }
      render(request)
    }
  }

  // The requests queued so far finish as cancelled; the flag drops once they are through the queue
  func cancelAllPendingVideoCompositionRequests() {
    setCancelling(true)
    renderQueue.async { [self] in
      setCancelling(false)
    }
  }

  private func isCancelling() -> Bool {
    cancelLock.lock()
    defer { cancelLock.unlock() }
    return cancelling
  }

  private func setCancelling(_ value: Bool) {
    cancelLock.lock()
    defer { cancelLock.unlock() }
    cancelling = value
  }

  /// On renderQueue. An error finishes the request: AVFoundation then fails the item, and the player moves to its
  /// next source.
  private func render(_ request: AVAsynchronousVideoCompositionRequest) {
    guard let renderer = RawStitchRenderer.shared else {
      request.finish(with: RawStitchError(reason: "Metal is not available"))
      return
    }
    guard let instruction = request.videoCompositionInstruction as? RawStitchInstruction else {
      request.finish(with: RawStitchError(reason: "the instruction is not a raw stitch instruction"))
      return
    }
    guard let output = request.renderContext.newPixelBuffer() else {
      request.finish(with: RawStitchError(reason: "no output pixel buffer"))
      return
    }
    if textureCache == nil {
      textureCache = renderer.makeTextureCache()
    }
    guard let cache = textureCache else {
      request.finish(with: RawStitchError(reason: "no Metal texture cache"))
      return
    }
    // Lets go of the textures of the frames already drawn
    CVMetalTextureCacheFlush(cache, 0)
    // Nil where a track has no frame at this time: the end of a shorter track, a lens track not decoded yet
    let frames = instruction.sourceTrackIDs.map { request.sourceFrame(byTrackID: $0) }
    let missingSource = frames.contains { $0 == nil }
    let recorder = statistics
    renderer.render(instruction: instruction, frames: frames, output: output, cache: cache) { gpuMs, error in
      recorder.record(gpuMs: gpuMs, missingSource: missingSource)
      if let error {
        request.finish(with: error)
      } else {
        request.finish(withComposedVideoFrame: output)
      }
    }
  }
}
