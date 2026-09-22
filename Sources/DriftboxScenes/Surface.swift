#if canImport(Metal)
  import Metal
  import simd

  /// The web's "material studies": a scene that is one fragment shader over the whole screen,
  /// fed the same handful of numbers. Eight of the web's scenes are written this way, and their
  /// GLSL carries over to Metal almost line for line — so these are the scenes that look exactly
  /// as they do there, uniforms and all. A subclass names its fragment function and supplies its
  /// source; this class keeps the clocks, eases the bands, warps to the touch and counts hits,
  /// as `useSurfaceMaterial` does.
  open class SurfaceScene: Scene {
    open class var id: String { fatalError("a surface scene names itself") }
    open class var name: String { fatalError("a surface scene names itself") }
    open class var accent: SIMD3<Float> { SIMD3(1, 1, 1) }
    /// The MSL fragment function, `fragment float4 <name>(Full in [[stage_in]],
    /// constant SurfaceUniforms &u [[buffer(0)]])`.
    open class var fragmentFunction: String { fatalError("a surface scene names its shader") }
    /// A second layer of instanced quads over the surface — the web's `instancedMesh` of
    /// `planeGeometry` cards — drawn with these functions, if the scene has one. The vertex
    /// function is `vertex Card <name>(uint vid [[vertex_id]], uint iid [[instance_id]],
    /// constant SurfaceUniforms &u [[buffer(0)]], constant float4x4 *instances [[buffer(1)]])`.
    open class var cardFunctions: (vertex: String, fragment: String)? { nil }
    /// The cards' matrices, as the web composes them: translation (x, y, seed), a turn about
    /// z, a scale. Asked for every frame; a scene that lays them out by aspect can.
    open func cards(aspect: Float) -> [simd_float4x4] { [] }

    /// What the shader is given; the layout is `SurfaceUniforms` in `Surface.preamble`.
    struct Uniforms {
      var size = SIMD2<Float>(1, 1)
      var time: Float = 0
      var travel: Float = 0
      var beat: Float = 0
      var scoreBeat: Float = 0
      var bass: Float = 0
      var mid: Float = 0
      var high: Float = 0
      var touch = SIMD3<Float>(0.5, 0.5, 0)
      var hits = (
        SIMD2<Float>(-100, 0), SIMD2<Float>(-100, 0), SIMD2<Float>(-100, 0), SIMD2<Float>(-100, 0),
        SIMD2<Float>(-100, 0), SIMD2<Float>(-100, 0), SIMD2<Float>(-100, 0), SIMD2<Float>(-100, 0)
      )
    }

    let pipeline: MTLRenderPipelineState
    let cardPipeline: MTLRenderPipelineState?
    var uniforms = Uniforms()
    var lastTime: Double?
    /// The finger's last known place, kept after it lifts so the warp eases out where it was.
    var touchAt = SIMD2<Float>(0.5, 0.5)
    var touchEnergy: Float = 0
    /// The hit detector: the mid band's recent level, when it last fired, and the slot to fill.
    var hitPrevious: Float = 0
    var hitLast: Float = -1
    var hitNext = 0

    public required init(device: MTLDevice, library: MTLLibrary) throws {
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = library.makeFunction(name: "fullscreen")
      descriptor.fragmentFunction = library.makeFunction(name: Self.fragmentFunction)
      descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
      pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
      if let functions = Self.cardFunctions {
        let cards = MTLRenderPipelineDescriptor()
        guard let vertex = library.makeFunction(name: functions.vertex),
          let fragment = library.makeFunction(name: functions.fragment)
        else { throw SceneRenderer.SceneError.missingFunction("\(functions)", library.functionNames) }
        cards.vertexFunction = vertex
        cards.fragmentFunction = fragment
        let colour = cards.colorAttachments[0]!
        colour.pixelFormat = .bgra8Unorm
        // three's normal blending: straight alpha over what is there.
        colour.isBlendingEnabled = true
        colour.sourceRGBBlendFactor = .sourceAlpha
        colour.destinationRGBBlendFactor = .oneMinusSourceAlpha
        colour.sourceAlphaBlendFactor = .one
        colour.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        cardPipeline = try device.makeRenderPipelineState(descriptor: cards)
      } else {
        cardPipeline = nil
      }
    }

    public func draw(
      _ input: SceneInput, into target: MTLTexture, size: SIMD2<Int>, commandBuffer: MTLCommandBuffer
    ) {
      advance(input, size: size)
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = target
      pass.colorAttachments[0].loadAction = .dontCare
      pass.colorAttachments[0].storeAction = .store
      guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
      encoder.setRenderPipelineState(pipeline)
      encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      if let cardPipeline {
        var instances = cards(aspect: uniforms.size.x / uniforms.size.y)
        if !instances.isEmpty {
          encoder.setRenderPipelineState(cardPipeline)
          encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
          encoder.setVertexBytes(
            &instances, length: MemoryLayout<simd_float4x4>.stride * instances.count, index: 1)
          encoder.drawPrimitives(
            type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instances.count)
        }
      }
      encoder.endEncoding()
    }

    /// three's `Matrix4.compose`: a translation, a turn about z, a scale.
    public static func compose(x: Float, y: Float, z: Float, angle: Float, scale: SIMD2<Float>)
      -> simd_float4x4
    {
      let c = cos(angle)
      let s = sin(angle)
      return simd_float4x4(
        SIMD4(c * scale.x, s * scale.x, 0, 0),
        SIMD4(-s * scale.y, c * scale.y, 0, 0),
        SIMD4(0, 0, 1, 0),
        SIMD4(x, y, z, 1))
    }

    /// One frame of the web's `useFrame`: the clocks run, the bands ease, the touch warps.
    func advance(_ input: SceneInput, size: SIMD2<Int>) {
      let dt = Float(min(input.time - (lastTime ?? input.time), 0.1))
      lastTime = input.time
      uniforms.size = SIMD2(Float(size.x), Float(size.y))
      uniforms.time += dt
      if input.running {
        uniforms.travel += dt
        uniforms.beat += dt * Float(input.bpm) / 60
        uniforms.scoreBeat = input.scoreBeat.map { Float($0) } ?? uniforms.beat
      }
      uniforms.bass = Analyser.ease(uniforms.bass, toward: input.levels.bass, dt: dt)
      uniforms.mid = Analyser.ease(uniforms.mid, toward: input.levels.mid, dt: dt)
      uniforms.high = Analyser.ease(uniforms.high, toward: input.levels.high, dt: dt, fall: 6)

      // The warp eases in under a finger and out after it lifts, so nothing snaps.
      if let touch = input.touch { touchAt = touch }
      let down: Float = input.touch == nil ? 0 : 1
      let rate: Float = input.touch == nil ? 1.8 : 6
      touchEnergy += (down - touchEnergy) * min(1, min(dt, 0.05) * rate)
      if input.touch == nil, touchEnergy < 0.001 { touchEnergy = 0 }
      uniforms.touch = SIMD3(touchAt.x, touchAt.y, touchEnergy)

      // A rise in the mids is a hit, at most seven a second; the shader is told when and how hard.
      let mid = input.levels.mid
      if input.running, mid - hitPrevious > 0.025, uniforms.time - hitLast > 0.14 {
        let hit = SIMD2<Float>(uniforms.time, min(1, mid * 2))
        withUnsafeMutableBytes(of: &uniforms.hits) { raw in
          raw.storeBytes(
            of: hit, toByteOffset: hitNext * MemoryLayout<SIMD2<Float>>.stride, as: SIMD2<Float>.self)
        }
        hitNext = (hitNext + 1) % 8
        hitLast = uniforms.time
      }
      hitPrevious += (mid - hitPrevious) * min(1, dt * 12)
    }
  }

  extension SurfaceScene {
    /// What every surface fragment sees. The names are the web's, so a scene reads the same in
    /// both languages: `vUv` is the fragment's place on the screen, 0...1 from the bottom left.
    static let preamble = """

      struct SurfaceUniforms {
        float2 size;
        float time;
        float travel;
        float beat;
        float scoreBeat;
        float bass;
        float mid;
        float high;
        float3 touch;
        float2 hits[8];
      };

      static inline float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
      static inline float line(float2 p, float2 a, float2 b) {
        float2 pa = p - a, ba = b - a;
        return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0));
      }
      // GLSL's mod, which floors; Metal's fmod truncates, and they part company below zero.
      static inline float mod(float x, float y) { return x - y * floor(x / y); }
      static inline float2 mod(float2 x, float y) { return x - y * floor(x / y); }
      static inline float3 mod(float3 x, float y) { return x - y * floor(x / y); }
      static inline float2x2 rotation(float c, float s) { return float2x2(float2(c, -s), float2(s, c)); }

      // A card: one of an instanced layer of quads, the web's `planeGeometry(2, 2)`.
      struct Card {
        float4 position [[position]];
        float2 uv;
        float2 vPage;
        float vSeed;
      };
      constant float2 cardCorners[6] = {
        float2(-1, -1), float2(1, -1), float2(1, 1), float2(-1, -1), float2(1, 1), float2(-1, 1)
      };

      """

    /// The uniforms under the web's names, at the top of a fragment, so the body below reads as
    /// its GLSL does.
    static let aliases = """
      float2 vUv = in.uv;
          float2 uSize = u.size; float uTime = u.time; float uTravel = u.travel; float uBeat = u.beat;
          float uScoreBeat = u.scoreBeat; float uBass = u.bass; float uMid = u.mid; float uHigh = u.high;
          float3 uTouch = u.touch; constant float2 *uHits = u.hits;
          (void)uSize; (void)uTime; (void)uTravel; (void)uBeat; (void)uScoreBeat; (void)uBass; (void)uMid;
          (void)uHigh; (void)uTouch; (void)uHits;
      """
  }
#endif
