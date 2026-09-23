import DriftboxGPU
import Foundation

// C's maths, which Foundation brings with it on Apple's platforms and not on Android.
#if canImport(Android)
  import Android
#endif

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
public final class ConvoyScene: GPUGeometryScene {
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

  /// A run of vertices to draw in one flat colour: a buffer of its own, or none when the run is
  /// empty. Its own buffer rather than a slice of one shared per layer, because the GPU layer
  /// draws a buffer from its first vertex and has no start to move `vertex_id` along with.
  struct Part {
    var vertices: (any GPUBuffer)?
    var count = 0
  }

  /// One carrier: its outline, its edges and its load, and where it is standing this frame.
  struct Vehicle {
    var fill = Part()
    var body = Part()
    var cargo = Part()
    var modelView = Matrix4.identity
  }

  var road = ConvoyRoadUniforms()
  /// What stands in for three's `LineBasicMaterial` and `MeshBasicMaterial`. Neither has a
  /// shader of its own, so this is the whole of what they do here: one colour, one opacity,
  /// no lighting and no vertex colours.
  var flat = ConvoyFlatUniforms()
  var dust = ConvoyDustUniforms()
  var vehicles: [Vehicle] = []

  var roadMesh: (positions: any GPUBuffer, uvs: any GPUBuffer, indices: any GPUBuffer, count: Int)!
  var sunMesh: (positions: any GPUBuffer, indices: any GPUBuffer, count: Int)!
  var stripes = Part()
  var ridgeLines = Part()
  var dustMesh: (positions: any GPUBuffer, speeds: any GPUBuffer)!
  var roadPipeline: (any GPUPipeline)!
  /// The flat material, twice: a GPU layer pipeline draws one kind of primitive, and the flat
  /// colour fills triangles for the silhouettes and the sun and draws lines for everything else.
  var flatFillPipeline: (any GPUPipeline)!
  var flatLinePipeline: (any GPUPipeline)!
  var dustPipeline: (any GPUPipeline)!

  var stripeModelView = Matrix4.identity
  var sunModelView = Matrix4.identity
  var ridgeModelView = Matrix4.identity

  /// The road's own clock, which only runs while the transport does — so a stopped song
  /// stops the convoy rather than leaving it driving on in silence.
  var elapsed: Float = 0
  var bass: Float = 0
  var high: Float = 0
  var roadRoll: Float = 0
  var convoyRoll: Float = 0
  var convoyScale: Float = 1

  override public func build() throws {
    flat.uColour = SIMD3(1, 1, 1)
    flat.uOpacity = 1

    let plane = Plane.build(width: 72, height: 7)
    roadMesh = try (
      buffer(plane.positions), buffer(plane.uvs), indices(plane.indices), plane.indices.count
    )

    let sun = Self.circleFan(radius: 4.8, segments: 48)
    sunMesh = try (buffer(sun.positions), indices(sun.indices), sun.indices.count)

    // Each carrier's three layers are three buffers of their own, so a frame is fifteen draws
    // out of fifteen buffers, built once.
    vehicles = []
    for kind in 0..<Self.places.count {
      let built = Self.vehicle(kind: kind)
      let vehicle = try Vehicle(
        fill: part(built.fill), body: part(built.body), cargo: part(built.cargo))
      vehicles.append(vehicle)
    }

    // Two rails a hand's width apart, which is all it takes to read as a kerb.
    stripes = try part([
      SIMD3<Float>(-40, 0, 0), SIMD3<Float>(40, 0, 0),
      SIMD3<Float>(-40, 0.12, 0), SIMD3<Float>(40, 0.12, 0),
    ])
    var ridge: [SIMD3<Float>] = []
    for at in 0..<(Self.ridge.count - 1) {
      ridge.append(SIMD3(Self.ridge[at].x, Self.ridge[at].y, 0))
      ridge.append(SIMD3(Self.ridge[at + 1].x, Self.ridge[at + 1].y, 0))
    }
    ridgeLines = try part(ridge)

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
    dustMesh = try (buffer(motes), buffer(speeds))

    roadPipeline = try pipeline(
      .convoyRoad, primitive: .triangles, blend: .none, depth: .testAndWrite,
      vertexBuffers: [.single(.float3, location: 0), .single(.float2, location: 1)])
    flatFillPipeline = try pipeline(
      .convoyFlat, primitive: .triangles, blend: .normal, depth: .testAndWrite,
      vertexBuffers: [.single(.float3, location: 0)])
    flatLinePipeline = try pipeline(
      .convoyFlat, primitive: .lines, blend: .normal, depth: .testAndWrite,
      vertexBuffers: [.single(.float3, location: 0)])
    // A sprite per mote rather than a point, with depth tested and not written, as three's
    // `depthWrite={false}` has it: so a mote never hides another.
    dustPipeline = try pipeline(
      .convoyDust, primitive: .triangles, blend: .additive, depth: .test,
      vertexBuffers: [
        .single(.float3, location: 0, perInstance: true),
        .single(.float, location: 1, perInstance: true),
      ])
  }

  /// A run of vertices in a buffer of its own; none for an empty run, which draws nothing.
  private func part(_ values: [SIMD3<Float>]) throws -> Part {
    if values.isEmpty { return Part() }
    return Part(vertices: try buffer(values), count: values.count)
  }

  override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
    let (rawBass, rawHigh) = input.wideLevels
    bass = Analyser.ease(bass, toward: rawBass, dt: dt, fall: 3.6)
    high = Analyser.ease(high, toward: rawHigh, dt: dt, fall: 5.2)
    if input.running { elapsed += dt * (0.75 + bass * 1.2) }

    road.uTime = elapsed
    road.uBass = bass
    road.uHigh = high
    dust.uTime = elapsed
    dust.uHigh = high

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

    let projection = camera.projectionMatrix(aspect: aspect)
    let view = camera.viewMatrix
    let roadGroup = Matrix4.model(position: .zero, rotation: SIMD3(0, 0, roadRoll))
    road.projectionMatrix = projection
    road.modelViewMatrix = view * roadGroup * Matrix4.model(position: SIMD3(0, -1.85, -2))
    stripeModelView = view * roadGroup * Matrix4.model(position: SIMD3(0, 0.48, -0.5))
    sunModelView = view * Matrix4.model(position: SIMD3(-10.5, 8.4, -4))
    ridgeModelView = view * Matrix4.model(position: SIMD3(0, 0, -3))
    flat.projectionMatrix = projection
    dust.projectionMatrix = projection
    dust.modelViewMatrix = view * Matrix4.model(position: SIMD3(0, 0, 0.4))

    let convoyGroup =
      Matrix4.model(position: .zero, rotation: SIMD3(0, 0, convoyRoll))
      * Self.scaling(SIMD3(convoyScale, 1, 1))
    for index in vehicles.indices {
      // One suspension cycle each, a fifth of a beat apart down the line, so the bass walks
      // along the convoy instead of bouncing all five at once.
      let tread = sin(elapsed * 9.5 - Float(index) * 1.35)
      let stand = SIMD3(Self.places[index], 0.8 + tread * (0.025 + bass * 0.16), Float(0))
      vehicles[index].modelView =
        view * convoyGroup
        * Matrix4.model(position: stand, rotation: SIMD3(0, 0, tread * bass * 0.018))
        * Self.scaling(SIMD3(repeating: Self.scales[index]))
    }
  }

  /// three's own order: the opaque objects first — the road and every part of every vehicle —
  /// and then the transparent ones back to front, the sun behind the ridge behind the kerb,
  /// with the dust last of all. Among the opaque draws the order is free, because they all
  /// test and write depth; among the transparent ones it is not, because they blend.
  override public func encode(_ pass: any GPUPass) {
    pass.setPipeline(roadPipeline)
    pass.setUniforms(road, binding: 0)
    pass.setVertexBuffer(roadMesh.positions, slot: 0)
    pass.setVertexBuffer(roadMesh.uvs, slot: 1)
    pass.drawIndexed(roadMesh.indices, count: roadMesh.count, instanceCount: 1)

    for vehicle in vehicles {
      flat.modelViewMatrix = vehicle.modelView
      paint(pass, flatFillPipeline, vehicle.fill, colour: Self.fillInk, opacity: 1)
      paint(pass, flatLinePipeline, vehicle.body, colour: Self.bodyInk, opacity: 1)
      paint(pass, flatLinePipeline, vehicle.cargo, colour: Self.cargoInk, opacity: 1)
    }

    flat.modelViewMatrix = sunModelView
    flat.uColour = Self.sunInk
    flat.uOpacity = 0.72
    pass.setPipeline(flatFillPipeline)
    pass.setUniforms(flat, binding: 0)
    pass.setVertexBuffer(sunMesh.positions, slot: 0)
    pass.drawIndexed(sunMesh.indices, count: sunMesh.count, instanceCount: 1)

    flat.modelViewMatrix = ridgeModelView
    paint(pass, flatLinePipeline, ridgeLines, colour: Self.ridgeInk, opacity: 0.7)
    flat.modelViewMatrix = stripeModelView
    paint(pass, flatLinePipeline, stripes, colour: Self.stripeInk, opacity: 0.75)

    pass.setPipeline(dustPipeline)
    pass.setUniforms(dust, binding: 0)
    pass.setVertexBuffer(dustMesh.positions, slot: 0)
    pass.setVertexBuffer(dustMesh.speeds, slot: 1)
    pass.draw(vertexCount: Self.spriteVertices, instanceCount: Self.dustCount)
  }

  /// One flat-coloured run, filled or drawn as lines by `pipeline`.
  private func paint(
    _ pass: any GPUPass, _ pipeline: any GPUPipeline, _ part: Part, colour: SIMD3<Float>,
    opacity: Float
  ) {
    guard let vertices = part.vertices, part.count > 0 else { return }
    flat.uColour = colour
    flat.uOpacity = opacity
    pass.setPipeline(pipeline)
    pass.setUniforms(flat, binding: 0)
    pass.setVertexBuffer(vertices, slot: 0)
    pass.draw(vertexCount: part.count)
  }

  /// A scale, innermost — where `Object3D.matrix` puts it, before the turn and the position.
  private static func scaling(_ scale: SIMD3<Float>) -> Matrix4 {
    Matrix4(
      SIMD4(scale.x, 0, 0, 0), SIMD4(0, scale.y, 0, 0), SIMD4(0, 0, scale.z, 0), SIMD4(0, 0, 0, 1))
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
}
