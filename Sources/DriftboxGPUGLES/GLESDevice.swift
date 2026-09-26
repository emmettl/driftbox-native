#if os(Android) || os(Linux)
  import CGLES
  import DriftboxGPU

  /// `GPUDevice` on OpenGL ES 3.0: the scenes' GPU on Android, and on Linux, where Mesa's software
  /// rasteriser gives CI a device with no graphics card, as WARP does on Windows.
  ///
  /// OpenGL keeps its state per thread, in a context made current there, so a device is used from
  /// the thread that made it and no other. The shaders are the GLSL ES `scripts/shaders.mjs`
  /// writes, compiled when a pipeline is made.
  ///
  /// OpenGL's framebuffers start at the bottom, where the other backends' targets start at the top.
  /// So everything is drawn into a target upside down — each vertex shader's y turned over as it is
  /// compiled — and a target's rows then start at the top in memory, as the conventions want: read
  /// back first row first, sampled with texture coordinates from the top left, and `gl_FragCoord`
  /// counting down from the top as it does in Metal and Direct3D. The one place that is not a
  /// target, a window, is shown by turning its frame over on the way to it.
  ///
  /// Colour is BGRA everywhere else and RGBA in OpenGL ES 3.0, which has no BGRA texture without an
  /// extension. A texture made from BGRA pixels is stored as given and read through a swizzle that
  /// swaps red and blue; a target stores what its shaders write, and is swapped as it is read back.
  public final class GLESDevice: GPUDevice {
    public var backend: GPUBackend { .openGLES }
    let display: EGLDisplay
    let context: EGLContext
    /// A one-pixel surface for the context to be current on when drawing only into targets.
    let offscreen: EGLSurface
    let config: EGLConfig
    /// The one vertex array everything is drawn through, set up again for each draw.
    private var vertexArray: GLuint = 0
    /// Uniform buffers by binding, each the size of the largest block of any program made so far.
    private var uniforms: [Int: GLuint] = [:]
    var largestBlock = 16
    /// What a pass has set, which stays set across passes as it does on the other backends.
    var pipeline: GLESPipeline?
    var vertexBuffers: [Int: GLESBuffer] = [:]
    /// Attribute locations enabled for the last draw, disabled when the next does not use them.
    private var enabled: Set<GLuint> = []

    /// A context on the system's default display, current on this thread, drawing off screen.
    public init() throws {
      // The default display; EGL_NO_DISPLAY, which is null, when there is none.
      guard let display = eglGetDisplay(nil) else {
        throw GLES.eglError("no EGL display")
      }
      guard eglInitialize(display, nil, nil) == EGL_TRUE else { throw GLES.eglError("EGL would not start") }
      #if os(Android)
        let surfaces = EGL_PBUFFER_BIT | EGL_WINDOW_BIT
      #else
        // Linux currently draws offscreen. Mesa's surfaceless platform has no window configs.
        let surfaces = EGL_PBUFFER_BIT
      #endif
      let wanted: [EGLint] = [
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, surfaces,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE,
      ]
      var config: EGLConfig?
      var count: EGLint = 0
      guard eglChooseConfig(display, wanted, &config, 1, &count) == EGL_TRUE, count > 0, let config else {
        throw GLES.eglError("no EGL configuration for OpenGL ES 3.0")
      }
      let version: [EGLint] = [EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE]
      guard let context = eglCreateContext(display, config, nil, version) else {
        throw GLES.eglError("no OpenGL ES 3.0 context")
      }
      let size: [EGLint] = [EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE]
      guard let offscreen = eglCreatePbufferSurface(display, config, size) else {
        eglDestroyContext(display, context)
        throw GLES.eglError("no surface to draw off screen on")
      }
      guard eglMakeCurrent(display, offscreen, offscreen, context) == EGL_TRUE else {
        eglDestroySurface(display, offscreen)
        eglDestroyContext(display, context)
        throw GLES.eglError("the context would not be made current")
      }
      self.display = display
      self.context = context
      self.offscreen = offscreen
      self.config = config
      glGenVertexArrays(1, &vertexArray)
      glBindVertexArray(vertexArray)
      glPixelStorei(GLenum(GL_UNPACK_ALIGNMENT), 4)
      glPixelStorei(GLenum(GL_PACK_ALIGNMENT), 4)
      // Nothing culled, as on the other backends: three draws both faces unless told otherwise.
      glDisable(GLenum(GL_CULL_FACE))
    }

    deinit {
      for buffer in uniforms.values {
        var name = buffer
        glDeleteBuffers(1, &name)
      }
      glDeleteVertexArrays(1, &vertexArray)
      eglMakeCurrent(display, nil, nil, nil)
      eglDestroySurface(display, offscreen)
      eglDestroyContext(display, context)
    }

    /// The version and renderer the context turned out to be, for whoever wants to say so.
    public var renderer: String {
      let name = glGetString(GLenum(GL_RENDERER)).map { String(cString: $0) } ?? "an unknown renderer"
      let version = glGetString(GLenum(GL_VERSION)).map { String(cString: $0) } ?? ""
      return "\(name), \(version)"
    }

    public func makeBuffer(_ bytes: UnsafeRawBufferPointer, kind: GPUBufferKind) throws -> any GPUBuffer {
      try GLESBuffer(bytes: bytes, kind: kind)
    }

    public func makeTexture(width: Int, height: Int, pixels: UnsafeRawBufferPointer?) throws -> any GPUTexture
    {
      try GLESTexture(width: width, height: height, pixels: pixels, bgra: true)
    }

    public func makeTarget(width: Int, height: Int) throws -> any GPUTarget {
      try GLESTarget(width: width, height: height)
    }

    public func makePipeline(_ descriptor: GPUPipelineDescriptor) throws -> any GPUPipeline {
      let pipeline = try GLESPipeline(descriptor: descriptor)
      largestBlock = max(largestBlock, descriptor.program.blocks.map(\.size).max() ?? 0)
      return pipeline
    }

    public func render(into target: any GPUTarget, clear: GPUClear, _ draw: (any GPUPass) throws -> Void)
      rethrows
    {
      let target = target as! GLESTarget
      glBindFramebuffer(GLenum(GL_FRAMEBUFFER), target.framebuffer)
      glViewport(0, 0, GLsizei(target.width), GLsizei(target.height))
      if case .colour(let rgba) = clear {
        // A clear writes only what the masks let through, and a pipeline may have left depth off.
        glDepthMask(GLboolean(GL_TRUE))
        glClearColor(rgba.x, rgba.y, rgba.z, rgba.w)
        glClearDepthf(1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT) | GLbitfield(GL_DEPTH_BUFFER_BIT))
        pipeline?.applyDepth()
      }
      try draw(GLESPass(device: self))
    }

    public func readPixels(_ target: any GPUTarget) throws -> [UInt8] {
      let target = target as! GLESTarget
      glBindFramebuffer(GLenum(GL_FRAMEBUFFER), target.framebuffer)
      var pixels = [UInt8](repeating: 0, count: target.width * target.height * 4)
      // Waits for everything drawn into it. Rows come back from the start of memory, which is the
      // top, since every target is drawn into upside down.
      pixels.withUnsafeMutableBytes {
        glReadPixels(
          0, 0, GLsizei(target.width), GLsizei(target.height), GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE),
          $0.baseAddress)
      }
      try GLES.check("reading the target")
      GLES.swapRedAndBlue(&pixels)
      return pixels
    }

    /// Fill the uniform buffer at `binding` from `bytes`, padded to the largest block there is,
    /// which is at least what any program reads from it.
    func setUniforms(_ bytes: UnsafeRawBufferPointer, binding: Int) {
      if uniforms[binding] == nil {
        var made: GLuint = 0
        glGenBuffers(1, &made)
        uniforms[binding] = made
      }
      let size = max((bytes.count + 15) / 16 * 16, largestBlock)
      var padded = [UInt8](repeating: 0, count: size)
      padded.withUnsafeMutableBytes { $0.copyMemory(from: bytes) }
      glBindBuffer(GLenum(GL_UNIFORM_BUFFER), uniforms[binding]!)
      // Given afresh each time, so that the driver need not wait for a draw still reading the last.
      padded.withUnsafeBytes {
        glBufferData(GLenum(GL_UNIFORM_BUFFER), $0.count, $0.baseAddress, GLenum(GL_DYNAMIC_DRAW))
      }
      glBindBufferBase(GLenum(GL_UNIFORM_BUFFER), GLuint(binding), uniforms[binding]!)
    }

    /// Point every attribute the pipeline reads at the buffer bound for it, as its layout says.
    func prepareDraw() {
      guard let pipeline else { return }
      var now: Set<GLuint> = []
      for (slot, layout) in pipeline.descriptor.vertexBuffers.enumerated() {
        guard let buffer = vertexBuffers[slot] else { continue }
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), buffer.name)
        for attribute in layout.attributes {
          let location = GLuint(attribute.location)
          glEnableVertexAttribArray(location)
          glVertexAttribPointer(
            location, GLint(attribute.format.size / 4), GLenum(GL_FLOAT), GLboolean(GL_FALSE),
            GLsizei(layout.stride), UnsafeRawPointer(bitPattern: attribute.offset))
          glVertexAttribDivisor(location, layout.perInstance ? 1 : 0)
          now.insert(location)
        }
      }
      for location in enabled.subtracting(now) { glDisableVertexAttribArray(location) }
      enabled = now
    }
  }

  /// The few things every file here says about OpenGL more than once.
  enum GLES {
    static func eglError(_ what: String) -> GPUError {
      GPUError("\(what) (EGL 0x\(String(eglGetError(), radix: 16)))")
    }

    /// An error if OpenGL has one waiting, having made it forget it.
    static func check(_ what: String) throws {
      let error = glGetError()
      guard error != GLenum(GL_NO_ERROR) else { return }
      throw GPUError("\(what) failed (GL 0x\(String(error, radix: 16)))")
    }

    /// RGBA to BGRA, or back: the same swap either way.
    static func swapRedAndBlue(_ pixels: inout [UInt8]) {
      pixels.withUnsafeMutableBufferPointer { bytes in
        var at = 0
        while at + 3 < bytes.count {
          bytes.swapAt(at, at + 2)
          at += 4
        }
      }
    }
  }
#endif
