#if canImport(Metal)
  import DriftboxGPU
  import Metal

  /// A program compiled for Metal, with the states a descriptor asks for.
  final class MetalPipeline: GPUPipeline {
    let descriptor: GPUPipelineDescriptor
    let state: any MTLRenderPipelineState
    let depthState: any MTLDepthStencilState
    let cull: MTLCullMode
    let primitive: MTLPrimitiveType

    init(device: MetalDevice, descriptor: GPUPipelineDescriptor) throws {
      if let mismatch = descriptor.mismatch { throw GPUError(mismatch) }
      self.descriptor = descriptor
      let program = descriptor.program
      let functions = try Self.functions(program, on: device)

      let description = MTLRenderPipelineDescriptor()
      description.label = program.name
      description.vertexFunction = functions.vertex
      description.fragmentFunction = functions.fragment
      let colour = description.colorAttachments[0]!
      colour.pixelFormat = .bgra8Unorm
      switch descriptor.blend {
      case .none:
        colour.isBlendingEnabled = false
      case .normal:
        colour.isBlendingEnabled = true
        colour.sourceRGBBlendFactor = .sourceAlpha
        colour.destinationRGBBlendFactor = .oneMinusSourceAlpha
        colour.sourceAlphaBlendFactor = .one
        colour.destinationAlphaBlendFactor = .oneMinusSourceAlpha
      case .additive:
        colour.isBlendingEnabled = true
        colour.sourceRGBBlendFactor = .sourceAlpha
        colour.destinationRGBBlendFactor = .one
        colour.sourceAlphaBlendFactor = .one
        colour.destinationAlphaBlendFactor = .one
      }
      colour.rgbBlendOperation = .add
      colour.alphaBlendOperation = .add
      // Every target has depth, used or not, and a pipeline must say what it is drawn with.
      description.depthAttachmentPixelFormat = .depth32Float

      // Only what the program reads, at its location, from the buffer its slot is bound at.
      let vertex = MTLVertexDescriptor()
      var reads = false
      for (slot, layout) in descriptor.vertexBuffers.enumerated() {
        let index = MetalDevice.vertexBufferBase + slot
        vertex.layouts[index].stride = layout.stride
        vertex.layouts[index].stepFunction = layout.perInstance ? .perInstance : .perVertex
        vertex.layouts[index].stepRate = 1
        for attribute in layout.attributes
        where program.attributes.contains(where: { $0.location == attribute.location }) {
          vertex.attributes[attribute.location].format = Self.format(attribute.format)
          vertex.attributes[attribute.location].offset = attribute.offset
          vertex.attributes[attribute.location].bufferIndex = index
          reads = true
        }
      }
      if reads { description.vertexDescriptor = vertex }

      do {
        state = try device.device.makeRenderPipelineState(descriptor: description)
      } catch {
        throw GPUError("\(program.name): no pipeline: \(error.localizedDescription)")
      }

      let depth = MTLDepthStencilDescriptor()
      depth.depthCompareFunction = descriptor.depth == .none ? .always : .less
      depth.isDepthWriteEnabled = descriptor.depth == .testAndWrite
      guard let depthState = device.device.makeDepthStencilState(descriptor: depth) else {
        throw GPUError("\(program.name): no depth state")
      }
      self.depthState = depthState
      // The layer's front is three's, counter-clockwise as it appears; the pass says so, since
      // Metal's own default is clockwise.
      cull =
        switch descriptor.cull {
        case .none: .none
        case .back: .back
        case .front: .front
        }

      primitive =
        switch descriptor.primitive {
        case .triangles: .triangle
        case .triangleStrip: .triangleStrip
        case .lines: .line
        case .lineStrip: .lineStrip
        }
    }

    static func format(_ format: GPUVertexFormat) -> MTLVertexFormat {
      switch format {
      case .float: .float
      case .float2: .float2
      case .float3: .float3
      case .float4: .float4
      }
    }

    /// The program's two stages, compiled once for the device and kept: each stage is a source of
    /// its own, with entry points `<name>Vertex` and `<name>Fragment`.
    static func functions(_ program: ShaderProgram, on device: MetalDevice) throws -> (
      vertex: any MTLFunction, fragment: any MTLFunction
    ) {
      if let known = device.libraries[program.name] { return known }
      let vertex = try compile(program.metal.vertex, entry: "\(program.name)Vertex", on: device)
      let fragment = try compile(program.metal.fragment, entry: "\(program.name)Fragment", on: device)
      device.libraries[program.name] = (vertex, fragment)
      return (vertex, fragment)
    }

    static func compile(_ source: String, entry: String, on device: MetalDevice) throws -> any MTLFunction {
      let library: any MTLLibrary
      do {
        library = try device.device.makeLibrary(source: source, options: nil)
      } catch {
        throw GPUError("\(entry) did not compile: \(error.localizedDescription)")
      }
      guard let function = library.makeFunction(name: entry) else {
        throw GPUError("\(entry) is not in what its source compiled to")
      }
      return function
    }
  }

  /// A pass's draws, into whatever `MetalDevice.render` began. Metal keeps what is set on an
  /// encoder across a change of pipeline, as the contract asks; the pass keeps only what a draw
  /// needs and the encoder does not hold, the pipeline's primitive. Depth and culling are the
  /// encoder's in Metal rather than the pipeline's, so each change of pipeline sets them.
  final class MetalPass: GPUPass {
    private let device: MetalDevice
    private let encoder: any MTLRenderCommandEncoder
    private var primitive: MTLPrimitiveType = .triangle

    init(device: MetalDevice, encoder: any MTLRenderCommandEncoder) {
      self.device = device
      self.encoder = encoder
    }

    func setPipeline(_ pipeline: any GPUPipeline) {
      let pipeline = pipeline as! MetalPipeline
      encoder.setRenderPipelineState(pipeline.state)
      encoder.setDepthStencilState(pipeline.depthState)
      encoder.setFrontFacing(.counterClockwise)
      encoder.setCullMode(pipeline.cull)
      primitive = pipeline.primitive
    }

    func setUniforms(_ bytes: UnsafeRawBufferPointer, binding: Int) {
      // Whole sixteen-byte registers, zeroed past what was given, as the Direct3D backend fills its
      // constant buffers: a block's struct can end before the last register the shader reads.
      var padded = [UInt8](repeating: 0, count: max(16, (bytes.count + 15) / 16 * 16))
      padded.withUnsafeMutableBytes { out in
        if let base = bytes.baseAddress { out.baseAddress!.copyMemory(from: base, byteCount: bytes.count) }
        encoder.setVertexBytes(out.baseAddress!, length: out.count, index: binding)
        encoder.setFragmentBytes(out.baseAddress!, length: out.count, index: binding)
      }
    }

    func setVertexBuffer(_ buffer: any GPUBuffer, slot: Int) {
      let buffer = buffer as! MetalBuffer
      encoder.setVertexBuffer(buffer.buffer, offset: 0, index: MetalDevice.vertexBufferBase + slot)
    }

    func setTexture(_ texture: any GPUTexture, binding: Int) {
      let texture = texture as! MetalTexture
      encoder.setFragmentTexture(texture.texture, index: binding)
      encoder.setFragmentSamplerState(device.sampler, index: binding)
    }

    func draw(vertexCount: Int, instanceCount: Int) {
      encoder.drawPrimitives(
        type: primitive, vertexStart: 0, vertexCount: vertexCount, instanceCount: instanceCount)
    }

    func drawIndexed(_ indices: any GPUBuffer, count: Int, instanceCount: Int) {
      let indices = indices as! MetalBuffer
      encoder.drawIndexedPrimitives(
        type: primitive, indexCount: count, indexType: .uint32, indexBuffer: indices.buffer,
        indexBufferOffset: 0, instanceCount: instanceCount)
    }
  }
#endif
