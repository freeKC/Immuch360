// Makes the photo and the video the macOS job of .github/workflows/immuch360-desktop.yml opens with the app, in a
// folder of their own: nothing to download, nothing under a licence, made on the runner with the frameworks of macOS.
//
//   swift make_test_media.swift <folder> [seconds]
//
//   <folder>/test-photo.jpg  1600x900, colour bars and the time it was made
//   <folder>/test-video.mp4  H.264 1280x720 at 30 frames per second, [seconds] long (default 12): bars that move four
//                            pixels a frame and the time of the frame, so that two captures of a playing video differ
import AVFoundation
import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: make_test_media.swift <folder> [seconds]")
    exit(2)
}
let folder = URL(fileURLWithPath: arguments[1], isDirectory: true)
let seconds = arguments.count > 2 ? max(1, Int(arguments[2]) ?? 12) : 12
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

let bars: [CGColor] = [
    CGColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1), CGColor(red: 0.75, green: 0.75, blue: 0, alpha: 1),
    CGColor(red: 0, green: 0.75, blue: 0.75, alpha: 1), CGColor(red: 0, green: 0.75, blue: 0, alpha: 1),
    CGColor(red: 0.75, green: 0, blue: 0.75, alpha: 1), CGColor(red: 0.75, green: 0, blue: 0, alpha: 1),
    CGColor(red: 0, green: 0, blue: 0.75, alpha: 1),
]

/// Colour bars shifted by [offset] pixels, and [label] in large white text in the middle
func draw(_ context: CGContext, width: Int, height: Int, offset: Int, label: String) {
    let barWidth = CGFloat(width) / CGFloat(bars.count)
    for index in -1...bars.count {
        let color = bars[((index % bars.count) + bars.count) % bars.count]
        context.setFillColor(color)
        let x = CGFloat(index) * barWidth + CGFloat(offset % Int(barWidth))
        context.fill(CGRect(x: x, y: 0, width: barWidth + 1, height: CGFloat(height)))
    }
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: CGFloat(height) / 8, weight: .bold),
        .foregroundColor: NSColor.white,
        .backgroundColor: NSColor.black,
    ]
    let text = NSAttributedString(string: " \(label) ", attributes: attributes)
    let size = text.size()
    text.draw(at: NSPoint(x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2))
    NSGraphicsContext.restoreGraphicsState()
}

// The photo
let photoWidth = 1600
let photoHeight = 900
guard
    let photoContext = CGContext(
        data: nil, width: photoWidth, height: photoHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else {
    print("no bitmap context")
    exit(1)
}
let stamp = ISO8601DateFormatter().string(from: Date())
draw(photoContext, width: photoWidth, height: photoHeight, offset: 0, label: "Immuch360 \(stamp.prefix(10))")
let photoBitmap = NSBitmapImageRep(cgImage: photoContext.makeImage()!)
guard let jpeg = photoBitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
    print("no JPEG")
    exit(1)
}
try jpeg.write(to: folder.appendingPathComponent("test-photo.jpg"))

// The video
let videoURL = folder.appendingPathComponent("test-video.mp4")
try? FileManager.default.removeItem(at: videoURL)
let width = 1280
let height = 720
let fps: Int32 = 30
let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000],
    ])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
writer.add(input)
guard writer.startWriting() else {
    print("cannot write \(videoURL.path): \(writer.error.map { "\($0)" } ?? "unknown error")")
    exit(1)
}
writer.startSession(atSourceTime: .zero)
let frames = seconds * Int(fps)
for frame in 0..<frames {
    while !input.isReadyForMoreMediaData {
        Thread.sleep(forTimeInterval: 0.005)
    }
    guard let pool = adaptor.pixelBufferPool else {
        print("no pixel buffer pool: \(writer.error.map { "\($0)" } ?? "unknown error")")
        exit(1)
    }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    guard let pixels = buffer else {
        print("no pixel buffer")
        exit(1)
    }
    CVPixelBufferLockBaseAddress(pixels, [])
    let context = CGContext(
        data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let time = String(format: "%02d.%02d", frame / Int(fps), frame % Int(fps))
    draw(context, width: width, height: height, offset: frame * 4, label: time)
    CVPixelBufferUnlockBaseAddress(pixels, [])
    if !adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) {
        print("frame \(frame) refused: \(writer.error.map { "\($0)" } ?? "unknown error")")
        exit(1)
    }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else {
    print("the video was not finished: \(writer.error.map { "\($0)" } ?? "unknown error")")
    exit(1)
}
for name in ["test-photo.jpg", "test-video.mp4"] {
    let size = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size]) ?? 0
    print("\(folder.appendingPathComponent(name).path): \(size) bytes")
}
