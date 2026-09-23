#if os(Android)
  import CGLES
  import DriftboxGPU

  extension GLESDevice {
    /// A surface on an Android window, `width` by `height` pixels. The device's context moves onto
    /// it, and back off it when the surface goes; so it is made, drawn into and let go of on the
    /// device's own thread, and there is one at a time.
    public func makeSurface(window: OpaquePointer, width: Int, height: Int) throws -> any GPUSurface {
      try GLESSurface(device: self, window: window, width: width, height: height)
    }
  }

  /// An Android window's EGL surface.
  ///
  /// A frame is drawn into a target, as every target is, upside down; presenting copies it to the
  /// window turned right way up, which is the one place the backend's rows meet OpenGL's own, and
  /// swaps. The swap waits for the display's next refresh, which is what paces a loop that draws,
  /// presents and draws again.
  final class GLESSurface: GPUSurface {
    private unowned let device: GLESDevice
    private let surface: EGLSurface
    private var frame: GLESTarget
    private(set) var width: Int
    private(set) var height: Int

    init(device: GLESDevice, window: OpaquePointer, width: Int, height: Int) throws {
      self.device = device
      guard let surface = eglCreateWindowSurface(device.display, device.config, window, nil) else {
        throw GLES.eglError("no surface on the window")
      }
      guard eglMakeCurrent(device.display, surface, surface, device.context) == EGL_TRUE else {
        eglDestroySurface(device.display, surface)
        throw GLES.eglError("the context would not move onto the window")
      }
      self.surface = surface
      eglSwapInterval(device.display, 1)
      self.width = width
      self.height = height
      frame = try GLESTarget(width: width, height: height)
    }

    deinit {
      eglMakeCurrent(device.display, device.offscreen, device.offscreen, device.context)
      eglDestroySurface(device.display, surface)
    }

    func resize(width: Int, height: Int) throws {
      guard width != self.width || height != self.height else { return }
      frame = try GLESTarget(width: width, height: height)
      self.width = width
      self.height = height
    }

    func target() throws -> any GPUTarget { frame }

    func present() throws {
      glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), frame.framebuffer)
      glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), 0)
      // The frame's first row, at the start of its memory, to the window's top, which in OpenGL's
      // own framebuffer is its last.
      glBlitFramebuffer(
        0, 0, GLint(width), GLint(height), 0, GLint(height), GLint(width), 0,
        GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_NEAREST))
      try GLES.check("showing the frame")
      guard eglSwapBuffers(device.display, surface) == EGL_TRUE else {
        throw GLES.eglError("the window would not show its frame")
      }
    }
  }
#endif
