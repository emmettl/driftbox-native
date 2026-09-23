#if os(Android) || os(Linux)
  import CGLES
  import DriftboxGPU

  /// A program linked from a `ShaderProgram`'s GLSL ES, and the state it draws with.
  ///
  /// GLSL ES 3.0 cannot say in the shader where a uniform block or a sampler is bound, as the other
  /// languages do, so each is bound here by name to the binding the generator recorded.
  final class GLESPipeline: GPUPipeline {
    let descriptor: GPUPipelineDescriptor
    let program: GLuint
    let mode: GLenum

    init(descriptor: GPUPipelineDescriptor) throws {
      if let mismatch = descriptor.mismatch { throw GPUError(mismatch) }
      self.descriptor = descriptor
      let source = descriptor.program
      let vertex = try Self.compile(
        Self.upsideDown(source.essl.vertex), GLenum(GL_VERTEX_SHADER), source.name)
      defer { glDeleteShader(vertex) }
      let fragment = try Self.compile(source.essl.fragment, GLenum(GL_FRAGMENT_SHADER), source.name)
      defer { glDeleteShader(fragment) }
      program = glCreateProgram()
      glAttachShader(program, vertex)
      glAttachShader(program, fragment)
      glLinkProgram(program)
      var linked: GLint = 0
      glGetProgramiv(program, GLenum(GL_LINK_STATUS), &linked)
      guard linked == GL_TRUE else {
        let log = Self.log(program, glGetProgramiv, glGetProgramInfoLog)
        glDeleteProgram(program)
        throw GPUError("\(source.name) did not link: \(log)")
      }
      for block in source.blocks {
        let index = glGetUniformBlockIndex(program, block.name)
        // A block no stage reads is dropped by the linker, and has nowhere to be bound.
        if index != GL_INVALID_INDEX { glUniformBlockBinding(program, index, GLuint(block.binding)) }
      }
      glUseProgram(program)
      for texture in source.textures {
        let location = glGetUniformLocation(program, texture.name)
        if location >= 0 { glUniform1i(location, GLint(texture.binding)) }
      }
      switch descriptor.primitive {
      case .triangles: mode = GLenum(GL_TRIANGLES)
      case .triangleStrip: mode = GLenum(GL_TRIANGLE_STRIP)
      case .lines: mode = GLenum(GL_LINES)
      case .lineStrip: mode = GLenum(GL_LINE_STRIP)
      }
      try GLES.check("making the \(source.name) pipeline")
    }

    deinit { glDeleteProgram(program) }

    /// Everything this pipeline draws with, made OpenGL's current state.
    func apply() {
      glUseProgram(program)
      switch descriptor.blend {
      case .none:
        glDisable(GLenum(GL_BLEND))
      case .normal:
        glEnable(GLenum(GL_BLEND))
        glBlendEquation(GLenum(GL_FUNC_ADD))
        glBlendFuncSeparate(
          GLenum(GL_SRC_ALPHA), GLenum(GL_ONE_MINUS_SRC_ALPHA), GLenum(GL_ONE), GLenum(GL_ONE_MINUS_SRC_ALPHA)
        )
      case .additive:
        glEnable(GLenum(GL_BLEND))
        glBlendEquation(GLenum(GL_FUNC_ADD))
        glBlendFuncSeparate(GLenum(GL_SRC_ALPHA), GLenum(GL_ONE), GLenum(GL_ONE), GLenum(GL_ONE))
      case .multiply:
        glEnable(GLenum(GL_BLEND))
        glBlendEquation(GLenum(GL_FUNC_ADD))
        glBlendFuncSeparate(GLenum(GL_DST_COLOR), GLenum(GL_ZERO), GLenum(GL_ZERO), GLenum(GL_ONE))
      }
      applyDepth()
      // The layer's front is counter-clockwise as a triangle appears on the target. Targets are
      // drawn here upside down, which turns every triangle over, so in OpenGL's own terms that
      // front is clockwise.
      switch descriptor.cull {
      case .none:
        glDisable(GLenum(GL_CULL_FACE))
      case .back:
        glEnable(GLenum(GL_CULL_FACE))
        glFrontFace(GLenum(GL_CW))
        glCullFace(GLenum(GL_BACK))
      case .front:
        glEnable(GLenum(GL_CULL_FACE))
        glFrontFace(GLenum(GL_CW))
        glCullFace(GLenum(GL_FRONT))
      }
    }

    /// Depth tested, nearer winning, and written or not; or neither: set again after a clear,
    /// which needs depth writing on whatever the pipeline wants.
    func applyDepth() {
      switch descriptor.depth {
      case .none:
        glDisable(GLenum(GL_DEPTH_TEST))
        glDepthMask(GLboolean(GL_FALSE))
      case .test, .testAndWrite:
        glEnable(GLenum(GL_DEPTH_TEST))
        glDepthFunc(GLenum(GL_LESS))
        glDepthMask(GLboolean(descriptor.depth == .testAndWrite ? GL_TRUE : GL_FALSE))
      }
    }

    /// `source` with y turned over at the end of `main`, the last function SPIRV-Cross writes: so
    /// that a target is drawn upside down, and its first row in memory is its top.
    static func upsideDown(_ source: String) -> String {
      guard let end = source.lastIndex(of: "}") else { return source }
      return source[..<end] + "    gl_Position.y = -gl_Position.y;\n" + source[end...]
    }

    private static func compile(_ source: String, _ stage: GLenum, _ name: String) throws -> GLuint {
      let shader = glCreateShader(stage)
      source.withCString { text in
        var pointer: UnsafePointer<GLchar>? = text
        glShaderSource(shader, 1, &pointer, nil)
      }
      glCompileShader(shader)
      var compiled: GLint = 0
      glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &compiled)
      guard compiled == GL_TRUE else {
        let log = Self.log(shader, glGetShaderiv, glGetShaderInfoLog)
        glDeleteShader(shader)
        let which = stage == GLenum(GL_VERTEX_SHADER) ? "vertex" : "fragment"
        throw GPUError("\(name)'s \(which) shader did not compile: \(log)")
      }
      return shader
    }

    /// What OpenGL said about a shader or a program.
    private static func log(
      _ object: GLuint,
      _ parameter: (GLuint, GLenum, UnsafeMutablePointer<GLint>?) -> Void,
      _ read: (GLuint, GLsizei, UnsafeMutablePointer<GLsizei>?, UnsafeMutablePointer<GLchar>?) -> Void
    ) -> String {
      var length: GLint = 0
      parameter(object, GLenum(GL_INFO_LOG_LENGTH), &length)
      guard length > 1 else { return "no reason given" }
      var text = [GLchar](repeating: 0, count: Int(length))
      read(object, length, nil, &text)
      return String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
  }

  /// A pass's draws, into whatever `GLESDevice.render` bound. What it sets is kept on the device,
  /// so that it stays set across passes, as it does on the other backends.
  final class GLESPass: GPUPass {
    let device: GLESDevice

    init(device: GLESDevice) { self.device = device }

    func setPipeline(_ pipeline: any GPUPipeline) {
      let pipeline = pipeline as! GLESPipeline
      device.pipeline = pipeline
      pipeline.apply()
    }

    func setUniforms(_ bytes: UnsafeRawBufferPointer, binding: Int) {
      device.setUniforms(bytes, binding: binding)
    }

    func setVertexBuffer(_ buffer: any GPUBuffer, slot: Int) {
      device.vertexBuffers[slot] = (buffer as! GLESBuffer)
    }

    func setTexture(_ texture: any GPUTexture, binding: Int) {
      let texture = texture as! GLESTexture
      glActiveTexture(GLenum(GL_TEXTURE0) + GLenum(binding))
      glBindTexture(GLenum(GL_TEXTURE_2D), texture.name)
    }

    func draw(vertexCount: Int, instanceCount: Int) {
      guard let pipeline = device.pipeline else { return }
      device.prepareDraw()
      glDrawArraysInstanced(pipeline.mode, 0, GLsizei(vertexCount), GLsizei(instanceCount))
    }

    func drawIndexed(_ indices: any GPUBuffer, count: Int, instanceCount: Int) {
      guard let pipeline = device.pipeline else { return }
      device.prepareDraw()
      glBindBuffer(GLenum(GL_ELEMENT_ARRAY_BUFFER), (indices as! GLESBuffer).name)
      glDrawElementsInstanced(
        pipeline.mode, GLsizei(count), GLenum(GL_UNSIGNED_INT), nil, GLsizei(instanceCount))
    }
  }
#endif
