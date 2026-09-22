#if canImport(Metal)
  import Metal
  import simd

  /// Flying down a wireframe corridor. The Rez one. Hard thin lines, no fill, cyan and
  /// magenta, everything snapping on the beat: sixty-four hexagonal ribs and the rails joining
  /// them, in one line list moved entirely in the vertex shader, surging on every kick.
  public final class Wireframe: GeometryScene {
    override public class var id: String { "wireframe" }
    override public class var name: String { "Wireframe" }
    override public class var accent: SIMD3<Float> { SIMD3(1, 1, 1) }
    override public class var background: SIMD3<Float> { SIMD3(0x03, 0x02, 0x0a) / 255 }

    static let depth: Float = 120
    static let ribs = 64
    static let sides = 6

    struct Uniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var time: Float = 0
      var bass: Float = 0
      var high: Float = 0
      var warp: Float = 0
      var touch = SIMD2<Float>(0.5, 0.5)
      var near = SIMD3<Float>(0x5f, 0xf0, 0xd0) / 255
      var far = SIMD3<Float>(0xc4, 0x3b, 0xff) / 255
    }

    var uniforms = Uniforms()
    var positions: MTLBuffer!
    var depths: MTLBuffer!
    var count = 0
    var lines: MTLRenderPipelineState!
    var travelled: Float = 0

    override public func build() throws {
      var positions: [SIMD3<Float>] = []
      var depths: [Float] = []
      let radius: Float = 9.5
      for index in 0..<Self.ribs {
        let z = Float(index) / Float(Self.ribs) * Self.depth
        for side in 0..<Self.sides {
          for step in [side, side + 1] {
            let a = Float(step) / Float(Self.sides) * .pi * 2
            positions.append(SIMD3(cos(a) * radius, sin(a) * radius, 0))
            depths.append(z)
          }
        }
      }
      // The rails: long lines down the corridor at each corner, which is what sells the speed.
      for side in 0..<Self.sides {
        let a = Float(side) / Float(Self.sides) * .pi * 2
        let corner = SIMD3(cos(a) * radius, sin(a) * radius, 0)
        for index in 0..<(Self.ribs - 1) {
          positions.append(corner)
          positions.append(corner)
          depths.append(Float(index) / Float(Self.ribs) * Self.depth)
          depths.append(Float(index + 1) / Float(Self.ribs) * Self.depth)
        }
      }
      self.positions = buffer(positions)
      self.depths = buffer(depths)
      count = positions.count
      lines = try pipeline(vertex: "wireframeVertex", fragment: "wireframeFragment", blend: .additive)
    }

    override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
      let (bass, high) = input.wideLevels
      let warp = touchEnergy
      // Speed follows the low end, so the corridor surges on every kick.
      travelled += dt * (20 + bass * 34)
      uniforms.time = travelled
      uniforms.bass = Analyser.ease(uniforms.bass, toward: bass, dt: dt, fall: 4.5)
      uniforms.high = Analyser.ease(uniforms.high, toward: high, dt: dt, fall: 6)
      uniforms.warp = warp
      uniforms.touch = touchAt
      // The camera rolls slightly with the finger; small, because a corridor that rolls too
      // far stops reading as a corridor.
      camera.roll += ((touchAt.x - 0.5) * -0.5 * warp - camera.roll) * min(1, dt * 2.5)
      camera.position.x += ((touchAt.x - 0.5) * 2.4 * warp - camera.position.x) * min(1, dt * 3)
      camera.position.y += ((touchAt.y - 0.5) * 1.8 * warp - camera.position.y) * min(1, dt * 3)
      camera.position.z = 3 - bass * 1.2
      uniforms.projectionMatrix = camera.projection(aspect: aspect)
      uniforms.modelViewMatrix = camera.view
    }

    override public func encode(_ encoder: MTLRenderCommandEncoder) {
      encoder.setRenderPipelineState(lines)
      encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
      encoder.setVertexBuffer(positions, offset: 0, index: 1)
      encoder.setVertexBuffer(depths, offset: 0, index: 2)
      encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: count)
    }

    static let source = """

      struct WireframeUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float uTime;
        float uBass;
        float uHigh;
        float uWarp;
        float2 uTouch;
        float3 uNear;
        float3 uFar;
      };
      struct WireframeVarying {
        float4 position [[position]];
        float vFade;
        float vPulse;
      };

      vertex WireframeVarying wireframeVertex(
        uint vid [[vertex_id]], constant WireframeUniforms &u [[buffer(0)]],
        constant float3 *positions [[buffer(1)]], constant float *aDepth [[buffer(2)]]
      ) {
        const float DEPTH = \(depth);
        float3 pos = positions[vid];
        float uTime = u.uTime, uBass = u.uBass, uWarp = u.uWarp;
        float2 uTouch = u.uTouch;
        // Travel. Everything slides toward the camera and wraps at the near end.
        float z = mod(aDepth[vid] + uTime, DEPTH);
        pos.z = z - DEPTH;
        // The corridor breathes on the low end, each rib slightly out of step with its neighbours.
        float phase = z * 0.09;
        float breathe = 1.0 + uBass * 0.42 * (0.6 + 0.4 * sin(phase));
        pos.xy *= breathe;
        // A waist that travels past you: exactly two waves per DEPTH, so it matches across the wrap.
        pos.xy *= 1.0 + sin(z * \(String(format: "%.6f", 2 * Float.pi * 2 / depth))) * 0.17;
        // Steered by the finger, more strongly the further away it is.
        float far = z / DEPTH;
        pos.x += (uTouch.x - 0.5) * uWarp * 78.0 * far * far;
        pos.y += (uTouch.y - 0.5) * uWarp * 56.0 * far * far;
        pos.xy *= 1.0 + sin(z * 0.16 - uTime * 3.0) * uWarp * 0.28;
        WireframeVarying out;
        out.vFade = 1.0 - smoothstep(0.42, 1.0, far);
        out.vPulse = 1.0 - fract(phase * 0.5 - uTime * 0.1);
        out.position = u.projectionMatrix * u.modelViewMatrix * float4(pos, 1.0);
        return out;
      }

      fragment float4 wireframeFragment(WireframeVarying in [[stage_in]], constant WireframeUniforms &u [[buffer(0)]]) {
        if (in.vFade < 0.01) discard_fragment();
        // Two colours down the length, so the corridor has depth cueing beyond brightness.
        float3 colour = mix(u.uFar, u.uNear, in.vFade);
        // Highs run a bright band down the tunnel. Hats become something travelling.
        colour += float3(0.5, 0.9, 1.0) * pow(in.vPulse, 6.0) * u.uHigh * 1.4;
        return float4(colour, in.vFade * (0.85 + u.uHigh * 0.5));
      }

      """
  }
#endif
