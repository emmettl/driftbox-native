/// Shows a finished frame in a target of another shape: fitted whole with black around it, or
/// filling it and cropped. A scene is framed for the shape it was drawn at, so a preview of a
/// projector's output shows the projector's picture with bars, and a backdrop covers its window.
public final class Presenter {
  private let pipeline: any GPUPipeline
  private let overlayPipeline: any GPUPipeline

  public init(device: any GPUDevice) throws {
    pipeline = try device.makePipeline(GPUPipelineDescriptor(program: .present, primitive: .triangleStrip))
    overlayPipeline = try device.makePipeline(
      GPUPipelineDescriptor(program: .overlay, primitive: .triangleStrip, blend: .normal))
  }

  /// `page` over what `target` already shows, pixel for pixel: an interface drawn on a canvas the
  /// size of the target, over the frame it was presented. The page is what a canvas leaves, its
  /// colour multiplied by its alpha, and goes over as the canvas drew it.
  public func overlay(_ page: any GPUTarget, into target: any GPUTarget, on device: any GPUDevice) {
    device.render(into: target, clear: .none) { pass in
      pass.setPipeline(overlayPipeline)
      pass.setTexture(page.colour, binding: 1)
      pass.draw(vertexCount: 4)
    }
  }

  /// `frame` into `target`, fitted, or `filling` it.
  public func present(
    _ frame: any GPUTarget, into target: any GPUTarget, on device: any GPUDevice, filling: Bool = false
  ) {
    let shape = SIMD2(Float(frame.width), Float(frame.height))
    let room = SIMD2(Float(target.width), Float(target.height))
    var uniforms = PresentUniforms()
    uniforms.scale = filling ? Self.cover(shape, in: room) : Self.fit(shape, in: room)
    device.render(into: target, clear: .colour(SIMD4(0, 0, 0, 1))) { pass in
      pass.setPipeline(pipeline)
      pass.setUniforms(uniforms, binding: 0)
      pass.setTexture(frame.colour, binding: 1)
      pass.draw(vertexCount: 4)
    }
  }

  /// How much of `target` a frame of size `frame` covers on each axis once fitted inside it
  /// without distortion: one on the axis that fills, less than one on the one that is
  /// letterboxed.
  public static func fit(_ frame: SIMD2<Float>, in target: SIMD2<Float>) -> SIMD2<Float> {
    guard frame.x > 0, frame.y > 0, target.x > 0, target.y > 0 else { return .zero }
    let frameAspect = frame.x / frame.y
    let targetAspect = target.x / target.y
    return frameAspect > targetAspect
      ? SIMD2(1, targetAspect / frameAspect) : SIMD2(frameAspect / targetAspect, 1)
  }

  /// The scale that covers `target` with `frame`, cropping whichever way it overhangs, in the
  /// same terms as `fit`.
  public static func cover(_ frame: SIMD2<Float>, in target: SIMD2<Float>) -> SIMD2<Float> {
    guard frame.x > 0, frame.y > 0, target.x > 0, target.y > 0 else { return .zero }
    let frameAspect = frame.x / frame.y
    let targetAspect = target.x / target.y
    return frameAspect > targetAspect
      ? SIMD2(frameAspect / targetAspect, 1) : SIMD2(1, targetAspect / frameAspect)
  }
}
