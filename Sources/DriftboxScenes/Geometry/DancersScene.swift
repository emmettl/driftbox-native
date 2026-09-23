import DriftboxGPU
import Foundation

/// Wireframe dancers.
///
/// The first scene with a FIGURE in it. Everything else here is a place, a body or a board;
/// this is people, and people are the one subject where the eye knows immediately whether you
/// got it right — a tunnel can be any width and nobody argues, but a forearm that is too long
/// reads as wrong before you have worked out why.
///
/// So the interesting problem is not drawing them, it is moving them. Nothing here is
/// keyframed. Every joint is a few sinusoids of the beat phase with a per-dancer offset, which
/// is cheap and, more importantly, means they are dancing to the actual transport rather than
/// to a loop that happens to be running alongside it. Miss a beat and they wait.
///
/// They watch the cursor. A dancer turns to face wherever your finger is and reaches toward it
/// when it comes close, so a drag across the floor pulls the room round with it. That is the
/// whole interaction and it is worth more than any amount of extra articulation.
///
/// Both materials are `ShaderMaterial`s, which three leaves out of the fog by default, so there
/// is no fog to port on either of them.
public final class DancersScene: GPUGeometryScene {
  override public class var id: String { "dancers" }
  override public class var name: String { "Dancers" }
  override public class var accent: SIMD3<Float> { SIMD3(255, 90, 190) / 255 }
  override public class var background: SIMD3<Float> { SIMD3(0x07, 0x03, 0x0d) / 255 }

  static let figures = 5
  /// Points around the head ring. Eight is enough to read as a head and few enough to stay
  /// angular, which is the same call the Rez corridor makes about its ribs.
  static let headPoints = 8
  static let beams = 4
  /// Room for one figure's line segments.
  ///
  /// A ceiling rather than a count. The figure is built from prisms, rings and balls whose
  /// numbers are easy to get wrong by one and tedious to keep in step with the drawing code, so
  /// the buffer is generously sized and the draw range is whatever was actually emitted.
  /// Miscounting downward would silently truncate a leg.
  static let segmentsPerFigure = 360
  static var figureVertices: Int { figures * segmentsPerFigure * 2 }
  static var beamVertices: Int { beams * 3 }

  static let palette: [SIMD3<Float>] = [
    SIMD3(0xff, 0x2e, 0x93) / 255, SIMD3(0x5f, 0xf0, 0xff) / 255, SIMD3(0xff, 0xd2, 0x3b) / 255,
    SIMD3(0x7d, 0xff, 0x6b) / 255, SIMD3(0xc8, 0x6b, 0xff) / 255,
  ]

  /// Limb lengths, in the same units the camera is framed against. Kept to real-ish human
  /// proportions: the forearm slightly shorter than the upper arm, the shin the same as the
  /// thigh, and the head about an eighth of the total. Getting these wrong is the fastest way
  /// to make a figure look like a stick insect.
  enum Body {
    static let hipWidth: Float = 0.19
    static let shoulderWidth: Float = 0.36
    static let spine: Float = 0.78
    static let neck: Float = 0.17
    static let head: Float = 0.15
    static let upperArm: Float = 0.34
    static let foreArm: Float = 0.31
    static let thigh: Float = 0.44
    static let shin: Float = 0.44

    // Thicknesses. A lay figure is a stack of tapered blocks joined by balls, and it is the
    // TAPER that reads as anatomy — a limb of constant width is a pipe. Every one of these is a
    // half-width, so a shoulder 0.15 across is 0.30 wide.
    static let chestTop: Float = 0.23
    static let waist: Float = 0.155
    static let pelvisBottom: Float = 0.2
    static let armTop: Float = 0.075
    static let armMid: Float = 0.055
    static let armEnd: Float = 0.042
    static let legTop: Float = 0.105
    static let legMid: Float = 0.075
    static let legEnd: Float = 0.05
    static let neckWide: Float = 0.055

    // The balls. Oversized against the limbs they join, which is what makes a mannequin a
    // mannequin rather than a mildly lumpy person.
    static let shoulderBall: Float = 0.085
    static let elbowBall: Float = 0.062
    static let hipBall: Float = 0.1
    static let kneeBall: Float = 0.08
  }

  /// What a dancer is doing.
  ///
  /// Five bodies running one cycle at five offsets is a chorus line, not a floor. These are
  /// three genuinely different motions, and the difference is mostly in the LEGS — which is
  /// also true of real dancing, where the arms follow and the feet decide.
  ///
  /// `bounce` is knees soft and weight rocking side to side, the default groove. `run` is on
  /// the spot: knees high in front, arms pumping opposite. `man` is the running man, whose
  /// whole trick is that it is a run played backwards — the lifted knee comes up in FRONT while
  /// the standing foot slides BEHIND, so the dancer appears to sprint without going anywhere.
  /// Getting that sign wrong just produces a jog.
  enum Move {
    case bounce
    case run
    case man
  }

  struct Dancer {
    var move: Move
    /// Where in the line this one stands, -1 to 1. Turned into a position each frame, since how
    /// far apart they should be depends on the shape of the window.
    var across: Float
    var x: Float = 0
    var z: Float
    /// Where in the bar this one is, so five bodies are not one body drawn five times.
    var phase: Float
    /// How big its movements are.
    var gusto: Float
    var facing: Float = 0
    var colour: SIMD3<Float>
  }

  var figure = DancersFigureUniforms()
  var beam = DancersBeamUniforms()
  var dancers: [Dancer] = []
  var figurePositions: (any GPUBuffer)!
  var figureColours: (any GPUBuffer)!
  var figureGlow: (any GPUBuffer)!
  /// What the figure buffers are refilled from each frame: the GPU layer's buffers are written
  /// whole from memory rather than through a pointer into them, so the frame is built here first.
  var figurePositionData = [SIMD3<Float>](repeating: .zero, count: DancersScene.figureVertices)
  var figureColourData = [SIMD3<Float>](repeating: .zero, count: DancersScene.figureVertices)
  var figureGlowData = [Float](repeating: 0, count: DancersScene.figureVertices)
  /// How many line vertices were emitted this frame — the web's `setDrawRange`.
  var figureCount = 0
  var beamPositions: (any GPUBuffer)!
  var beamPositionData = [SIMD3<Float>](repeating: .zero, count: DancersScene.beamVertices)
  var beamColours: (any GPUBuffer)!
  var beamDrop: (any GPUBuffer)!
  var figurePipeline: (any GPUPipeline)!
  var beamPipeline: (any GPUPipeline)!
  var clock: Float = 0
  var beat: Float = 0

  override public func build() throws {
    // Every figure vertex is rewritten each frame, so these are allocated once at full size and
    // drawn with a varying count rather than rebuilt when a pose changes.
    figurePositions = try buffer(figurePositionData)
    figureColours = try buffer(figureColourData)
    figureGlow = try buffer(figureGlowData)
    beamPositions = try buffer(beamPositionData)

    var colours: [SIMD3<Float>] = []
    var drops: [Float] = []
    for index in 0..<Self.beams {
      let colour = Self.palette[(index + 1) % Self.palette.count]
      for vertex in 0..<3 {
        colours.append(colour)
        // The apex is at the lamp; the two base corners are on the floor.
        drops.append(vertex == 0 ? 0 : 1)
      }
    }
    beamColours = try buffer(colours)
    beamDrop = try buffer(drops)

    var random = Noise(seed: 1989)
    // Two of the five do the running man, one runs, the rest groove — enough that the eye finds
    // the pattern and not so much that it looks like a routine.
    let moves: [Move] = [.man, .bounce, .run, .man, .bounce]
    dancers = (0..<Self.figures).map { index in
      // An arc rather than a line, so the ones at the ends turn inward and the group reads as a
      // group rather than as a row of separate people.
      let across = (Float(index) / Float(Self.figures - 1) - 0.5) * 2
      return Dancer(
        move: moves[index % moves.count], across: across,
        z: -abs(across) * 0.9 + random.next() * 0.3, phase: random.next(),
        gusto: 0.75 + random.next() * 0.5, colour: Self.palette[index % Self.palette.count])
    }

    let layouts: [GPUVertexLayout] = [
      .single(.float3, location: 0), .single(.float3, location: 1), .single(.float, location: 2),
    ]
    figurePipeline = try pipeline(
      .dancersFigure, primitive: .lines, blend: .additive, vertexBuffers: layouts)
    beamPipeline = try pipeline(
      .dancersBeam, primitive: .triangles, blend: .additive, vertexBuffers: layouts)
  }

  override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
    let (bass, high) = input.wideLevels
    clock += dt
    figure.uBass += (bass - figure.uBass) * min(1, dt * 6)
    beam.uHigh += (high - beam.uHigh) * min(1, dt * 7)

    // The beat clock. Advanced by the transport's own tempo rather than by a fixed rate, so the
    // dancing is ON the record instead of merely near it.
    let bpm = Float(input.bpm)
    beat = (beat + dt * (bpm / 60)).truncatingRemainder(dividingBy: 4)

    // Where the finger is, on the floor. Worked out against the camera as it was left last
    // frame, which is where the finger was actually pointing when it was put there.
    let ray = camera.ray(through: touchAt, aspect: aspect)
    let hit = ray.y == 0 ? 0 : -camera.position.y / ray.y
    let reach = ray * max(0, hit) + camera.position

    // How far apart they stand. A line of five is a wide, shallow subject, and on a phone the
    // width is what the frame runs out of first — so they close up rather than the camera
    // backing off until they are ants. Reshape the subject, not the lens; the same call the
    // Lifeforms bodies and the Defcon board both make.
    let portrait = aspect < 0.85
    let spread: Float = portrait ? 1.2 : 2.5
    for index in dancers.indices { dancers[index].x = dancers[index].across * spread }

    var v = 0

    for index in dancers.indices {
      // Turn to face the finger, easing round rather than snapping — a head that tracks
      // instantly reads as a turret.
      let want = atan2(reach.x - dancers[index].x, reach.z - dancers[index].z)
      let delta =
        (want - dancers[index].facing + .pi * 3).truncatingRemainder(dividingBy: .pi * 2) - .pi
      dancers[index].facing += delta * min(1, dt * 2.5 * (0.3 + touchEnergy))
      let d = dancers[index]
      let away = reach.x - d.x
      let ahead = reach.z - d.z
      let near = exp(-(away * away + ahead * ahead) * 0.12) * touchEnergy

      let t = (beat + d.phase * 4).truncatingRemainder(dividingBy: 4)
      let swing = sin(t * .pi)
      let punch = abs(sin(t * .pi))
      let lift = d.gusto * (0.6 + figure.uBass * 1.4)

      // Hips: a bounce on every beat and a sway across every two.
      let hipY = 0.86 - punch * 0.07 * lift
      let hipX = sin(t * .pi * 0.5) * 0.06 * lift
      let lean = near * 0.35

      let facingCos = cos(d.facing)
      let facingSin = sin(d.facing)
      /// Local (x = across, y = up, z = forward) into world.
      func put(_ p: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(
          d.x + p.x * facingCos + p.z * facingSin, p.y, d.z - p.x * facingSin + p.z * facingCos)
      }

      let chestY = hipY + Body.spine
      let chestZ = lean * 0.5
      let headY = chestY + Body.neck + Body.head

      func line(_ from: SIMD3<Float>, _ to: SIMD3<Float>, _ heat: Float) {
        // Past the end of this figure's slice. Writing on would corrupt the next dancer's limbs
        // rather than failing, which is the worst way for a miscount to show up.
        if v >= (index + 1) * Self.segmentsPerFigure * 2 { return }
        figurePositionData[v] = put(from)
        figurePositionData[v + 1] = put(to)
        figureColourData[v] = d.colour
        figureColourData[v + 1] = d.colour
        figureGlowData[v] = heat
        figureGlowData[v + 1] = heat
        v += 2
      }

      let beatGlow = punch * 0.5 + near * 0.5

      /// A tapered four-sided prism between two points — one limb segment.
      ///
      /// The awkward part is the cross-section's orientation: a prism needs two axes
      /// perpendicular to the bone, and there is no natural choice, so one is taken from any
      /// reference that is not parallel to it. Using a fixed reference falls apart exactly when
      /// a limb points along it, which for a dancer is every time an arm goes straight up —
      /// hence the swap to a sideways reference for near-vertical bones.
      func bone(
        _ from: SIMD3<Float>, _ to: SIMD3<Float>, _ r0: Float, _ r1: Float, _ heat: Float
      ) {
        var dir = to - from
        let len = dir.length
        if len < 1e-4 { return }
        dir /= len
        let reference: SIMD3<Float> = abs(dir.y) > 0.92 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let sideways = dir.cross(reference).normalized
        let forward = dir.cross(sideways).normalized

        // Turned an eighth, so the flats face the viewer and the silhouette is a rectangle
        // rather than a diamond.
        func corner(_ base: SIMD3<Float>, _ k: Int, _ radius: Float) -> SIMD3<Float> {
          let angle = Float(k) * .pi / 2 + .pi / 4
          return base + (sideways * cos(angle) + forward * sin(angle)) * radius
        }
        for k in 0..<4 {
          let n = (k + 1) % 4
          line(corner(from, k, r0), corner(from, n, r0), heat)
          line(corner(to, k, r1), corner(to, n, r1), heat)
          line(corner(from, k, r0), corner(to, k, r1), heat)
        }
      }

      /// A joint. Two perpendicular rings, which is the cheapest thing that reads as a sphere
      /// and, on a lay figure, the detail that says the limb pivots there.
      func ball(_ centre: SIMD3<Float>, _ radius: Float, _ heat: Float) {
        let count = 6
        for i in 0..<count {
          let a0 = Float(i) / Float(count) * .pi * 2
          let a1 = Float(i + 1) / Float(count) * .pi * 2
          line(
            SIMD3(centre.x + cos(a0) * radius, centre.y + sin(a0) * radius, centre.z),
            SIMD3(centre.x + cos(a1) * radius, centre.y + sin(a1) * radius, centre.z), heat)
          line(
            SIMD3(centre.x, centre.y + sin(a0) * radius, centre.z + cos(a0) * radius),
            SIMD3(centre.x, centre.y + sin(a1) * radius, centre.z + cos(a1) * radius), heat)
        }
      }

      let waistY = hipY + Body.spine * 0.42

      // Torso: two blocks and a waist ball, which is how the real thing is built and why it can
      // bend at all. One prism from hips to shoulders would be a barrel.
      let waist = SIMD3(hipX * 0.6, waistY, chestZ * 0.4)
      let chest = SIMD3(0, chestY, chestZ)
      bone(SIMD3(hipX, hipY, 0), waist, Body.pelvisBottom, Body.waist, beatGlow)
      ball(waist, Body.waist * 0.95, beatGlow)
      bone(waist, chest, Body.waist, Body.chestTop, beatGlow)
      bone(
        chest, SIMD3(0, chestY + Body.neck, chestZ), Body.neckWide, Body.neckWide * 0.85, beatGlow)

      // Arms. Up on the beat, and reaching toward the finger when it is close — which is the
      // whole point of the scene, so it gets the biggest number in here.
      let pumping = d.move != .bounce
      for side in [-1, 1] as [Float] {
        // A runner's arms are bent and driving forward and back; a groover's swing out to the
        // sides. Same two bones, and it is the axis that changes.
        let raise =
          pumping
          ? 0.9 + swing * side * 0.5 * lift + near * 1.5 : swing * side * 0.9 * lift + near * 1.5
        let shoulderX = side * Body.shoulderWidth
        let elbowX = shoulderX + side * Body.upperArm * cos(raise * 0.8)
        let elbowY = chestY + Body.upperArm * sin(raise * 0.9) * 0.8
        let elbowZ = chestZ + near * 0.4 - (pumping ? swing * side * 0.22 * lift : 0)
        let handX = elbowX + side * Body.foreArm * cos(raise * 1.4) * 0.7
        let handY = elbowY + Body.foreArm * sin(raise * 1.5 + 0.4)
        let handZ = elbowZ + near * 0.7 - (pumping ? swing * side * 0.34 * lift : 0)
        let shoulder = SIMD3(shoulderX, chestY, chestZ)
        let elbow = SIMD3(elbowX, elbowY, elbowZ)
        let hand = SIMD3(handX, handY, handZ)
        ball(shoulder, Body.shoulderBall, beatGlow)
        bone(shoulder, elbow, Body.armTop, Body.armMid, beatGlow)
        ball(elbow, Body.elbowBall, beatGlow)
        bone(elbow, hand, Body.armMid, Body.armEnd, beatGlow + near * 0.6)
        // The mitt. A lay figure has no fingers, just a flat paddle, and leaving it off is the
        // difference between a mannequin and an armature.
        let along = hand - elbow
        let span = along.length == 0 ? 1 : along.length
        bone(
          hand, hand + along / span * 0.09, Body.armEnd * 1.25, Body.armEnd * 0.9,
          beatGlow + near * 0.6)
      }

      // Legs. The move lives here.
      for side in [-1, 1] as [Float] {
        // One leg leads and the other trails, half a beat apart.
        let legPhase = sin((t + (side < 0 ? 0 : 1)) * .pi)
        let hipJointX = hipX + side * Body.hipWidth

        let bend: Float
        let kneeZ: Float
        let footZ: Float
        let footDrop: Float
        switch d.move {
        case .bounce:
          let step = legPhase * 0.32 * lift
          bend = 0.72 + abs(step) * 0.5 - punch * 0.12
          kneeZ = step * 0.55
          footZ = step * 1.15
          footDrop = 0.92 - abs(step) * 0.35
        case .run:
          // Knee up in front, foot tucked under it. The lift is the whole read.
          let up = max(0, legPhase) * lift
          bend = 0.74 - up * 0.34
          kneeZ = up * 0.5
          footZ = up * 0.22
          footDrop = 0.9 - up * 0.44
        case .man:
          // The running man. The lifted knee comes up in FRONT and the standing foot slides
          // BACK at the same moment — the two happen together and in opposite directions, which
          // is what makes it look like sprinting on the spot. Do both forward and it is a jog;
          // do neither and it is a march.
          let up = max(0, legPhase) * lift
          let slide = max(0, -legPhase) * lift
          bend = 0.76 - up * 0.4 + slide * 0.14
          kneeZ = up * 0.54 - slide * 0.16
          footZ = up * 0.2 - slide * 0.72
          footDrop = 0.9 - up * 0.5 + slide * 0.08
        }

        let kneeX = hipJointX + side * 0.04 + kneeZ * 0.2
        let kneeY = hipY - Body.thigh * bend
        let footX = kneeX + side * 0.03
        let footY = max(0.05, kneeY - Body.shin * footDrop)
        let hipJoint = SIMD3(hipJointX, hipY, 0)
        let knee = SIMD3(kneeX, kneeY, kneeZ)
        let foot = SIMD3(footX, footY, footZ)
        ball(hipJoint, Body.hipBall, beatGlow)
        bone(hipJoint, knee, Body.legTop, Body.legMid, beatGlow)
        ball(knee, Body.kneeBall, beatGlow)
        bone(knee, foot, Body.legMid, Body.legEnd, beatGlow)
        // And a wedge of a foot, pointing the way the dancer faces.
        bone(
          foot, SIMD3(footX, footY * 0.35, footZ + 0.11), Body.legEnd, Body.legEnd * 0.8, beatGlow)
      }

      // The head: an ovoid, taller than it is wide, drawn as three rings. No face — a lay figure
      // has none, and adding one here would be the single fastest way to make five dancers look
      // like five of the same doll.
      let headTall = Body.head * 1.22
      for i in 0..<Self.headPoints {
        let a0 = Float(i) / Float(Self.headPoints) * .pi * 2
        let a1 = Float(i + 1) / Float(Self.headPoints) * .pi * 2
        let (c0, s0) = (cos(a0), sin(a0))
        let (c1, s1) = (cos(a1), sin(a1))
        // Across, front to back, and round the equator.
        line(
          SIMD3(c0 * Body.head, headY + s0 * headTall, chestZ),
          SIMD3(c1 * Body.head, headY + s1 * headTall, chestZ), beatGlow + 0.2)
        line(
          SIMD3(0, headY + s0 * headTall, chestZ + c0 * Body.head),
          SIMD3(0, headY + s1 * headTall, chestZ + c1 * Body.head), beatGlow + 0.2)
        line(
          SIMD3(c0 * Body.head, headY, chestZ + s0 * Body.head),
          SIMD3(c1 * Body.head, headY, chestZ + s1 * Body.head), beatGlow + 0.2)
      }
    }
    figureCount = v
    // A frame is drawn whether or not its figures could be written; they are last frame's if not.
    try? figurePositionData.withUnsafeBytes { try figurePositions.update($0) }
    try? figureColourData.withUnsafeBytes { try figureColours.update($0) }
    try? figureGlowData.withUnsafeBytes { try figureGlow.update($0) }

    // The lights: four beams from above, sweeping, splayed wider on the loud bits.
    for index in 0..<Self.beams {
      let sweep = sin(clock * (0.5 + Float(index) * 0.13) + Float(index) * 1.7) * 4.5
      let splay = 0.7 + beam.uHigh * 1.1
      beamPositionData[index * 3] = SIMD3((Float(index) / Float(Self.beams - 1) - 0.5) * 7, 5.2, -2.6)
      beamPositionData[index * 3 + 1] = SIMD3(sweep - splay, 0, 1.5)
      beamPositionData[index * 3 + 2] = SIMD3(sweep + splay, 0, 1.5)
    }
    try? beamPositionData.withUnsafeBytes { try beamPositions.update($0) }

    // Framed on the group rather than at a fixed distance, so a wide window comes in instead of
    // leaving a band of empty stage above their heads. The group's extent on screen is the
    // outermost dancer plus an arm's reach across, and from the feet to the top of a raised hand
    // vertically.
    let distance = fitDistance(
      camera: camera, aspect: aspect, halfWidth: spread + 1.0, halfHeight: 1.35, fill: 0.86)
    camera.position = SIMD3(
      (touchAt.x - 0.5) * 1.2 * touchEnergy, 1.15 + figure.uBass * 0.12, distance)
    camera.target = SIMD3(0, 1.05, 0)
    figure.projectionMatrix = camera.projectionMatrix(aspect: aspect)
    figure.modelViewMatrix = camera.viewMatrix
    beam.projectionMatrix = figure.projectionMatrix
    beam.modelViewMatrix = figure.modelViewMatrix
  }

  /// Beams first and additive, so the figures are drawn over the light rather than being washed
  /// out by it. Neither material writes depth, so neither pipeline asks for it and the order on
  /// its own decides what covers what. The beams are double-sided in the web, and no backend of
  /// the GPU layer culls anything.
  override public func encode(_ pass: any GPUPass) {
    pass.setPipeline(beamPipeline)
    pass.setUniforms(beam, binding: 0)
    pass.setVertexBuffer(beamPositions, slot: 0)
    pass.setVertexBuffer(beamColours, slot: 1)
    pass.setVertexBuffer(beamDrop, slot: 2)
    pass.draw(vertexCount: Self.beamVertices)

    guard figureCount > 0 else { return }
    pass.setPipeline(figurePipeline)
    pass.setUniforms(figure, binding: 0)
    pass.setVertexBuffer(figurePositions, slot: 0)
    pass.setVertexBuffer(figureColours, slot: 1)
    pass.setVertexBuffer(figureGlow, slot: 2)
    pass.draw(vertexCount: figureCount)
  }
}
