#if canImport(Metal)
  import Metal
  import simd

  /// Still water, for the darkwave one. Undertow is 82bpm with no snare anywhere, a rimshot,
  /// and more reverb than anything else in the set — a record that is mostly the space around
  /// the hits. Every other scene reads the mix as a LEVEL; this one reads EVENTS. A hit drops
  /// a ring on a black water plane and the ring travels outward and dies; between hits nothing
  /// moves but the drift. The reverb you can hear is the picture: something small happening in
  /// something very big.
  public final class Stillwater: GeometryScene {
    override public class var id: String { "water" }
    override public class var name: String { "Stillwater" }
    override public class var accent: SIMD3<Float> { SIMD3(150, 220, 255) / 255 }
    override public class var background: SIMD3<Float> { SIMD3(0x01, 0x04, 0x0c) / 255 }

    /// Points across the water, per side: dense enough that a ring reads as a ring rather
    /// than as a dotted line.
    static let side = 160
    static let extent: Float = 90
    /// Rings alive at once. Past about a dozen they overlap into noise anyway, and each one
    /// costs a loop iteration per vertex per frame.
    static let ripples = 12

    struct WaterUniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var time: Float = 0
      var bass: Float = 0
      var high: Float = 0
      var warp: Float = 0
      var pixel: Float = 1
      var touch = SIMD2<Float>(0.5, 0.5)
    }

    struct HazeUniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var bass: Float = 0
    }

    var water = WaterUniforms()
    var haze = HazeUniforms()
    /// Each ring is (x, z, age, strength); a dead one has strength 0 and contributes nothing,
    /// so expiry needs no branching in the shader.
    var rings = [SIMD4<Float>](repeating: .zero, count: Stillwater.ripples)
    var points: MTLBuffer!
    var hazeMesh: (positions: MTLBuffer, uvs: MTLBuffer, indices: MTLBuffer, count: Int)!
    var waterPipeline: MTLRenderPipelineState!
    var hazePipeline: MTLRenderPipelineState!
    var onBass = Onset(rise: 1.5, refractory: 0.16, rates: SIMD2(30, 2.5), floor: 0.06)
    var onHigh = Onset(rise: 1.7, refractory: 0.1, rates: SIMD2(30, 2.5), floor: 0.06)
    /// Deterministic placement, so the same track drops rings in the same places twice.
    var roll = Roll(seed: 0.371)
    var nextRing = 0
    var drift: Float = 0

    override public func build() throws {
      var positions: [SIMD3<Float>] = []
      positions.reserveCapacity(Self.side * Self.side)
      // Deterministic scatter, so the surface is the same water every time it is opened.
      var noise = Noise(seed: 20857)
      func jitter() -> Float { noise.next() - 0.5 }
      let step = Self.extent / Float(Self.side - 1)
      for a in 0..<Self.side {
        for b in 0..<Self.side {
          let t = Float(b) / Float(Self.side - 1)
          // Biased away from the camera: the near rows are stretched across most of the screen
          // and the far ones crowded into the horizon, so an even grid would spend most of its
          // points where they cannot be told apart. Scattered off the lattice too — seen at
          // this angle a regular grid collapses into radial spokes converging on the vanishing
          // point, and water is not on a grid anyway.
          positions.append(
            SIMD3(
              (Float(a) / Float(Self.side - 1) - 0.5) * Self.extent + jitter() * step * 2.2, 0,
              -pow(t, 1.55) * Self.extent * 1.35 + 8 + jitter() * step * 2.6))
        }
      }
      points = buffer(positions)
      let plane = Plane.build(width: 420, height: 60)
      hazeMesh = (buffer(plane.positions), buffer(plane.uvs), buffer(plane.indices), plane.indices.count)
      waterPipeline = try pipeline(
        vertex: "stillwaterVertex", fragment: "stillwaterFragment", blend: .additive)
      hazePipeline = try pipeline(
        vertex: "stillwaterHazeVertex", fragment: "stillwaterHazeFragment", blend: .additive)
    }

    override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
      let (bass, high) = input.wideLevels
      water.time += dt
      // Not eased: the surface swell follows the low end loosely and the RINGS carry the
      // transients, so smoothing here costs nothing and keeps the water from jittering.
      water.bass += (bass - water.bass) * min(1, dt * 3)
      water.high += (high - water.high) * min(1, dt * 4)
      water.warp = touchEnergy
      water.touch = touchAt
      water.pixel = input.pixelRatio

      for index in rings.indices where rings[index].w > 0 {
        rings[index].z += dt
        // Dead once the ring has travelled past the far edge or faded out.
        if rings[index].z > 6 { rings[index].w = 0 }
      }
      func spawn(strength: Float, spread: Float) {
        // Kept in the near half: a ring dropped at the far edge is a bright smudge on the
        // horizon by the time it has expanded.
        rings[nextRing] = SIMD4(
          (roll.next() - 0.5) * Self.extent * spread * 0.7, -roll.next() * 42 * spread - 5, 0, strength)
        nextRing = (nextRing + 1) % Self.ripples
      }
      // Kicks land wide and heavy; the rimshot and the top end drop smaller rings nearer.
      let kick = onBass.detect(bass, dt: dt)
      if kick > 0 { spawn(strength: 1.5 + kick * 2.2, spread: 0.8) }
      let tick = onHigh.detect(high, dt: dt)
      if tick > 0 { spawn(strength: 0.5 + tick * 0.9, spread: 0.55) }

      // Low and slow. The camera sits just above the surface so the plane is seen almost edge
      // on, which is what makes it read as water going to a horizon rather than as a field of
      // dots seen from above. Pitched down enough to put the horizon in the upper third:
      // level with the surface is the truer water shot and leaves half the frame empty sky.
      drift += dt * 0.05
      let portrait = aspect < 0.85
      camera.position = SIMD3(
        sin(drift) * 2.2 + (touchAt.x - 0.5) * 3 * touchEnergy, (portrait ? 5.2 : 4.0) + water.bass * 0.6, 12)
      camera.rotation = SIMD3(portrait ? -0.26 : -0.18, 0, sin(drift * 0.6) * 0.012)
      water.projectionMatrix = camera.projection(aspect: aspect)
      water.modelViewMatrix = camera.view
      haze.projectionMatrix = water.projectionMatrix
      // Sat ON the waterline: the plane runs from y=0 upward, so the bright end of the
      // gradient is exactly where the water ends.
      haze.modelViewMatrix = camera.view * modelMatrix(position: SIMD3(0, 30, -118))
      haze.bass = water.bass
    }

    override public func encode(_ encoder: MTLRenderCommandEncoder) {
      // Haze first, as its render order asks.
      encoder.setRenderPipelineState(hazePipeline)
      encoder.setVertexBytes(&haze, length: MemoryLayout<HazeUniforms>.stride, index: 0)
      encoder.setVertexBuffer(hazeMesh.positions, offset: 0, index: 1)
      encoder.setVertexBuffer(hazeMesh.uvs, offset: 0, index: 2)
      encoder.setFragmentBytes(&haze, length: MemoryLayout<HazeUniforms>.stride, index: 0)
      encoder.drawIndexedPrimitives(
        type: .triangle, indexCount: hazeMesh.count, indexType: .uint32, indexBuffer: hazeMesh.indices,
        indexBufferOffset: 0)

      encoder.setRenderPipelineState(waterPipeline)
      encoder.setVertexBytes(&water, length: MemoryLayout<WaterUniforms>.stride, index: 0)
      encoder.setVertexBuffer(points, offset: 0, index: 1)
      rings.withUnsafeBytes { raw in
        encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 4)
      }
      encoder.setFragmentBytes(&water, length: MemoryLayout<WaterUniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Self.side * Self.side)
    }

    static let source = """

      struct StillwaterUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float uTime;
        float uBass;
        float uHigh;
        float uWarp;
        float uPixel;
        float2 uTouch;
      };
      struct StillwaterVarying {
        float4 position [[position]];
        float pointSize [[point_size]];
        float vLift;
        float vFade;
      };

      vertex StillwaterVarying stillwaterVertex(
        uint vid [[vertex_id]], constant StillwaterUniforms &u [[buffer(0)]],
        constant float3 *vertices [[buffer(1)]], constant float4 *uRipples [[buffer(4)]]
      ) {
        float uTime = u.uTime;
        float3 pos = vertices[vid];
        // The idle surface: two long, slow swells crossing. Barely visible, but a dead flat
        // plane of points reads as a texture rather than as water, and the rings landing on
        // something that is already alive is most of what sells them.
        float swell = sin(pos.x * 0.055 + uTime * 0.28) * 0.34 + sin(pos.z * 0.041 - uTime * 0.19) * 0.28;
        pos.y += swell * (0.6 + u.uBass * 1.4);

        float lift = 0.0;
        for (int i = 0; i < \(ripples); i++) {
          float4 r = uRipples[i];
          if (r.w <= 0.0) continue;
          float d = distance(pos.xz, r.xy);
          // Where the front has reached by now, and a narrow band around it. Outside the band
          // the water has not been touched yet or has already settled — which is what makes
          // this a travelling ring and not the whole pond bobbing.
          float front = r.z * 15.0;
          float band = exp(-(d - front) * (d - front) * 0.05);
          lift += sin((d - front) * 1.1) * band * r.w * exp(-r.z * 0.55);
        }
        pos.y += lift;

        // A finger drags a standing swell around with it, so touching the water does the same
        // kind of thing a hit does rather than warping the whole plane.
        float2 finger = float2((u.uTouch.x - 0.5) * \(extent), (0.5 - u.uTouch.y) * \(extent) - 20.0);
        float fd = distance(pos.xz, finger);
        pos.y += exp(-fd * fd * 0.004) * u.uWarp * 3.2 * (0.6 + sin(fd * 0.5 - uTime * 5.0) * 0.4);

        StillwaterVarying out;
        float4 view = u.modelViewMatrix * float4(pos, 1.0);
        out.position = u.projectionMatrix * view;
        // Points shrink with distance like anything else would, and the far edge of the plane
        // has to fade out or the horizon is a hard line of dots.
        float dist = -view.z;
        out.pointSize = clamp(90.0 / dist, 1.0, 5.0) * u.uPixel;
        out.vLift = lift;
        out.vFade = 1.0 - smoothstep(45.0, 130.0, dist);
        return out;
      }

      fragment float4 stillwaterFragment(
        StillwaterVarying in [[stage_in]], float2 pointCoord [[point_coord]],
        constant StillwaterUniforms &u [[buffer(0)]]
      ) {
        // Round points. Without this every "drop" is a square, which at 5px is obvious.
        float2 d = pointCoord - 0.5;
        if (dot(d, d) > 0.25) discard_fragment();
        if (in.vFade < 0.01) discard_fragment();
        // Still water is almost black. A ring passing lifts a point into cold blue-white, so
        // the only bright thing on screen is the thing that just happened.
        float energy = clamp(abs(in.vLift) * 1.5, 0.0, 1.0);
        float3 colour = mix(float3(0.10, 0.16, 0.30), float3(0.70, 0.88, 1.0), energy);
        return float4(
          colour * (0.55 + energy * 1.6 + u.uHigh * 0.25), in.vFade * (0.35 + energy * 0.65));
      }

      struct StillwaterHazeUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float uBass;
      };
      struct StillwaterHazeVarying {
        float4 position [[position]];
        float2 vUv;
      };

      vertex StillwaterHazeVarying stillwaterHazeVertex(
        uint vid [[vertex_id]], constant StillwaterHazeUniforms &u [[buffer(0)]],
        constant float3 *vertices [[buffer(1)]], constant float2 *uvs [[buffer(2)]]
      ) {
        StillwaterHazeVarying out;
        out.vUv = uvs[vid];
        out.position = u.projectionMatrix * u.modelViewMatrix * float4(vertices[vid], 1.0);
        return out;
      }

      fragment float4 stillwaterHazeFragment(
        StillwaterHazeVarying in [[stage_in]], constant StillwaterHazeUniforms &u [[buffer(0)]]
      ) {
        // Brightest at the waterline and gone well before the top of the plane, so it is a band
        // of haze sitting on the horizon rather than a wash over the whole sky.
        float band = pow(1.0 - smoothstep(0.0, 0.55, in.vUv.y), 2.0);
        // A little wider across the middle, which stops it reading as a drawn rectangle.
        band *= 0.55 + 0.45 * sin(in.vUv.x * 3.14159);
        return float4(float3(0.08, 0.16, 0.34) * band * (1.0 + u.uBass * 0.9), band * 0.55);
      }

      """
  }
#endif
