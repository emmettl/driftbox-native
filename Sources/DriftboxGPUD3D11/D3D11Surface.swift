#if os(Windows)
  import DriftboxGPU
  import WinSDK
  import WinSDK.DirectX

  extension D3D11Device {
    /// A window's surface: a flip-model swap chain of two BGRA buffers, the size given.
    public func makeSurface(window: HWND, width: Int, height: Int) throws -> any GPUSurface {
      try D3D11Surface(device: self, window: window, width: width, height: height)
    }
  }

  /// A window's swap chain. Flip model, which is what Windows composes without a copy, and which
  /// wants the target bound again every frame — as `D3D11Device.render` does anyway.
  final class D3D11Surface: GPUSurface {
    private unowned let device: D3D11Device
    private let swapChain: UnsafeMutablePointer<IDXGISwapChain1>
    private var current: D3D11Target?
    private(set) var width: Int
    private(set) var height: Int

    init(device: D3D11Device, window: HWND, width: Int, height: Int) throws {
      self.device = device
      self.width = max(1, width)
      self.height = max(1, height)
      // The factory that made the device's adapter, which is the one a swap chain for it must come from.
      let d = device.device
      var dxgiDevice: UnsafeMutableRawPointer?
      var iid = IID_IDXGIDevice
      var result = d.pointee.lpVtbl.pointee.QueryInterface(d, &iid, &dxgiDevice)
      guard result >= 0, let dxgiDevice else { throw D3D11.error("no DXGI device", result) }
      let asDevice = dxgiDevice.assumingMemoryBound(to: IDXGIDevice.self)
      defer { D3D11.release(asDevice) }
      var adapter: UnsafeMutablePointer<IDXGIAdapter>?
      result = asDevice.pointee.lpVtbl.pointee.GetAdapter(asDevice, &adapter)
      guard result >= 0, let adapter else { throw D3D11.error("no adapter", result) }
      defer { D3D11.release(adapter) }
      var factory: UnsafeMutableRawPointer?
      var factoryIID = IID_IDXGIFactory2
      result = adapter.pointee.lpVtbl.pointee.GetParent(adapter, &factoryIID, &factory)
      guard result >= 0, let factory else { throw D3D11.error("no DXGI factory", result) }
      let asFactory = factory.assumingMemoryBound(to: IDXGIFactory2.self)
      defer { D3D11.release(asFactory) }

      var description = DXGI_SWAP_CHAIN_DESC1()
      description.Width = UINT(self.width)
      description.Height = UINT(self.height)
      description.Format = DXGI_FORMAT_B8G8R8A8_UNORM
      description.SampleDesc = DXGI_SAMPLE_DESC(Count: 1, Quality: 0)
      // Sampled as well as drawn into, so that a surface's target is a target like any other.
      description.BufferUsage = DXGI_USAGE(DXGI_USAGE_RENDER_TARGET_OUTPUT | DXGI_USAGE_SHADER_INPUT)
      description.BufferCount = 2
      description.Scaling = DXGI_SCALING_STRETCH
      description.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD
      description.AlphaMode = DXGI_ALPHA_MODE_IGNORE
      var swapChain: UnsafeMutablePointer<IDXGISwapChain1>?
      let unknown = UnsafeMutableRawPointer(d).assumingMemoryBound(to: IUnknown.self)
      result = asFactory.pointee.lpVtbl.pointee.CreateSwapChainForHwnd(
        asFactory, unknown, window, &description, nil, nil, &swapChain)
      guard result >= 0, let swapChain else { throw D3D11.error("no swap chain", result) }
      self.swapChain = swapChain
    }

    deinit {
      current = nil
      D3D11.release(swapChain)
    }

    func resize(width: Int, height: Int) throws {
      let width = max(1, width)
      let height = max(1, height)
      guard width != self.width || height != self.height else { return }
      // Nothing may hold a buffer while the chain changes them, and DXGI says only "invalid call"
      // when something does, so the likeliest something is named here instead.
      if current != nil, !isKnownUniquelyReferenced(&current) {
        throw GPUError("a target from this surface is still held: let go of it before the window resizes")
      }
      current = nil
      let result = swapChain.pointee.lpVtbl.pointee.ResizeBuffers(
        swapChain, 0, UINT(width), UINT(height), DXGI_FORMAT_UNKNOWN, 0)
      guard result >= 0 else { throw D3D11.error("the swap chain would not resize", result) }
      self.width = width
      self.height = height
    }

    /// Buffer zero, which in Direct3D 11 is always whichever buffer is next to be drawn into.
    func target() throws -> any GPUTarget {
      if let current { return current }
      var buffer: UnsafeMutableRawPointer?
      var iid = IID_ID3D11Texture2D
      let result = swapChain.pointee.lpVtbl.pointee.GetBuffer(swapChain, 0, &iid, &buffer)
      guard result >= 0, let buffer else { throw D3D11.error("no back buffer", result) }
      let texture = try D3D11Texture(
        device: device, owning: buffer.assumingMemoryBound(to: ID3D11Texture2D.self), width: width,
        height: height)
      let target = try D3D11Target(device: device, colour: texture)
      current = target
      return target
    }

    func present() throws {
      let result = swapChain.pointee.lpVtbl.pointee.Present(swapChain, 1, 0)
      // A window that is hidden or covered is not an error; what is drawn is simply not shown.
      guard result >= 0 else { throw D3D11.error("could not present", result) }
    }
  }
#endif
