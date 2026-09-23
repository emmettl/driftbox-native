#if canImport(Metal) && canImport(QuartzCore)
  import DriftboxGPU
  import Metal
  import QuartzCore

  extension MetalDevice {
    /// A layer's surface: `layer` set up to be drawn into by this device, BGRA, at the size given
    /// in pixels. Whatever holds the layer — a view on the Mac or on iOS — says what size it is.
    public func makeSurface(layer: CAMetalLayer, width: Int, height: Int) throws -> any GPUSurface {
      try MetalSurface(device: self, layer: layer, width: width, height: height)
    }
  }

  /// A `CAMetalLayer`'s drawables, one a frame. Not framebuffer-only, so that a surface's target can
  /// be sampled and read back like any other, as the Direct3D backend's swap chain can; and one
  /// depth buffer for them all, the surface's size.
  final class MetalSurface: GPUSurface {
    private unowned let device: MetalDevice
    private let layer: CAMetalLayer
    private var depth: any MTLTexture
    private var drawable: (any CAMetalDrawable)?
    private var current: MetalTarget?
    private(set) var width: Int
    private(set) var height: Int

    init(device: MetalDevice, layer: CAMetalLayer, width: Int, height: Int) throws {
      self.device = device
      self.layer = layer
      self.width = max(1, width)
      self.height = max(1, height)
      layer.device = device.device
      layer.pixelFormat = .bgra8Unorm
      layer.framebufferOnly = false
      layer.drawableSize = CGSize(width: self.width, height: self.height)
      depth = try MetalTarget.depth(on: device, width: self.width, height: self.height)
    }

    func resize(width: Int, height: Int) throws {
      let width = max(1, width)
      let height = max(1, height)
      guard width != self.width || height != self.height else { return }
      // A drawable of the old size, taken and not yet shown, goes back unshown.
      drawable = nil
      current = nil
      layer.drawableSize = CGSize(width: width, height: height)
      depth = try MetalTarget.depth(on: device, width: width, height: height)
      self.width = width
      self.height = height
    }

    /// The layer's next drawable, taken the first time a frame asks for it: which waits while
    /// every drawable is still on its way to the display, and so paces a loop that presents each.
    func target() throws -> any GPUTarget {
      if let current { return current }
      guard let drawable = layer.nextDrawable() else { throw GPUError("no drawable from the layer") }
      let target = MetalTarget(colour: MetalTexture(device: device, wrapping: drawable.texture), depth: depth)
      self.drawable = drawable
      current = target
      return target
    }

    /// The frame's drawable, shown once everything drawn into it has been. A frame nothing was
    /// drawn into shows nothing new.
    func present() throws {
      defer {
        drawable = nil
        current = nil
      }
      guard let drawable else { return }
      guard let commands = device.queue.makeCommandBuffer() else { throw GPUError("could not present") }
      commands.present(drawable)
      commands.commit()
    }
  }
#endif
