#if os(Windows)
  import DriftboxGPU
  import WinSDK
  import WinSDK.DirectX

  /// A program compiled for Direct3D, with the states a descriptor asks for.
  final class D3D11Pipeline: GPUPipeline {
    let descriptor: GPUPipelineDescriptor
    let vertexShader: UnsafeMutablePointer<ID3D11VertexShader>
    let pixelShader: UnsafeMutablePointer<ID3D11PixelShader>
    /// Nil for a program that reads no attributes.
    let inputLayout: UnsafeMutablePointer<ID3D11InputLayout>?
    let blendState: UnsafeMutablePointer<ID3D11BlendState>
    let depthState: UnsafeMutablePointer<ID3D11DepthStencilState>
    let rasterizer: UnsafeMutablePointer<ID3D11RasterizerState>
    let topology: D3D_PRIMITIVE_TOPOLOGY

    init(device: D3D11Device, descriptor: GPUPipelineDescriptor) throws {
      if let mismatch = descriptor.mismatch { throw GPUError(mismatch) }
      self.descriptor = descriptor
      let d = device.device
      let program = descriptor.program

      let vertexCode = try Self.compile(program.hlsl.vertex, profile: "vs_5_0", name: "\(program.name).vert")
      defer { D3D11.release(vertexCode) }
      let pixelCode = try Self.compile(program.hlsl.fragment, profile: "ps_5_0", name: "\(program.name).frag")
      defer { D3D11.release(pixelCode) }
      let (vertexBytes, vertexSize) = Self.bytes(vertexCode)
      let (pixelBytes, pixelSize) = Self.bytes(pixelCode)

      var vertexShader: UnsafeMutablePointer<ID3D11VertexShader>?
      var made = d.pointee.lpVtbl.pointee.CreateVertexShader(d, vertexBytes, vertexSize, nil, &vertexShader)
      guard made >= 0, let vertexShader else { throw D3D11.error("\(program.name): no vertex shader", made) }
      var pixelShader: UnsafeMutablePointer<ID3D11PixelShader>?
      made = d.pointee.lpVtbl.pointee.CreatePixelShader(d, pixelBytes, pixelSize, nil, &pixelShader)
      guard made >= 0, let pixelShader else {
        D3D11.release(vertexShader)
        throw D3D11.error("\(program.name): no pixel shader", made)
      }
      self.vertexShader = vertexShader
      self.pixelShader = pixelShader

      // SPIRV-Cross names an attribute at location n `TEXCOORDn`, whatever it was called.
      var elements: [D3D11_INPUT_ELEMENT_DESC] = []
      let semantic = strdup("TEXCOORD")
      defer { free(semantic) }
      for (slot, layout) in descriptor.vertexBuffers.enumerated() {
        for attribute in layout.attributes
        where program.attributes.contains(where: { $0.location == attribute.location }) {
          elements.append(
            D3D11_INPUT_ELEMENT_DESC(
              SemanticName: semantic, SemanticIndex: UINT(attribute.location),
              Format: Self.format(attribute.format),
              InputSlot: UINT(slot), AlignedByteOffset: UINT(attribute.offset),
              InputSlotClass: layout.perInstance
                ? D3D11_INPUT_PER_INSTANCE_DATA : D3D11_INPUT_PER_VERTEX_DATA,
              InstanceDataStepRate: layout.perInstance ? 1 : 0))
        }
      }
      if elements.isEmpty {
        inputLayout = nil
      } else {
        var layout: UnsafeMutablePointer<ID3D11InputLayout>?
        made = d.pointee.lpVtbl.pointee.CreateInputLayout(
          d, &elements, UINT(elements.count), vertexBytes, vertexSize, &layout)
        guard made >= 0, let layout else {
          D3D11.release(pixelShader)
          D3D11.release(vertexShader)
          throw D3D11.error("\(program.name): the vertex layout does not fit", made)
        }
        inputLayout = layout
      }

      var blend = D3D11_BLEND_DESC()
      var target = D3D11_RENDER_TARGET_BLEND_DESC()
      target.RenderTargetWriteMask = UINT8(D3D11_COLOR_WRITE_ENABLE_ALL.rawValue)
      switch descriptor.blend {
      case .none:
        target.BlendEnable = false
      case .normal:
        target.BlendEnable = true
        target.SrcBlend = D3D11_BLEND_SRC_ALPHA
        target.DestBlend = D3D11_BLEND_INV_SRC_ALPHA
        target.SrcBlendAlpha = D3D11_BLEND_ONE
        target.DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA
      case .additive:
        target.BlendEnable = true
        target.SrcBlend = D3D11_BLEND_SRC_ALPHA
        target.DestBlend = D3D11_BLEND_ONE
        target.SrcBlendAlpha = D3D11_BLEND_ONE
        target.DestBlendAlpha = D3D11_BLEND_ONE
      case .multiply:
        target.BlendEnable = true
        target.SrcBlend = D3D11_BLEND_DEST_COLOR
        target.DestBlend = D3D11_BLEND_ZERO
        target.SrcBlendAlpha = D3D11_BLEND_ZERO
        target.DestBlendAlpha = D3D11_BLEND_ONE
      }
      target.BlendOp = D3D11_BLEND_OP_ADD
      target.BlendOpAlpha = D3D11_BLEND_OP_ADD
      blend.RenderTarget.0 = target
      var blendState: UnsafeMutablePointer<ID3D11BlendState>?
      made = d.pointee.lpVtbl.pointee.CreateBlendState(d, &blend, &blendState)
      guard made >= 0, let blendState else { throw D3D11.error("\(program.name): no blend state", made) }
      self.blendState = blendState

      var depth = D3D11_DEPTH_STENCIL_DESC()
      depth.DepthEnable = WindowsBool(descriptor.depth != .none)
      depth.DepthWriteMask =
        descriptor.depth == .testAndWrite ? D3D11_DEPTH_WRITE_MASK_ALL : D3D11_DEPTH_WRITE_MASK_ZERO
      depth.DepthFunc = D3D11_COMPARISON_LESS
      var depthState: UnsafeMutablePointer<ID3D11DepthStencilState>?
      made = d.pointee.lpVtbl.pointee.CreateDepthStencilState(d, &depth, &depthState)
      guard made >= 0, let depthState else { throw D3D11.error("\(program.name): no depth state", made) }
      self.depthState = depthState

      // The layer's front is three's, counter-clockwise as it appears; Direct3D's is clockwise.
      var raster = D3D11_RASTERIZER_DESC()
      raster.FillMode = D3D11_FILL_SOLID
      raster.FrontCounterClockwise = true
      raster.CullMode =
        switch descriptor.cull {
        case .none: D3D11_CULL_NONE
        case .back: D3D11_CULL_BACK
        case .front: D3D11_CULL_FRONT
        }
      raster.DepthClipEnable = true
      var rasterizer: UnsafeMutablePointer<ID3D11RasterizerState>?
      made = d.pointee.lpVtbl.pointee.CreateRasterizerState(d, &raster, &rasterizer)
      guard made >= 0, let rasterizer else { throw D3D11.error("\(program.name): no rasterizer state", made) }
      self.rasterizer = rasterizer

      topology =
        switch descriptor.primitive {
        case .triangles: D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST
        case .triangleStrip: D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP
        case .lines: D3D11_PRIMITIVE_TOPOLOGY_LINELIST
        case .lineStrip: D3D11_PRIMITIVE_TOPOLOGY_LINESTRIP
        }
    }

    deinit {
      D3D11.release(rasterizer)
      D3D11.release(depthState)
      D3D11.release(blendState)
      D3D11.release(inputLayout)
      D3D11.release(pixelShader)
      D3D11.release(vertexShader)
    }

    static func format(_ format: GPUVertexFormat) -> DXGI_FORMAT {
      switch format {
      case .float: DXGI_FORMAT_R32_FLOAT
      case .float2: DXGI_FORMAT_R32G32_FLOAT
      case .float3: DXGI_FORMAT_R32G32B32_FLOAT
      case .float4: DXGI_FORMAT_R32G32B32A32_FLOAT
      }
    }

    /// HLSL to bytecode, with the compiler's own words when it will not.
    static func compile(_ source: String, profile: String, name: String) throws -> UnsafeMutablePointer<
      ID3DBlob
    > {
      var code: UnsafeMutablePointer<ID3DBlob>?
      var errors: UnsafeMutablePointer<ID3DBlob>?
      let flags = UINT(D3DCOMPILE_OPTIMIZATION_LEVEL3)
      let result = source.withCString { text in
        D3DCompile(text, SIZE_T(strlen(text)), name, nil, nil, "main", profile, flags, 0, &code, &errors)
      }
      defer { D3D11.release(errors) }
      guard result >= 0, let code else {
        let message = errors.map { blob -> String in
          let (bytes, size) = Self.bytes(blob)
          return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(size)), as: UTF8.self)
        }
        throw GPUError("\(name) did not compile: \(message ?? "no reason given")")
      }
      return code
    }

    static func bytes(_ blob: UnsafeMutablePointer<ID3DBlob>) -> (UnsafeMutableRawPointer?, SIZE_T) {
      (blob.pointee.lpVtbl.pointee.GetBufferPointer(blob), blob.pointee.lpVtbl.pointee.GetBufferSize(blob))
    }
  }

  /// A pass's draws, into whatever `D3D11Device.render` bound.
  ///
  /// Direct3D sets a vertex buffer's stride with the buffer, where the other backends take it from
  /// the pipeline; so the pass remembers what is bound, and binds it again when the pipeline changes.
  final class D3D11Pass: GPUPass {
    let device: D3D11Device
    private var context: UnsafeMutablePointer<ID3D11DeviceContext> { device.context }
    private var strides: [UINT] = []
    private var bound: [Int: D3D11Buffer] = [:]

    init(device: D3D11Device) { self.device = device }

    func setPipeline(_ pipeline: any GPUPipeline) {
      let pipeline = pipeline as! D3D11Pipeline
      context.pointee.lpVtbl.pointee.VSSetShader(context, pipeline.vertexShader, nil, 0)
      context.pointee.lpVtbl.pointee.PSSetShader(context, pipeline.pixelShader, nil, 0)
      context.pointee.lpVtbl.pointee.IASetInputLayout(context, pipeline.inputLayout)
      context.pointee.lpVtbl.pointee.IASetPrimitiveTopology(context, pipeline.topology)
      var factor: [Float] = [1, 1, 1, 1]
      context.pointee.lpVtbl.pointee.OMSetBlendState(context, pipeline.blendState, &factor, 0xFFFF_FFFF)
      context.pointee.lpVtbl.pointee.OMSetDepthStencilState(context, pipeline.depthState, 0)
      context.pointee.lpVtbl.pointee.RSSetState(context, pipeline.rasterizer)
      strides = pipeline.descriptor.vertexBuffers.map { UINT($0.stride) }
      for (slot, buffer) in bound { bind(buffer, slot: slot) }
    }

    func setUniforms(_ bytes: UnsafeRawBufferPointer, binding: Int) {
      guard let buffer = device.constantBuffer(binding: binding, size: bytes.count) else { return }
      var mapped = D3D11_MAPPED_SUBRESOURCE()
      let resource = D3D11.resource(buffer)
      guard
        context.pointee.lpVtbl.pointee.Map(context, resource, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped) >= 0,
        let data = mapped.pData
      else { return }
      let rounded = (bytes.count + 15) / 16 * 16
      data.initializeMemory(as: UInt8.self, repeating: 0, count: rounded)
      if let base = bytes.baseAddress { data.copyMemory(from: base, byteCount: bytes.count) }
      context.pointee.lpVtbl.pointee.Unmap(context, resource, 0)
      var buffers: [UnsafeMutablePointer<ID3D11Buffer>?] = [buffer]
      context.pointee.lpVtbl.pointee.VSSetConstantBuffers(context, UINT(binding), 1, &buffers)
      context.pointee.lpVtbl.pointee.PSSetConstantBuffers(context, UINT(binding), 1, &buffers)
    }

    func setVertexBuffer(_ buffer: any GPUBuffer, slot: Int) {
      let buffer = buffer as! D3D11Buffer
      bound[slot] = buffer
      bind(buffer, slot: slot)
    }

    private func bind(_ buffer: D3D11Buffer, slot: Int) {
      var buffers: [UnsafeMutablePointer<ID3D11Buffer>?] = [buffer.buffer]
      var stride: [UINT] = [slot < strides.count ? strides[slot] : 0]
      var offset: [UINT] = [0]
      context.pointee.lpVtbl.pointee.IASetVertexBuffers(context, UINT(slot), 1, &buffers, &stride, &offset)
    }

    func setTexture(_ texture: any GPUTexture, binding: Int) {
      let texture = texture as! D3D11Texture
      var views: [UnsafeMutablePointer<ID3D11ShaderResourceView>?] = [texture.view]
      var samplers: [UnsafeMutablePointer<ID3D11SamplerState>?] = [device.sampler]
      context.pointee.lpVtbl.pointee.PSSetShaderResources(context, UINT(binding), 1, &views)
      context.pointee.lpVtbl.pointee.PSSetSamplers(context, UINT(binding), 1, &samplers)
    }

    func draw(vertexCount: Int, instanceCount: Int) {
      context.pointee.lpVtbl.pointee.DrawInstanced(context, UINT(vertexCount), UINT(instanceCount), 0, 0)
    }

    func drawIndexed(_ indices: any GPUBuffer, count: Int, instanceCount: Int) {
      let indices = indices as! D3D11Buffer
      context.pointee.lpVtbl.pointee.IASetIndexBuffer(context, indices.buffer, DXGI_FORMAT_R32_UINT, 0)
      context.pointee.lpVtbl.pointee.DrawIndexedInstanced(context, UINT(count), UINT(instanceCount), 0, 0, 0)
    }
  }
#endif
