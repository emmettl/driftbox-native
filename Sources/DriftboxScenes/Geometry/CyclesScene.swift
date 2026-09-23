import DriftboxGPU
import Foundation

// C's maths, which Foundation brings with it on Apple's platforms and not on Android.
#if canImport(Android)
  import Android
#endif

/// Light cycles. Sunset already owns "glowing grid to a horizon", so this one is shot from
/// ABOVE — the game-board view rather than the chase — which is also the only way to read
/// the shape of a trail, and the trail is the whole point of a light cycle.
///
/// The bikes travel on the axes and turn ninety degrees, which is the one rule the film
/// never breaks, and they turn ON THE BEAT: a grid full of right angles being drawn by the
/// kick drum, so the picture is a record of what the music did rather than a reaction to how
/// loud it is. Miss a beat and there is a longer straight; four in a row and you get a
/// staircase. A big hit derezzes the arena — every wall flashes white and is gone — because
/// without it the grid silts up into a solid mass after twenty seconds.
public final class CyclesScene: GPUGeometryScene {
  override public class var id: String { "cycles" }
  override public class var name: String { "Light Cycles" }
  override public class var accent: SIMD3<Float> { SIMD3(1, 1, 1) }
  override public class var background: SIMD3<Float> { SIMD3(0x01, 0x05, 0x0c) / 255 }

  /// Sized against a PORTRAIT frame, which is the tight one by a long way: a phone's
  /// horizontal field of view is about 0.6 of its vertical, and at the first size this was,
  /// the distance needed to fit the arena was past the canvas's 200-unit far plane. The
  /// arena had to come in rather than the camera going back. `cyclesGrid.frag` fades the
  /// grid against this.
  static let arena: Float = 44
  static let gridStep: Float = 5.5
  static let bikes = 5
  /// Corners kept per trail. Only turns are stored — the straights between them need no
  /// points — so this is a lot more wall than the number suggests.
  static let trailCorners = 64
  static let wallHeight: Float = 2.6
  /// Cyan first, because the hero rides the blue one.
  static let colours: [SIMD3<Float>] = [
    SIMD3(0x5f, 0xf0, 0xff) / 255, SIMD3(0xff, 0x9d, 0x2e) / 255, SIMD3(0xc8, 0x6b, 0xff) / 255,
    SIMD3(0x7d, 0xff, 0x6b) / 255, SIMD3(0xff, 0x4d, 0x7a) / 255,
  ]
  /// North, east, south, west. Right angles only, which is the rule.
  static let steps: [SIMD2<Float>] = [SIMD2(0, -1), SIMD2(1, 0), SIMD2(0, 1), SIMD2(-1, 0)]

  struct Bike {
    var x: Float
    var z: Float
    var facing: Int
    /// Corners behind it, oldest first, as x/z/time triples.
    var corners: [SIMD3<Float>] = []
    var positions: any GPUBuffer
    var ages: any GPUBuffer
    /// How many indices to draw this frame.
    var indexCount = 0
  }

  var wall = CyclesWallUniforms()
  var grid = CyclesGridUniforms()
  var bikes: [Bike] = []
  /// What a wall's buffers are written from, one bike at a time: made once at full size, as the
  /// buffers are, so a frame allocates nothing. Only the front of it is drawn for any one bike.
  var wallPositions = [SIMD3<Float>](repeating: .zero, count: CyclesScene.wallVertices)
  var wallAges = [Float](repeating: 0, count: CyclesScene.wallVertices)
  var riders = [SIMD3<Float>](repeating: .zero, count: CyclesScene.bikes)
  var wallIndices: (any GPUBuffer)!
  var gridLines: (any GPUBuffer)!
  var gridCount = 0
  var riderPositions: (any GPUBuffer)!
  var riderColours: (any GPUBuffer)!
  var wallPipeline: (any GPUPipeline)!
  var gridPipeline: (any GPUPipeline)!
  var riderPipeline: (any GPUPipeline)!
  var clock: Float = 0
  var derez: Float = 0
  var onTurn = Onset(rise: 1.4, refractory: 0.13)
  var onDerez = Onset(rise: 2.6, refractory: 3.5)
  var roll = Roll(seed: 0.2718)

  static var wallVertices: Int { (trailCorners + 1) * 2 }

  override public func build() throws {
    wall.uColour = SIMD3(1, 1, 1)
    grid.uPixel = 1

    var lines: [SIMD3<Float>] = []
    var g = -Self.arena
    while g <= Self.arena {
      lines.append(contentsOf: [SIMD3(g, 0, -Self.arena), SIMD3(g, 0, Self.arena)])
      lines.append(contentsOf: [SIMD3(-Self.arena, 0, g), SIMD3(Self.arena, 0, g)])
      g += Self.gridStep
    }
    gridLines = try buffer(lines)
    gridCount = lines.count

    // Two vertices per corner — floor and top — and two triangles per segment between them.
    // Allocated once at full size and drawn with a varying index count, because a trail that
    // reallocated its buffers every time it turned would allocate on the beat.
    var indices: [UInt32] = []
    for segment in 0..<Self.trailCorners {
      let a = UInt32(segment * 2)
      indices.append(contentsOf: [a, a + 1, a + 2, a + 1, a + 3, a + 2])
    }
    wallIndices = try self.indices(indices)

    bikes = try (0..<Self.bikes).map { index in
      // Spread around the arena, each already pointing somewhere different.
      let a = Float(index) / Float(Self.bikes) * .pi * 2
      let positions = try buffer(wallPositions)
      let ages = try buffer(wallAges)
      return Bike(
        x: cos(a) * Self.arena * 0.55, z: sin(a) * Self.arena * 0.55, facing: index % 4,
        positions: positions, ages: ages)
    }
    riderPositions = try buffer(riders)
    riderColours = try buffer((0..<Self.bikes).map { Self.colours[$0 % Self.colours.count] })

    wallPipeline = try pipeline(
      .cyclesWall, primitive: .triangles, blend: .additive,
      vertexBuffers: [.single(.float3, location: 0), .single(.float, location: 1)])
    gridPipeline = try pipeline(
      .cyclesGrid, primitive: .lines, blend: .additive, vertexBuffers: [.single(.float3, location: 0)])
    // Sprites rather than points: a rider is an instance, and its position and colour step per
    // instance.
    riderPipeline = try pipeline(
      .cyclesRider, blend: .additive,
      vertexBuffers: [
        .single(.float3, location: 0, perInstance: true), .single(.float3, location: 1, perInstance: true),
      ])
  }

  /// Which of the two legal turns points more toward the middle. Needed because a bike that
  /// turns when it reaches a wall turns ALONG the wall — the only way to face away from it
  /// is a 180, which a light cycle does not do. Left to itself every bike ends up circling
  /// the perimeter and the middle of the arena stays empty.
  private func inward(_ bike: Bike) -> Int {
    func toward(_ turn: Int) -> Float {
      let step = Self.steps[(bike.facing + turn) % 4]
      return -(bike.x * step.x + bike.z * step.y)
    }
    return toward(1) > toward(3) ? 1 : 3
  }

  private func turn(_ index: Int, towards: Int?) {
    bikes[index].corners.append(SIMD3(bikes[index].x, bikes[index].z, clock))
    if bikes[index].corners.count > Self.trailCorners { bikes[index].corners.removeFirst() }
    let by = towards ?? (roll.next() < 0.5 ? 1 : 3)
    bikes[index].facing = (bikes[index].facing + by) % 4
  }

  override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
    let (bass, high) = input.wideLevels
    clock += dt
    wall.uTime = clock
    wall.uBass += (bass - wall.uBass) * min(1, dt * 6)
    grid.uBass = wall.uBass
    grid.uPixel = input.pixelRatio

    // The derez. Rare and loud, so it lands on a crash rather than on every kick.
    if onDerez.detect(high, dt: dt) > 0 {
      derez = 1
      for index in bikes.indices { bikes[index].corners.removeAll(keepingCapacity: true) }
    }
    derez = max(0, derez - dt * 1.6)
    wall.uDerez = derez
    grid.uDerez = derez

    // One turn signal for the whole grid, so every bike corners on the same beat and the
    // arena fills with parallel right angles rather than with noise.
    let beat = onTurn.detect(bass, dt: dt) > 0
    let speed = 17 + wall.uBass * 13

    for index in bikes.indices {
      let step = Self.steps[bikes[index].facing]
      bikes[index].x += step.x * speed * dt
      bikes[index].z += step.y * speed * dt

      // Turned back at a SOFT boundary well inside the arena, not at the wall itself.
      // Turning at the wall is too late: the only legal turn there runs along it, so a bike
      // follows the edge to a corner and never comes back. A random walk on a grid drifts
      // outward on its own, so something has to push back.
      let closing = bikes[index].x * step.x + bikes[index].z * step.y < 0
      let out =
        (bikes[index].x * bikes[index].x + bikes[index].z * bikes[index].z).squareRoot() / Self.arena
      if out > 0.66 && !closing {
        // Kept turning until it is actually heading home, then left alone.
        turn(index, towards: inward(bikes[index]))
      } else if beat && roll.next() < 0.72 {
        turn(index, towards: roll.next() < out ? inward(bikes[index]) : (roll.next() < 0.5 ? 1 : 3))
      }
      // A hard stop as well, for the frame where a bike is quick enough to clear the soft
      // ring and the wall together.
      let limit = Self.arena * 0.97
      bikes[index].x = max(-limit, min(limit, bikes[index].x))
      bikes[index].z = max(-limit, min(limit, bikes[index].z))

      // Rebuild the wall: every corner behind it, plus the bike's own position as the
      // leading edge, so the newest section grows continuously between turns.
      let count = bikes[index].corners.count
      for corner in 0..<count {
        let at = bikes[index].corners[corner]
        for vertex in [corner * 2, corner * 2 + 1] {
          wallPositions[vertex] = SIMD3(at.x, vertex % 2 == 1 ? Self.wallHeight : 0, at.y)
          wallAges[vertex] = clock - at.z
        }
      }
      for vertex in [count * 2, count * 2 + 1] {
        wallPositions[vertex] = SIMD3(bikes[index].x, vertex % 2 == 1 ? Self.wallHeight : 0, bikes[index].z)
        wallAges[vertex] = 0
      }
      // Written whole into the bike's own buffers: Metal wrote them in place, and this layer
      // replaces a buffer's contents instead. A wall is last frame's if the write fails.
      let positions = bikes[index].positions
      let ages = bikes[index].ages
      try? wallPositions.withUnsafeBytes { try positions.update($0) }
      try? wallAges.withUnsafeBytes { try ages.update($0) }
      bikes[index].indexCount = count * 6
      riders[index] = SIMD3(bikes[index].x, Self.wallHeight * 0.5, bikes[index].z)
    }
    try? riders.withUnsafeBytes { try riderPositions.update($0) }

    // High and slightly off, which is the board view. A finger walks the camera round the
    // arena and drops it toward the deck, so you can go from the map to the chase.
    let orbit = clock * 0.045 + (touchAt.x - 0.5) * 2.4 * touchEnergy
    // The floor is square, but seen from this angle its depth is foreshortened to roughly
    // three quarters — so it is a wide, shallow subject however square it is on the ground.
    let fit = fitDistance(
      camera: camera, aspect: aspect, halfWidth: Self.arena * 1.45, halfHeight: Self.arena * 1.1)
    let height = fit * 0.76 - touchEnergy * (touchAt.y - 0.5) * 80
    let range = fit * 0.7 + wall.uBass * 3
    camera.position = SIMD3(sin(orbit) * range, max(9, height), cos(orbit) * range)
    // Aimed a little NEARER than the middle. Looking down at a floor, the near half is much
    // larger on screen than the far half, so centring on the origin leaves the visual mass in
    // the bottom third with empty sky above it.
    let nearer = Self.arena * 0.3
    camera.target = SIMD3(sin(orbit) * nearer, 0, cos(orbit) * nearer)
    wall.projectionMatrix = camera.projectionMatrix(aspect: aspect)
    wall.modelViewMatrix = camera.viewMatrix
    grid.projectionMatrix = wall.projectionMatrix
    grid.modelViewMatrix = wall.modelViewMatrix
  }

  override public func encode(_ pass: any GPUPass) {
    pass.setPipeline(gridPipeline)
    pass.setUniforms(grid, binding: 0)
    pass.setVertexBuffer(gridLines, slot: 0)
    pass.draw(vertexCount: gridCount)

    pass.setPipeline(wallPipeline)
    for (index, bike) in bikes.enumerated() where bike.indexCount > 0 {
      wall.uColour = Self.colours[index % Self.colours.count]
      pass.setUniforms(wall, binding: 0)
      pass.setVertexBuffer(bike.positions, slot: 0)
      pass.setVertexBuffer(bike.ages, slot: 1)
      pass.drawIndexed(wallIndices, count: bike.indexCount, instanceCount: 1)
    }

    pass.setPipeline(riderPipeline)
    pass.setUniforms(grid, binding: 0)
    pass.setVertexBuffer(riderPositions, slot: 0)
    pass.setVertexBuffer(riderColours, slot: 1)
    pass.draw(vertexCount: Self.spriteVertices, instanceCount: Self.bikes)
  }
}
