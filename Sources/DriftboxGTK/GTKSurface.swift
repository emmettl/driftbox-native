#if os(Linux)
  import DriftboxGPU
  import DriftboxGPUGLES

  /// GTK schedules the frame; present copies into its framebuffer without owning or swapping it.
  public final class GTKSurface: GPUSurface {
    let device: GLESDevice
    public private(set) var width = 1
    public private(set) var height = 1
    var framebuffer: UInt32 = 0
    private var image: (any GPUTarget)?
    init(device: GLESDevice) { self.device = device }
    public func resize(width: Int, height: Int) throws {
      self.width = max(1, width)
      self.height = max(1, height)
      image = try device.makeTarget(width: self.width, height: self.height)
    }
    public func target() throws -> any GPUTarget {
      if image == nil { try resize(width: width, height: height) }
      return image!
    }
    public func present() throws {
      try device.presentToToolkit(target(), framebuffer: framebuffer, width: width, height: height)
    }
  }
#endif
