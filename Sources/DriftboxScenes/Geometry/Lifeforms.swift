#if canImport(Metal)
  import Metal
  import simd

  /// Pulsing spheres, drifting in deep space — the ISDN-era Future Sound of London videos:
  /// organic bodies breathing slowly, wireframe over translucent, nothing quite still and
  /// nothing quite symmetrical. The surfaces are NOT spheres: every vertex is pushed in and
  /// out by layered noise, so the silhouette is always changing and never repeats exactly.
  /// Bass inflates, highs make the surface twitch, a finger drags them toward it.
  public final class Lifeforms: GeometryScene {
    override public class var id: String { "lifeforms" }
    override public class var name: String { "Lifeforms" }
    override public class var accent: SIMD3<Float> { SIMD3(1, 1, 1) }
    override public class var background: SIMD3<Float> { SIMD3(0x04, 0x03, 0x0c) / 255 }

    /// Where the bodies sit, how big, and what colour. Hand-placed rather than random: a
    /// random cluster looks like a mistake, and the depth ordering is what gives the scene
    /// somewhere to be.
    struct Body {
      var position: SIMD3<Float>
      var size: Float
      var seed: Float
      var inner: SIMD3<Float>
      var rim: SIMD3<Float>
    }

    static func colour(_ hex: UInt32) -> SIMD3<Float> {
      SIMD3(Float((hex >> 16) & 0xff), Float((hex >> 8) & 0xff), Float(hex & 0xff)) / 255
    }

    static let bodies: [Body] = [
      Body(position: SIMD3(0, 0.2, -4), size: 1.5, seed: 0, inner: colour(0x2a0f4d), rim: colour(0xff5fc8)),
      Body(
        position: SIMD3(-3.4, 1.1, -8), size: 1.1, seed: 3.7, inner: colour(0x08303d), rim: colour(0x4be0ff)),
      Body(
        position: SIMD3(3.6, -0.6, -9), size: 1.35, seed: 8.1, inner: colour(0x3d1030), rim: colour(0xffb02e)),
      Body(
        position: SIMD3(-1.6, -1.8, -13), size: 2.1, seed: 12.4, inner: colour(0x101a45),
        rim: colour(0x8a6bff)),
      Body(
        position: SIMD3(4.4, 2.3, -16), size: 1.7, seed: 17.9, inner: colour(0x2c0a2a), rim: colour(0xff2e93)),
      Body(
        position: SIMD3(-5.2, -0.4, -19), size: 2.4, seed: 21.3, inner: colour(0x062c33),
        rim: colour(0x5ff0d0)),
      Body(
        position: SIMD3(1.2, 3.1, -23), size: 2, seed: 26.8, inner: colour(0x1a0b3a), rim: colour(0xc46bff)),
    ]

    struct Uniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var normalMatrix = matrix_identity_float4x4
      var time: Float = 0
      var bass: Float = 0
      var high: Float = 0
      var warp: Float = 0
      var seed: Float = 0
      var pull = SIMD3<Float>(0, 0, 0)
      var inner = SIMD3<Float>(0, 0, 0)
      var rim = SIMD3<Float>(1, 1, 1)
    }

    var uniforms = [Uniforms]()
    var spin = [SIMD2<Float>](repeating: .zero, count: Lifeforms.bodies.count)
    var positions: MTLBuffer!
    var count = 0
    var pipelineState: MTLRenderPipelineState!
    var drift: Float = 0

    override public func build() throws {
      // Detail 5: enough that the noise reads as a surface rather than as facets, and cheap
      // enough to run seven of.
      let mesh = Icosahedron.build(radius: 1, detail: 5)
      positions = buffer(mesh)
      count = mesh.count
      uniforms = Self.bodies.map { body in
        var one = Uniforms()
        one.time = body.seed
        one.seed = body.seed
        one.inner = body.inner
        one.rim = body.rim
        return one
      }
      pipelineState = try pipeline(vertex: "lifeformsVertex", fragment: "lifeformsFragment", blend: .additive)
    }

    /// How far apart the bodies sit, given the shape of the screen. The cluster is hand-placed
    /// about twice as wide as it is tall, which frames well in landscape and badly on a phone;
    /// squeezing it horizontally and stretching it vertically is cheaper than solving it with
    /// camera distance alone.
    static func spread(aspect: Float) -> SIMD2<Float> {
      aspect >= 0.85 ? SIMD2(1, 1) : SIMD2(0.6, 2.5)
    }

    override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
      let (bass, high) = input.wideLevels
      let warp = touchEnergy
      let spread = Self.spread(aspect: aspect)
      drift += dt * 0.08

      // A slow wander, so it never settles into a still frame, plus a lean toward the finger
      // and a push back on the kick.
      camera.position.x +=
        (sin(drift) * 1.4 + (touchAt.x - 0.5) * 5 * warp - camera.position.x) * min(1, dt * 1.6)
      camera.position.y +=
        (cos(drift * 0.7) * 0.9 + (touchAt.y - 0.5) * 3 * warp - camera.position.y) * min(1, dt * 1.6)
      // Pull back on a tall screen: the same composition that works in landscape falls apart
      // turned ninety degrees.
      camera.position.z = (aspect < 0.85 ? 7.2 : 5.5) - bass * 0.6
      camera.target = SIMD3(0, 0.4, -12)
      let projection = camera.projection(aspect: aspect)
      let view = camera.view

      for index in uniforms.indices {
        let body = Self.bodies[index]
        uniforms[index].time += dt
        uniforms[index].bass = Analyser.ease(uniforms[index].bass, toward: bass, dt: dt, fall: 2.4)
        uniforms[index].high = Analyser.ease(uniforms[index].high, toward: high, dt: dt, fall: 5)
        uniforms[index].warp = warp
        // The finger, put into the scene at this body's depth so the pull is toward a point in
        // space rather than toward the camera plane; relative to the body, since the shader
        // works in object space.
        uniforms[index].pull = SIMD3(
          (touchAt.x - 0.5) * 9, (touchAt.y - 0.5) * 7, -body.position.z * 0.15)
        // Everything turns, slowly, at its own rate and on its own axis: uniform rotation would
        // make seven bodies look like one object.
        spin[index].y += dt * (0.05 + body.seed * 0.004)
        spin[index].x += dt * 0.021
        let place = SIMD3(
          body.position.x * spread.x,
          body.position.y * spread.y + sin(uniforms[index].time * 0.31 + body.seed) * 0.35,
          body.position.z)
        let scale = body.size * (1 + bass * 0.1)
        let model =
          modelMatrix(position: place, rotation: SIMD3(spin[index].x, spin[index].y, 0))
          * simd_float4x4(diagonal: SIMD4(scale, scale, scale, 1))
        uniforms[index].projectionMatrix = projection
        uniforms[index].modelViewMatrix = view * model
        // For a rotation and a uniform scale the inverse transpose is the rotation itself, and
        // the shader normalises what comes out.
        uniforms[index].normalMatrix = view * model
      }
    }

    override public func encode(_ encoder: MTLRenderCommandEncoder) {
      encoder.setRenderPipelineState(pipelineState)
      encoder.setVertexBuffer(positions, offset: 0, index: 1)
      for index in uniforms.indices {
        encoder.setVertexBytes(&uniforms[index], length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms[index], length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
      }
    }

    static let source = """

      struct LifeformsUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float4x4 normalMatrix;
        float uTime;
        float uBass;
        float uHigh;
        float uWarp;
        float uSeed;
        float3 uPull;
        float3 uInner;
        float3 uRim;
      };
      struct LifeformsVarying {
        float4 position [[position]];
        float3 vNormal;
        float3 vView;
        float vBulge;
      };

      // Cheap 3D value noise. Not the good kind, but this runs per vertex per frame, and the
      // difference is invisible once three octaves are layered and the whole thing is moving.
      static float3 lifeformsHash3(float3 p) {
        p = float3(dot(p, float3(127.1, 311.7, 74.7)),
                   dot(p, float3(269.5, 183.3, 246.1)),
                   dot(p, float3(113.5, 271.9, 124.6)));
        return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
      }
      static float lifeformsNoise(float3 p) {
        float3 i = floor(p);
        float3 f = fract(p);
        float3 u = f * f * (3.0 - 2.0 * f);
        return mix(
          mix(mix(dot(lifeformsHash3(i + float3(0,0,0)), f - float3(0,0,0)),
                  dot(lifeformsHash3(i + float3(1,0,0)), f - float3(1,0,0)), u.x),
              mix(dot(lifeformsHash3(i + float3(0,1,0)), f - float3(0,1,0)),
                  dot(lifeformsHash3(i + float3(1,1,0)), f - float3(1,1,0)), u.x), u.y),
          mix(mix(dot(lifeformsHash3(i + float3(0,0,1)), f - float3(0,0,1)),
                  dot(lifeformsHash3(i + float3(1,0,1)), f - float3(1,0,1)), u.x),
              mix(dot(lifeformsHash3(i + float3(0,1,1)), f - float3(0,1,1)),
                  dot(lifeformsHash3(i + float3(1,1,1)), f - float3(1,1,1)), u.x), u.y), u.z);
      }

      vertex LifeformsVarying lifeformsVertex(
        uint vid [[vertex_id]], constant LifeformsUniforms &u [[buffer(0)]],
        constant float3 *vertices [[buffer(1)]]
      ) {
        float uTime = u.uTime, uBass = u.uBass, uHigh = u.uHigh, uWarp = u.uWarp, uSeed = u.uSeed;
        float3 pos = vertices[vid];
        float3 n = normalize(pos);
        // Three octaves, each drifting at its own speed so the surface never repeats.
        float slow = lifeformsNoise(n * 1.4 + float3(uSeed, uTime * 0.13, 0.0));
        float mid = lifeformsNoise(n * 3.1 + float3(0.0, uTime * 0.29, uSeed)) * 0.45;
        float fast = lifeformsNoise(n * 7.4 + float3(uTime * 0.6, uSeed, 0.0)) * 0.18;
        // Bass inflates the whole body; highs only reach the fine octave, so hats read as a
        // shiver across the surface rather than as the thing breathing faster.
        float bulge = slow * (0.34 + uBass * 0.72) + mid * (0.2 + uHigh * 0.5) + fast * uHigh * 1.4;
        pos += n * bulge;
        // Dragged toward the finger, and squashed along the way — a body leaning, not a whole
        // object sliding.
        float3 toPull = u.uPull - pos;
        pos += toPull * uWarp * 0.85 * (0.4 + slow * 0.6);
        pos -= n * dot(n, normalize(toPull + float3(0.0001))) * uWarp * 0.3;
        LifeformsVarying out;
        out.vBulge = bulge;
        out.vNormal = normalize((u.normalMatrix * float4(n, 0.0)).xyz);
        float4 mv = u.modelViewMatrix * float4(pos, 1.0);
        out.vView = -mv.xyz;
        out.position = u.projectionMatrix * mv;
        return out;
      }

      fragment float4 lifeformsFragment(
        LifeformsVarying in [[stage_in]], constant LifeformsUniforms &u [[buffer(0)]]
      ) {
        // Fresnel: bright at the silhouette, near-transparent facing you. It is what makes a
        // translucent body read as volume rather than as a flat coloured disc.
        float fres = pow(1.0 - abs(dot(normalize(in.vNormal), normalize(in.vView))), 2.2);
        float3 colour = mix(u.uInner, u.uRim, clamp(fres + in.vBulge * 0.5, 0.0, 1.0));
        float alpha = clamp(fres * 0.9 + 0.06 + u.uBass * 0.12, 0.0, 1.0);
        return float4(colour * (0.8 + u.uBass * 0.9), alpha);
      }

      """
  }
#endif
