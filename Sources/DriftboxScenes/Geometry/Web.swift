#if canImport(Metal)
  import Metal
  import simd

  /// The web. Tempest 2000. Not another tunnel: this is a well that narrows to a point and
  /// does not move at all — you look into it, and things travel up the lanes toward you, which
  /// is why it is built from spokes rather than ribs. Sixteen lanes, sixteen logarithmic
  /// bands, so a kick lights one lane and a hat another and the web reads as the *shape* of
  /// the mix rather than as its loudness. A finger is a black hole and the web falls into it.
  public final class Web: GeometryScene {
    override public class var id: String { "web" }
    override public class var name: String { "Web" }
    override public class var accent: SIMD3<Float> { SIMD3(1, 1, 1) }
    override public class var background: SIMD3<Float> { SIMD3(0x03, 0x00, 0x0a) / 255 }

    /// Tempest's own count for a circular web, and conveniently the number of steps in a bar.
    static let lanes = 16
    /// Rings from the rim down to the throat.
    static let rings = 14
    static let rim: Float = 13

    struct Uniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var bands = (
        Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0),
        Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0)
      )
      var time: Float = 0
      var bass: Float = 0
      var high: Float = 0
      var warp: Float = 0
      var eye = SIMD3<Float>(0, 0, 15)
      var ray = SIMD3<Float>(0, 0, -1)
    }

    var uniforms = Uniforms()
    var eased = [Float](repeating: 0, count: Web.lanes)
    var positions: MTLBuffer!
    var lanes: MTLBuffer!
    var ringsBuffer: MTLBuffer!
    var count = 0
    var pipelineState: MTLRenderPipelineState!

    override public func build() throws {
      var positions: [SIMD3<Float>] = []
      var laneOf: [Float] = []
      var ringOf: [Float] = []
      // `ring` runs 0 at the throat to 1 at the rim, and drives both radius and depth — a well
      // rather than a tube, so it narrows away from you instead of running parallel.
      func at(lane: Int, ring: Int) -> SIMD3<Float> {
        let a = Float(lane) / Float(Self.lanes) * .pi * 2
        let t = Float(ring) / Float(Self.rings - 1)
        let radius = Self.rim * (0.06 + 0.94 * t * t)
        return SIMD3(cos(a) * radius, sin(a) * radius, -34 * (1 - t) * (1 - t))
      }
      func push(lane: Int, ring: Int) {
        positions.append(at(lane: lane, ring: ring))
        laneOf.append(Float(lane % Self.lanes))
        ringOf.append(Float(ring) / Float(Self.rings - 1))
      }
      // The spokes. These are what make it a web rather than a tunnel.
      for lane in 0..<Self.lanes {
        for ring in 0..<(Self.rings - 1) {
          push(lane: lane, ring: ring)
          push(lane: lane, ring: ring + 1)
        }
      }
      // And a ring at each depth, closing the lanes into cells.
      for ring in 0..<Self.rings {
        for lane in 0..<Self.lanes {
          push(lane: lane, ring: ring)
          push(lane: lane + 1, ring: ring)
        }
      }
      self.positions = buffer(positions)
      self.lanes = buffer(laneOf)
      ringsBuffer = buffer(ringOf)
      count = positions.count
      pipelineState = try pipeline(vertex: "webVertex", fragment: "webFragment", blend: .additive)
    }

    override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
      let (bass, high) = input.wideLevels
      uniforms.time += dt
      uniforms.bass = Analyser.ease(uniforms.bass, toward: bass, dt: dt, fall: 5)
      uniforms.high = Analyser.ease(uniforms.high, toward: high, dt: dt, fall: 6)
      uniforms.warp = touchEnergy
      // Eased per lane, so a hit blooms and falls away instead of strobing on one frame.
      let bands = input.bands
      for lane in 0..<Self.lanes {
        eased[lane] = Analyser.ease(
          eased[lane], toward: lane < bands.count ? bands[lane] : 0, dt: dt, fall: 4.5)
      }
      withUnsafeMutableBytes(of: &uniforms.bands) { raw in
        for lane in 0..<Self.lanes {
          raw.storeBytes(of: eased[lane], toByteOffset: lane * MemoryLayout<Float>.stride, as: Float.self)
        }
      }

      // Further back on a tall screen: the web is as wide as it is anything, and a portrait
      // phone at the desktop distance puts you so far inside it that the rim is off the edges.
      let portrait = aspect < 0.85
      camera.position = SIMD3(0, 0, (portrait ? 23 : 15) - bass * 1.6)
      camera.roll += dt * 0.05
      uniforms.projectionMatrix = camera.projection(aspect: aspect)
      uniforms.modelViewMatrix = camera.view
      // The eye ray through the fingertip, from the camera itself, so it holds at any fov,
      // aspect or distance — and this camera also rolls.
      uniforms.eye = camera.position
      uniforms.ray = camera.ray(through: touchAt, aspect: aspect)
    }

    override public func encode(_ encoder: MTLRenderCommandEncoder) {
      encoder.setRenderPipelineState(pipelineState)
      encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
      encoder.setVertexBuffer(positions, offset: 0, index: 1)
      encoder.setVertexBuffer(lanes, offset: 0, index: 2)
      encoder.setVertexBuffer(ringsBuffer, offset: 0, index: 3)
      encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: count)
    }

    static let source = """

      struct WebUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float uBands[\(lanes)];
        float uTime;
        float uBass;
        float uHigh;
        float uWarp;
        float3 uEye;
        float3 uRay;
      };
      struct WebVarying {
        float4 position [[position]];
        float vLane;
        float vRing;
        float vHeat;
        float vHole;
      };

      vertex WebVarying webVertex(
        uint vid [[vertex_id]], constant WebUniforms &u [[buffer(0)]],
        constant float3 *vertices [[buffer(1)]], constant float *aLaneIn [[buffer(2)]],
        constant float *aRingIn [[buffer(3)]]
      ) {
        float uBass = u.uBass, uWarp = u.uWarp;
        float3 uEye = u.uEye, uRay = u.uRay;
        float aLane = aLaneIn[vid], aRing = aRingIn[vid];
        float3 pos = vertices[vid];

        // How loud this lane is.
        float heat = u.uBands[int(aLane + 0.5)];
        // The lane swells outward with its own band. This is the readout: a loud lane is
        // physically wider than a quiet one, so the web takes the shape of the mix.
        pos.xy *= 1.0 + heat * 0.55 * aRing;
        // The whole well pumps on the low end.
        pos.xy *= 1.0 + uBass * 0.16;

        // A finger is a black hole, and the web falls into it. In polar coordinates around
        // the finger, because the two things that make this read as gravity — everything
        // falling inward, and the near stuff swirling harder than the far — are a radius term
        // and an angle term, one line each. The hole is the whole LINE OF SIGHT through the
        // fingertip, not a point on one plane: this web is thirty-four units deep.
        float along = (pos.z - uEye.z) / uRay.z;
        float2 finger = uEye.xy + uRay.xy * along;
        float2 rel = pos.xy - finger;
        float r = length(rel);
        float angle = atan2(rel.y, rel.x);
        // Infall, softened at the bottom so the pull is finite at the centre, and capped just
        // short of the full distance so nothing crosses the middle and comes out the far side.
        float pull = min(uWarp * 26.0 / (r + 2.2), r * 0.96);
        float sunk = r - pull;
        // Frame dragging: rotation rises sharply close in, so the web winds into a spiral near
        // the finger and is barely disturbed at the rim.
        angle += uWarp * 5.2 / (r + 1.8);
        pos.xy = finger + float2(cos(angle), sin(angle)) * sunk;
        // And a funnel: the geometry nearest the hole is dragged away down the well.
        pos.z -= uWarp * 14.0 * exp(-r * r * 0.016);

        WebVarying out;
        out.vLane = aLane;
        out.vRing = aRing;
        out.vHeat = heat;
        // How hard this vertex was compressed. Light piles up where the lines bunch, which is
        // the accretion ring, and it costs nothing because the number is already computed.
        out.vHole = pull / max(r, 0.001);
        out.position = u.projectionMatrix * u.modelViewMatrix * float4(pos, 1.0);
        return out;
      }

      // Hue to RGB, so the whole web can cycle through the spectrum rather than crossfading
      // between two chosen colours. Tempest does not have a palette; it has all of them.
      static float3 webHue(float h) {
        float3 k = mod(float3(5.0, 3.0, 1.0) + h * 6.0, 6.0);
        return clamp(min(k, 4.0 - k), 0.0, 1.0);
      }

      fragment float4 webFragment(WebVarying in [[stage_in]], constant WebUniforms &u [[buffer(0)]]) {
        // Hue runs around the web AND drifts with time, so neighbouring lanes are never the
        // same colour and the whole thing cycles.
        float h = fract(in.vLane / \(lanes).0 + u.uTime * 0.06 + in.vRing * 0.15);
        float3 colour = webHue(h);
        // Brightest at the rim, and much brighter on a loud lane.
        float bright = (0.16 + in.vRing * 0.5) + in.vHeat * 2.6 + u.uHigh * 0.3;
        // The accretion ring: whatever is falling hardest goes white, so the hole has an edge.
        colour = mix(colour, float3(1.0), in.vHole * 0.55);
        bright += in.vHole * in.vHole * 2.2;
        return float4(
          colour * bright, clamp(0.25 + in.vHeat * 1.8 + in.vRing * 0.3 + in.vHole, 0.0, 1.0));
      }

      """
  }
#endif
