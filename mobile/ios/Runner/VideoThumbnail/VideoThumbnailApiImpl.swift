import AVFoundation
import Flutter
import UIKit

/// A frame of a video as a JPEG, for the network share browser. AVFoundation reads the video over HTTP from the media
/// bridge of the app, by ranges: only the index of the file and the samples around the frame. The browser asks for
/// two frames at a time at most.
///
/// A frame not taken within `timeout` fails then, and the reads of the video stop: the browser goes on with the next
/// video, still two at a time.
class VideoThumbnailApiImpl: VideoThumbnailApi {
  private static let jpegQuality: CGFloat = 0.8

  /// Longest a frame takes, in seconds
  private static let timeout: TimeInterval = 45

  func thumbnailForUrl(
    url: String,
    headers: [String: String],
    timeMs: Int64,
    maxWidth: Int64,
    completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
  ) {
    guard let videoUrl = URL(string: url) else {
      completion(.failure(PigeonError(code: "INVALID_URL", message: "Cannot read the video URL \(url)", details: nil)))
      return
    }
    let options: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
    let asset = AVURLAsset(url: videoUrl, options: options)
    let generator = AVAssetImageGenerator(asset: asset)
    // Portrait videos upright, as they play
    generator.appliesPreferredTrackTransform = true
    // The frame fits in the box keeping its aspect ratio: a box four times as tall as it is wide keeps a portrait
    // video maxWidth pixels wide too
    let width = CGFloat(max(maxWidth, 1))
    generator.maximumSize = CGSize(width: width, height: width * 4)
    // The sync frame nearest the time asked for decodes without the frames before it
    let tolerance = CMTime(seconds: 2, preferredTimescale: 600)
    generator.requestedTimeToleranceBefore = tolerance
    generator.requestedTimeToleranceAfter = tolerance

    let reply = ReplyOnce(completion)
    let deadline = DispatchWorkItem {
      let failure = PigeonError(code: "TIMEOUT", message: "No frame after \(Int(Self.timeout)) s", details: nil)
      if reply.send(.failure(failure)) {
        generator.cancelAllCGImageGeneration()
        asset.cancelLoading()
      }
    }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.timeout, execute: deadline)

    Task {
      do {
        let duration = try await asset.load(.duration)
        var time = CMTime(value: timeMs, timescale: 1000)
        // A video shorter than the time asked for: its middle frame
        if duration.isNumeric && duration.seconds > 0 && CMTimeCompare(duration, time) <= 0 {
          time = CMTimeMultiplyByRatio(duration, multiplier: 1, divisor: 2)
        }
        let image = try await Self.frame(of: generator, at: time)
        guard let data = UIImage(cgImage: image).jpegData(compressionQuality: Self.jpegQuality) else {
          throw PigeonError(code: "THUMBNAIL_FAILED", message: "The frame could not be encoded", details: nil)
        }
        reply.send(.success(FlutterStandardTypedData(bytes: data)))
      } catch let error as PigeonError {
        reply.send(.failure(error))
      } catch {
        reply.send(.failure(PigeonError(code: "THUMBNAIL_FAILED", message: error.localizedDescription, details: nil)))
      }
      deadline.cancel()
    }
  }

  /// The frame of the video at [time]. generateCGImagesAsynchronously rather than the async image(at:), which needs
  /// iOS 16: the app runs on iOS 15 too.
  private static func frame(of generator: AVAssetImageGenerator, at time: CMTime) async throws -> CGImage {
    try await withCheckedThrowingContinuation { continuation in
      generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, error in
        if result == .succeeded, let image = image {
          continuation.resume(returning: image)
          return
        }
        let message = result == .cancelled ? "Cancelled" : "No frame in the video"
        continuation.resume(throwing: error ?? PigeonError(code: "THUMBNAIL_FAILED", message: message, details: nil))
      }
    }
  }
}

/// Hands the result over to Flutter once: the frame or the timeout, whichever comes first
private final class ReplyOnce {
  private let lock = NSLock()
  private var completion: ((Result<FlutterStandardTypedData, Error>) -> Void)?

  init(_ completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void) {
    self.completion = completion
  }

  /// Whether this was the reply, none having been sent before
  @discardableResult
  func send(_ result: Result<FlutterStandardTypedData, Error>) -> Bool {
    lock.lock()
    let completion = self.completion
    self.completion = nil
    lock.unlock()
    guard let completion = completion else {
      return false
    }
    completion(result)
    return true
  }
}
