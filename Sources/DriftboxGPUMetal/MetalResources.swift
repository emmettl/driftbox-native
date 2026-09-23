#if canImport(Metal)
  import DriftboxGPU
  import Metal

  /// A buffer in the GPU's own memory, written in the queue's order.
  final class MetalBuffer: GPUBuffer {
    let buffer: any MTLBuffer
    let length: Int
    private unowned let device: MetalDevice

    init(device: MetalDevice, bytes: UnsafeRawBufferPointer) throws {
      self.device = device
      length = bytes.count
      // Metal will not make a buffer of no bytes.
      guard let buffer = device.device.makeBuffer(length: max(4, bytes.count), options: .storageModePrivate)
      else { throw GPUError("no buffer of \(bytes.count) bytes") }
      self.buffer = buffer
      try update(bytes)
    }

    func update(_ bytes: UnsafeRawBufferPointer) throws {
      guard bytes.count <= length else { throw GPUError("\(bytes.count) bytes into a buffer of \(length)") }
      try device.upload(bytes) { blit, staging in
        blit.copy(from: staging, sourceOffset: 0, to: buffer, destinationOffset: 0, size: bytes.count)
      }
    }
  }

  final class MetalTexture: GPUTexture {
    let texture: any MTLTexture
    let width: Int
    let height: Int
    private unowned let device: MetalDevice

    convenience init(device: MetalDevice, width: Int, height: Int, renderTarget: Bool) throws {
      let description = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: max(1, width), height: max(1, height), mipmapped: false)
      description.usage = renderTarget ? [.shaderRead, .renderTarget] : .shaderRead
      description.storageMode = .private
      guard let texture = device.device.makeTexture(descriptor: description) else {
        throw GPUError("no \(width)×\(height) texture")
      }
      self.init(device: device, wrapping: texture)
    }

    /// A texture made elsewhere: a drawable's.
    init(device: MetalDevice, wrapping texture: any MTLTexture) {
      self.device = device
      self.texture = texture
      width = texture.width
      height = texture.height
    }

    func update(_ pixels: UnsafeRawBufferPointer) throws {
      let row = width * 4
      guard pixels.count >= row * height else {
        throw GPUError("\(pixels.count) bytes for a \(width)×\(height) texture")
      }
      try device.upload(UnsafeRawBufferPointer(rebasing: pixels[0..<row * height])) { blit, staging in
        blit.copy(
          from: staging, sourceOffset: 0, sourceBytesPerRow: row, sourceBytesPerImage: row * height,
          sourceSize: MTLSize(width: width, height: height, depth: 1), to: texture, destinationSlice: 0,
          destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
      }
    }
  }

  /// Colour to draw into and sample afterwards, and a depth buffer the same size.
  final class MetalTarget: GPUTarget {
    let colourTexture: MetalTexture
    let depth: any MTLTexture
    var width: Int { colourTexture.width }
    var height: Int { colourTexture.height }
    var colour: any GPUTexture { colourTexture }

    init(device: MetalDevice, colour: MetalTexture) throws {
      colourTexture = colour
      depth = try Self.depth(on: device, width: colour.width, height: colour.height)
    }

    /// A target drawing into `colour` with a depth buffer it shares: a surface's, which keeps one
    /// for every drawable rather than making one each frame.
    init(colour: MetalTexture, depth: any MTLTexture) {
      colourTexture = colour
      self.depth = depth
    }

    static func depth(on device: MetalDevice, width: Int, height: Int) throws -> any MTLTexture {
      let description = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .depth32Float, width: max(1, width), height: max(1, height), mipmapped: false)
      description.usage = .renderTarget
      description.storageMode = .private
      guard let depth = device.device.makeTexture(descriptor: description) else {
        throw GPUError("no depth buffer")
      }
      return depth
    }
  }
#endif
