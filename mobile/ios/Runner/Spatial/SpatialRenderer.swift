import Metal
import MetalKit
import QuartzCore
import simd

/// Size and refresh rate of the disparity map. The renderer starts on medium and, with
/// [SpatialRenderer.adaptiveQuality], steps down when the GPU time of a frame averages more than 12 ms over a second,
/// and up when it stays under 6 ms for five seconds.
enum SpatialQuality: Int, CaseIterable {
  case low = 0
  case medium = 1
  case high = 2

  /// Width of the disparity map; its height follows the shape of the eye
  var mapWidth: Int {
    switch self {
    case .low:
      return 320
    case .medium:
      return 480
    case .high:
      return 640
    }
  }

  /// The map is computed once every this many frames
  var interval: Int {
    switch self {
    case .low:
      return 4
    case .medium:
      return 2
    case .high:
      return 1
    }
  }

  /// The left right consistency check, which also gives the map in right eye coordinates
  var consistencyCheck: Bool { self != .low }

  var name: String {
    switch self {
    case .low:
      return "low"
    case .medium:
      return "medium"
    case .high:
      return "high"
    }
  }
}

/// Diagnostics for the debug overlay
struct SpatialStats {
  var quality: SpatialQuality
  var mapWidth: Int
  var mapHeight: Int
  /// Average GPU time of a frame over the last second, in milliseconds
  var gpuMs: Double
  var renderFps: Double
  var disparityFps: Double
  /// False when a shader failed to load: the renderer then shows the left eye only
  var stereoAvailable: Bool
}

// Swift copies of the uniform structures of SpatialShaders.metal. They hold only 16 byte vectors and 4x4 matrices,
// which Swift and Metal lay out the same way.
private struct SpatialViewportUniforms {
  var rotation: simd_float4x4
  var rect: SIMD4<Float>
  var lens: SIMD4<Float>
  var sphere: SIMD4<Float>
}

private struct SpatialSynthesisUniforms {
  var leftRect: SIMD4<Float>
  var rightRect: SIMD4<Float>
  var view: SIMD4<Float>
  var extra: SIMD4<Float>
}

/// The textures of the disparity pipeline, all at the size of the map
private final class DisparityMaps {
  let width: Int
  let height: Int
  let grayLeft: MTLTexture
  let grayRight: MTLTexture
  let rawLeft: MTLTexture
  let rawRight: MTLTexture
  let checkedLeft: MTLTexture
  let checkedRight: MTLTexture
  let blurPassLeft: MTLTexture
  let blurPassRight: MTLTexture
  let blurredLeft: MTLTexture
  let blurredRight: MTLTexture
  // Ping pong pairs of the temporal blend: [current] holds the newest map
  let historyLeft: [MTLTexture]
  let historyRight: [MTLTexture]
  var current = 0
  var hasHistory = false
  var hasRightMap = false

  init?(device: MTLDevice, width: Int, height: Int) {
    self.width = width
    self.height = height
    func make(_ format: MTLPixelFormat) -> MTLTexture? {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: format,
        width: width,
        height: height,
        mipmapped: false
      )
      descriptor.usage = [.shaderRead, .shaderWrite]
      descriptor.storageMode = .private
      return device.makeTexture(descriptor: descriptor)
    }
    guard let grayLeft = make(.r16Float), let grayRight = make(.r16Float),
      let rawLeft = make(.rg16Float), let rawRight = make(.rg16Float),
      let checkedLeft = make(.rg16Float), let checkedRight = make(.rg16Float),
      let blurPassLeft = make(.rg16Float), let blurPassRight = make(.rg16Float),
      let blurredLeft = make(.rg16Float), let blurredRight = make(.rg16Float),
      let historyLeft0 = make(.rg16Float), let historyLeft1 = make(.rg16Float),
      let historyRight0 = make(.rg16Float), let historyRight1 = make(.rg16Float)
    else {
      return nil
    }
    self.grayLeft = grayLeft
    self.grayRight = grayRight
    self.rawLeft = rawLeft
    self.rawRight = rawRight
    self.checkedLeft = checkedLeft
    self.checkedRight = checkedRight
    self.blurPassLeft = blurPassLeft
    self.blurPassRight = blurPassRight
    self.blurredLeft = blurredLeft
    self.blurredRight = blurredRight
    historyLeft = [historyLeft0, historyLeft1]
    historyRight = [historyRight0, historyRight1]
  }
}

/// Draws a stereoscopic video frame as seen from an in between viewpoint, with Metal (see SpatialShaders.metal for
/// the method).
///
/// Every frame: the eyes are cut from the video frame (or, for a 360 degree video, the current viewport of each eye
/// is rendered into a texture at the output size), the disparity map is refreshed every [SpatialQuality.interval]
/// frames, then the synthesis shader draws the view for [viewpoint] into the drawable, letterboxed. If a shader or a
/// pipeline cannot be created, the renderer draws the left eye only; the initialiser fails only when not even that
/// is possible.
final class SpatialRenderer {
  /// How the eyes sit in the frame. Auto is read as side by side: the player resolves it before.
  var layout: SpatialStereoLayout = .sideBySide {
    didSet {
      if layout != oldValue {
        resetHistory()
      }
    }
  }
  /// A 360 degree video ([SpatialProjection.equirectangular]) or a 180 degree one
  /// ([SpatialProjection.equirectangular180], VR180: the front half of the sphere, black behind) is shown through a
  /// viewport
  var projection: SpatialProjection = .flat {
    didSet {
      if projection != oldValue {
        resetHistory()
      }
    }
  }
  /// 0 is the left eye, 0.5 the middle, 1 the right eye
  var viewpoint: Float = 0.5
  /// 360 degree videos: yaw around the vertical axis (radians, growing to the left), pitch (growing upwards), and the
  /// field of view of the longer side of the screen, in degrees
  var yaw: Float = 0
  var pitch: Float = 0
  var fov: Float = 80
  /// 360 degree videos: the orientation of the device when the motion sensors drive the view. It then replaces the
  /// pitch, and the yaw turns it around the vertical axis.
  var attitude: simd_quatf?
  var quality: SpatialQuality = .medium
  var adaptiveQuality = true
  /// Shows the disparity map instead of the picture
  var showDisparity = false

  private static let searchRange = 24
  // The longer side of the 360 degree eye viewports, at most
  private static let maxViewportSize: CGFloat = 1920

  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let passthroughPipeline: MTLRenderPipelineState
  private let viewportPipeline: MTLRenderPipelineState?
  private let synthesisPipeline: MTLRenderPipelineState?
  private let disparityViewPipeline: MTLRenderPipelineState?
  private let grayPipeline: MTLComputePipelineState?
  private let disparityPipeline: MTLComputePipelineState?
  private let consistencyPipeline: MTLComputePipelineState?
  private let blurPipeline: MTLComputePipelineState?
  private let temporalPipeline: MTLComputePipelineState?
  private let stereoAvailable: Bool

  private var maps: DisparityMaps?
  private var eyeViewports: (left: MTLTexture, right: MTLTexture)?
  private var frameCount = 0

  // Statistics, the GPU times come from the completion handlers on another thread
  private let statsLock = NSLock()
  private var gpuTimeSum: Double = 0
  private var gpuTimeCount = 0
  private var windowStart = CACurrentMediaTime()
  private var framesInWindow = 0
  private var updatesInWindow = 0
  private var lastGpuMs: Double = 0
  private var lastRenderFps: Double = 0
  private var lastDisparityFps: Double = 0
  private var fastSeconds = 0
  private var lastStepDown: CFTimeInterval = 0
  /// Seconds the adaptive rule ignores after new maps or a quality change: the first frames build the pipelines
  private var warmupWindows = 1

  /// Fails when the device cannot draw even the left eye (no command queue, no shader library). [pixelFormat] is the
  /// one of the MTKView.
  init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
    guard let commandQueue = device.makeCommandQueue() else {
      print("Spatial renderer: no command queue")
      return nil
    }
    guard let library = device.makeDefaultLibrary() else {
      print("Spatial renderer: no Metal library")
      return nil
    }
    guard
      let passthrough = Self.makeRenderPipeline(
        library,
        device: device,
        fragment: "spatialPassthroughFragment",
        pixelFormat: pixelFormat
      )
    else {
      return nil
    }
    let viewport = Self.makeRenderPipeline(
      library,
      device: device,
      fragment: "spatialViewportFragment",
      pixelFormat: pixelFormat
    )
    let synthesis = Self.makeRenderPipeline(
      library,
      device: device,
      fragment: "spatialSynthesisFragment",
      pixelFormat: pixelFormat
    )
    let disparityView = Self.makeRenderPipeline(
      library,
      device: device,
      fragment: "spatialDisparityFragment",
      pixelFormat: pixelFormat
    )
    let gray = Self.makeComputePipeline(library, device: device, name: "spatialGrayDownsample")
    let disparity = Self.makeComputePipeline(library, device: device, name: "spatialDisparity")
    let consistency = Self.makeComputePipeline(library, device: device, name: "spatialConsistency")
    let blur = Self.makeComputePipeline(library, device: device, name: "spatialGuidedBlur")
    let temporal = Self.makeComputePipeline(library, device: device, name: "spatialTemporalBlend")
    let stereo =
      synthesis != nil && disparityView != nil && gray != nil && disparity != nil && consistency != nil
      && blur != nil && temporal != nil
    if !stereo {
      print("Spatial renderer: a stereo pipeline failed, showing the left eye only")
    }

    self.device = device
    self.commandQueue = commandQueue
    passthroughPipeline = passthrough
    viewportPipeline = viewport
    synthesisPipeline = synthesis
    disparityViewPipeline = disparityView
    grayPipeline = gray
    disparityPipeline = disparity
    consistencyPipeline = consistency
    blurPipeline = blur
    temporalPipeline = temporal
    stereoAvailable = stereo
  }

  /// Forgets the previous disparity maps, after a seek or a change of layout, so that the old scene does not blend in
  func resetHistory() {
    maps?.hasHistory = false
  }

  func stats() -> SpatialStats {
    SpatialStats(
      quality: quality,
      mapWidth: maps?.width ?? 0,
      mapHeight: maps?.height ?? 0,
      gpuMs: lastGpuMs,
      renderFps: lastRenderFps,
      disparityFps: lastDisparityFps,
      stereoAvailable: stereoAvailable
    )
  }

  /// Draws [source], the current video frame (BGRA), into the drawable of [view]. [retaining] is kept alive until the
  /// GPU is done with the frame: the CVMetalTexture that [source] comes from.
  func draw(in view: MTKView, source: MTLTexture, retaining resource: AnyObject? = nil) {
    let now = CACurrentMediaTime()
    updateStatistics(now: now)
    frameCount += 1
    framesInWindow += 1

    let drawableSize = view.drawableSize
    guard drawableSize.width > 0, drawableSize.height > 0,
      let commandBuffer = commandQueue.makeCommandBuffer()
    else {
      return
    }
    // The CVMetalTexture behind [source], and so its pixel buffer, must outlive the GPU work on every commit path,
    // the early ones without a drawable included: else the player may reuse the buffer while the GPU still reads it
    let retained = resource
    commandBuffer.addCompletedHandler { _ in
      withExtendedLifetime(retained) {}
    }

    let eyes = Self.eyeRects(for: layout)
    let stereo = eyes.stereo && stereoAvailable
    let drawableAspect = Float(drawableSize.width / drawableSize.height)

    var leftTexture = source
    var rightTexture = source
    var leftRect = eyes.left
    var rightRect = eyes.right
    var contentAspect = Self.displayAspect(
      frameWidth: Float(source.width),
      frameHeight: Float(source.height),
      rect: eyes.left,
      layout: layout
    )
    var monoViewport = false

    if projection != .flat, viewportPipeline != nil {
      contentAspect = drawableAspect
      if stereo, let viewports = eyeViewportTextures(for: drawableSize, pixelFormat: view.colorPixelFormat) {
        encodeViewport(commandBuffer, source: source, rect: eyes.left, target: viewports.left)
        encodeViewport(commandBuffer, source: source, rect: eyes.right, target: viewports.right)
        leftTexture = viewports.left
        rightTexture = viewports.right
        leftRect = SIMD4<Float>(0, 0, 1, 1)
        rightRect = SIMD4<Float>(0, 0, 1, 1)
      } else {
        // Not stereoscopic, or the stereo path is not available: the viewport of the left eye, straight to the
        // drawable
        monoViewport = true
      }
    }

    var mapsReady = false
    if stereo && !monoViewport, let maps = disparityMaps(eyeAspect: contentAspect) {
      if !maps.hasHistory || frameCount % quality.interval == 0 {
        encodeDisparity(
          commandBuffer,
          maps: maps,
          left: leftTexture,
          leftRect: leftRect,
          right: rightTexture,
          rightRect: rightRect
        )
        updatesInWindow += 1
      }
      mapsReady = maps.hasHistory
    }

    // The drawable as late as possible: it is a scarce resource
    guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else {
      commandBuffer.commit()
      return
    }
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
      commandBuffer.commit()
      return
    }
    encoder.setViewport(Self.letterbox(contentAspect: contentAspect, in: drawableSize))

    if monoViewport, let viewportPipeline {
      var uniforms = viewportUniforms(rect: eyes.left, aspect: drawableAspect)
      encoder.setRenderPipelineState(viewportPipeline)
      encoder.setFragmentTexture(source, index: 0)
      encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SpatialViewportUniforms>.stride, index: 0)
    } else if mapsReady, let maps, let synthesisPipeline, let disparityViewPipeline {
      let leftMap = maps.historyLeft[maps.current]
      let rightMap = maps.hasRightMap ? maps.historyRight[maps.current] : leftMap
      let texel = 1 / Float(maps.width)
      var uniforms = SpatialSynthesisUniforms(
        leftRect: leftRect,
        rightRect: rightRect,
        view: SIMD4<Float>(min(max(viewpoint, 0), 1), texel, maps.hasRightMap ? 1 : 0, 1.5 * texel),
        extra: SIMD4<Float>(Float(Self.searchRange) * texel, 0, 0, 0)
      )
      if showDisparity {
        encoder.setRenderPipelineState(disparityViewPipeline)
        encoder.setFragmentTexture(leftMap, index: 0)
      } else {
        encoder.setRenderPipelineState(synthesisPipeline)
        encoder.setFragmentTexture(leftTexture, index: 0)
        encoder.setFragmentTexture(rightTexture, index: 1)
        encoder.setFragmentTexture(leftMap, index: 2)
        encoder.setFragmentTexture(rightMap, index: 3)
      }
      encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SpatialSynthesisUniforms>.stride, index: 0)
    } else {
      var rect = leftRect
      encoder.setRenderPipelineState(passthroughPipeline)
      encoder.setFragmentTexture(leftTexture, index: 0)
      encoder.setFragmentBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
    }
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()

    commandBuffer.present(drawable)
    commandBuffer.addCompletedHandler { [weak self] buffer in
      let milliseconds = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
      self?.recordGpuTime(milliseconds)
    }
    commandBuffer.commit()
  }

  // MARK: - Eyes

  /// Where the eyes are in the frame, in texture coordinates (origin xy, size zw)
  static func eyeRects(for layout: SpatialStereoLayout) -> (
    left: SIMD4<Float>, right: SIMD4<Float>, stereo: Bool
  ) {
    let leftHalf = SIMD4<Float>(0, 0, 0.5, 1)
    let rightHalf = SIMD4<Float>(0.5, 0, 0.5, 1)
    let topHalf = SIMD4<Float>(0, 0, 1, 0.5)
    let bottomHalf = SIMD4<Float>(0, 0.5, 1, 0.5)
    switch layout {
    case .auto, .sideBySide:
      return (leftHalf, rightHalf, true)
    case .sideBySideSwapped:
      return (rightHalf, leftHalf, true)
    case .topBottom:
      return (topHalf, bottomHalf, true)
    case .topBottomSwapped:
      return (bottomHalf, topHalf, true)
    case .none:
      let whole = SIMD4<Float>(0, 0, 1, 1)
      return (whole, whole, false)
    }
  }

  /// Width over height of an eye on screen. Half side by side videos squeeze each eye to half its width, half top
  /// and bottom ones to half its height: an eye much narrower (or wider) than any usual picture is one of those, and
  /// shows at the shape of the whole frame.
  static func displayAspect(frameWidth: Float, frameHeight: Float, rect: SIMD4<Float>, layout: SpatialStereoLayout)
    -> Float
  {
    let width = frameWidth * rect.z
    let height = frameHeight * rect.w
    guard width > 0, height > 0 else { return 16 / 9 }
    var aspect = width / height
    switch layout {
    case .auto, .sideBySide, .sideBySideSwapped:
      if aspect < 1.2 {
        aspect *= 2
      }
    case .topBottom, .topBottomSwapped:
      if aspect > 2.5 {
        aspect /= 2
      }
    case .none:
      break
    }
    return aspect
  }

  /// The largest rectangle of [contentAspect] centred in the drawable
  private static func letterbox(contentAspect: Float, in size: CGSize) -> MTLViewport {
    let width = Double(size.width)
    let height = Double(size.height)
    let aspect = Double(max(contentAspect, 0.01))
    var viewportWidth = width
    var viewportHeight = width / aspect
    if viewportHeight > height {
      viewportHeight = height
      viewportWidth = height * aspect
    }
    return MTLViewport(
      originX: (width - viewportWidth) / 2,
      originY: (height - viewportHeight) / 2,
      width: viewportWidth,
      height: viewportHeight,
      znear: 0,
      zfar: 1
    )
  }

  // MARK: - 360 degree viewports

  /// The two eye viewports of a 360 degree video, at the shape of the drawable, recreated when its size changes
  private func eyeViewportTextures(for drawableSize: CGSize, pixelFormat: MTLPixelFormat) -> (
    left: MTLTexture, right: MTLTexture
  )? {
    let scale = min(1, Self.maxViewportSize / max(drawableSize.width, drawableSize.height))
    let width = max(Int((drawableSize.width * scale).rounded()), 1)
    let height = max(Int((drawableSize.height * scale).rounded()), 1)
    if let existing = eyeViewports, existing.left.width == width, existing.left.height == height,
      existing.left.pixelFormat == pixelFormat
    {
      return existing
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: pixelFormat,
      width: width,
      height: height,
      mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .private
    guard let left = device.makeTexture(descriptor: descriptor),
      let right = device.makeTexture(descriptor: descriptor)
    else {
      return nil
    }
    eyeViewports = (left, right)
    // The maps follow the shape of the viewports
    maps = nil
    return (left, right)
  }

  private func encodeViewport(
    _ commandBuffer: MTLCommandBuffer,
    source: MTLTexture,
    rect: SIMD4<Float>,
    target: MTLTexture
  ) {
    guard let viewportPipeline else { return }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .dontCare
    pass.colorAttachments[0].storeAction = .store
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
    var uniforms = viewportUniforms(rect: rect, aspect: Float(target.width) / Float(max(target.height, 1)))
    encoder.setRenderPipelineState(viewportPipeline)
    encoder.setFragmentTexture(source, index: 0)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SpatialViewportUniforms>.stride, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
  }

  /// The field of view spans the longer side of the output, in landscape as in portrait
  private func viewportUniforms(rect: SIMD4<Float>, aspect: Float) -> SpatialViewportUniforms {
    let halfTangent = tan(fov * Float.pi / 360)
    var horizontal = halfTangent
    var vertical = halfTangent
    if aspect >= 1 {
      vertical = halfTangent / aspect
    } else {
      horizontal = halfTangent * aspect
    }
    // The eye of a half sphere spans half the longitudes of a full one
    let longitudeSpan: Float = projection == .equirectangular180 ? Float.pi : 2 * Float.pi
    return SpatialViewportUniforms(
      rotation: simd_float4x4(cameraOrientation()),
      rect: rect,
      lens: SIMD4<Float>(horizontal, vertical, 0, 0),
      sphere: SIMD4<Float>(longitudeSpan, 0, 0, 0)
    )
  }

  /// Camera space to world: the yaw around the vertical axis, then the device attitude or the pitch
  private func cameraOrientation() -> simd_quatf {
    let yawRotation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
    if let attitude {
      return yawRotation * attitude
    }
    return yawRotation * simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
  }

  // MARK: - Disparity

  /// The maps for the current quality, with the height that keeps the pixels of the eye square
  private func disparityMaps(eyeAspect: Float) -> DisparityMaps? {
    let width = quality.mapWidth
    var height = Int((Float(width) / max(eyeAspect, 0.01)).rounded())
    height = min(max(height, width / 4), width * 2)
    height += height % 2
    if let maps, maps.width == width, maps.height == height {
      return maps
    }
    maps = DisparityMaps(device: device, width: width, height: height)
    // The second that allocates the maps and first runs the passes is not representative
    warmupWindows = max(warmupWindows, 1)
    return maps
  }

  private func encodeDisparity(
    _ commandBuffer: MTLCommandBuffer,
    maps: DisparityMaps,
    left: MTLTexture,
    leftRect: SIMD4<Float>,
    right: MTLTexture,
    rightRect: SIMD4<Float>
  ) {
    guard let grayPipeline, let disparityPipeline, let consistencyPipeline, let blurPipeline, let temporalPipeline,
      let encoder = commandBuffer.makeComputeCommandEncoder()
    else {
      return
    }
    let width = maps.width
    let height = maps.height
    let check = quality.consistencyCheck

    // Grayscale eyes at the size of the map
    encoder.setComputePipelineState(grayPipeline)
    for (eye, rect, gray) in [(left, leftRect, maps.grayLeft), (right, rightRect, maps.grayRight)] {
      var eyeRect = rect
      encoder.setTexture(eye, index: 0)
      encoder.setTexture(gray, index: 1)
      encoder.setBytes(&eyeRect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
      Self.dispatch(encoder, width: width, height: height)
    }

    // Block matching, from the left eye, and from the right eye for the consistency check
    encoder.setComputePipelineState(disparityPipeline)
    var leftConfig = SIMD4<Int32>(1, Int32(Self.searchRange), 0, 0)
    encoder.setTexture(maps.grayLeft, index: 0)
    encoder.setTexture(maps.grayRight, index: 1)
    encoder.setTexture(maps.rawLeft, index: 2)
    encoder.setBytes(&leftConfig, length: MemoryLayout<SIMD4<Int32>>.stride, index: 0)
    Self.dispatch(encoder, width: width, height: height)
    if check {
      var rightConfig = SIMD4<Int32>(-1, Int32(Self.searchRange), 0, 0)
      encoder.setTexture(maps.grayRight, index: 0)
      encoder.setTexture(maps.grayLeft, index: 1)
      encoder.setTexture(maps.rawRight, index: 2)
      encoder.setBytes(&rightConfig, length: MemoryLayout<SIMD4<Int32>>.stride, index: 0)
      Self.dispatch(encoder, width: width, height: height)

      encoder.setComputePipelineState(consistencyPipeline)
      encoder.setTexture(maps.rawLeft, index: 0)
      encoder.setTexture(maps.rawRight, index: 1)
      encoder.setTexture(maps.checkedLeft, index: 2)
      encoder.setTexture(maps.checkedRight, index: 3)
      Self.dispatch(encoder, width: width, height: height)
    }

    // Edge aware blur, horizontal then vertical, guided by the grayscale eye
    encoder.setComputePipelineState(blurPipeline)
    var sides = [(check ? maps.checkedLeft : maps.rawLeft, maps.grayLeft, maps.blurPassLeft, maps.blurredLeft)]
    if check {
      sides.append((maps.checkedRight, maps.grayRight, maps.blurPassRight, maps.blurredRight))
    }
    for (input, guide, pass, output) in sides {
      var horizontal = SIMD4<Int32>(1, 0, 0, 0)
      encoder.setTexture(input, index: 0)
      encoder.setTexture(guide, index: 1)
      encoder.setTexture(pass, index: 2)
      encoder.setBytes(&horizontal, length: MemoryLayout<SIMD4<Int32>>.stride, index: 0)
      Self.dispatch(encoder, width: width, height: height)
      var vertical = SIMD4<Int32>(0, 1, 0, 0)
      encoder.setTexture(pass, index: 0)
      encoder.setTexture(guide, index: 1)
      encoder.setTexture(output, index: 2)
      encoder.setBytes(&vertical, length: MemoryLayout<SIMD4<Int32>>.stride, index: 0)
      Self.dispatch(encoder, width: width, height: height)
    }

    // Temporal blend into the other texture of each ping pong pair
    let next = 1 - maps.current
    let reset = !maps.hasHistory || (check && !maps.hasRightMap)
    encoder.setComputePipelineState(temporalPipeline)
    var blends = [(maps.blurredLeft, maps.historyLeft[maps.current], maps.historyLeft[next])]
    if check {
      blends.append((maps.blurredRight, maps.historyRight[maps.current], maps.historyRight[next]))
    }
    for (current, history, output) in blends {
      var config = SIMD4<Int32>(reset ? 1 : 0, 0, 0, 0)
      encoder.setTexture(current, index: 0)
      encoder.setTexture(history, index: 1)
      encoder.setTexture(output, index: 2)
      encoder.setBytes(&config, length: MemoryLayout<SIMD4<Int32>>.stride, index: 0)
      Self.dispatch(encoder, width: width, height: height)
    }
    encoder.endEncoding()

    maps.current = next
    maps.hasHistory = true
    maps.hasRightMap = check
  }

  /// 8x8 threadgroups, the tile size of the block matching kernel, over the whole map
  private static func dispatch(_ encoder: MTLComputeCommandEncoder, width: Int, height: Int) {
    let group = 8
    let threads = MTLSize(width: group, height: group, depth: 1)
    let groups = MTLSize(width: (width + group - 1) / group, height: (height + group - 1) / group, depth: 1)
    encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
  }

  // MARK: - Statistics and adaptive quality

  private func recordGpuTime(_ milliseconds: Double) {
    guard milliseconds.isFinite, milliseconds > 0 else { return }
    statsLock.lock()
    gpuTimeSum += milliseconds
    gpuTimeCount += 1
    statsLock.unlock()
  }

  /// Once a second: the rates, the average GPU time, and the quality step it calls for
  private func updateStatistics(now: CFTimeInterval) {
    let elapsed = now - windowStart
    guard elapsed >= 1 else { return }
    statsLock.lock()
    let sum = gpuTimeSum
    let count = gpuTimeCount
    gpuTimeSum = 0
    gpuTimeCount = 0
    statsLock.unlock()

    lastRenderFps = Double(framesInWindow) / elapsed
    lastDisparityFps = Double(updatesInWindow) / elapsed
    framesInWindow = 0
    updatesInWindow = 0
    windowStart = now
    guard count > 0 else { return }
    let average = sum / Double(count)
    lastGpuMs = average

    let stereo = stereoAvailable && Self.eyeRects(for: layout).stereo
    guard adaptiveQuality, stereo else {
      fastSeconds = 0
      return
    }
    if warmupWindows > 0 {
      warmupWindows -= 1
      return
    }
    if average > 12 {
      fastSeconds = 0
      if let lower = SpatialQuality(rawValue: quality.rawValue - 1) {
        quality = lower
        lastStepDown = now
        warmupWindows = 1
      }
    } else if average < 6 {
      fastSeconds += 1
      // After a step down, the quality that was too slow waits half a minute before another try
      if fastSeconds >= 5, now - lastStepDown > 30, let higher = SpatialQuality(rawValue: quality.rawValue + 1) {
        quality = higher
        fastSeconds = 0
        warmupWindows = 1
      }
    } else {
      fastSeconds = 0
    }
  }

  // MARK: - Pipelines

  private static func makeRenderPipeline(
    _ library: MTLLibrary,
    device: MTLDevice,
    fragment: String,
    pixelFormat: MTLPixelFormat
  ) -> MTLRenderPipelineState? {
    guard let vertexFunction = library.makeFunction(name: "spatialFullscreenVertex"),
      let fragmentFunction = library.makeFunction(name: fragment)
    else {
      print("Spatial renderer: missing shader \(fragment)")
      return nil
    }
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = vertexFunction
    descriptor.fragmentFunction = fragmentFunction
    descriptor.colorAttachments[0].pixelFormat = pixelFormat
    do {
      return try device.makeRenderPipelineState(descriptor: descriptor)
    } catch {
      print("Spatial renderer: cannot create the \(fragment) pipeline: \(error)")
      return nil
    }
  }

  private static func makeComputePipeline(_ library: MTLLibrary, device: MTLDevice, name: String)
    -> MTLComputePipelineState?
  {
    guard let function = library.makeFunction(name: name) else {
      print("Spatial renderer: missing kernel \(name)")
      return nil
    }
    do {
      let pipeline = try device.makeComputePipelineState(function: function)
      // The kernels run in 8x8 threadgroups
      guard pipeline.maxTotalThreadsPerThreadgroup >= 64 else {
        print("Spatial renderer: kernel \(name) cannot run 64 threads per group")
        return nil
      }
      return pipeline
    } catch {
      print("Spatial renderer: cannot create the \(name) pipeline: \(error)")
      return nil
    }
  }
}
