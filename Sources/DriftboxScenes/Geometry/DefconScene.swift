import DriftboxGPU
import Foundation

/// DEFCON.
///
/// A map, seen from almost straight down, with two sides that shoot at each other on the beat.
/// It is the only scene where the music causes something to HAPPEN rather than something to
/// move: a kick launches a missile, the missile takes four seconds to fly, and it lands
/// whenever it lands. So the picture is running a couple of bars behind the record at all
/// times, which is the point — a launch and its arrival are different events, and the gap
/// between them is the whole feeling of the game it comes from.
///
/// Abstract rather than cartographic. The territories are generated blobs, not coastlines,
/// because a recognisable world map invites you to look for your own house and this wants to be
/// read as a board. What is kept from the original is the colour language and nothing else:
/// deep blue landmasses with thin pale outlines, green for one side, red for the other, white
/// only at the moment of impact.
///
/// The web scene has no `<fog>`, so there is none to port. Four of its six objects are three's
/// own `LineBasicMaterial`, which has no shader to copy — the two line programs here are the
/// smallest shaders that do what it does, a flat colour at an opacity or one interpolated from
/// the vertices.
public final class DefconScene: GPUGeometryScene {
  override public class var id: String { "defcon" }
  override public class var name: String { "Defcon" }
  override public class var accent: SIMD3<Float> { SIMD3(255, 250, 200) / 255 }
  override public class var background: SIMD3<Float> { SIMD3(0x01, 0x03, 0x0e) / 255 }

  static let worldX: Float = 38
  static let worldZ: Float = 30
  /// Missiles in the air at once.
  static let missiles = 14
  /// Points along a trajectory. The arc is drawn as it is flown, so this is also how smooth the
  /// curve looks at the moment it lands.
  static let arcPoints = 18
  static let impacts = 10
  static let ringPoints = 30
  static let citiesPerSide = 7
  static let arcVertices = missiles * (arcPoints - 1) * 2
  static let ringVertices = impacts * ringPoints * 2
  /// How many points a blob's outline is drawn with.
  static let blobPoints = 44

  static let green = SIMD3<Float>(0x4b, 0xff, 0x9d) / 255
  static let red = SIMD3<Float>(0xff, 0x3b, 0x4d) / 255
  static let white = SIMD3<Float>(1, 1, 1)

  struct City {
    var x: Float
    var z: Float
    /// -1 west, +1 east.
    var side: Float
  }

  struct Missile {
    var from: City
    var to: City
    /// 0 at launch, 1 on impact. Negative means the slot is free.
    var t: Float
    var speed: Float
  }

  struct Impact {
    var x: Float = 0
    var z: Float = 0
    var age: Float = -1
    var side: Float = 1
  }

  var land = DefconLandUniforms()
  /// One flat colour at one opacity: three's `LineBasicMaterial` without vertex colours.
  var line = DefconLineUniforms()
  /// The same material with `vertexColors` on, where the colour arrives per vertex instead.
  var tint = DefconTintUniforms()

  var landMesh: (any GPUBuffer)!
  var landCount = 0
  var coastMesh: (any GPUBuffer)!
  var coastCount = 0
  var graticuleMesh: (any GPUBuffer)!
  var graticuleCount = 0
  var glyphMesh: (any GPUBuffer)!
  var glyphColours: (any GPUBuffer)!
  var glyphCount = 0
  var arcMesh: (any GPUBuffer)!
  var arcColours: (any GPUBuffer)!
  var ringMesh: (any GPUBuffer)!
  var ringColours: (any GPUBuffer)!
  /// What the arc and ring buffers are written from each frame, made once at full size as the
  /// buffers are: Metal filled its buffers in place, and this layer replaces a buffer's contents.
  var arcPositions = [SIMD3<Float>](repeating: .zero, count: DefconScene.arcVertices)
  var arcTints = [SIMD3<Float>](repeating: .zero, count: DefconScene.arcVertices)
  var ringPositions = [SIMD3<Float>](repeating: .zero, count: DefconScene.ringVertices)
  var ringTints = [SIMD3<Float>](repeating: .zero, count: DefconScene.ringVertices)

  var landPipeline: (any GPUPipeline)!
  var linePipeline: (any GPUPipeline)!
  var tintPipeline: (any GPUPipeline)!

  var cities: [City] = []
  var flight: [Missile] = []
  var hits = [Impact](repeating: Impact(), count: DefconScene.impacts)
  var nextMissile = 0
  var nextImpact = 0
  var clock: Float = 0
  var alert: Float = 0
  var onLaunch = Onset(rise: 1.45, refractory: 0.3)
  var roll = Noise(seed: 20240)

  override public func build() throws {
    line.uColour = SIMD3(1, 1, 1)
    line.uOpacity = 1
    tint.uOpacity = 1

    let world = Self.world()
    cities = world.cities
    landMesh = try buffer(world.land)
    landCount = world.land.count
    coastMesh = try buffer(world.coast)
    coastCount = world.coast.count

    // The graticule. Sparse and very dim: it is there to say "this is a map", and any brighter
    // it competes with the thing the map is for.
    var grid: [SIMD3<Float>] = []
    var x = -Self.worldX
    while x <= Self.worldX {
      grid.append(contentsOf: [SIMD3(x, 0, -Self.worldZ), SIMD3(x, 0, Self.worldZ)])
      x += 9.5
    }
    var z = -Self.worldZ
    while z <= Self.worldZ {
      grid.append(contentsOf: [SIMD3(-Self.worldX, 0, z), SIMD3(Self.worldX, 0, z)])
      z += 9.5
    }
    graticuleMesh = try buffer(grid)
    graticuleCount = grid.count

    // A glyph per city: a small diamond, which is as much vector iconography as reads at this
    // distance. Colour is baked in, since a city never changes sides.
    var glyphs: [SIMD3<Float>] = []
    var colours: [SIMD3<Float>] = []
    for city in cities {
      let colour = city.side < 0 ? Self.green : Self.red
      let r: Float = 1.15
      let corners: [SIMD2<Float>] = [SIMD2(0, -r), SIMD2(r, 0), SIMD2(0, r), SIMD2(-r, 0)]
      for i in 0..<4 {
        let a = corners[i]
        let b = corners[(i + 1) % 4]
        glyphs.append(SIMD3(city.x + a.x, 0.05, city.z + a.y))
        glyphs.append(SIMD3(city.x + b.x, 0.05, city.z + b.y))
        colours.append(contentsOf: [colour, colour])
      }
    }
    glyphMesh = try buffer(glyphs)
    glyphColours = try buffer(colours)
    glyphCount = glyphs.count

    // The arcs and the rings are rewritten every frame, so they are allocated once at full size
    // and filled in place rather than rebuilt.
    arcMesh = try buffer(arcPositions)
    arcColours = try buffer(arcTints)
    ringMesh = try buffer(ringPositions)
    ringColours = try buffer(ringTints)

    flight = [Missile](
      repeating: Missile(from: cities[0], to: cities[0], t: -1, speed: 0.25), count: Self.missiles)

    landPipeline = try pipeline(
      .defconLand, primitive: .triangles, blend: .additive, vertexBuffers: [.single(.float3, location: 0)])
    linePipeline = try pipeline(
      .defconLine, primitive: .lines, blend: .normal, vertexBuffers: [.single(.float3, location: 0)])
    tintPipeline = try pipeline(
      .defconTint, primitive: .lines, blend: .additive,
      vertexBuffers: [.single(.float3, location: 0), .single(.float3, location: 1)])
  }

  /// One of the seven cities on a side. Clamped, unlike the web: `Noise` hands its value back
  /// as a `Float`, and one a hair under one rounds up on the way in — which would index off the
  /// end of the side it belongs to. The web's double-precision generator cannot get there.
  private func pickCity() -> Int {
    min(Self.citiesPerSide - 1, Int(roll.next() * Float(Self.citiesPerSide)))
  }

  /// A plain parabola. Ballistic enough at this scale, and the alternative — a great circle on a
  /// globe — would need a globe.
  private func arcAt(_ missile: Missile, _ t: Float) -> SIMD3<Float> {
    let flat = min(1, max(0, t))
    let run = missile.to.x - missile.from.x
    let rise = missile.to.z - missile.from.z
    let reach = (run * run + rise * rise).squareRoot()
    return SIMD3(
      missile.from.x + run * flat, sin(flat * .pi) * reach * 0.22, missile.from.z + rise * flat)
  }

  override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
    let (bass, high) = input.wideLevels
    clock += dt

    land.uBass += (bass - land.uBass) * min(1, dt * 4)

    // Launch on the beat. Two at a time when it is loud, which is what turns an exchange into a
    // war over the course of a section.
    let kick = onLaunch.detect(bass, dt: dt)
    if kick > 0 {
      let salvo = kick > 0.5 ? 2 : 1
      for _ in 0..<salvo {
        let west = roll.next() < 0.5
        let from = cities[(west ? 0 : Self.citiesPerSide) + pickCity()]
        let to = cities[(west ? Self.citiesPerSide : 0) + pickCity()]
        flight[nextMissile].from = from
        flight[nextMissile].to = to
        flight[nextMissile].t = 0
        // Slow. The gap between a launch and its arrival is the whole point, so this is measured
        // in bars rather than in frames.
        flight[nextMissile].speed = 0.16 + roll.next() * 0.09
        nextMissile = (nextMissile + 1) % Self.missiles
      }
    }

    // Fly, and land.
    var v = 0
    var airborne = 0
    for index in flight.indices {
      if flight[index].t >= 0 {
        flight[index].t += dt * flight[index].speed
        airborne += 1
        if flight[index].t >= 1 {
          flight[index].t = -1
          hits[nextImpact].x = flight[index].to.x
          hits[nextImpact].z = flight[index].to.z
          hits[nextImpact].age = 0
          hits[nextImpact].side = flight[index].to.side
          nextImpact = (nextImpact + 1) % Self.impacts
          alert = 1
        }
      }
      let missile = flight[index]
      let colour = missile.from.side < 0 ? Self.green : Self.red
      let span = Float(Self.arcPoints - 1)
      for s in 0..<(Self.arcPoints - 1) {
        // Only the flown part of the arc is drawn; the rest is collapsed onto the launch site,
        // where it is invisible. Cheaper than a draw range per missile and it means the
        // trajectory draws itself as the thing travels.
        let t0 = missile.t < 0 ? 0 : (Float(s) / span) * missile.t
        let t1 = missile.t < 0 ? 0 : (Float(s + 1) / span) * missile.t
        arcPositions[v] = arcAt(missile, t0)
        arcPositions[v + 1] = arcAt(missile, t1)
        // Brightest at the head, so it reads as something travelling rather than as a line that
        // happens to be getting longer.
        let lead = missile.t < 0 ? 0 : pow(Float(s + 1) / span, 3)
        // Only the very tip goes pale. Whitening the whole trail loses which side fired it,
        // which is the one thing a trajectory has to tell you.
        let tip = colour.mix(Self.white, lead * 0.35)
        let shade = tip * (missile.t < 0 ? 0 : 0.3 + lead * 1.4)
        arcTints[v] = shade
        arcTints[v + 1] = shade
        v += 2
      }
    }
    // A frame is drawn whether or not these could be written; they are last frame's if not.
    try? arcPositions.withUnsafeBytes { try arcMesh.update($0) }
    try? arcTints.withUnsafeBytes { try arcColours.update($0) }

    // Impacts: a ring that expands and dies.
    var r = 0
    for index in hits.indices {
      if hits[index].age >= 0 {
        hits[index].age += dt
        if hits[index].age > 3.2 { hits[index].age = -1 }
      }
      let hit = hits[index]
      let live = hit.age >= 0
      // Kept small. A blast ring that grows to a third of the board stops being a place
      // something happened and becomes weather.
      let radius = live ? hit.age * 3.4 : 0
      let fade = live ? max(0, 1 - hit.age / 3.2) : 0
      // White at the instant of impact and into its side's colour as it dies. Cubed, so almost
      // all of the brightness is in the first half second.
      let side = hit.side < 0 ? Self.green : Self.red
      let shade = Self.white.mix(side, 1 - fade) * (fade * fade * fade * 3.4)
      for s in 0..<Self.ringPoints {
        let a0 = Float(s) / Float(Self.ringPoints) * .pi * 2
        let a1 = Float(s + 1) / Float(Self.ringPoints) * .pi * 2
        ringPositions[r] = SIMD3(hit.x + cos(a0) * radius, 0.1, hit.z + sin(a0) * radius)
        ringPositions[r + 1] = SIMD3(hit.x + cos(a1) * radius, 0.1, hit.z + sin(a1) * radius)
        ringTints[r] = shade
        ringTints[r + 1] = shade
        r += 2
      }
    }
    try? ringPositions.withUnsafeBytes { try ringMesh.update($0) }
    try? ringTints.withUnsafeBytes { try ringColours.update($0) }

    // How bad it has got. Rises on every impact and decays slowly, and the land runs from blue
    // toward red with it — the DEFCON level, without a readout saying so.
    alert = max(0, alert - dt * 0.14)
    let level = min(1, alert + Float(airborne) / Float(Self.missiles))
    land.uAlert += (level - land.uAlert) * min(1, dt * 1.5)

    // Nearly overhead, drifting. A finger tips the board toward the horizon, which turns a map
    // into a battlefield without ever leaving it.
    let portrait = aspect < 0.85
    let lean = touchEnergy * (touchAt.y - 0.5) * 46
    let swing = sin(clock * 0.06) * 3 + (touchAt.x - 0.5) * 14 * touchEnergy
    // The BOARD turns, not the camera. This map is half again as wide as it is deep, and a
    // phone's horizontal field of view is about 0.6 of its vertical — so framing it landscape on
    // a portrait screen means backing off until it is a strip through the middle with dead space
    // above and below. Turned a quarter, the same map fills the same phone at two thirds the
    // distance. Reshape the subject, not the lens.
    let yaw: Float = portrait ? .pi / 2 : 0
    // And the extents swap with it. Seen from near overhead the board's depth is foreshortened,
    // so its on-screen height is the shorter side times about 0.85.
    let across = portrait ? Self.worldZ : Self.worldX
    let deep = (portrait ? Self.worldX : Self.worldZ) * 0.85
    let range = fitDistance(camera: camera, aspect: aspect, halfWidth: across, halfHeight: deep)
    camera.position = SIMD3(swing, range * 0.94 - lean * 0.5 + high * 1.5, range * 0.3 + lean)
    camera.target = .zero

    land.projectionMatrix = camera.projectionMatrix(aspect: aspect)
    // three turns the group the whole board is in, which is a model matrix in front of the view.
    land.modelViewMatrix = camera.viewMatrix * Matrix4.model(position: .zero, rotation: SIMD3(0, yaw, 0))
    line.projectionMatrix = land.projectionMatrix
    line.modelViewMatrix = land.modelViewMatrix
    tint.projectionMatrix = land.projectionMatrix
    tint.modelViewMatrix = land.modelViewMatrix
  }

  /// Graticule, land, coast, glyphs, arcs, rings — three's own order, which here is the order
  /// the objects are declared in: everything is transparent and everything sits at the group's
  /// origin, so the depth sort finds nothing to sort by and falls back on how they were added.
  /// No pipeline asks for depth: the camera is above a board that is flat to within a tenth
  /// of a unit, so every later object is nearer than the one before it and the order alone
  /// decides what covers what.
  override public func encode(_ pass: any GPUPass) {
    pass.setPipeline(linePipeline)
    line.uColour = SIMD3(0x12, 0x3a, 0x6b) / 255
    line.uOpacity = 0.32
    pass.setUniforms(line, binding: 0)
    pass.setVertexBuffer(graticuleMesh, slot: 0)
    pass.draw(vertexCount: graticuleCount)

    pass.setPipeline(landPipeline)
    pass.setUniforms(land, binding: 0)
    pass.setVertexBuffer(landMesh, slot: 0)
    pass.draw(vertexCount: landCount)

    pass.setPipeline(linePipeline)
    line.uColour = SIMD3(0x8f, 0xd0, 0xff) / 255
    line.uOpacity = 0.5
    pass.setUniforms(line, binding: 0)
    pass.setVertexBuffer(coastMesh, slot: 0)
    pass.draw(vertexCount: coastCount)

    pass.setPipeline(tintPipeline)
    tint.uOpacity = 0.9
    pass.setUniforms(tint, binding: 0)
    pass.setVertexBuffer(glyphMesh, slot: 0)
    pass.setVertexBuffer(glyphColours, slot: 1)
    pass.draw(vertexCount: glyphCount)

    tint.uOpacity = 1
    pass.setUniforms(tint, binding: 0)
    pass.setVertexBuffer(arcMesh, slot: 0)
    pass.setVertexBuffer(arcColours, slot: 1)
    pass.draw(vertexCount: Self.arcVertices)

    pass.setVertexBuffer(ringMesh, slot: 0)
    pass.setVertexBuffer(ringColours, slot: 1)
    pass.draw(vertexCount: Self.ringVertices)
  }

  /// The board, built once. Deterministic: it has to be the same board every time it opens, and
  /// the web's generator is the same linear congruential one `Noise` is.
  private static func world() -> (land: [SIMD3<Float>], coast: [SIMD3<Float>], cities: [City]) {
    var random = Noise(seed: 7734)

    // Territories: blobs, not coastlines. A circle with its radius pushed around by a few
    // harmonics gives something that reads as land at a glance and as nothing in particular on
    // inspection, which is exactly the intent.
    //
    // Spaced so they barely touch. Overlapping blobs each draw their own closed outline, and the
    // outlines that end up INSIDE the landmass read as soap bubbles rather than as coastline — a
    // coast is a boundary, and boundaries do not cross each other.
    let blobs: [SIMD3<Float>] = [
      SIMD3(-27, -14, 9), SIMD3(-14, -3, 10), SIMD3(-29, 11, 8), SIMD3(-9, 17, 7),
      SIMD3(21, -15, 9), SIMD3(29, -1, 9), SIMD3(15, 9, 8), SIMD3(31, 16, 7),
    ]
    var land: [SIMD3<Float>] = []
    var coast: [SIMD3<Float>] = []
    for blob in blobs {
      let centre = SIMD2(blob.x, blob.y)
      let radius = blob.z
      let wob0 = 0.3 + random.next() * 0.5
      let wob1 = 0.2 + random.next() * 0.4
      let wob2 = 0.15 + random.next() * 0.3
      let phase0 = random.next() * 6.28
      let phase1 = random.next() * 6.28
      let phase2 = random.next() * 6.28
      let n = blobPoints
      var points: [SIMD2<Float>] = []
      for i in 0..<n {
        let a = Float(i) / Float(n) * .pi * 2
        let r =
          radius
          * (1 + sin(a * 2 + phase0) * wob0 * 0.55 + sin(a * 3 + phase1) * wob1 * 0.45
            + sin(a * 5 + phase2) * wob2 * 0.3)
        points.append(SIMD2(centre.x + cos(a) * r, centre.y + sin(a) * r * 0.8))
      }
      for i in 0..<n {
        let a = points[i]
        let b = points[(i + 1) % n]
        // three hands the closed shape to `ShapeGeometry`, which ear-clips it. The blob is a
        // radius as a function of angle about its own centre, so it is star shaped from there
        // and a fan covers exactly the same region — no ear clipper needed to fill it.
        //
        // The fill is laid into the world with the z axis FLIPPED and the outline is not, which
        // is what the web does: it rotates and then mirrors the shape geometry and builds the
        // outline straight from the same points. So the coast sits opposite the land it belongs
        // to. Kept, because it is the picture the scene actually draws.
        land.append(contentsOf: [
          SIMD3(centre.x, 0, -centre.y), SIMD3(a.x, 0, -a.y), SIMD3(b.x, 0, -b.y),
        ])
        // Negated to follow the fill, which the scale below mirrors across z. The web
        // pushed these straight through, which left every coastline across the board from
        // its landmass; emmettl/driftbox#300 fixes it there.
        coast.append(contentsOf: [SIMD3(a.x, 0.02, -a.y), SIMD3(b.x, 0.02, -b.y)])
      }
    }

    // Cities, kept on their own side of the board and off the very edge.
    var cities: [City] = []
    for side in [Float(-1), Float(1)] {
      for _ in 0..<citiesPerSide {
        let x = side * (7 + random.next() * (worldX - 12))
        let z = (random.next() - 0.5) * (worldZ * 1.5)
        cities.append(City(x: x, z: z, side: side))
      }
    }

    return (land, coast, cities)
  }
}
