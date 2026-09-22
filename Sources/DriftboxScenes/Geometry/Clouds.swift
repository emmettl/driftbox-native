#if canImport(Metal)
  import Metal
  import simd

  /// Little fluffy clouds.
  ///
  /// Every other scene in this box is a dark room with glowing lines in it. That is nine scenes
  /// of the same fundamental idea, and by now the restraint has stopped being a style and
  /// started being a rut — so this one is a bright blue sky in the middle of the afternoon, and
  /// the only thing on it is weather.
  ///
  /// Which is also the right answer for the record. The Orb's is ambient house built out of a
  /// 303 and an 808 with a woman talking about the sky over the top of it, and it is *funny* —
  /// warm and daft and completely unbothered. Doing that in cold cyan vectors would be a
  /// misread. So: cartoon clouds, drawn as clusters of soft round puffs, which squash and
  /// stretch on the beat the way a cartoon does, and a rainbow that turns up when it gets loud
  /// enough to deserve one.
  ///
  /// The one thing it keeps from the rest of the set is that nothing is a texture. The puffs are
  /// point sprites shaded in the fragment shader, the sky is a gradient, the rainbow is seven
  /// arcs. No images anywhere, same as there are no samples anywhere.
  public final class Clouds: GeometryScene {
    override public class var id: String { "clouds" }
    override public class var name: String { "Clouds" }
    /// The only dark accent in the set, and the only ring: a dark blob on a bright sky is a
    /// smudge on the lens, whereas an outline reads as something drawn on top of it.
    override public class var accent: SIMD3<Float> { SIMD3(40, 70, 130) / 255 }
    /// The sky sphere is guaranteed to cover the frame, so the clear colour is never seen. It
    /// is the pale end of the sky's own gradient rather than black all the same, because black
    /// is what would show if that ever stopped being true.
    override public class var background: SIMD3<Float> { SIMD3(0.72, 0.88, 0.98) }

    static let clouds = 7
    static let puffs = 24
    /// How far out the clouds drift before wrapping round to the other side.
    static let span: Float = 46
    static let rainbowBands = 7
    static let rainbowSegments = 40
    static let puffCount = clouds * puffs
    static let bowCount = rainbowBands * rainbowSegments * 2

    struct SkyUniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var sun = SIMD3<Float>(0.2, 0.44, -1)
      var bass: Float = 0
    }

    struct PuffUniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var pixelRatio: Float = 1
    }

    struct BowUniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var show: Float = 0
    }

    /// Where one cloud lives, how fast it drifts, and how squashed it is right now.
    struct Drift {
      var x: Float
      var y: Float
      var z: Float
      var speed: Float
      var squash: Float = 1
      var phase: Float
    }

    var sky = SkyUniforms()
    var puff = PuffUniforms()
    var bow = BowUniforms()
    /// Each cloud's placement and squash, `(x, y, z, squash)`, as the puff shader reads it.
    var slots = [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 1), count: Clouds.clouds)
    var drift: [Drift] = []

    var skyMesh: (positions: MTLBuffer, indices: MTLBuffer, count: Int)!
    var puffMesh: (positions: MTLBuffer, cloud: MTLBuffer, size: MTLBuffer, top: MTLBuffer)!
    var bowMesh: (positions: MTLBuffer, colours: MTLBuffer)!
    var skyPipeline: MTLRenderPipelineState!
    var puffPipeline: MTLRenderPipelineState!
    var bowPipeline: MTLRenderPipelineState!

    var clock: Float = 0
    /// How much rainbow there is to fade toward; `bow.show` chases it.
    var showing: Float = 0
    var onBeat = Onset(rise: 1.4, refractory: 0.16)
    var onBow = Onset(rise: 2.4, refractory: 6)

    override public func build() throws {
      // The sky is a sphere around everything rather than a background colour, because a
      // gradient needs somewhere to be drawn and this guarantees it covers the frame at any
      // aspect without any arithmetic.
      let ball = Self.sphere(radius: 140, widthSegments: 24, heightSegments: 16)
      skyMesh = (buffer(ball.positions), buffer(ball.indices), ball.indices.count)

      // Deterministic, so the sky is the same sky every time it opens.
      var random = Noise(seed: 1969)
      var positions: [SIMD3<Float>] = []
      var cloud: [Float] = []
      var size: [Float] = []
      var top: [Float] = []
      for c in 0..<Self.clouds {
        for p in 0..<Self.puffs {
          // A cloud is a fat lens of puffs: wide, shallow, and heavier along the bottom so it
          // has a flat base and a lumpy top. A blob of evenly scattered points is a sphere, and
          // a spherical cloud looks like a sheep.
          let t = Float(p) / Float(Self.puffs - 1)
          let across = (random.next() - 0.5) * 2
          let height = pow(random.next(), 1.7)
          let lift = cos(across * 1.2) * 0.55
          positions.append(
            SIMD3(across * 7.5, height * 2.6 * lift + 0.2, (random.next() - 0.5) * 2.4))
          cloud.append(Float(c))
          // Bigger in the middle and toward the base, so the silhouette tapers at the ends.
          size.append((2.6 + (1 - abs(across)) * 3.2) * (0.75 + random.next() * 0.5))
          top.append(min(1, height * 0.6 + lift * 0.5 + t * 0.1))
        }
      }
      puffMesh = (buffer(positions), buffer(cloud), buffer(size), buffer(top))

      var bowPositions: [SIMD3<Float>] = []
      var bowColours: [SIMD3<Float>] = []
      let bands = [0xff4d4d, 0xff9d3b, 0xffe14d, 0x5ede63, 0x4db8ff, 0x5a63e8, 0xa45ce8]
      for b in 0..<Self.rainbowBands {
        let hex = bands[b]
        let colour =
          SIMD3(Float((hex >> 16) & 0xff), Float((hex >> 8) & 0xff), Float(hex & 0xff)) / 255
        let radius = 30 - Float(b) * 1.4
        for s in 0..<Self.rainbowSegments {
          let a0 = Float.pi * (Float(s) / Float(Self.rainbowSegments))
          let a1 = Float.pi * (Float(s + 1) / Float(Self.rainbowSegments))
          bowPositions.append(SIMD3(cos(a0) * radius, sin(a0) * radius - 12, -30))
          bowPositions.append(SIMD3(cos(a1) * radius, sin(a1) * radius - 12, -30))
          bowColours.append(contentsOf: [colour, colour])
        }
      }
      bowMesh = (buffer(bowPositions), buffer(bowColours))

      var place = Noise(seed: 4223)
      drift = (0..<Self.clouds).map { i in
        Drift(
          x: (Float(i) / Float(Self.clouds) - 0.5) * Self.span * 2 + place.next() * 6,
          y: -8 + place.next() * 22, z: -20 - place.next() * 34, speed: 0.9 + place.next() * 1.5,
          phase: place.next() * 6.28)
      }

      skyPipeline = try pipeline(vertex: "cloudsSkyVertex", fragment: "cloudsSkyFragment", blend: .none)
      bowPipeline = try pipeline(vertex: "cloudsBowVertex", fragment: "cloudsBowFragment", blend: .normal)
      puffPipeline = try pipeline(
        vertex: "cloudsPuffVertex", fragment: "cloudsPuffFragment", blend: .normal)
    }

    override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
      let (bass, high) = input.wideLevels
      clock += dt
      sky.bass += (bass - sky.bass) * min(1, dt * 4)
      puff.pixelRatio = input.pixelRatio

      let kick = onBeat.detect(bass, dt: dt) > 0
      if onBow.detect(high, dt: dt) > 0 { showing = 1 }
      // Long enough to enjoy, short enough that it is an event. At 0.12 it outlasted its own
      // refractory period and simply never left.
      showing = max(0, showing - dt * 0.28)
      bow.show += (showing - bow.show) * min(1, dt * 2)

      for i in drift.indices {
        drift[i].x -= dt * drift[i].speed
        // Wrapped round rather than respawned, so the sky never runs out and never repeats in a
        // way you can catch.
        if drift[i].x < -Self.span { drift[i].x += Self.span * 2 }

        // A finger pushes clouds aside — they part around it and drift back. On a scene made of
        // weather, shoving it is the obvious thing to try.
        let fingerX = (touchAt.x - 0.5) * Self.span * 1.4
        let fingerY = (touchAt.y - 0.5) * 34
        let away = drift[i].x - fingerX
        let reach = drift[i].y - fingerY
        let gap = (away * away + reach * reach).squareRoot()
        let shove = exp(-gap * gap * 0.004) * touchEnergy * 9
        let bob = sin(clock * 0.5 + drift[i].phase) * 0.7

        // Squash on the kick, spring back. Cartoon volume: flatter also means wider, which the
        // shader does by dividing x by the same number it multiplies y by.
        if kick { drift[i].squash = 0.76 }
        drift[i].squash += (1 - drift[i].squash) * min(1, dt * 5)

        slots[i] = SIMD4(
          drift[i].x + (away < 0 ? -1 : 1) * shove, drift[i].y + bob, drift[i].z, drift[i].squash)
      }

      // Barely moves. The clouds do the drifting; a camera that also drifts just makes it hard
      // to tell which is which.
      let portrait = aspect < 0.85
      camera.position = SIMD3(
        (touchAt.x - 0.5) * 2 * touchEnergy, 2 + high * 0.6, portrait ? 34 : 26)
      camera.rotation = SIMD3(0.06, 0, 0)
      let projection = camera.projection(aspect: aspect)
      sky.projectionMatrix = projection
      // The sky follows the camera. `vDir` is the direction from the sphere's own centre, so it
      // only equals the direction you are actually looking if the two coincide — left at the
      // origin with the camera thirty units away, the gradient skews and the sun smears into a
      // vertical band down one side of the frame.
      sky.modelViewMatrix = camera.view * modelMatrix(position: camera.position)
      puff.projectionMatrix = projection
      puff.modelViewMatrix = camera.view
      bow.projectionMatrix = projection
      bow.modelViewMatrix = camera.view
    }

    /// Sky, rainbow, then puffs — three's own order, the opaque sphere ahead of the two
    /// transparent objects and those two in the order they are added. Nothing asks for
    /// `depthState`: every material here writes no depth, so there is nothing for a depth test
    /// to read and the order on its own decides what covers what.
    override public func encode(_ encoder: MTLRenderCommandEncoder) {
      encoder.setRenderPipelineState(skyPipeline)
      encoder.setVertexBytes(&sky, length: MemoryLayout<SkyUniforms>.stride, index: 0)
      encoder.setVertexBuffer(skyMesh.positions, offset: 0, index: 1)
      encoder.setFragmentBytes(&sky, length: MemoryLayout<SkyUniforms>.stride, index: 0)
      encoder.drawIndexedPrimitives(
        type: .triangle, indexCount: skyMesh.count, indexType: .uint32, indexBuffer: skyMesh.indices,
        indexBufferOffset: 0)

      encoder.setRenderPipelineState(bowPipeline)
      encoder.setVertexBytes(&bow, length: MemoryLayout<BowUniforms>.stride, index: 0)
      encoder.setVertexBuffer(bowMesh.positions, offset: 0, index: 1)
      encoder.setVertexBuffer(bowMesh.colours, offset: 0, index: 2)
      encoder.setFragmentBytes(&bow, length: MemoryLayout<BowUniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: Self.bowCount)

      // Not additive, and not depth-written. Clouds are opaque white on a bright sky, so adding
      // them just blows out to a flat sheet; and writing depth makes the puffs within one cloud
      // cut circular holes in each other.
      encoder.setRenderPipelineState(puffPipeline)
      encoder.setVertexBytes(&puff, length: MemoryLayout<PuffUniforms>.stride, index: 0)
      encoder.setVertexBuffer(puffMesh.positions, offset: 0, index: 1)
      encoder.setVertexBuffer(puffMesh.cloud, offset: 0, index: 2)
      encoder.setVertexBuffer(puffMesh.size, offset: 0, index: 3)
      encoder.setVertexBuffer(puffMesh.top, offset: 0, index: 4)
      slots.withUnsafeBytes { raw in
        encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 5)
      }
      encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Self.puffCount)
    }

    /// three's `SphereGeometry`: rings of latitude from the north pole down, each of
    /// `widthSegments + 1` points around, uvs from the bottom left, and two triangles a cell —
    /// except at the poles, where one of the two would be degenerate and three leaves it out.
    /// The seam column is duplicated so the uv can run to 1 there, and the pole rows are nudged
    /// half a cell across so a pole's uv sits in the middle of the cell below it.
    private static func sphere(radius: Float, widthSegments: Int, heightSegments: Int) -> (
      positions: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32]
    ) {
      let across = max(3, widthSegments)
      let down = max(2, heightSegments)
      var positions: [SIMD3<Float>] = []
      var uvs: [SIMD2<Float>] = []
      var indices: [UInt32] = []
      for iy in 0...down {
        let v = Float(iy) / Float(down)
        var uOffset: Float = 0
        if iy == 0 { uOffset = 0.5 / Float(across) }
        if iy == down { uOffset = -0.5 / Float(across) }
        for ix in 0...across {
          let u = Float(ix) / Float(across)
          let phi = u * .pi * 2
          let theta = v * .pi
          positions.append(
            SIMD3(-radius * cos(phi) * sin(theta), radius * cos(theta), radius * sin(phi) * sin(theta)))
          uvs.append(SIMD2(u + uOffset, 1 - v))
        }
      }
      for iy in 0..<down {
        for ix in 0..<across {
          let a = UInt32(ix + 1 + (across + 1) * iy)
          let b = UInt32(ix + (across + 1) * iy)
          let c = UInt32(ix + (across + 1) * (iy + 1))
          let d = UInt32(ix + 1 + (across + 1) * (iy + 1))
          if iy != 0 { indices.append(contentsOf: [a, b, d]) }
          if iy != down - 1 { indices.append(contentsOf: [b, c, d]) }
        }
      }
      return (positions, uvs, indices)
    }

    static let source = """

      struct CloudsSkyUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float3 uSun;
        float uBass;
      };
      struct CloudsSkyVarying {
        float4 position [[position]];
        float3 vDir;
      };

      vertex CloudsSkyVarying cloudsSkyVertex(
        uint vid [[vertex_id]], constant CloudsSkyUniforms &u [[buffer(0)]],
        constant float3 *vertices [[buffer(1)]]
      ) {
        CloudsSkyVarying out;
        float3 position = vertices[vid];
        out.vDir = normalize(position);
        out.position = u.projectionMatrix * u.modelViewMatrix * float4(position, 1.0);
        return out;
      }

      fragment float4 cloudsSkyFragment(
        CloudsSkyVarying in [[stage_in]], constant CloudsSkyUniforms &u [[buffer(0)]]
      ) {
        float3 vDir = normalize(in.vDir);
        // Deep at the zenith, pale at the horizon. Every real sky does this and it is most of
        // what stops a flat blue fill reading as a wall.
        float up = clamp(vDir.y * 0.5 + 0.5, 0.0, 1.0);
        float3 high = float3(0.16, 0.44, 0.86);
        float3 low = float3(0.72, 0.88, 0.98);
        float3 sky = mix(low, high, pow(up, 0.7));

        // And a broad warm glow around the sun, which is what makes it feel like an afternoon
        // rather than a colour swatch.
        // The halo exponent matters more than it looks. At 3 the glow spreads over sixty
        // degrees, which on a portrait phone is most of the frame — so with the sun anywhere
        // near the edge you see only its flank and it reads as a white band down one side
        // rather than as a sun at all.
        float toward = max(0.0, dot(vDir, normalize(u.uSun)));
        sky += float3(1.0, 0.94, 0.76) * (pow(toward, 26.0) * 1.1 + pow(toward, 7.0) * 0.2);

        return float4(sky * (1.0 + u.uBass * 0.1), 1.0);
      }

      struct CloudsPuffUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float uPixelRatio;
      };
      struct CloudsPuffVarying {
        float4 position [[position]];
        float pointSize [[point_size]];
        float vTop;
        float vShade;
      };

      vertex CloudsPuffVarying cloudsPuffVertex(
        uint vid [[vertex_id]], constant CloudsPuffUniforms &u [[buffer(0)]],
        constant float3 *vertices [[buffer(1)]], constant float *aCloudIn [[buffer(2)]],
        constant float *aSizeIn [[buffer(3)]], constant float *aTopIn [[buffer(4)]],
        constant float4 *uClouds [[buffer(5)]]
      ) {
        // Which cloud this puff belongs to. The web unrolls a loop over all seven slots here,
        // because older GLSL will not index a uniform array with a value that arrived on an
        // attribute; Metal will, so it is one fetch.
        float4 cloud = uClouds[int(aCloudIn[vid] + 0.5)];

        // Squash and stretch. The oldest trick in animation: a cartoon body keeps its volume,
        // so anything that flattens also has to widen. Driven by the kick, it makes the whole
        // sky bounce without a single thing moving from where it is.
        float squash = cloud.w;
        float3 pos = vertices[vid];
        pos.y *= squash;
        pos.x /= squash;
        pos += cloud.xyz;

        CloudsPuffVarying out;
        out.vTop = aTopIn[vid];
        // Lit from where the sun is, roughly: the tops of the puffs are white and the
        // undersides go blue-grey. Real enough at this size, and it is what makes a circle read
        // as a lump rather than as a dot.
        out.vShade = 0.55 + out.vTop * 0.45;

        float4 view = u.modelViewMatrix * float4(pos, 1.0);
        out.position = u.projectionMatrix * view;
        out.pointSize = aSizeIn[vid] * u.uPixelRatio * (300.0 / max(1.0, -view.z));
        return out;
      }

      fragment float4 cloudsPuffFragment(
        CloudsPuffVarying in [[stage_in]], float2 pointCoord [[point_coord]]
      ) {
        float2 d = pointCoord - 0.5;
        float r = length(d);
        if (r > 0.5) discard_fragment();

        // A soft edge, but not too soft — a cartoon cloud has an edge you could draw round.
        // Fading it out over the last fifth of the radius gives a lump rather than a smudge.
        float alpha = 1.0 - smoothstep(0.30, 0.5, r);

        // Shaded within the puff as well as between them, so each lump is round.
        float lift = 1.0 - smoothstep(-0.1, 0.45, d.y);
        float3 white = float3(1.0, 0.99, 0.97);
        float3 shadow = float3(0.66, 0.74, 0.86);
        float3 colour = mix(shadow, white, clamp(in.vShade * 0.55 + lift * 0.6, 0.0, 1.0));

        return float4(colour, alpha);
      }

      struct CloudsBowUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float uShow;
      };
      struct CloudsBowVarying {
        float4 position [[position]];
        float3 vColour;
      };

      vertex CloudsBowVarying cloudsBowVertex(
        uint vid [[vertex_id]], constant CloudsBowUniforms &u [[buffer(0)]],
        constant float3 *vertices [[buffer(1)]], constant float3 *aColour [[buffer(2)]]
      ) {
        CloudsBowVarying out;
        out.vColour = aColour[vid];
        out.position = u.projectionMatrix * u.modelViewMatrix * float4(vertices[vid], 1.0);
        return out;
      }

      fragment float4 cloudsBowFragment(
        CloudsBowVarying in [[stage_in]], constant CloudsBowUniforms &u [[buffer(0)]]
      ) {
        if (u.uShow < 0.01) discard_fragment();
        return float4(in.vColour, u.uShow * 0.72);
      }

      """
  }
#endif
