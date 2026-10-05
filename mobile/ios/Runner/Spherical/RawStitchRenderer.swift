import CoreVideo
import Foundation
import Metal
import simd

// Swift copies of RawStitchLens, RawStitchFace and RawStitchUniforms of RawStitchShaders.metal: float4 members only,
// which Swift and Metal lay out the same way (16 byte alignment, no padding)
struct RawStitchLensUniforms {
  var row0 = SIMD4<Float>(repeating: 0)
  var row1 = SIMD4<Float>(repeating: 0)
  var row2 = SIMD4<Float>(repeating: 0)
  var projection = SIMD4<Float>(repeating: 0)  // fx / S, fy / S, (cx - i S) / S, cy / S
  var radial = SIMD4<Float>(repeating: 0)  // k1, k2, k3, k4
  var extra = SIMD4<Float>(repeating: 0)  // k5, xi, p1, p2
  var region = SIMD4<Float>(0, 0, 1, 1)  // origin xy, size zw, fractions of the source
  var source = SIMD4<Float>(repeating: 0)  // source index, 1 when it has a frame, half a texel of it (x, y)
}

struct RawStitchFaceUniforms {
  var forward = SIMD4<Float>(repeating: 0)  // w: source
  var right = SIMD4<Float>(repeating: 0)  // w: slot
  var down = SIMD4<Float>(repeating: 0)
}

struct RawStitchUniforms {
  var lens0 = RawStitchLensUniforms()
  var lens1 = RawStitchLensUniforms()
  var face0 = RawStitchFaceUniforms()
  var face1 = RawStitchFaceUniforms()
  var face2 = RawStitchFaceUniforms()
  var face3 = RawStitchFaceUniforms()
  var face4 = RawStitchFaceUniforms()
  var face5 = RawStitchFaceUniforms()
  var camera0 = SIMD4<Float>(repeating: 0)
  var camera1 = SIMD4<Float>(repeating: 0)
  var camera2 = SIMD4<Float>(repeating: 0)
  var settings = SIMD4<Float>(repeating: 0)  // projection, output width, output height, 0
  var angles = SIMD4<Float>(repeating: 0)  // max theta, blend start, blend end (radians), 0
  var presence = SIMD4<Float>(repeating: 0)  // source 0 has a frame, source 1 has one
  var eac = SIMD4<Float>(repeating: 0)  // face, half, overlap, middle
  var eacTrack = SIMD4<Float>(repeating: 0)  // right, declared track width, declared track height, 0
  var range0 = SIMD4<Float>(repeating: 0)  // luma scale, luma offset, chroma scale, chroma offset
  var range1 = SIMD4<Float>(repeating: 0)
  var colorMatrix0 = SIMD4<Float>(repeating: 0)  // Cr to R, Cb to G, Cr to G, Cb to B
  var colorMatrix1 = SIMD4<Float>(repeating: 0)
}

/// The Metal side of RawStitchCompositor: one device, one command queue and the two pipelines of
/// RawStitchShaders.metal, shared by every compositor (Metal makes them safe to use from several threads). Nil when
/// Metal or the shaders are missing.
final class RawStitchRenderer: @unchecked Sendable {
  static let shared: RawStitchRenderer? = RawStitchRenderer()

  let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let fisheyePipeline: MTLRenderPipelineState
  private let eacPipeline: MTLRenderPipelineState
  // Bound where a source has no frame: the shaders never read them
  private let blackLuma: MTLTexture
  private let blackChroma: MTLTexture

  /// One source picture as the shaders read it: its two planes over the pixel buffer (no copy), and how its values
  /// turn into R'G'B'
  private struct SourcePlanes {
    let luma: CVMetalTexture
    let chroma: CVMetalTexture
    let lumaTexture: MTLTexture
    let chromaTexture: MTLTexture
    let range: SIMD4<Float>
    let colorMatrix: SIMD4<Float>
    let width: Int
    let height: Int
  }

  private init?() {
    guard let device = MTLCreateSystemDefaultDevice() else {
      print("RawStitch: no Metal device")
      return nil
    }
    guard let commandQueue = device.makeCommandQueue() else {
      print("RawStitch: no command queue")
      return nil
    }
    guard let library = device.makeDefaultLibrary() else {
      print("RawStitch: no Metal library")
      return nil
    }
    guard let vertexFunction = library.makeFunction(name: "rawStitchVertex"),
      let fisheyeFunction = library.makeFunction(name: "rawStitchFisheyeFragment"),
      let eacFunction = library.makeFunction(name: "rawStitchEacFragment")
    else {
      print("RawStitch: the shaders are missing from the Metal library")
      return nil
    }
    guard
      let fisheyePipeline = Self.makePipeline(device: device, vertex: vertexFunction, fragment: fisheyeFunction),
      let eacPipeline = Self.makePipeline(device: device, vertex: vertexFunction, fragment: eacFunction),
      let blackLuma = Self.makeBlackTexture(device: device, format: .r8Unorm, bytesPerPixel: 1),
      let blackChroma = Self.makeBlackTexture(device: device, format: .rg8Unorm, bytesPerPixel: 2)
    else {
      return nil
    }
    self.device = device
    self.commandQueue = commandQueue
    self.fisheyePipeline = fisheyePipeline
    self.eacPipeline = eacPipeline
    self.blackLuma = blackLuma
    self.blackChroma = blackChroma
    assert(MemoryLayout<RawStitchLensUniforms>.stride == 128)
    assert(MemoryLayout<RawStitchFaceUniforms>.stride == 48)
    assert(MemoryLayout<RawStitchUniforms>.stride == 736)
  }

  private static func makePipeline(device: MTLDevice, vertex: MTLFunction, fragment: MTLFunction)
    -> MTLRenderPipelineState?
  {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = vertex
    descriptor.fragmentFunction = fragment
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    do {
      return try device.makeRenderPipelineState(descriptor: descriptor)
    } catch {
      print("RawStitch: cannot create the \(fragment.name) pipeline: \(error)")
      return nil
    }
  }

  private static func makeBlackTexture(device: MTLDevice, format: MTLPixelFormat, bytesPerPixel: Int) -> MTLTexture? {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: format, width: 1, height: 1, mipmapped: false)
    guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
    let zeros = [UInt8](repeating: 0, count: bytesPerPixel)
    texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: zeros, bytesPerRow: bytesPerPixel)
    return texture
  }

  /// A texture cache for one compositor: the textures it gives live over the pixel buffers of that compositor's frames
  func makeTextureCache() -> CVMetalTextureCache? {
    var cache: CVMetalTextureCache?
    guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess else {
      return nil
    }
    return cache
  }

  /// Stitches [frames] (one per track of the instruction's geometry, nil where a track has no frame at this time)
  /// into [output], a BGRA pixel buffer. [completion] runs once, on a Metal thread when the GPU is done, with the GPU
  /// time in milliseconds, or at once with the error when the frame cannot be drawn.
  func render(
    instruction: RawStitchInstruction,
    frames: [CVPixelBuffer?],
    output: CVPixelBuffer,
    cache: CVMetalTextureCache,
    completion: @escaping (Double?, Error?) -> Void
  ) {
    let geometry = instruction.geometry
    var sources: [SourcePlanes?] = [nil, nil]
    do {
      for index in 0..<min(frames.count, 2) {
        if let frame = frames[index] {
          sources[index] = try Self.planes(of: frame, cache: cache)
        }
      }
    } catch {
      completion(nil, error)
      return
    }
    guard
      let outputTexture = Self.texture(
        output, plane: 0, format: .bgra8Unorm, usage: [.renderTarget, .shaderRead], cache: cache),
      let outputMetalTexture = CVMetalTextureGetTexture(outputTexture)
    else {
      completion(nil, RawStitchError(reason: "no Metal texture over the output pixel buffer"))
      return
    }
    let outputWidth = CVPixelBufferGetWidth(output)
    let outputHeight = CVPixelBufferGetHeight(output)

    var uniforms = RawStitchUniforms()
    uniforms.settings = SIMD4<Float>(
      Float(geometry.projection.rawValue), Float(outputWidth), Float(outputHeight), 0)
    uniforms.angles = geometry.angles
    uniforms.presence = SIMD4<Float>(sources[0] == nil ? 0 : 1, sources[1] == nil ? 0 : 1, 0, 0)
    if let source = sources[0] {
      uniforms.range0 = source.range
      uniforms.colorMatrix0 = source.colorMatrix
    }
    if let source = sources[1] {
      uniforms.range1 = source.range
      uniforms.colorMatrix1 = source.colorMatrix
    }
    if geometry.lenses.count == 2 {
      uniforms.lens0 = Self.lensUniforms(geometry.lenses[0], sources: sources)
      uniforms.lens1 = Self.lensUniforms(geometry.lenses[1], sources: sources)
    }
    if let eac = geometry.eac {
      if let source0 = sources[0], let source1 = sources[1],
        source0.width != source1.width || source0.height != source1.height
      {
        completion(
          nil,
          RawStitchError(
            reason: "the two EAC strips are \(source0.width)x\(source0.height) and "
              + "\(source1.width)x\(source1.height)"))
        return
      }
      uniforms.camera0 = eac.cameraRows[0]
      uniforms.camera1 = eac.cameraRows[1]
      uniforms.camera2 = eac.cameraRows[2]
      uniforms.eac = SIMD4<Float>(eac.face, eac.half, eac.overlap, eac.middle)
      uniforms.eacTrack = SIMD4<Float>(eac.right, eac.trackWidth, eac.trackHeight, 0)
      let faces = eac.faces.map { RawStitchFaceUniforms(forward: $0.forward, right: $0.right, down: $0.down) }
      if faces.count == 6 {
        uniforms.face0 = faces[0]
        uniforms.face1 = faces[1]
        uniforms.face2 = faces[2]
        uniforms.face3 = faces[3]
        uniforms.face4 = faces[4]
        uniforms.face5 = faces[5]
      }
    }

    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
      completion(nil, RawStitchError(reason: "no Metal command buffer"))
      return
    }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = outputMetalTexture
    // Every output pixel is written
    pass.colorAttachments[0].loadAction = .dontCare
    pass.colorAttachments[0].storeAction = .store
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
      completion(nil, RawStitchError(reason: "no Metal render encoder"))
      return
    }
    encoder.setRenderPipelineState(geometry.projection == .eac ? eacPipeline : fisheyePipeline)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<RawStitchUniforms>.stride, index: 0)
    encoder.setFragmentTexture(sources[0]?.lumaTexture ?? blackLuma, index: 0)
    encoder.setFragmentTexture(sources[0]?.chromaTexture ?? blackChroma, index: 1)
    encoder.setFragmentTexture(sources[1]?.lumaTexture ?? blackLuma, index: 2)
    encoder.setFragmentTexture(sources[1]?.chromaTexture ?? blackChroma, index: 3)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()

    // SceneKit gets the same kind of frame as from any 8 bit BT.709 video
    CVBufferSetAttachment(
      output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(
      output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

    // The CVMetalTextures, and through them the pixel buffers, must outlive the GPU work: else the decoder may reuse
    // a source buffer while the GPU still reads it
    let retained: [CVMetalTexture] = [outputTexture] + sources.compactMap { $0 }.flatMap { [$0.luma, $0.chroma] }
    commandBuffer.addCompletedHandler { buffer in
      withExtendedLifetime(retained) {}
      completion((buffer.gpuEndTime - buffer.gpuStartTime) * 1000, buffer.error)
    }
    commandBuffer.commit()
  }

  /// The uniforms of [lens], with the presence and the half texel of the source that holds it
  private static func lensUniforms(_ lens: RawStitchGeometry.Lens, sources: [SourcePlanes?]) -> RawStitchLensUniforms {
    var uniforms = RawStitchLensUniforms()
    uniforms.row0 = lens.rows[0]
    uniforms.row1 = lens.rows[1]
    uniforms.row2 = lens.rows[2]
    uniforms.projection = lens.projection
    uniforms.radial = lens.radial
    uniforms.extra = lens.extra
    uniforms.region = lens.region
    if lens.texture < sources.count, let source = sources[lens.texture] {
      uniforms.source = SIMD4<Float>(
        Float(lens.texture), 1, 0.5 / Float(max(source.width, 1)), 0.5 / Float(max(source.height, 1)))
    } else {
      uniforms.source = SIMD4<Float>(Float(lens.texture), 0, 0, 0)
    }
    return uniforms
  }

  /// The two planes of [frame] and its conversion to R'G'B': the range of its pixel format (8 bit, or 10 bit in the
  /// high bits of 16) and the matrix its attachment names (BT.709 when it names none)
  private static func planes(of frame: CVPixelBuffer, cache: CVMetalTextureCache) throws -> SourcePlanes {
    let pixelFormat = CVPixelBufferGetPixelFormatType(frame)
    let lumaFormat: MTLPixelFormat
    let chromaFormat: MTLPixelFormat
    let range: SIMD4<Float>
    switch pixelFormat {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
      lumaFormat = .r8Unorm
      chromaFormat = .rg8Unorm
      range = SIMD4<Float>(255.0 / 219.0, 16.0 / 219.0, 255.0 / 224.0, 128.0 / 224.0)
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      lumaFormat = .r8Unorm
      chromaFormat = .rg8Unorm
      range = SIMD4<Float>(1, 0, 1, 128.0 / 255.0)
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
      lumaFormat = .r16Unorm
      chromaFormat = .rg16Unorm
      range = SIMD4<Float>(65535.0 / 64.0 / 876.0, 64.0 / 876.0, 65535.0 / 64.0 / 896.0, 512.0 / 896.0)
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
      lumaFormat = .r16Unorm
      chromaFormat = .rg16Unorm
      range = SIMD4<Float>(65535.0 / 64.0 / 1023.0, 0, 65535.0 / 64.0 / 1023.0, 512.0 / 1023.0)
    default:
      throw RawStitchError(
        reason: "source pixel format \(VideoDecoderSupport.fourCharacterCode(pixelFormat)) is not handled")
    }
    guard CVPixelBufferGetPlaneCount(frame) >= 2,
      let luma = texture(frame, plane: 0, format: lumaFormat, usage: .shaderRead, cache: cache),
      let chroma = texture(frame, plane: 1, format: chromaFormat, usage: .shaderRead, cache: cache),
      let lumaTexture = CVMetalTextureGetTexture(luma),
      let chromaTexture = CVMetalTextureGetTexture(chroma)
    else {
      throw RawStitchError(reason: "no Metal texture over a source pixel buffer")
    }
    let matrixName = CVBufferCopyAttachment(frame, kCVImageBufferYCbCrMatrixKey, nil) as? String
    let colorMatrix: SIMD4<Float>
    if matrixName == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) {
      colorMatrix = SIMD4<Float>(1.402, 0.344136, 0.714136, 1.772)
    } else if matrixName == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) {
      colorMatrix = SIMD4<Float>(1.4746, 0.164553, 0.571353, 1.8814)
    } else {
      colorMatrix = SIMD4<Float>(1.5748, 0.187324, 0.468124, 1.8556)
    }
    return SourcePlanes(
      luma: luma,
      chroma: chroma,
      lumaTexture: lumaTexture,
      chromaTexture: chromaTexture,
      range: range,
      colorMatrix: colorMatrix,
      width: CVPixelBufferGetWidthOfPlane(frame, 0),
      height: CVPixelBufferGetHeightOfPlane(frame, 0)
    )
  }

  /// A Metal texture over one plane of [buffer], without a copy
  private static func texture(
    _ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, usage: MTLTextureUsage, cache: CVMetalTextureCache
  ) -> CVMetalTexture? {
    let planar = CVPixelBufferIsPlanar(buffer)
    let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
    let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
    let attributes = [kCVMetalTextureUsage as String: NSNumber(value: usage.rawValue)] as CFDictionary
    var texture: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, cache, buffer, attributes, format, width, height, plane, &texture)
    return status == kCVReturnSuccess ? texture : nil
  }
}
