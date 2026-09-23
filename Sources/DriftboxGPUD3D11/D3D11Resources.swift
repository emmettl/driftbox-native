#if os(Windows)
  import DriftboxGPU
  import WinSDK
  import WinSDK.DirectX

  final class D3D11Buffer: GPUBuffer {
    let buffer: UnsafeMutablePointer<ID3D11Buffer>
    let length: Int
    private unowned let device: D3D11Device

    init(device: D3D11Device, bytes: UnsafeRawBufferPointer, kind: GPUBufferKind) throws {
      self.device = device
      length = bytes.count
      var description = D3D11_BUFFER_DESC()
      description.ByteWidth = UINT(max(4, bytes.count))
      description.Usage = D3D11_USAGE_DEFAULT
      description.BindFlags = UINT(
        (kind == .vertex ? D3D11_BIND_VERTEX_BUFFER : D3D11_BIND_INDEX_BUFFER).rawValue)
      var data = D3D11_SUBRESOURCE_DATA(pSysMem: bytes.baseAddress, SysMemPitch: 0, SysMemSlicePitch: 0)
      var buffer: UnsafeMutablePointer<ID3D11Buffer>?
      let made = withUnsafePointer(to: &data) { data in
        device.device.pointee.lpVtbl.pointee.CreateBuffer(
          device.device, &description, bytes.isEmpty ? nil : data, &buffer)
      }
      guard made >= 0, let buffer else { throw D3D11.error("no buffer", made) }
      self.buffer = buffer
    }

    deinit { D3D11.release(buffer) }

    func update(_ bytes: UnsafeRawBufferPointer) throws {
      guard bytes.count <= length else { throw GPUError("\(bytes.count) bytes into a buffer of \(length)") }
      guard let base = bytes.baseAddress else { return }
      // A box, so that a shorter update writes only what it has.
      var box = D3D11_BOX(left: 0, top: 0, front: 0, right: UINT(bytes.count), bottom: 1, back: 1)
      device.context.pointee.lpVtbl.pointee.UpdateSubresource(
        device.context, D3D11.resource(buffer), 0, &box, base, 0, 0)
    }
  }

  final class D3D11Texture: GPUTexture {
    let texture: UnsafeMutablePointer<ID3D11Texture2D>
    let view: UnsafeMutablePointer<ID3D11ShaderResourceView>
    let width: Int
    let height: Int
    private unowned let device: D3D11Device

    init(device: D3D11Device, width: Int, height: Int, pixels: UnsafeRawBufferPointer?, renderTarget: Bool)
      throws
    {
      self.device = device
      self.width = width
      self.height = height
      var description = D3D11_TEXTURE2D_DESC()
      description.Width = UINT(width)
      description.Height = UINT(height)
      description.MipLevels = 1
      description.ArraySize = 1
      description.Format = DXGI_FORMAT_B8G8R8A8_UNORM
      description.SampleDesc = DXGI_SAMPLE_DESC(Count: 1, Quality: 0)
      description.Usage = D3D11_USAGE_DEFAULT
      description.BindFlags = UINT(
        D3D11_BIND_SHADER_RESOURCE.rawValue | (renderTarget ? D3D11_BIND_RENDER_TARGET.rawValue : 0))
      var data = D3D11_SUBRESOURCE_DATA(
        pSysMem: pixels?.baseAddress, SysMemPitch: UINT(width * 4), SysMemSlicePitch: 0)
      var texture: UnsafeMutablePointer<ID3D11Texture2D>?
      let made = withUnsafePointer(to: &data) { data in
        device.device.pointee.lpVtbl.pointee.CreateTexture2D(
          device.device, &description, pixels?.baseAddress == nil ? nil : data, &texture)
      }
      guard made >= 0, let texture else { throw D3D11.error("no texture", made) }
      var view: UnsafeMutablePointer<ID3D11ShaderResourceView>?
      let viewed = device.device.pointee.lpVtbl.pointee.CreateShaderResourceView(
        device.device, D3D11.resource(texture), nil, &view)
      guard viewed >= 0, let view else {
        D3D11.release(texture)
        throw D3D11.error("no texture view", viewed)
      }
      self.texture = texture
      self.view = view
    }

    deinit {
      D3D11.release(view)
      D3D11.release(texture)
    }

    func update(_ pixels: UnsafeRawBufferPointer) throws {
      guard pixels.count >= width * height * 4, let base = pixels.baseAddress else {
        throw GPUError("\(pixels.count) bytes for a \(width)×\(height) texture")
      }
      device.context.pointee.lpVtbl.pointee.UpdateSubresource(
        device.context, D3D11.resource(texture), 0, nil, base, UINT(width * 4), 0)
    }
  }

  final class D3D11Target: GPUTarget {
    let width: Int
    let height: Int
    let colourTexture: D3D11Texture
    let renderView: UnsafeMutablePointer<ID3D11RenderTargetView>
    let depthTexture: UnsafeMutablePointer<ID3D11Texture2D>
    let depthView: UnsafeMutablePointer<ID3D11DepthStencilView>
    var colour: any GPUTexture { colourTexture }

    init(device: D3D11Device, width: Int, height: Int) throws {
      self.width = width
      self.height = height
      colourTexture = try D3D11Texture(
        device: device, width: width, height: height, pixels: nil, renderTarget: true)
      var renderView: UnsafeMutablePointer<ID3D11RenderTargetView>?
      let viewed = device.device.pointee.lpVtbl.pointee.CreateRenderTargetView(
        device.device, D3D11.resource(colourTexture.texture), nil, &renderView)
      guard viewed >= 0, let renderView else { throw D3D11.error("no render target", viewed) }

      var description = D3D11_TEXTURE2D_DESC()
      description.Width = UINT(width)
      description.Height = UINT(height)
      description.MipLevels = 1
      description.ArraySize = 1
      description.Format = DXGI_FORMAT_D32_FLOAT
      description.SampleDesc = DXGI_SAMPLE_DESC(Count: 1, Quality: 0)
      description.Usage = D3D11_USAGE_DEFAULT
      description.BindFlags = UINT(D3D11_BIND_DEPTH_STENCIL.rawValue)
      var depthTexture: UnsafeMutablePointer<ID3D11Texture2D>?
      let made = device.device.pointee.lpVtbl.pointee.CreateTexture2D(
        device.device, &description, nil, &depthTexture)
      guard made >= 0, let depthTexture else {
        D3D11.release(renderView)
        throw D3D11.error("no depth buffer", made)
      }
      var depthView: UnsafeMutablePointer<ID3D11DepthStencilView>?
      let depthViewed = device.device.pointee.lpVtbl.pointee.CreateDepthStencilView(
        device.device, D3D11.resource(depthTexture), nil, &depthView)
      guard depthViewed >= 0, let depthView else {
        D3D11.release(depthTexture)
        D3D11.release(renderView)
        throw D3D11.error("no depth view", depthViewed)
      }
      self.renderView = renderView
      self.depthTexture = depthTexture
      self.depthView = depthView
    }

    deinit {
      D3D11.release(depthView)
      D3D11.release(depthTexture)
      D3D11.release(renderView)
    }
  }
#endif
