#if canImport(Metal)
  import Metal
  import simd

  /// Endless Convoy.
  ///
  /// Side-on like an early cabinet game, but not pixel art and not a battle. A procession of
  /// heavy machines crosses a road that never arrives anywhere, carrying increasingly absurd
  /// cargo: a tank, a house, a tree and — at the back — smaller copies of itself. The image is
  /// solid low-poly silhouettes with bright vector edges, rather than another room made only
  /// of glowing lines.
  ///
  /// The convoy does not scroll. It holds its ground while the road and dust run under it,
  /// because the song's whole character is obstinacy: the same phrase continuing while the
  /// world changes around it. Bass compresses each vehicle's suspension in sequence, highs
  /// throw dust, and a touch tilts the road into an impossible incline while the Kaoss filter
  /// makes the motor audibly labour.
  ///
  /// The web scene declares no `<fog>` at all, so there is nothing to port either way — neither
  /// for the two `ShaderMaterial`s nor for the flat materials that would have received it.
  public final class Convoy: GeometryScene {
    override public class var id: String { "convoy" }
    override public class var name: String { "Endless Convoy" }
    override public class var accent: SIMD3<Float> { SIMD3(255, 250, 220) / 255 }
    override public class var background: SIMD3<Float> { SIMD3(0x07, 0x10, 0x17) / 255 }

    static let dustCount = 150
    /// Where each carrier stands. It never moves along the road; the road moves under it.
    static let places: [Float] = [-13.2, -6.6, 0, 6.6, 13.2]
    static let scales: [Float] = [1.12, 0.92, 1, 0.88, 0.82]
    /// The ridge behind everything, as the polyline three spells out segment by segment.
    static let ridge: [SIMD2<Float>] = [
      SIMD2(-38, 4.4), SIMD2(-31, 8.2), SIMD2(-25, 5.2), SIMD2(-18, 9.4), SIMD2(-9, 4.7),
      SIMD2(-2, 7.4), SIMD2(7, 4.5), SIMD2(15, 8.8), SIMD2(23, 5.1), SIMD2(31, 7.2), SIMD2(39, 4.6),
    ]

    static let fillInk = SIMD3<Float>(0x10, 0x2b, 0x32) / 255
    static let bodyInk = SIMD3<Float>(0x72, 0xf0, 0xd8) / 255
    static let cargoInk = SIMD3<Float>(0xff, 0xb0, 0x4a) / 255
    static let stripeInk = SIMD3<Float>(0x4b, 0xe0, 0xcf) / 255
    static let sunInk = SIMD3<Float>(0xb8, 0x49, 0x36) / 255
    static let ridgeInk = SIMD3<Float>(0x21, 0x4f, 0x5a) / 255

    struct RoadUniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var time: Float = 0
      var bass: Float = 0
      var high: Float = 0
    }

    /// What stands in for three's `LineBasicMaterial` and `MeshBasicMaterial`. Neither has a
    /// shader of its own, so this is the whole of what they do here: one colour, one opacity,
    /// no lighting and no vertex colours.
    struct FlatUniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var colour = SIMD3<Float>(1, 1, 1)
      var opacity: Float = 1
    }

    struct DustUniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var time: Float = 0
      var high: Float = 0
    }

    /// A run of vertices inside one of the three shared vehicle buffers.
    struct Part {
      var start = 0
      var count = 0
    }

    /// One carrier: which slices of the shared buffers are its outline, its edges and its load,
    /// and where it is standing this frame.
    struct Vehicle {
      var fill = Part()
      var body = Part()
      var cargo = Part()
      var modelView = matrix_identity_float4x4
    }

    var road = RoadUniforms()
    var flat = FlatUniforms()
    var dust = DustUniforms()
    var vehicles: [Vehicle] = []

    var roadMesh: (positions: MTLBuffer, uvs: MTLBuffer, indices: MTLBuffer, count: Int)!
    var sunMesh: (positions: MTLBuffer, indices: MTLBuffer, count: Int)!
    var fills: MTLBuffer!
    var bodies: MTLBuffer!
    var cargoes: MTLBuffer!
    var stripes: MTLBuffer!
    var ridgeLines: MTLBuffer!
    var dustMesh: (positions: MTLBuffer, speeds: MTLBuffer)!
    var roadPipeline: MTLRenderPipelineState!
    var flatPipeline: MTLRenderPipelineState!
    var dustPipeline: MTLRenderPipelineState!
    /// Depth tested but not written, which is what three's `depthWrite={false}` leaves the dust.
    var dustDepth: MTLDepthStencilState?

    var stripeModelView = matrix_identity_float4x4
    var sunModelView = matrix_identity_float4x4
    var ridgeModelView = matrix_identity_float4x4

    /// The road's own clock, which only runs while the transport does — so a stopped song
    /// stops the convoy rather than leaving it driving on in silence.
    var elapsed: Float = 0
    var bass: Float = 0
    var high: Float = 0
    var roadRoll: Float = 0
    var convoyRoll: Float = 0
    var convoyScale: Float = 1

    override public func build() throws {
      let plane = Plane.build(width: 72, height: 7)
      roadMesh = (buffer(plane.positions), buffer(plane.uvs), buffer(plane.indices), plane.indices.count)

      let sun = Self.circleFan(radius: 4.8, segments: 48)
      sunMesh = (buffer(sun.positions), buffer(sun.indices), sun.indices.count)

      // The five carriers share one buffer per layer, so a frame is fifteen draws out of three
      // buffers rather than fifteen buffers.
      var fill: [SIMD3<Float>] = []
      var body: [SIMD3<Float>] = []
      var cargo: [SIMD3<Float>] = []
      vehicles = (0..<Self.places.count).map { kind in
        let built = Self.vehicle(kind: kind)
        let slot = Vehicle(
          fill: Part(start: fill.count, count: built.fill.count),
          body: Part(start: body.count, count: built.body.count),
          cargo: Part(start: cargo.count, count: built.cargo.count))
        fill += built.fill
        body += built.body
        cargo += built.cargo
        return slot
      }
      fills = buffer(fill)
      bodies = buffer(body)
      cargoes = buffer(cargo)

      // Two rails a hand's width apart, which is all it takes to read as a kerb.
      stripes = buffer([
        SIMD3<Float>(-40, 0, 0), SIMD3<Float>(40, 0, 0),
        SIMD3<Float>(-40, 0.12, 0), SIMD3<Float>(40, 0.12, 0),
      ])
      var ridge: [SIMD3<Float>] = []
      for at in 0..<(Self.ridge.count - 1) {
        ridge.append(SIMD3(Self.ridge[at].x, Self.ridge[at].y, 0))
        ridge.append(SIMD3(Self.ridge[at + 1].x, Self.ridge[at + 1].y, 0))
      }
      ridgeLines = buffer(ridge)

      // Deterministic, so the same grit blows past every time the scene opens.
      var random = Noise(seed: 7319)
      var motes: [SIMD3<Float>] = []
      var speeds: [Float] = []
      for _ in 0..<Self.dustCount {
        let across = (random.next() - 0.5) * 44
        // Squared, so most of it hangs low around the wheels and only a little gets thrown up.
        let height = 0.45 + pow(random.next(), 2) * 2.4
        motes.append(SIMD3(across, height, 0.1))
        speeds.append(random.next())
      }
      dustMesh = (buffer(motes), buffer(speeds))

      roadPipeline = try pipeline(vertex: "convoyRoadVertex", fragment: "convoyRoadFragment", blend: .none)
      flatPipeline = try pipeline(vertex: "convoyFlatVertex", fragment: "convoyFlatFragment", blend: .normal)
      dustPipeline = try pipeline(
        vertex: "convoyDustVertex", fragment: "convoyDustFragment", blend: .additive)

      let descriptor = MTLDepthStencilDescriptor()
      descriptor.depthCompareFunction = .less
      descriptor.isDepthWriteEnabled = false
      dustDepth = device.makeDepthStencilState(descriptor: descriptor)
    }

    override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
      let (rawBass, rawHigh) = input.wideLevels
      bass = Analyser.ease(bass, toward: rawBass, dt: dt, fall: 3.6)
      high = Analyser.ease(high, toward: rawHigh, dt: dt, fall: 5.2)
      if input.running { elapsed += dt * (0.75 + bass * 1.2) }

      road.time = elapsed
      road.bass = bass
      road.high = high
      dust.time = elapsed
      dust.high = high

      // A finger pulls the road onto an incline it could not really be on, and the convoy goes
      // with it rather than sliding off — the whole picture leans, which is the joke.
      let slope = (touchAt.y - 0.5) * touchEnergy * 0.32
      roadRoll += (slope - roadRoll) * min(1, dt * 3.4)
      convoyRoll += (slope - convoyRoll) * min(1, dt * 3.4)

      // Compress the lineup in portrait, but still crop its ends rather than backing far
      // enough to show every vehicle. A convoy continuing past both edges reads as larger;
      // five complete tiny tanks in the middle of a phone read as a diagram.
      let portrait = aspect < 0.72
      convoyScale += ((portrait ? 0.5 : 1) - convoyScale) * min(1, dt * 5)

      camera.fovDegrees = 42
      camera.far = 120
      // Landscape frames the whole column. Portrait deliberately frames its middle three
      // carriers; touch can pan toward the head or tail, and the road proves it continues.
      let distance = fitDistance(
        camera: camera, aspect: aspect, halfWidth: portrait ? 4.4 : 17,
        halfHeight: portrait ? 6.2 : 7.6, fill: 0.9)
      let targetX = (touchAt.x - 0.5) * touchEnergy * 3
      let targetY = (portrait ? 2.8 : 4.35) + (touchAt.y - 0.5) * touchEnergy * 1.4
      camera.position.x += (targetX - camera.position.x) * min(1, dt * 2.4)
      camera.position.y += (targetY - camera.position.y) * min(1, dt * 2.4)
      camera.position.z += (distance - camera.position.z) * min(1, dt * 3.2)
      camera.target = SIMD3(targetX * 0.2, portrait ? 2.1 : 3.35, 0)

      let projection = camera.projection(aspect: aspect)
      let view = camera.view
      let roadGroup = modelMatrix(position: .zero, rotation: SIMD3(0, 0, roadRoll))
      road.projectionMatrix = projection
      road.modelViewMatrix = view * roadGroup * modelMatrix(position: SIMD3(0, -1.85, -2))
      stripeModelView = view * roadGroup * modelMatrix(position: SIMD3(0, 0.48, -0.5))
      sunModelView = view * modelMatrix(position: SIMD3(-10.5, 8.4, -4))
      ridgeModelView = view * modelMatrix(position: SIMD3(0, 0, -3))
      flat.projectionMatrix = projection
      dust.projectionMatrix = projection
      dust.modelViewMatrix = view * modelMatrix(position: SIMD3(0, 0, 0.4))

      let convoyGroup =
        modelMatrix(position: .zero, rotation: SIMD3(0, 0, convoyRoll))
        * Self.scaling(SIMD3(convoyScale, 1, 1))
      for index in vehicles.indices {
        // One suspension cycle each, a fifth of a beat apart down the line, so the bass walks
        // along the convoy instead of bouncing all five at once.
        let tread = sin(elapsed * 9.5 - Float(index) * 1.35)
        let stand = SIMD3(Self.places[index], 0.8 + tread * (0.025 + bass * 0.16), Float(0))
        vehicles[index].modelView =
          view * convoyGroup
          * modelMatrix(position: stand, rotation: SIMD3(0, 0, tread * bass * 0.018))
          * Self.scaling(SIMD3(repeating: Self.scales[index]))
      }
    }

    /// three's own order: the opaque objects first — the road and every part of every vehicle —
    /// and then the transparent ones back to front, the sun behind the ridge behind the kerb,
    /// with the dust last of all. Among the opaque draws the order is free, because they all
    /// test and write depth; among the transparent ones it is not, because they blend.
    override public func encode(_ encoder: MTLRenderCommandEncoder) {
      encoder.setDepthStencilState(depthState)

      encoder.setRenderPipelineState(roadPipeline)
      encoder.setVertexBytes(&road, length: MemoryLayout<RoadUniforms>.stride, index: 0)
      encoder.setVertexBuffer(roadMesh.positions, offset: 0, index: 1)
      encoder.setVertexBuffer(roadMesh.uvs, offset: 0, index: 2)
      encoder.setFragmentBytes(&road, length: MemoryLayout<RoadUniforms>.stride, index: 0)
      encoder.drawIndexedPrimitives(
        type: .triangle, indexCount: roadMesh.count, indexType: .uint32, indexBuffer: roadMesh.indices,
        indexBufferOffset: 0)

      encoder.setRenderPipelineState(flatPipeline)
      for vehicle in vehicles {
        flat.modelViewMatrix = vehicle.modelView
        paint(encoder, fills, vehicle.fill, type: .triangle, colour: Self.fillInk, opacity: 1)
        paint(encoder, bodies, vehicle.body, type: .line, colour: Self.bodyInk, opacity: 1)
        paint(encoder, cargoes, vehicle.cargo, type: .line, colour: Self.cargoInk, opacity: 1)
      }

      flat.modelViewMatrix = sunModelView
      flat.colour = Self.sunInk
      flat.opacity = 0.72
      encoder.setVertexBytes(&flat, length: MemoryLayout<FlatUniforms>.stride, index: 0)
      encoder.setVertexBuffer(sunMesh.positions, offset: 0, index: 1)
      encoder.setFragmentBytes(&flat, length: MemoryLayout<FlatUniforms>.stride, index: 0)
      encoder.drawIndexedPrimitives(
        type: .triangle, indexCount: sunMesh.count, indexType: .uint32, indexBuffer: sunMesh.indices,
        indexBufferOffset: 0)

      flat.modelViewMatrix = ridgeModelView
      paint(
        encoder, ridgeLines, Part(start: 0, count: (Self.ridge.count - 1) * 2), type: .line,
        colour: Self.ridgeInk, opacity: 0.7)
      flat.modelViewMatrix = stripeModelView
      paint(encoder, stripes, Part(start: 0, count: 4), type: .line, colour: Self.stripeInk, opacity: 0.75)

      encoder.setDepthStencilState(dustDepth)
      encoder.setRenderPipelineState(dustPipeline)
      encoder.setVertexBytes(&dust, length: MemoryLayout<DustUniforms>.stride, index: 0)
      encoder.setVertexBuffer(dustMesh.positions, offset: 0, index: 1)
      encoder.setVertexBuffer(dustMesh.speeds, offset: 0, index: 2)
      encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Self.dustCount)
    }

    /// One flat-coloured run out of a shared buffer. `vertexStart` moves `vertex_id` with it,
    /// so the shader indexes the whole buffer and still reads the right slice.
    private func paint(
      _ encoder: MTLRenderCommandEncoder, _ vertices: MTLBuffer, _ part: Part,
      type: MTLPrimitiveType, colour: SIMD3<Float>, opacity: Float
    ) {
      guard part.count > 0 else { return }
      flat.colour = colour
      flat.opacity = opacity
      encoder.setVertexBytes(&flat, length: MemoryLayout<FlatUniforms>.stride, index: 0)
      encoder.setVertexBuffer(vertices, offset: 0, index: 1)
      encoder.setFragmentBytes(&flat, length: MemoryLayout<FlatUniforms>.stride, index: 0)
      encoder.drawPrimitives(type: type, vertexStart: part.start, vertexCount: part.count)
    }

    /// A scale, innermost — where `Object3D.matrix` puts it, before the turn and the position.
    private static func scaling(_ scale: SIMD3<Float>) -> simd_float4x4 {
      simd_float4x4(diagonal: SIMD4(scale.x, scale.y, scale.z, 1))
    }

    /// three's `CircleGeometry`: the centre, then a rim anticlockwise from the x axis with the
    /// seam point repeated so the last triangle closes, and a fan of indices over the two.
    private static func circleFan(radius: Float, segments: Int) -> (
      positions: [SIMD3<Float>], indices: [UInt32]
    ) {
      var positions: [SIMD3<Float>] = [SIMD3(0, 0, 0)]
      for step in 0...segments {
        let a = Float(step) / Float(segments) * .pi * 2
        positions.append(SIMD3(cos(a) * radius, sin(a) * radius, 0))
      }
      var indices: [UInt32] = []
      for step in 1...segments { indices.append(contentsOf: [UInt32(step), UInt32(step + 1), 0]) }
      return (positions, indices)
    }

    /// One carrier, as three builds it: filled shapes for the silhouette, and two sets of line
    /// segments over the top — the machine's own edges and whatever it is carrying.
    ///
    /// The fills are three's `ShapeGeometry`, which earcuts each outline. Every outline here is
    /// convex, and for a convex polygon a fan covers exactly the same area, so that is what
    /// this does instead of carrying an earcut across.
    private static func vehicle(kind: Int) -> (
      fill: [SIMD3<Float>], body: [SIMD3<Float>], cargo: [SIMD3<Float>]
    ) {
      var fill: [SIMD3<Float>] = []
      var body: [SIMD3<Float>] = []
      var cargo: [SIMD3<Float>] = []

      func ring(_ cx: Float, _ cy: Float, _ radius: Float, _ segments: Int) -> [SIMD2<Float>] {
        (0..<segments).map { step in
          let a = Float(step) / Float(segments) * .pi * 2
          return SIMD2(cx + cos(a) * radius, cy + sin(a) * radius)
        }
      }
      func shape(_ points: [SIMD2<Float>]) {
        for corner in 1..<(points.count - 1) {
          for at in [points[0], points[corner], points[corner + 1]] {
            fill.append(SIMD3(at.x, at.y, 0))
          }
        }
      }
      func line(_ out: inout [SIMD3<Float>], _ a: SIMD2<Float>, _ b: SIMD2<Float>) {
        out.append(SIMD3(a.x, a.y, 0))
        out.append(SIMD3(b.x, b.y, 0))
      }
      func poly(_ out: inout [SIMD3<Float>], _ points: [SIMD2<Float>], closed: Bool = true) {
        for at in 0..<(points.count - 1) { line(&out, points[at], points[at + 1]) }
        if closed { line(&out, points[points.count - 1], points[0]) }
      }
      func circle(
        _ out: inout [SIMD3<Float>], _ cx: Float, _ cy: Float, _ radius: Float, _ segments: Int = 18
      ) {
        poly(&out, ring(cx, cy, radius, segments))
      }

      let track: [SIMD2<Float>] = [
        SIMD2(-2.5, 0.15), SIMD2(-2.15, -0.35), SIMD2(1.95, -0.35), SIMD2(2.5, 0.15),
        SIMD2(2.1, 0.75), SIMD2(-2.05, 0.75),
      ]
      let hull: [SIMD2<Float>] = [
        SIMD2(-2.2, 0.78), SIMD2(-1.7, 1.55), SIMD2(1.7, 1.55), SIMD2(2.15, 0.78),
      ]
      shape(track)
      shape(hull)
      poly(&body, track)
      poly(&body, hull)

      for x in [Float(-1.55), -0.52, 0.52, 1.55] {
        // three's `Shape.absarc` is an ellipse curve, and a path divides one of those at twice
        // its twelve curve segments — so the filled wheel is a twenty-four sided disc, rather
        // than the eighteen the drawn rim uses.
        shape(ring(x, 0.2, 0.42, 24))
        circle(&body, x, 0.2, 0.42)
        circle(&body, x, 0.2, 0.13, 10)
        line(&body, SIMD2(x - 0.32, -0.04), SIMD2(x + 0.32, 0.44))
        line(&body, SIMD2(x - 0.32, 0.44), SIMD2(x + 0.32, -0.04))
      }

      switch kind {
      case 0:
        let turret: [SIMD2<Float>] = [
          SIMD2(-1.0, 1.58), SIMD2(-0.62, 2.18), SIMD2(0.8, 2.18), SIMD2(1.25, 1.58),
        ]
        shape(turret)
        poly(&body, turret)
        line(&body, SIMD2(0.55, 2.18), SIMD2(3.1, 2.78))
        line(&body, SIMD2(0.62, 2.03), SIMD2(3.14, 2.63))
        line(&body, SIMD2(3.1, 2.78), SIMD2(3.14, 2.63))
      case 1:
        // A small house on the flatbed. It is literal enough to read at phone size and absurd
        // enough to say this convoy is transporting a life, not ammunition.
        poly(
          &cargo,
          [
            SIMD2(-1.2, 1.58), SIMD2(-1.2, 3.1), SIMD2(0, 4.05), SIMD2(1.25, 3.1),
            SIMD2(1.25, 1.58),
          ])
        poly(&cargo, [SIMD2(-0.55, 1.58), SIMD2(-0.55, 2.45), SIMD2(0.15, 2.45), SIMD2(0.15, 1.58)])
        poly(&cargo, [SIMD2(0.45, 2.7), SIMD2(0.45, 3.2), SIMD2(0.9, 3.2), SIMD2(0.9, 2.7)])
      case 2:
        // A tree, balanced upright despite whatever angle the road is pulled onto.
        line(&cargo, SIMD2(-0.05, 1.55), SIMD2(-0.05, 4.0))
        line(&cargo, SIMD2(0.1, 1.55), SIMD2(0.1, 4.0))
        for leaf in [SIMD3<Float>(-0.85, 3.85, 0.78), SIMD3(0, 4.45, 0.92), SIMD3(0.9, 3.85, 0.74)] {
          circle(&cargo, leaf.x, leaf.y, leaf.z, 12)
        }
      case 3:
        // A cylindrical machine or sleeper — kept deliberately unresolved. The eye can read
        // it as a generator, an animal or a person in a capsule, which is more useful than a
        // tiny label explaining the joke.
        poly(&cargo, [SIMD2(-1.55, 1.65), SIMD2(-1.2, 3.25), SIMD2(1.2, 3.25), SIMD2(1.55, 1.65)])
        circle(&cargo, -1.18, 2.44, 0.8, 14)
        circle(&cargo, 1.18, 2.44, 0.8, 14)
        line(&cargo, SIMD2(-0.65, 2.3), SIMD2(0.7, 2.3))
      default:
        // The Boss Machine thought folded into the convoy: one carrier stacked with smaller
        // versions of itself. At a glance it is cargo; on inspection it is recursion.
        for row in 0..<3 {
          let scale = 0.58 - Float(row) * 0.11
          let y = 1.7 + Float(row) * 0.82
          let x = Float(row) * 0.15
          poly(
            &cargo,
            [
              SIMD2(x - 1.8 * scale, y), SIMD2(x - 1.4 * scale, y + 0.55 * scale),
              SIMD2(x + 1.4 * scale, y + 0.55 * scale), SIMD2(x + 1.8 * scale, y),
            ])
          circle(&cargo, x - 0.85 * scale, y, 0.28 * scale, 9)
          circle(&cargo, x + 0.85 * scale, y, 0.28 * scale, 9)
          line(&cargo, SIMD2(x, y + 0.55 * scale), SIMD2(x + 1.6 * scale, y + 1.05 * scale))
        }
      }

      return (fill, body, cargo)
    }

    static let source = """

      struct ConvoyRoadUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float uTime;
        float uBass;
        float uHigh;
      };
      struct ConvoyRoadVarying {
        float4 position [[position]];
        float2 vUv;
      };

      vertex ConvoyRoadVarying convoyRoadVertex(
        uint vid [[vertex_id]], constant ConvoyRoadUniforms &u [[buffer(0)]],
        constant float3 *vertices [[buffer(1)]], constant float2 *uvs [[buffer(2)]]
      ) {
        ConvoyRoadVarying out;
        out.vUv = uvs[vid];
        out.position = u.projectionMatrix * u.modelViewMatrix * float4(vertices[vid], 1.0);
        return out;
      }

      fragment float4 convoyRoadFragment(
        ConvoyRoadVarying in [[stage_in]], constant ConvoyRoadUniforms &u [[buffer(0)]]
      ) {
        float3 ground = float3(0.035, 0.075, 0.09);
        float3 lineColour = float3(0.13, 0.72, 0.68);

        // Uneven spacing compresses toward the horizon, giving the flat side view just enough
        // depth to feel like a cabinet landscape rather than a diagram.
        float away = pow(in.vUv.y, 1.65);
        float horizontal = 1.0 - smoothstep(0.035, 0.09, abs(fract(away * 8.0) - 0.5));
        float scroll = in.vUv.x * 22.0 + u.uTime * (1.7 + u.uBass * 2.2);
        float vertical = 1.0 - smoothstep(0.035, 0.085, abs(fract(scroll) - 0.5));
        float grid = max(horizontal * 0.6, vertical * (0.25 + away * 0.7));

        float3 colour = ground + lineColour * grid * (0.34 + u.uHigh * 0.75);
        return float4(colour, 1.0);
      }

      // The whole of three's `LineBasicMaterial` and `MeshBasicMaterial` as this scene uses
      // them: a position, a flat colour and an opacity. No lighting, no vertex colours, no
      // size attenuation — none of those is switched on anywhere here.
      struct ConvoyFlatUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float3 uColour;
        float uOpacity;
      };
      struct ConvoyFlatVarying {
        float4 position [[position]];
      };

      vertex ConvoyFlatVarying convoyFlatVertex(
        uint vid [[vertex_id]], constant ConvoyFlatUniforms &u [[buffer(0)]],
        constant float3 *vertices [[buffer(1)]]
      ) {
        ConvoyFlatVarying out;
        out.position = u.projectionMatrix * u.modelViewMatrix * float4(vertices[vid], 1.0);
        return out;
      }

      fragment float4 convoyFlatFragment(constant ConvoyFlatUniforms &u [[buffer(0)]]) {
        return float4(u.uColour, u.uOpacity);
      }

      struct ConvoyDustUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float uTime;
        float uHigh;
      };
      struct ConvoyDustVarying {
        float4 position [[position]];
        float pointSize [[point_size]];
        float vLife;
      };

      vertex ConvoyDustVarying convoyDustVertex(
        uint vid [[vertex_id]], constant ConvoyDustUniforms &u [[buffer(0)]],
        constant float3 *vertices [[buffer(1)]], constant float *aSpeedIn [[buffer(2)]]
      ) {
        float aSpeed = aSpeedIn[vid];
        float3 pos = vertices[vid];
        // The grit is what actually travels. Wrapped through a forty-four unit band so the
        // road keeps arriving without anything ever being created or destroyed.
        float travel = u.uTime * (2.0 + aSpeed * 4.0);
        pos.x = mod(pos.x - travel + 22.0, 44.0) - 22.0;
        pos.y += sin(pos.x * 1.7 + aSpeed * 12.0) * 0.12;
        ConvoyDustVarying out;
        out.vLife = 0.25 + u.uHigh * 0.75;
        out.position = u.projectionMatrix * u.modelViewMatrix * float4(pos, 1.0);
        // Framebuffer pixels in both languages, and deliberately not scaled by the backing
        // ratio: the web asks for the same one-to-four-and-a-half pixel speck on every screen.
        out.pointSize = 1.0 + u.uHigh * 3.5;
        return out;
      }

      fragment float4 convoyDustFragment(
        ConvoyDustVarying in [[stage_in]], float2 pointCoord [[point_coord]]
      ) {
        float2 p = pointCoord - 0.5;
        if (dot(p, p) > 0.25) discard_fragment();
        return float4(0.95, 0.72, 0.36, in.vLife);
      }

      """
  }
#endif
