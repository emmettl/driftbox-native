#if os(Android) || os(Linux)
  import CGLES
  import DriftboxGPU

  final class GLESBuffer: GPUBuffer {
    let name: GLuint
    let length: Int
    private let binding: GLenum

    init(bytes: UnsafeRawBufferPointer, kind: GPUBufferKind) throws {
      var made: GLuint = 0
      glGenBuffers(1, &made)
      name = made
      length = bytes.count
      binding = GLenum(kind == .index ? GL_ELEMENT_ARRAY_BUFFER : GL_ARRAY_BUFFER)
      glBindBuffer(binding, name)
      glBufferData(binding, max(1, bytes.count), bytes.baseAddress, GLenum(GL_DYNAMIC_DRAW))
      try GLES.check("making a buffer of \(bytes.count) bytes")
    }

    deinit {
      var doomed = name
      glDeleteBuffers(1, &doomed)
    }

    func update(_ bytes: UnsafeRawBufferPointer) throws {
      guard bytes.count <= length else {
        throw GPUError("\(bytes.count) bytes do not fit in a buffer of \(length)")
      }
      glBindBuffer(binding, name)
      glBufferSubData(binding, 0, bytes.count, bytes.baseAddress)
      try GLES.check("writing a buffer")
    }
  }

  final class GLESTexture: GPUTexture {
    let name: GLuint
    let width: Int
    let height: Int
    /// Whether it holds BGRA, read through a swizzle, rather than the RGBA a target is drawn in.
    private let bgra: Bool

    init(width: Int, height: Int, pixels: UnsafeRawBufferPointer?, bgra: Bool) throws {
      var made: GLuint = 0
      glGenTextures(1, &made)
      name = made
      self.width = width
      self.height = height
      self.bgra = bgra
      glBindTexture(GLenum(GL_TEXTURE_2D), name)
      // The one sampler every backend reads through: linear, clamped at the edges, no mipmaps.
      glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
      glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
      glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
      glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
      if bgra {
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_SWIZZLE_R), GL_BLUE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_SWIZZLE_B), GL_RED)
      }
      // Rows as given: the first is at the start of the texture, which is where a texture
      // coordinate of zero reads, and so at the top.
      glTexImage2D(
        GLenum(GL_TEXTURE_2D), 0, GL_RGBA8, GLsizei(width), GLsizei(height), 0, GLenum(GL_RGBA),
        GLenum(GL_UNSIGNED_BYTE), pixels?.baseAddress)
      try GLES.check("making a \(width) by \(height) texture")
    }

    deinit {
      var doomed = name
      glDeleteTextures(1, &doomed)
    }

    func update(_ pixels: UnsafeRawBufferPointer) throws {
      guard pixels.count >= width * height * 4 else {
        throw GPUError("\(pixels.count) bytes are not \(width) by \(height) pixels")
      }
      glBindTexture(GLenum(GL_TEXTURE_2D), name)
      if bgra {
        glTexSubImage2D(
          GLenum(GL_TEXTURE_2D), 0, 0, 0, GLsizei(width), GLsizei(height), GLenum(GL_RGBA),
          GLenum(GL_UNSIGNED_BYTE), pixels.baseAddress)
      } else {
        // A target's colour holds RGBA, so BGRA written into it is turned round first.
        var rgba = [UInt8](pixels.prefix(width * height * 4))
        GLES.swapRedAndBlue(&rgba)
        rgba.withUnsafeBytes {
          glTexSubImage2D(
            GLenum(GL_TEXTURE_2D), 0, 0, 0, GLsizei(width), GLsizei(height), GLenum(GL_RGBA),
            GLenum(GL_UNSIGNED_BYTE), $0.baseAddress)
        }
      }
      try GLES.check("writing a texture")
    }
  }

  /// A framebuffer: a colour texture to sample afterwards, and 32-bit float depth.
  final class GLESTarget: GPUTarget {
    let framebuffer: GLuint
    let width: Int
    let height: Int
    let colourTexture: GLESTexture
    private let depth: GLuint
    var colour: any GPUTexture { colourTexture }

    init(width: Int, height: Int) throws {
      colourTexture = try GLESTexture(width: width, height: height, pixels: nil, bgra: false)
      self.width = width
      self.height = height
      var madeDepth: GLuint = 0
      glGenRenderbuffers(1, &madeDepth)
      depth = madeDepth
      glBindRenderbuffer(GLenum(GL_RENDERBUFFER), depth)
      glRenderbufferStorage(
        GLenum(GL_RENDERBUFFER), GLenum(GL_DEPTH_COMPONENT32F), GLsizei(width), GLsizei(height))
      var madeFramebuffer: GLuint = 0
      glGenFramebuffers(1, &madeFramebuffer)
      framebuffer = madeFramebuffer
      glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
      glFramebufferTexture2D(
        GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), colourTexture.name, 0)
      glFramebufferRenderbuffer(
        GLenum(GL_FRAMEBUFFER), GLenum(GL_DEPTH_ATTACHMENT), GLenum(GL_RENDERBUFFER), depth)
      let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
      guard status == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
        throw GPUError("a \(width) by \(height) target is not complete (0x\(String(status, radix: 16)))")
      }
    }

    deinit {
      var doomedFramebuffer = framebuffer
      glDeleteFramebuffers(1, &doomedFramebuffer)
      var doomedDepth = depth
      glDeleteRenderbuffers(1, &doomedDepth)
    }
  }
#endif
