#if canImport(Metal)
  import Metal
  import simd

  /// Rings of Saturn. The first scene that is an OBJECT rather than a place: every other one
  /// puts you inside something and this one puts a body in front of you and leaves you
  /// outside it. The rings shimmer on the sixteenths, and the big hits punch holes in the
  /// planet — a white flash, then a dark scar that outlives it by a long way, which is the
  /// Shoemaker-Levy 9 detail worth stealing. Two point clouds and no lines: a gas giant drawn
  /// in wireframe looks like a diagram of a gas giant.
  public final class Saturn: GeometryScene {
    override public class var id: String { "saturn" }
    override public class var name: String { "Saturn" }
    override public class var accent: SIMD3<Float> { SIMD3(150, 220, 255) / 255 }
    override public class var background: SIMD3<Float> { SIMD3(0x03, 0x03, 0x0a) / 255 }

    /// Points on the planet, on a Fibonacci sphere so they are evenly spread rather than
    /// piled up at the poles the way a lat/long grid does.
    static let planetPoints = 14000
    static let planetRadius: Float = 9
    static let ringPoints = 26000
    static let ringInner: Float = 12
    static let ringOuter: Float = 22
    /// Impacts kept at once. Scars outlast flashes by a long way, so this holds more than
    /// there are hits in a bar.
    static let impacts = 10

    struct PlanetUniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var time: Float = 0
      var bass: Float = 0
      var high: Float = 0
      var pixelRatio: Float = 1
    }

    struct RingUniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var time: Float = 0
      var bass: Float = 0
      var hat: Float = 0
      var warp: Float = 0
      var pixelRatio: Float = 1
    }

    var planet = PlanetUniforms()
    /// xyz where an impact landed, w its age in seconds; negative means the slot is empty.
    /// Its own buffer rather than a field of the uniforms: a Swift array in a struct is a
    /// pointer, and what the shader would read is the pointer.
    var impacts = [SIMD4<Float>](repeating: SIMD4(0, 1, 0, -1), count: Saturn.impacts)
    var ring = RingUniforms()
    var planetPositions: MTLBuffer!
    var ringRadii: MTLBuffer!
    var ringPhases: MTLBuffer!
    var ringGrit: MTLBuffer!
    var planetPipeline: MTLRenderPipelineState!
    var ringPipeline: MTLRenderPipelineState!
    var onKick = Onset(rise: 1.55, refractory: 0.22)
    var roll = Roll(seed: 0.613)
    var nextImpact = 0
    var spin: Float = 0

    override public func build() throws {
      // The golden-angle spiral, nudged off itself: evenly spaced is exactly what produces a
      // moire, so the sphere would read as woven fabric rather than as cloud tops. A jitter of
      // a fraction of the spacing kills the interference without clumping the points.
      var positions: [SIMD3<Float>] = []
      positions.reserveCapacity(Self.planetPoints)
      let golden = Float.pi * (3 - Float(5).squareRoot())
      var noise = Noise(seed: 40503)
      func jitter(_ scale: Float) -> Float { (noise.next() - 0.5) * scale }
      for index in 0..<Self.planetPoints {
        let y = min(1, max(-1, 1 - Float(index) / Float(Self.planetPoints - 1) * 2 + jitter(0.02)))
        let radius = (max(0, 1 - y * y)).squareRoot()
        let theta = golden * Float(index) + jitter(0.06)
        positions.append(
          SIMD3(
            cos(theta) * radius * Self.planetRadius, y * Self.planetRadius,
            sin(theta) * radius * Self.planetRadius)
        )
      }
      planetPositions = buffer(positions)

      // Gaps at fixed fractions of the way out: a solid annulus reads as a plate, and the
      // divisions are what make it read as rings, plural.
      var radii: [Float] = []
      var phases: [Float] = []
      var grit: [Float] = []
      var ringNoise = Noise(seed: 88172)
      let gaps: [(Float, Float)] = [(0.28, 0.33), (0.62, 0.66), (0.88, 0.91)]
      for _ in 0..<Self.ringPoints {
        var t = ringNoise.next()
        for (from, to) in gaps where t > from && t < to { t = t < (from + to) / 2 ? from : to }
        radii.append(Self.ringInner + t * (Self.ringOuter - Self.ringInner))
        phases.append(ringNoise.next() * .pi * 2)
        grit.append(ringNoise.next() * 2 - 1)
      }
      ringRadii = buffer(radii)
      ringPhases = buffer(phases)
      ringGrit = buffer(grit)

      planetPipeline = try pipeline(
        vertex: "saturnPlanetVertex", fragment: "saturnPlanetFragment", blend: .normal)
      ringPipeline = try pipeline(
        vertex: "saturnRingVertex", fragment: "saturnRingFragment", blend: .additive)
    }

    override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
      let (bass, high) = input.wideLevels
      planet.time += dt
      planet.bass += (bass - planet.bass) * min(1, dt * 4)
      planet.high += (high - planet.high) * min(1, dt * 5)
      planet.pixelRatio = input.pixelRatio
      ring.time += dt
      ring.bass = planet.bass
      // Snapped up, eased down: the ring shimmer has to arrive with the hat, not swell into
      // it. Smoothing both ways turns a break into a wash.
      ring.hat = high > ring.hat ? high : ring.hat + (high - ring.hat) * min(1, dt * 7)
      ring.warp = touchEnergy
      ring.pixelRatio = input.pixelRatio

      for index in impacts.indices where impacts[index].w >= 0 {
        impacts[index].w += dt
        // Retired once the scar has faded to nothing, not when the flash has.
        if impacts[index].w > 26 { impacts[index].w = -1 }
      }
      if onKick.detect(bass, dt: dt) > 0 {
        // Somewhere on the sphere, biased to the lit side so the flash is actually seen.
        let y = roll.next() * 1.3 - 0.55
        let a = roll.next() * .pi * 2
        let radius = (max(0.01, 1 - y * y)).squareRoot()
        impacts[nextImpact] = SIMD4(cos(a) * radius - 0.35, y, sin(a) * radius + 0.5, 0)
        nextImpact = (nextImpact + 1) % Self.impacts
      }

      // The whole system turns, tilted, and a finger swings the camera round it and lifts the
      // ring plane toward edge-on.
      spin += dt * 0.06
      let system = modelMatrix(
        position: .zero,
        rotation: SIMD3(0.42 - (touchAt.y - 0.5) * 0.7 * touchEnergy, spin, 0.16))
      // Framed against whichever edge is binding. Seen at this tilt the system is as wide as
      // the outer ring and roughly two thirds as tall.
      let orbit = (touchAt.x - 0.5) * 1.6 * touchEnergy
      let distance =
        fitDistance(camera: camera, aspect: aspect, halfWidth: Self.ringOuter, halfHeight: 15) - bass * 1.5
      camera.position = SIMD3(sin(orbit) * distance, 9 + bass * 0.8, cos(orbit) * distance)
      camera.target = .zero
      let modelView = camera.view * system
      planet.projectionMatrix = camera.projection(aspect: aspect)
      planet.modelViewMatrix = modelView
      ring.projectionMatrix = planet.projectionMatrix
      ring.modelViewMatrix = modelView
    }

    override public func encode(_ encoder: MTLRenderCommandEncoder) {
      encoder.setRenderPipelineState(planetPipeline)
      impacts.withUnsafeBytes { raw in
        encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 4)
      }
      encoder.setVertexBytes(&planet, length: MemoryLayout<PlanetUniforms>.stride, index: 0)
      encoder.setFragmentBytes(&planet, length: MemoryLayout<PlanetUniforms>.stride, index: 0)
      encoder.setVertexBuffer(planetPositions, offset: 0, index: 1)
      encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Self.planetPoints)

      // Additive, so where the rings cross in front of the planet they brighten it rather than
      // punching a hole in it — which is what a field of ice does.
      encoder.setRenderPipelineState(ringPipeline)
      encoder.setVertexBytes(&ring, length: MemoryLayout<RingUniforms>.stride, index: 0)
      encoder.setVertexBuffer(ringRadii, offset: 0, index: 1)
      encoder.setVertexBuffer(ringPhases, offset: 0, index: 2)
      encoder.setVertexBuffer(ringGrit, offset: 0, index: 3)
      encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Self.ringPoints)
    }

    static let source = """

      struct SaturnPlanetUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float uTime;
        float uBass;
        float uHigh;
        float uPixelRatio;
      };
      struct SaturnPlanetVarying {
        float4 position [[position]];
        float pointSize [[point_size]];
        float3 vNormal;
        float vFlash;
        float vScar;
      };

      vertex SaturnPlanetVarying saturnPlanetVertex(
        uint vid [[vertex_id]], constant SaturnPlanetUniforms &u [[buffer(0)]],
        constant float3 *positions [[buffer(1)]], constant float4 *uImpacts [[buffer(4)]]
      ) {
        float3 position = positions[vid];
        float3 dir = normalize(position);
        float lift = 0.0, flash = 0.0, scar = 0.0;
        for (int i = 0; i < \(impacts); i++) {
          float4 hit = uImpacts[i];
          if (hit.w < 0.0) continue;
          // Angular distance from the impact point: cheaper than acos and monotonic in it,
          // which is all this needs — the falloff constants are tuned against it.
          float sep = 1.0 - dot(dir, normalize(hit.xyz));
          float age = hit.w;
          // The flash: bright, brief, and spreading outward as a shock front for the first
          // moments so it reads as something arriving rather than a lamp switching on.
          float front = 0.02 + age * 0.35;
          flash += exp(-(sep - front) * (sep - front) * 900.0) * exp(-age * 5.0);
          // The scar: a fixed blot that decays over many seconds.
          float blot = exp(-sep * sep * 260.0);
          scar += blot * exp(-age * 0.18);
          // And the surface itself is thrown up a little where it was hit.
          lift += blot * exp(-age * 1.2) * 0.5;
        }
        float3 pos = position * (1.0 + u.uBass * 0.02 + lift * 0.06);
        SaturnPlanetVarying out;
        out.vNormal = dir;
        out.vFlash = flash;
        out.vScar = min(scar, 1.0);
        float4 view = u.modelViewMatrix * float4(pos, 1.0);
        out.position = u.projectionMatrix * view;
        out.pointSize = clamp(140.0 / -view.z, 1.0, 3.4) * u.uPixelRatio;
        return out;
      }

      fragment float4 saturnPlanetFragment(
        SaturnPlanetVarying in [[stage_in]], float2 pointCoord [[point_coord]],
        constant SaturnPlanetUniforms &u [[buffer(0)]]
      ) {
        float2 d = pointCoord - 0.5;
        if (dot(d, d) > 0.25) discard_fragment();
        // Banded like a gas giant, by latitude: bands rather than a smooth gradient because
        // that is the one cue that says "gas giant" and not "moon".
        float band = 0.5 + 0.5 * sin(in.vNormal.y * 22.0);
        float3 colour = mix(float3(0.82, 0.68, 0.44), float3(0.94, 0.86, 0.66), band);
        // A terminator, so it is lit from somewhere and reads as a sphere. Without this a
        // point cloud on a ball is a flat disc.
        float light = clamp(dot(in.vNormal, normalize(float3(-0.55, 0.35, 0.75))), 0.0, 1.0);
        float shade = 0.06 + pow(light, 0.8) * 0.94;
        // Scars are dark and reddish — a bruise in the cloud tops, not a hole.
        colour = mix(colour, float3(0.30, 0.10, 0.07), in.vScar * 0.85);
        colour += float3(1.0, 0.95, 0.85) * in.vFlash * 2.6;
        float alpha = clamp(shade * 0.85 + in.vFlash + in.vScar * 0.3, 0.0, 1.0);
        return float4(colour * (shade + u.uHigh * 0.12) + float3(in.vFlash), alpha);
      }

      struct SaturnRingUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float uTime;
        float uBass;
        float uHat;
        float uWarp;
        float uPixelRatio;
      };
      struct SaturnRingVarying {
        float4 position [[position]];
        float pointSize [[point_size]];
        float vShine;
        float vRadius;
      };

      vertex SaturnRingVarying saturnRingVertex(
        uint vid [[vertex_id]], constant SaturnRingUniforms &u [[buffer(0)]],
        constant float *aRadius [[buffer(1)]], constant float *aPhase [[buffer(2)]],
        constant float *aGrit [[buffer(3)]]
      ) {
        float radius = aRadius[vid], phase = aPhase[vid], grit = aGrit[vid];
        // Keplerian: the inner ring goes round faster than the outer one. This is the single
        // thing that stops the rings looking like a painted disc.
        float speed = 26.0 / pow(radius, 1.5);
        float angle = phase + u.uTime * speed;
        float r = radius * (1.0 + u.uBass * 0.012);
        // The sixteenths make the ring particles jitter in and out. A break this busy needs
        // somewhere to go that is not brightness.
        r += sin(phase * 40.0 + u.uTime * 9.0) * u.uHat * 0.5 * grit;
        // A finger fans the rings out and thickens them.
        r += u.uWarp * grit * 1.6;
        float3 pos = float3(cos(angle) * r, grit * 0.18 * (1.0 + u.uHat * 2.0 + u.uWarp * 6.0), sin(angle) * r);
        SaturnRingVarying out;
        out.vShine = 0.35 + u.uHat * 0.9;
        out.vRadius = (radius - \(ringInner)) / \(ringOuter - ringInner);
        float4 view = u.modelViewMatrix * float4(pos, 1.0);
        out.position = u.projectionMatrix * view;
        out.pointSize = clamp(90.0 / -view.z, 1.0, 2.6) * u.uPixelRatio;
        return out;
      }

      fragment float4 saturnRingFragment(
        SaturnRingVarying in [[stage_in]], float2 pointCoord [[point_coord]]
      ) {
        float2 d = pointCoord - 0.5;
        if (dot(d, d) > 0.25) discard_fragment();
        // Icier than the planet, and paler further out.
        float3 colour = mix(float3(0.72, 0.66, 0.55), float3(0.86, 0.90, 1.0), in.vRadius);
        return float4(colour * in.vShine, in.vShine * 0.85);
      }

      """
  }
#endif
