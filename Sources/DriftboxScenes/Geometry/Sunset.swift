#if canImport(Metal)
  import Metal
  import simd

  /// The chillwave scene: a sun with slatted bands, a wireframe floor running to the horizon,
  /// haze. Everything that moves is driven by the audio rather than by a clock — bass drives
  /// the sun and the ground swell, highs the grid's brightness — so the picture is a readout
  /// of the mix and not a screensaver playing alongside it. A finger pulls the floor toward
  /// it, in the vertex shader, so the grid lines stretch around the touch.
  ///
  /// The web puts a `fog` in this scene and no material uses it: three only fogs a
  /// `ShaderMaterial` that asks to be fogged, and neither of these does. So there is none here.
  public final class Sunset: GeometryScene {
    override public class var id: String { "sunset" }
    override public class var name: String { "Sunset" }
    override public class var accent: SIMD3<Float> { SIMD3(120, 255, 230) / 255 }
    override public class var background: SIMD3<Float> { SIMD3(0x0a, 0x04, 0x18) / 255 }

    struct GridUniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var time: Float = 0
      var bass: Float = 0
      var high: Float = 0
      var warp: Float = 0
      var spread: Float = 40
      var touch = SIMD2<Float>(0.5, 0.5)
      var near = SIMD3<Float>(0xff, 0x5f, 0xc8) / 255
      var far = SIMD3<Float>(0x4b, 0xe0, 0xff) / 255
    }

    struct SunUniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var bass: Float = 0
      var top = SIMD3<Float>(0xff, 0xe6, 0x6d) / 255
      var bottom = SIMD3<Float>(0xff, 0x2e, 0x93) / 255
    }

    var grid = GridUniforms()
    var sun = SunUniforms()
    var gridMesh: (positions: MTLBuffer, uvs: MTLBuffer, indices: MTLBuffer, count: Int)!
    var sunMesh: (positions: MTLBuffer, uvs: MTLBuffer, indices: MTLBuffer, count: Int)!
    var gridPipeline: MTLRenderPipelineState!
    var sunPipeline: MTLRenderPipelineState!

    private func upload(_ built: (positions: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32]))
      -> (positions: MTLBuffer, uvs: MTLBuffer, indices: MTLBuffer, count: Int)
    {
      (buffer(built.positions), buffer(built.uvs), buffer(built.indices), built.indices.count)
    }

    override public func build() throws {
      gridMesh = upload(Plane.build(width: 140, height: 140, segments: SIMD2(120, 120)))
      sunMesh = upload(Plane.build(width: 26, height: 26))
      gridPipeline = try pipeline(vertex: "sunsetGridVertex", fragment: "sunsetGridFragment", blend: .normal)
      sunPipeline = try pipeline(vertex: "sunsetSunVertex", fragment: "sunsetSunFragment", blend: .normal)
    }

    override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
      let (bass, high) = input.wideLevels
      let warp = touchEnergy
      grid.time += dt
      grid.bass = Analyser.ease(grid.bass, toward: bass, dt: dt)
      grid.high = Analyser.ease(grid.high, toward: high, dt: dt)
      grid.touch = touchAt
      grid.warp = warp
      // How wide a slice of floor the camera sees, from its own field of view: a phone in
      // portrait sees a narrow one, a desktop window a wide one, and a fixed number is wrong
      // for both.
      grid.spread = 30 * aspect
      sun.bass = Analyser.ease(sun.bass, toward: bass, dt: dt)

      // The camera leans toward the finger, which is most of why the warp reads as depth
      // rather than as a texture effect.
      camera.position.y = 1.15 + bass * 0.22 + warp * 2.2
      camera.position.x += ((touchAt.x - 0.5) * 8.5 * warp - camera.position.x) * min(1, dt * 3)
      camera.target = SIMD3(0, 1.6, -30)

      let projection = camera.projection(aspect: aspect)
      let view = camera.view
      grid.projectionMatrix = projection
      grid.modelViewMatrix = view * modelMatrix(position: SIMD3(0, -0.6, -30), rotationX: -.pi / 2)
      sun.projectionMatrix = projection
      sun.modelViewMatrix =
        view * modelMatrix(position: SIMD3(0, 3.4, -46), scale: 1 + bass * 0.06 + warp * 0.04)
    }

    override public func encode(_ encoder: MTLRenderCommandEncoder) {
      // Furthest first, as three draws its transparent objects.
      draw(encoder, pipeline: sunPipeline, mesh: sunMesh, uniforms: &sun)
      draw(encoder, pipeline: gridPipeline, mesh: gridMesh, uniforms: &grid)
    }

    private func draw<T>(
      _ encoder: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState,
      mesh: (positions: MTLBuffer, uvs: MTLBuffer, indices: MTLBuffer, count: Int), uniforms: inout T
    ) {
      encoder.setRenderPipelineState(pipeline)
      encoder.setVertexBytes(&uniforms, length: MemoryLayout<T>.stride, index: 0)
      encoder.setVertexBuffer(mesh.positions, offset: 0, index: 1)
      encoder.setVertexBuffer(mesh.uvs, offset: 0, index: 2)
      encoder.setFragmentBytes(&uniforms, length: MemoryLayout<T>.stride, index: 0)
      encoder.drawIndexedPrimitives(
        type: .triangle, indexCount: mesh.count, indexType: .uint32, indexBuffer: mesh.indices,
        indexBufferOffset: 0)
    }

    static let source = """

      struct SunsetGridUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float uTime;
        float uBass;
        float uHigh;
        float uWarp;
        float uSpread;
        float2 uTouch;
        float3 uNear;
        float3 uFar;
      };
      struct SunsetGridVarying {
        float4 position [[position]];
        float2 vUv;
        float vDist;
        float vPull;
      };

      vertex SunsetGridVarying sunsetGridVertex(
        uint vid [[vertex_id]], constant SunsetGridUniforms &u [[buffer(0)]],
        constant float3 *positions [[buffer(1)]], constant float2 *uvs [[buffer(2)]]
      ) {
        float uTime = u.uTime, uBass = u.uBass, uWarp = u.uWarp, uSpread = u.uSpread;
        float2 uTouch = u.uTouch;
        SunsetGridVarying out;
        out.vUv = uvs[vid];
        float3 pos = positions[vid];
        // A slow swell in the floor, deeper when the low end is loud: rolling hills rather
        // than a flat plane, so the grid has something to describe.
        float ridge = sin(pos.x * 0.18 + uTime * 0.25) * cos(pos.y * 0.13 - uTime * 0.16);
        pos.z += ridge * (1.1 + uBass * 3.4) * smoothstep(4.0, 40.0, abs(pos.y));
        // The finger: a gaussian well centred on it, so the floor lifts toward the touch and
        // falls away smoothly rather than denting at a point. uSpread is the width of floor
        // the camera can actually see, and the depth range is tight for the same reason.
        float2 target = float2((uTouch.x - 0.5) * uSpread, mix(9.0, 40.0, 1.0 - uTouch.y));
        float d = length(pos.xy - target);
        // Two envelopes, not one, and this is the whole trick. A single gaussian forces a
        // choice: tight enough to keep the horizon, or wide enough to be obvious, never both.
        // So the LIFT stays tight and tall, and a separate, far wider envelope carries a
        // travelling ripple out across the rest of the floor.
        float pull = exp(-d * d / 520.0);
        pos.z += pull * uWarp * 58.0;
        // The wake stays SMALL even though it is wide: the floor sits about half a unit below
        // the camera, and a ripple as tall as the central lift stops reading as a floor at all.
        float wake = exp(-d * d / 5200.0);
        pos.z += sin(d * 0.26 - uTime * 6.0) * wake * uWarp * 4.5;
        // A second, slower wave the other way, so the interference never repeats.
        pos.z += sin(d * 0.11 + uTime * 2.3) * wake * uWarp * 2.2;
        // Lit by the spike AND the wake, so the glow spreads with the disturbance.
        out.vPull = (pull + wake * 0.55) * uWarp;
        out.vDist = length(pos.xy);
        out.position = u.projectionMatrix * u.modelViewMatrix * float4(pos, 1.0);
        return out;
      }

      fragment float4 sunsetGridFragment(
        SunsetGridVarying in [[stage_in]], constant SunsetGridUniforms &u [[buffer(0)]]
      ) {
        // Scroll toward the viewer. The lines come from the fract of the scaled uv, with the
        // width scaled by fwidth so distant lines stay one pixel wide instead of aliasing.
        float2 uv = float2(in.vUv.x * 60.0, in.vUv.y * 60.0 - u.uTime * 1.6);
        float2 grid = abs(fract(uv - 0.5) - 0.5) / fwidth(uv);
        float lines = 1.0 - min(min(grid.x, grid.y), 1.0);
        float fade = 1.0 - smoothstep(0.0, 0.62, in.vUv.y);
        float3 colour = mix(u.uNear, u.uFar, in.vUv.y);
        float glow = lines * fade * (0.55 + u.uHigh * 0.85);
        if (glow < 0.004) discard_fragment();
        // Lit where the finger is, so the warp is visible even on a still floor.
        float3 lit = mix(colour * (0.7 + u.uHigh), float3(1.0, 0.82, 0.42), clamp(in.vPull * 3.0, 0.0, 1.0));
        return float4(lit, glow * (1.0 + in.vPull * 7.0));
      }

      struct SunsetSunUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float uBass;
        float3 uTop;
        float3 uBottom;
      };
      struct SunsetSunVarying {
        float4 position [[position]];
        float2 vUv;
      };

      vertex SunsetSunVarying sunsetSunVertex(
        uint vid [[vertex_id]], constant SunsetSunUniforms &u [[buffer(0)]],
        constant float3 *positions [[buffer(1)]], constant float2 *uvs [[buffer(2)]]
      ) {
        SunsetSunVarying out;
        out.vUv = uvs[vid];
        out.position = u.projectionMatrix * u.modelViewMatrix * float4(positions[vid], 1.0);
        return out;
      }

      fragment float4 sunsetSunFragment(
        SunsetSunVarying in [[stage_in]], constant SunsetSunUniforms &u [[buffer(0)]]
      ) {
        float2 vUv = in.vUv;
        float2 p = vUv * 2.0 - 1.0;
        float r = length(p);
        if (r > 1.0) discard_fragment();
        float3 colour = mix(u.uBottom, u.uTop, vUv.y);
        // The slats. They widen toward the bottom of the disc, which is the detail that makes
        // this read as the genre rather than as a sunset.
        float band = smoothstep(0.0, 1.0, vUv.y);
        float slat = step(0.34 + band * 0.6, fract(vUv.y * 17.0));
        float mask = mix(slat, 1.0, smoothstep(0.42, 0.95, vUv.y));
        float edge = smoothstep(1.0, 0.86, r);
        return float4(colour * (1.0 + u.uBass * 0.7), mask * edge);
      }

      """
  }
#endif
