#if os(Windows)
  import DriftboxGPU
  import WinSDK
  import WinSDK.DirectX

  /// `GPUDevice` on Direct3D 11: the scenes' GPU on Windows.
  ///
  /// Direct3D 11 rather than 12 because the scenes ask for nothing 11 cannot do, and 11 does the
  /// bookkeeping — resource states, memory, synchronisation — that 12 hands to its caller. The
  /// shaders are the HLSL `scripts/shaders.mjs` writes, compiled here when a pipeline is made.
  public final class D3D11Device: GPUDevice {
    public enum Driver: Sendable {
      /// The graphics card, and Windows' software rasteriser where there is none.
      case hardware
      /// The software rasteriser, WARP, always: the same pixels on every machine, and a device on a
      /// machine with no graphics card at all — which is what a test wants.
      case software
    }

    public var backend: GPUBackend { .direct3D11 }
    let device: UnsafeMutablePointer<ID3D11Device>
    let context: UnsafeMutablePointer<ID3D11DeviceContext>
    /// The one sampler every texture is read through: linear, clamped at the edges.
    let sampler: UnsafeMutablePointer<ID3D11SamplerState>
    /// Filled, and nothing culled: three draws both faces unless told otherwise, and so does Metal.
    let rasterizer: UnsafeMutablePointer<ID3D11RasterizerState>
    /// Constant buffers by binding and size, each mapped afresh whenever it is set: Direct3D gives
    /// every map a new copy, so a block set once per draw costs no waiting.
    var constants: [Int: [Int: UnsafeMutablePointer<ID3D11Buffer>]] = [:]

    public init(driver: Driver = .hardware) throws {
      var device: UnsafeMutablePointer<ID3D11Device>?
      var context: UnsafeMutablePointer<ID3D11DeviceContext>?
      var levels = [D3D_FEATURE_LEVEL_11_0]
      let drivers =
        driver == .software ? [D3D_DRIVER_TYPE_WARP] : [D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_WARP]
      var result: HRESULT = -1
      for type in drivers {
        result = D3D11CreateDevice(
          nil, type, nil, UINT(D3D11_CREATE_DEVICE_BGRA_SUPPORT.rawValue), &levels, UINT(levels.count),
          UINT(D3D11_SDK_VERSION), &device, nil, &context)
        if result >= 0 { break }
      }
      guard result >= 0, let device, let context else { throw D3D11.error("no Direct3D 11 device", result) }
      self.device = device
      self.context = context

      var description = D3D11_SAMPLER_DESC()
      description.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR
      description.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP
      description.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP
      description.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP
      description.MaxLOD = Float.greatestFiniteMagnitude
      var sampler: UnsafeMutablePointer<ID3D11SamplerState>?
      let made = device.pointee.lpVtbl.pointee.CreateSamplerState(device, &description, &sampler)
      guard made >= 0, let sampler else {
        D3D11.release(context)
        D3D11.release(device)
        throw D3D11.error("no sampler", made)
      }
      self.sampler = sampler

      var raster = D3D11_RASTERIZER_DESC()
      raster.FillMode = D3D11_FILL_SOLID
      raster.CullMode = D3D11_CULL_NONE
      raster.DepthClipEnable = true
      var rasterizer: UnsafeMutablePointer<ID3D11RasterizerState>?
      let rastered = device.pointee.lpVtbl.pointee.CreateRasterizerState(device, &raster, &rasterizer)
      guard rastered >= 0, let rasterizer else {
        D3D11.release(sampler)
        D3D11.release(context)
        D3D11.release(device)
        throw D3D11.error("no rasterizer state", rastered)
      }
      self.rasterizer = rasterizer
    }

    deinit {
      for sizes in constants.values { for buffer in sizes.values { D3D11.release(buffer) } }
      D3D11.release(rasterizer)
      D3D11.release(sampler)
      D3D11.release(context)
      D3D11.release(device)
    }

    public func makeBuffer(_ bytes: UnsafeRawBufferPointer, kind: GPUBufferKind) throws -> any GPUBuffer {
      try D3D11Buffer(device: self, bytes: bytes, kind: kind)
    }

    public func makeTexture(width: Int, height: Int, pixels: UnsafeRawBufferPointer?) throws -> any GPUTexture
    {
      try D3D11Texture(device: self, width: width, height: height, pixels: pixels, renderTarget: false)
    }

    public func makeTarget(width: Int, height: Int) throws -> any GPUTarget {
      try D3D11Target(device: self, width: width, height: height)
    }

    public func makePipeline(_ descriptor: GPUPipelineDescriptor) throws -> any GPUPipeline {
      try D3D11Pipeline(device: self, descriptor: descriptor)
    }

    public func render(into target: any GPUTarget, clear: GPUClear, _ draw: (any GPUPass) throws -> Void)
      rethrows
    {
      let target = target as! D3D11Target
      // A texture still bound to be read cannot be drawn into; nothing is read across passes.
      var none = [UnsafeMutablePointer<ID3D11ShaderResourceView>?](repeating: nil, count: 8)
      context.pointee.lpVtbl.pointee.PSSetShaderResources(context, 0, 8, &none)
      var views: [UnsafeMutablePointer<ID3D11RenderTargetView>?] = [target.renderView]
      context.pointee.lpVtbl.pointee.OMSetRenderTargets(context, 1, &views, target.depthView)
      var viewport = D3D11_VIEWPORT(
        TopLeftX: 0, TopLeftY: 0, Width: Float(target.width), Height: Float(target.height), MinDepth: 0,
        MaxDepth: 1)
      context.pointee.lpVtbl.pointee.RSSetViewports(context, 1, &viewport)
      context.pointee.lpVtbl.pointee.RSSetState(context, rasterizer)
      if case .colour(let rgba) = clear {
        var colour = [rgba.x, rgba.y, rgba.z, rgba.w]
        context.pointee.lpVtbl.pointee.ClearRenderTargetView(context, target.renderView, &colour)
        context.pointee.lpVtbl.pointee.ClearDepthStencilView(
          context, target.depthView, UINT(D3D11_CLEAR_DEPTH.rawValue), 1, 0)
      }
      defer {
        var unbound: [UnsafeMutablePointer<ID3D11RenderTargetView>?] = [nil]
        context.pointee.lpVtbl.pointee.OMSetRenderTargets(context, 1, &unbound, nil)
      }
      try draw(D3D11Pass(device: self))
    }

    public func readPixels(_ target: any GPUTarget) throws -> [UInt8] {
      let target = target as! D3D11Target
      var description = D3D11_TEXTURE2D_DESC()
      description.Width = UINT(target.width)
      description.Height = UINT(target.height)
      description.MipLevels = 1
      description.ArraySize = 1
      description.Format = DXGI_FORMAT_B8G8R8A8_UNORM
      description.SampleDesc = DXGI_SAMPLE_DESC(Count: 1, Quality: 0)
      description.Usage = D3D11_USAGE_STAGING
      description.CPUAccessFlags = UINT(D3D11_CPU_ACCESS_READ.rawValue)
      var staging: UnsafeMutablePointer<ID3D11Texture2D>?
      let made = device.pointee.lpVtbl.pointee.CreateTexture2D(device, &description, nil, &staging)
      guard made >= 0, let staging else { throw D3D11.error("no staging texture", made) }
      defer { D3D11.release(staging) }
      context.pointee.lpVtbl.pointee.CopyResource(
        context, D3D11.resource(staging), D3D11.resource(target.colourTexture.texture))
      var mapped = D3D11_MAPPED_SUBRESOURCE()
      // Waits for the copy, and so for everything drawn before it.
      let map = context.pointee.lpVtbl.pointee.Map(
        context, D3D11.resource(staging), 0, D3D11_MAP_READ, 0, &mapped)
      guard map >= 0, let data = mapped.pData else { throw D3D11.error("could not read the target", map) }
      defer { context.pointee.lpVtbl.pointee.Unmap(context, D3D11.resource(staging), 0) }
      let row = target.width * 4
      var pixels = [UInt8](repeating: 0, count: row * target.height)
      pixels.withUnsafeMutableBytes { out in
        for y in 0..<target.height {
          (out.baseAddress! + y * row).copyMemory(from: data + y * Int(mapped.RowPitch), byteCount: row)
        }
      }
      return pixels
    }

    /// The constant buffer for a block of `size` bytes at `binding`, made the first time it is
    /// asked for. Sized up to whole sixteen-byte registers, as Direct3D insists.
    func constantBuffer(binding: Int, size: Int) -> UnsafeMutablePointer<ID3D11Buffer>? {
      let size = (size + 15) / 16 * 16
      if let known = constants[binding]?[size] { return known }
      var description = D3D11_BUFFER_DESC()
      description.ByteWidth = UINT(size)
      description.Usage = D3D11_USAGE_DYNAMIC
      description.BindFlags = UINT(D3D11_BIND_CONSTANT_BUFFER.rawValue)
      description.CPUAccessFlags = UINT(D3D11_CPU_ACCESS_WRITE.rawValue)
      var buffer: UnsafeMutablePointer<ID3D11Buffer>?
      guard device.pointee.lpVtbl.pointee.CreateBuffer(device, &description, nil, &buffer) >= 0, let buffer
      else {
        return nil
      }
      constants[binding, default: [:]][size] = buffer
      return buffer
    }
  }

  /// The few things every file here says about COM and Direct3D more than once.
  enum D3D11 {
    static func error(_ what: String, _ result: HRESULT) -> GPUError {
      GPUError("\(what) (0x\(String(UInt32(bitPattern: result), radix: 16)))")
    }

    /// Any COM object, let go of. Every Direct3D interface starts with IUnknown's three methods.
    static func release<T>(_ object: UnsafeMutablePointer<T>?) {
      guard let object else { return }
      let unknown = UnsafeMutableRawPointer(object).assumingMemoryBound(to: IUnknown.self)
      _ = unknown.pointee.lpVtbl.pointee.Release(unknown)
    }

    /// A texture or buffer as the `ID3D11Resource` it also is.
    static func resource<T>(_ object: UnsafeMutablePointer<T>) -> UnsafeMutablePointer<ID3D11Resource> {
      UnsafeMutableRawPointer(object).assumingMemoryBound(to: ID3D11Resource.self)
    }
  }
#endif
