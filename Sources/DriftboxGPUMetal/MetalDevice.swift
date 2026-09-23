#if canImport(Metal)
  import DriftboxGPU
  import Metal

  /// `GPUDevice` on Metal: the scenes' GPU on the Mac and iOS.
  ///
  /// The shaders are the Metal Shading Language `scripts/shaders.mjs` writes, compiled here when a
  /// pipeline is made, as the Direct3D backend compiles its HLSL. Everything is drawn on one queue,
  /// so a pass, a buffer written again and a read all happen in the order they were asked for.
  public final class MetalDevice: GPUDevice {
    public var backend: GPUBackend { .metal }
    public let device: any MTLDevice
    let queue: any MTLCommandQueue
    /// The one sampler every texture is read through: linear, clamped at the edges, as Direct3D's.
    let sampler: any MTLSamplerState
    /// Compiled programs by name: a pipeline made twice from one program compiles it once.
    var libraries: [String: (vertex: any MTLFunction, fragment: any MTLFunction)] = [:]

    /// Where vertex buffer `slot` is bound. Metal has one table of buffers for uniforms and vertex
    /// data both, and the generated shaders read uniform block `n` at `buffer(n)`; the vertex data
    /// goes well above them.
    static let vertexBufferBase = 16

    /// The system's GPU, or an error on a machine with none.
    public convenience init() throws {
      guard let device = MTLCreateSystemDefaultDevice() else { throw GPUError("no Metal device") }
      try self.init(device: device)
    }

    public init(device: any MTLDevice) throws {
      self.device = device
      guard let queue = device.makeCommandQueue() else { throw GPUError("no Metal command queue") }
      self.queue = queue
      let description = MTLSamplerDescriptor()
      description.minFilter = .linear
      description.magFilter = .linear
      description.mipFilter = .linear
      description.sAddressMode = .clampToEdge
      description.tAddressMode = .clampToEdge
      description.rAddressMode = .clampToEdge
      guard let sampler = device.makeSamplerState(descriptor: description) else {
        throw GPUError("no Metal sampler")
      }
      self.sampler = sampler
    }

    public func makeBuffer(_ bytes: UnsafeRawBufferPointer, kind: GPUBufferKind) throws -> any GPUBuffer {
      try MetalBuffer(device: self, bytes: bytes)
    }

    public func makeTexture(width: Int, height: Int, pixels: UnsafeRawBufferPointer?) throws -> any GPUTexture
    {
      let texture = try MetalTexture(device: self, width: width, height: height, renderTarget: false)
      if let pixels { try texture.update(pixels) }
      return texture
    }

    public func makeTarget(width: Int, height: Int) throws -> any GPUTarget {
      try MetalTarget(
        device: self, colour: MetalTexture(device: self, width: width, height: height, renderTarget: true))
    }

    public func makePipeline(_ descriptor: GPUPipelineDescriptor) throws -> any GPUPipeline {
      try MetalPipeline(device: self, descriptor: descriptor)
    }

    public func render(into target: any GPUTarget, clear: GPUClear, _ draw: (any GPUPass) throws -> Void)
      rethrows
    {
      let target = target as! MetalTarget
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = target.colourTexture.texture
      pass.colorAttachments[0].storeAction = .store
      pass.depthAttachment.texture = target.depth
      pass.depthAttachment.storeAction = .store
      if case .colour(let rgba) = clear {
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(
          red: Double(rgba.x), green: Double(rgba.y), blue: Double(rgba.z), alpha: Double(rgba.w))
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
      } else {
        pass.colorAttachments[0].loadAction = .load
        pass.depthAttachment.loadAction = .load
      }
      // A queue that will not give a command buffer or an encoder is a device that has gone; there
      // is nothing to draw with, and nothing a caller could do about it.
      guard let commands = queue.makeCommandBuffer(),
        let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
      else { return }
      defer {
        encoder.endEncoding()
        commands.commit()
      }
      try draw(MetalPass(device: self, encoder: encoder))
    }

    public func readPixels(_ target: any GPUTarget) throws -> [UInt8] {
      let target = target as! MetalTarget
      let row = target.width * 4
      guard let buffer = device.makeBuffer(length: row * target.height, options: .storageModeShared),
        let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
      else { throw GPUError("could not read the target") }
      blit.copy(
        from: target.colourTexture.texture, sourceSlice: 0, sourceLevel: 0,
        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        sourceSize: MTLSize(width: target.width, height: target.height, depth: 1), to: buffer,
        destinationOffset: 0, destinationBytesPerRow: row, destinationBytesPerImage: row * target.height)
      blit.endEncoding()
      // Behind everything drawn into it on the same queue, so waiting for this waits for that.
      commands.commit()
      commands.waitUntilCompleted()
      if let error = commands.error {
        throw GPUError("could not read the target: \(error.localizedDescription)")
      }
      return [UInt8](UnsafeRawBufferPointer(start: buffer.contents(), count: row * target.height))
    }

    /// `bytes` into `resource` in the queue's order: a blit from a copy of them, so a draw already
    /// asked for reads what was there and one asked for next reads this — what Direct3D's
    /// `UpdateSubresource` does, and what writing the resource's memory directly would not.
    func upload(_ bytes: UnsafeRawBufferPointer, _ copy: (any MTLBlitCommandEncoder, any MTLBuffer) -> Void)
      throws
    {
      guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
      guard let staging = device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared),
        let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
      else { throw GPUError("could not write \(bytes.count) bytes to the GPU") }
      copy(blit, staging)
      blit.endEncoding()
      commands.commit()
    }
  }
#endif
