import DriftboxGPU
import Foundation

// C's maths, which Foundation brings with it on Apple's platforms and not on Android.
#if canImport(Android)
  import Android
#endif

/// The trench run, after Atari's vector Star Wars cabinet.
///
/// The trench IS the station's equatorial groove. That sentence is the whole scene. A dive
/// into something has to be a dive into THAT thing, so the groove is cut into the sphere —
/// the hull's latitude rings stop at the trench lip, the floor is a ring of its own at a
/// smaller radius, and flying down it is flying around the station's equator.
///
/// Two things fall out of that, and both are improvements. There is no scrolling and no
/// wrapping, because the trench is a closed ring and travelling is an angle going up; and from
/// orbit the groove is visible on the hull as a band missing from the sphere, so the thing you
/// are about to dive into is the thing you can already see.
///
/// The station has to be big for its floor to read as a canyon rather than a bowl, and big
/// means the far plane has to move. The layer ships 200 for everybody; this scene pushes its
/// own camera to 10500.
///
/// The web scene declares no `<fog>` at all, so there is nothing to port either way — for the
/// `ShaderMaterial` three would not have applied one, and the beams' `LineBasicMaterial` had
/// none to receive. The fog in the station shader is the scene's own uniform, and that does
/// carry across: it is distance fog whose range travels with the dive.
public final class TrenchScene: GPUGeometryScene {
  override public class var id: String { "trench" }
  override public class var name: String { "Trench" }
  override public class var accent: SIMD3<Float> { SIMD3(120, 255, 210) / 255 }
  override public class var background: SIMD3<Float> { SIMD3(0x01, 0x01, 0x0a) / 255 }

  /// The station is very large, and that is the whole reason the trench looks straight.
  ///
  /// Curvature over the visible stretch is just arc length over radius. At 420 the hundred and
  /// fifty units you can see ahead bend through seventeen degrees, and the floor visibly rolls
  /// away like the inside of a barrel. At 3200 the same stretch bends through three, which is
  /// what the cabinet's trench does — it converges to a vanishing point and does not curl.
  /// Flat is not a shading choice here; it is a radius.
  static let stationRadius: Float = 3200
  static let trenchHalfWidth: Float = 30
  static let trenchDepth: Float = 46
  static let floorRadius = stationRadius - trenchDepth
  /// Cross-sections around the full ring. At this radius that is a rib every seven units —
  /// closer together and the walls stop reading as ribs and become a solid sheet of lines.
  static let ribs = 2870
  /// Where the run starts, as a distance from the station's centre.
  static let orbitRadius: Float = 7400
  static let orbitHeight: Float = 1750
  /// How high above the trench floor the ship ends up flying. Enough that the breathing floor
  /// never reaches it: the pulse is 2.5 units and the ship needs to clear that with room to
  /// spare, or a loud bar puts the camera underground.
  static let flyHeight: Float = 16
  /// How far round the station the approach swings before the dive, in radians. The camera
  /// arcs through this and arrives at the trench entry, which is what carries the dish past
  /// the frame instead of welding it to face wherever the run happens to start.
  static let approachSweep: Float = 1.15
  /// The lens. Wide in orbit, so the whole station fits; long in the trench, where a narrow
  /// angle stops the near walls splaying out at the frame edges.
  static let orbitFov: Float = 60
  static let trenchFov: Float = 46
  /// Far enough to see the whole station. The layer's default of 200 would clip it in half
  /// before it had finished appearing. Depth precision does not suffer for it: everything here
  /// is additive lines with no depth writes, so there is nothing to z-fight.
  static let farPlane: Float = 10500

  /// Segments per laser beam. Enough to bend smoothly, few enough to rewrite every frame.
  static let beamSegments = 7
  /// How far in front of the camera the cannons sit. Only the frame they define matters.
  static let muzzleDistance: Float = 3
  /// Strands per beam. A one-pixel line is a hairline however bright the colour, so three
  /// chains side by side, hue-split, give the beam both body and a prismatic edge.
  static let beamStrands: [Float] = [-1, 0, 1]
  static var beamVertices: Int { 4 * beamStrands.count * beamSegments * 2 }

  var station = TrenchStationUniforms()
  /// What stands in for three's `LineBasicMaterial` on the beams. It has no shader of its own,
  /// so this is the whole of what it does here: the vertex colour, and one opacity.
  var beam = TrenchBeamUniforms()

  var stationPositions: (any GPUBuffer)!
  var stationKinds: (any GPUBuffer)!
  var stationCount = 0
  var beamPositions: (any GPUBuffer)!
  var beamColours: (any GPUBuffer)!
  /// What the beams' buffers are written from: the Metal scene wrote them in place, and here
  /// they are filled on the CPU and handed over whole.
  var beamPositionData = [SIMD3<Float>](repeating: .zero, count: TrenchScene.beamVertices)
  var beamColourData = [SIMD3<Float>](repeating: .zero, count: TrenchScene.beamVertices)
  var stationPipeline: (any GPUPipeline)!
  var beamPipeline: (any GPUPipeline)!

  /// How far round the equator the ship has flown, in radians.
  var flown: Float = 0
  var approach: Float = 0
  var clock: Float = 0
  var roll: Float = 0
  var firing = false

  override public func build() throws {
    station.uTouch = SIMD2(0.5, 0.5)
    station.uFog = SIMD2(1900, 11000)
    beam.uOpacity = 0.95

    let built = Self.buildStation()
    stationPositions = try buffer(built.positions)
    stationKinds = try buffer(built.kinds)
    stationCount = built.positions.count

    // Rewritten in full every frame the cannons are lit, so they are allocated once at their
    // final size rather than rebuilt on the beat.
    beamPositions = try buffer(beamPositionData)
    beamColours = try buffer(beamColourData)

    stationPipeline = try pipeline(
      .trenchStation, primitive: .lines, blend: .additive,
      vertexBuffers: [.single(.float3, location: 0), .single(.float, location: 1)])
    beamPipeline = try pipeline(
      .trenchBeam, primitive: .lines, blend: .additive,
      vertexBuffers: [.single(.float3, location: 0), .single(.float3, location: 1)])
  }

  override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
    let (bass, high) = input.wideLevels
    let warp = touchEnergy

    clock += dt
    // The dive only happens once the music does. Before that you are holding station.
    if input.running { approach = min(1, approach + dt * 0.16) }
    // Squared, so it hangs in orbit and then drops. A linear descent reads as a lift.
    let drop = approach * approach

    station.uBass = Analyser.ease(station.uBass, toward: bass, dt: dt, fall: 5)
    station.uHigh = Analyser.ease(station.uHigh, toward: high, dt: dt, fall: 6)
    station.uWarp = warp
    station.uTouch = touchAt
    // Wide open in orbit, close in once you are down in the groove. One fixed range cannot
    // serve a shot that starts a kilometre out and ends in a ditch.
    station.uFog = SIMD2(1900 - 1830 * drop, 11000 - 10520 * drop)

    // Travel is an ANGLE. There is no scrolling geometry and nothing to wrap.
    let speed = (16 + bass * 52) * (0.25 + drop * 1.6)
    flown += (dt * speed) / Self.stationRadius

    // The flight path, in the same cylindrical coordinates the station is built in: from high
    // and far out, to down inside the groove.
    let radius = Self.orbitRadius + (Self.floorRadius + Self.flyHeight - Self.orbitRadius) * drop
    let height = Self.orbitHeight * (1 - drop) + (touchAt.y - 0.5) * 3 * warp
    // The approach ARCS. The camera starts a radian or so round the station and swings to the
    // trench entry as it drops, so the hull turns under you and the dish comes past — which is
    // a better answer than bolting the dish to face the starting angle, because it does not
    // care where on the station the dish happens to be.
    let ang = flown
    let around = ang - Self.approachSweep * (1 - drop)
    camera.position = SIMD3(cos(around) * radius, height, sin(around) * radius)
    camera.far = Self.farPlane
    // And the lens lengthens as it goes. A wide angle is right for holding the whole station
    // in frame and wrong inside a corridor, where it splays the near walls out to the corners.
    camera.fovDegrees = Self.orbitFov + (Self.trenchFov - Self.orbitFov) * drop

    // The aim swings from the station itself to a point along the trench ahead. At the start
    // you are looking AT the thing; by the end you are looking down it.
    //
    // The target sits at the ship's OWN radius, not on the floor. Aiming at the floor a short
    // way ahead pitches the camera down at it, which frames the ground rather than the
    // corridor — the trench only reads as somewhere you are flying if the look is level and
    // far enough ahead to be past where the floor curves away.
    let aheadAng = ang + 0.05
    let lookRadius = Self.floorRadius + Self.flyHeight
    let look = SIMD3<Float>(
      cos(aheadAng) * lookRadius * drop, 0, sin(aheadAng) * lookRadius * drop)
    // UP is radial once you are in the groove, and this is the whole orientation of the scene.
    // A trench cut round an equator opens RADIALLY OUTWARD, and its two walls are the north and
    // south faces — so from inside it, "out of the trench" points away from the station's axis,
    // which is horizontal in world terms, and the walls are above and below you in world Y.
    // Leaving up as world-up flies the whole run rolled ninety degrees.
    let up = SIMD3<Float>(0, 1, 0).mix(SIMD3(cos(around), 0, sin(around)), drop).normalized
    roll += ((touchAt.x - 0.5) * -0.35 * warp - roll) * min(1, dt * 3)

    let world = Self.cameraWorld(position: camera.position, target: look, up: up, roll: roll)
    let view = world.inverse
    let projection = camera.projectionMatrix(aspect: aspect)
    station.projectionMatrix = projection
    station.modelViewMatrix = view
    beam.projectionMatrix = projection
    beam.modelViewMatrix = view

    // Four cannons at the corners of the screen, converging on the finger. Both ends are
    // derived from the camera rather than written down: a muzzle at a fixed offset is in the
    // corner on the viewport you happened to test and off the edge on every other.
    firing = warp > 0.002 && drop > 0.35
    beam.uOpacity = 0.95 * min(1, warp * 1.35)
    guard firing else { return }
    fire(world: world, projection: projection, up: up, aspect: aspect)
  }

  /// Rewrite every strand of every beam, from the corners of the frame to the finger.
  private func fire(
    world: Matrix4, projection: Matrix4, up: SIMD3<Float>, aspect: Float
  ) {
    let halfHeight = tan(camera.fovDegrees * .pi / 360) * Self.muzzleDistance
    let halfWidth = halfHeight * aspect

    // three's `unproject`: any depth on the line through that screen point gives the same
    // direction from the eye, so the 0...1 depth convention does not matter here.
    // Unprojected into the camera's own space and turned into the world's rather than through
    // the inverse of projection and view, as three does in doubles: in Float, a point a fraction
    // of a unit in front of an eye thousands of units out loses most of its digits when the eye
    // is taken off it again, and the beams landed wherever that rounding put them.
    let ndc = SIMD4<Float>(touchAt.x * 2 - 1, touchAt.y * 2 - 1, 0.5, 1)
    let eye = projection.inverse * ndc
    let toward = world * SIMD4(eye.x / eye.w, eye.y / eye.w, eye.z / eye.w, 0)
    let aim = SIMD3(toward.x, toward.y, toward.z).normalized
    let target = camera.position + aim * 70

    var v = 0
    for cannon in 0..<4 {
      let corner = SIMD4<Float>(
        cannon % 2 != 0 ? halfWidth : -halfWidth, cannon < 2 ? -halfHeight : halfHeight,
        -Self.muzzleDistance, 1)
      let placed = world * corner
      let muzzle = SIMD3(placed.x, placed.y, placed.z)
      let direction = (target - muzzle).normalized
      let perpendicular = direction.cross(up).normalized
      let hue = (Float(cannon) / 4 + clock * 0.12).truncatingRemainder(dividingBy: 1)

      for strand in Self.beamStrands {
        let colour = Self.hsl(hue + strand * 0.045 + 1, strand == 0 ? 0.72 : 0.55)
        for segment in 0..<Self.beamSegments {
          // Both ends of each segment, so the chain is drawn as separate lines rather than as
          // a strip — which is what the web's `lineSegments` wants.
          for end in 0...1 {
            let t = Float(segment + end) / Float(Self.beamSegments)
            var at = muzzle + (target - muzzle) * t
            // Wobble and spread, both widest mid-flight and zero at either end, so the beam
            // still leaves the corner and still lands exactly on the finger.
            let w = sin(t * .pi)
            at += perpendicular * (strand * w * 0.5)
            at.x += sin(t * 13 + clock * 11 + Float(cannon) * 1.7) * w * 0.9
            at.y += cos(t * 9 + clock * 8 + Float(cannon) * 2.3) * w * 0.9
            beamPositionData[v] = at
            beamColourData[v] = colour
            v += 1
          }
        }
      }
    }
    // A frame is drawn whether or not the beams could be written; they are last frame's if not.
    try? beamPositionData.withUnsafeBytes { try beamPositions.update($0) }
    try? beamColourData.withUnsafeBytes { try beamColours.update($0) }
  }

  /// The station, then the beams over it — which is the order three sorts them into, both
  /// being transparent and both sitting at the origin. No depth at all: the station leaves
  /// `depthWrite` off, and although the beams do write depth they are drawn last, so nothing in
  /// the scene is ever tested against anything.
  override public func encode(_ pass: any GPUPass) {
    pass.setPipeline(stationPipeline)
    pass.setUniforms(station, binding: 0)
    pass.setVertexBuffer(stationPositions, slot: 0)
    pass.setVertexBuffer(stationKinds, slot: 1)
    pass.draw(vertexCount: stationCount)

    guard firing else { return }
    pass.setPipeline(beamPipeline)
    pass.setUniforms(beam, binding: 0)
    pass.setVertexBuffer(beamPositions, slot: 0)
    pass.setVertexBuffer(beamColours, slot: 1)
    pass.draw(vertexCount: Self.beamVertices)
  }

  /// A point on the station: an angle round the equator, a height along its axis, and a
  /// distance from that axis. Everything here is built in these three.
  private static func at(_ angle: Float, _ y: Float, _ radius: Float) -> SIMD3<Float> {
    SIMD3(cos(angle) * radius, y, sin(angle) * radius)
  }

  /// three's `Matrix4.lookAt` followed by `Object3D.rotateZ`, as the world transform of a
  /// camera that is not using world up. The layer's `Camera` always takes up as (0, 1, 0), and
  /// the whole orientation of this scene is that in the groove it is not.
  private static func cameraWorld(
    position: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>, roll: Float
  ) -> Matrix4 {
    var back = position - target
    if back.lengthSquared == 0 { back.z = 1 }
    back = back.normalized
    var right = up.cross(back)
    if right.lengthSquared == 0 {
      // three nudges the axis rather than giving up, so a camera looking straight along its
      // own up still produces a frame instead of a matrix full of NaN.
      if abs(up.z) == 1 { back.x += 0.0001 } else { back.z += 0.0001 }
      back = back.normalized
      right = up.cross(back)
    }
    right = right.normalized
    let over = back.cross(right)
    let basis = Matrix4(
      SIMD4(right.x, right.y, right.z, 0), SIMD4(over.x, over.y, over.z, 0),
      SIMD4(back.x, back.y, back.z, 0), SIMD4(position.x, position.y, position.z, 1))
    // `rotateZ` turns the camera about its OWN z, so it multiplies on the right.
    let c = cos(roll)
    let s = sin(roll)
    let spin = Matrix4(
      SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
    return basis * spin
  }

  /// three's `Color.setHSL`, which is where the beams' hue split comes from. Saturation is one
  /// at every call site here, so it is folded in rather than carried as an argument.
  private static func hsl(_ hue: Float, _ lightness: Float) -> SIMD3<Float> {
    let h = hue - floor(hue)
    let l = min(1, max(0, lightness))
    let high = l <= 0.5 ? l * 2 : 1
    let low = 2 * l - high
    func channel(_ offset: Float) -> Float {
      var t = h + offset
      if t < 0 { t += 1 }
      if t > 1 { t -= 1 }
      if t < 1.0 / 6 { return low + (high - low) * 6 * t }
      if t < 1.0 / 2 { return high }
      if t < 2.0 / 3 { return low + (high - low) * 6 * (2.0 / 3 - t) }
      return low
    }
    return SIMD3(channel(1.0 / 3), channel(0), channel(-1.0 / 3))
  }

  /// The hull, the groove cut into it, the clutter bolted to its walls and the dish — one
  /// buffer, one draw call, because they are all the same station.
  ///
  /// Deterministic pseudo-random rather than anything seeded from the clock: the greebles have
  /// to be in the same place every time the scene opens, or switching away and back rebuilds a
  /// different station and it stops being a place.
  private static func buildStation() -> (positions: [SIMD3<Float>], kinds: [Float]) {
    var positions: [SIMD3<Float>] = []
    var kinds: [Float] = []
    positions.reserveCapacity(200_000)
    kinds.reserveCapacity(200_000)
    var random = Noise(seed: 1337)

    func line(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ kind: Float) {
      positions.append(a)
      positions.append(b)
      kinds.append(kind)
      kinds.append(kind)
    }

    let halfWidth = trenchHalfWidth
    let floorAt = floorRadius
    let hullAt = stationRadius

    // --- The groove.
    for i in 0..<ribs {
      let ang = Float(i) / Float(ribs) * .pi * 2
      let next = Float(i + 1) / Float(ribs) * .pi * 2

      // Floor across, and an upright up each wall to the lip.
      line(at(ang, -halfWidth, floorAt), at(ang, halfWidth, floorAt), 0)
      line(at(ang, -halfWidth, floorAt), at(ang, -halfWidth, hullAt), 0)
      line(at(ang, halfWidth, floorAt), at(ang, halfWidth, hullAt), 0)

      // Rails running the length, at the floor line and along both lips — what gives the speed
      // something continuous to read against. No special case at the join: a ring has no last
      // rib, which is one of the things that got simpler.
      for rail in [
        SIMD2<Float>(-halfWidth, floorAt), SIMD2(halfWidth, floorAt),
        SIMD2(-halfWidth, hullAt), SIMD2(halfWidth, hullAt),
      ] {
        line(at(ang, rail.x, rail.y), at(next, rail.x, rail.y), 0)
      }

      // Machinery comes in readable bays rather than isolated little cubes. The local
      // coordinates are distance along the trench, projection from the wall, and height above
      // the floor. Everything still follows the station's closed equatorial ring.
      guard i % 4 == 0 else { continue }
      let side: Float = random.next() < 0.5 ? -1 : 1
      func point(_ x: Float, _ inset: Float, _ h: Float) -> SIMD3<Float> {
        at(ang + x / stationRadius, side * (halfWidth - inset), floorAt + h)
      }
      func edge(_ a: (Float, Float, Float), _ b: (Float, Float, Float), _ kind: Float = 1) {
        line(point(a.0, a.1, a.2), point(b.0, b.1, b.2), kind)
      }
      func box(
        _ x0: Float, _ x1: Float, _ d0: Float, _ d1: Float, _ h0: Float, _ h1: Float,
        _ kind: Float = 1
      ) {
        for x in [x0, x1] {
          edge((x, d0, h0), (x, d1, h0), kind)
          edge((x, d0, h1), (x, d1, h1), kind)
          edge((x, d0, h0), (x, d0, h1), kind)
          edge((x, d1, h0), (x, d1, h1), kind)
        }
        for d in [d0, d1] {
          edge((x0, d, h0), (x1, d, h0), kind)
          edge((x0, d, h1), (x1, d, h1), kind)
        }
      }
      let width = 12 + random.next() * 6
      let height = 9 + random.next() * 5
      let base = 5 + random.next() * 17
      let depth = 4 + random.next() * 2
      let type = (i / 4) % 4

      // A mounting plate and two long supply runs make each assembly belong to the wall.
      // Elbows bring the conduits out to the front of the housing.
      box(-width / 2 - 1, width / 2 + 1, 0, 0.8, base - 1, base + height + 1, 0)
      for h in [base - 2, base + height + 2] {
        edge((-12, 1.2, h), (10, 1.2, h), 2)
        edge((10, 1.2, h), (10, depth, h), 2)
        edge((10, depth, h), (width / 2, depth, h + (h < base ? 2 : -2)), 2)
      }

      if type == 0 {
        // Stepped heat exchanger: deep housing, raised rim and recessed louvres.
        box(-width / 2, width / 2, 0.8, depth, base, base + height)
        box(-width / 2 + 1, width / 2 - 1, depth, depth + 1.2, base + 1, base + height - 1)
        for fin in 0..<6 {
          let h = base + 2 + Float(fin) * (height - 4) / 5
          edge((-width / 2 + 2, depth + 0.9, h), (width / 2 - 2, depth + 0.9, h), 2)
          edge((-width / 2 + 2, depth + 0.9, h), (-width / 2 + 2, depth + 0.2, h + 0.6))
        }
        for lamp in 0..<3 {
          let x = -width / 2 + 2 + Float(lamp) * 2
          edge((x, depth + 1.25, base + height - 0.6), (x + 0.9, depth + 1.25, base + height - 0.6), 3)
        }
      } else if type == 1 {
        // Twin coolant cylinders, with retaining bands and connections to the wall.
        for x in [-width * 0.25, width * 0.25] {
          let radius: Float = 2.2
          for h in [base, base + height * 0.25, base + height * 0.75, base + height] {
            for segment in 0..<10 {
              let a = Float(segment) * .pi / 5
              let b = Float(segment + 1) * .pi / 5
              edge(
                (x + cos(a) * radius, 3.2 + sin(a) * radius, h),
                (x + cos(b) * radius, 3.2 + sin(b) * radius, h), 2)
            }
          }
          for rib in 0..<4 {
            let a = Float(rib) * .pi / 2
            edge(
              (x + cos(a) * radius, 3.2 + sin(a) * radius, base),
              (x + cos(a) * radius, 3.2 + sin(a) * radius, base + height))
          }
          edge((x, 3.2, base + height), (x, 3.2, base + height + 2), 2)
          edge((x, 3.2, base + height + 2), (x, 0, base + height + 2), 2)
        }
      } else if type == 2 {
        // An exhaust mouth inside a square duct, with an inner ring and radial vanes.
        box(-width / 2, width / 2, 0.8, depth, base, base + height)
        let radius = min(width, height) * 0.4
        let middle = base + height / 2
        for r in [radius, radius * 0.3] {
          for segment in 0..<12 {
            let a = Float(segment) * .pi / 6
            let b = Float(segment + 1) * .pi / 6
            edge(
              (cos(a) * r, depth + 0.15, middle + sin(a) * r),
              (cos(b) * r, depth + 0.15, middle + sin(b) * r))
          }
        }
        for vane in 0..<8 {
          let a = Float(vane) * .pi / 4
          edge(
            (cos(a) * radius * 0.3, depth + 0.2, middle + sin(a) * radius * 0.3),
            (cos(a + 0.35) * radius, depth + 0.2, middle + sin(a + 0.35) * radius), 2)
        }
      } else {
        // A paired gun mount with a pedestal, a head and long stepped barrels. These project
        // along the wall; none of the machinery enters the ship's flight lane.
        box(-5, 5, 0.8, 6, base, base + 3)
        box(-3, 3, 2, 5, base + 3, base + 6)
        box(-4, 4, 1.5, 6, base + 6, base + 9)
        for d in [Float(2.3), 5.2] {
          box(4, 8, d - 0.7, d + 0.7, base + 7, base + 8.4)
          box(8, 16, d - 0.4, d + 0.4, base + 7.3, base + 8.1, 2)
          edge((16, d - 0.4, base + 7.7), (16, d + 0.4, base + 7.7), 3)
        }
      }

      // Shallow service hatches near the floor's edge give downward glances detail, while the
      // central twenty units remain clear for the run and its breathing floor.
      box(-6, 6, 5, 12, 0.2, 0.8, 0)
      for slat in 0..<4 {
        let x = -4 + Float(slat) * 2.5
        edge((x, 6, 0.85), (x, 11, 0.85), 2)
      }

      // A recognisable landmark every eight bays: fly beneath a triangulated gantry. Its
      // lowest tie is 36 units up, well clear of the 16-unit camera height.
      if i % 32 == 0 {
        box(-2, 2, 0, halfWidth * 2, 36, 40, 0)
        for span in 0..<6 {
          let d = Float(span) * 10
          edge((-2, d, 36), (-2, d + 10, 40), 1)
          edge((2, d, 40), (2, d + 10, 36), 1)
        }
        for d in [Float(2), halfWidth * 2 - 2] {
          edge((0, d, 32), (0, d, 35), 3)
        }
      }
    }

    // --- The hull, stopping at the trench lips.
    //
    // Latitude rings that would fall inside the groove are simply not drawn, and meridian
    // segments that would cross it are skipped. That absence IS the trench: from outside you
    // see a band missing from the sphere, which is the one detail that makes a wireframe ball
    // read as that battle station.
    let lats = 22
    let ringSteps = 72
    for i in 1..<lats {
      let phi = Float(i) / Float(lats) * .pi - .pi / 2
      let y = sin(phi) * hullAt
      if abs(y) < halfWidth { continue }
      let r = cos(phi) * hullAt
      for s in 0..<ringSteps {
        line(
          at(Float(s) / Float(ringSteps) * .pi * 2, y, r),
          at(Float(s + 1) / Float(ringSteps) * .pi * 2, y, r), 0)
      }
    }
    let meridians = 30
    for m in 0..<meridians {
      let ang = Float(m) / Float(meridians) * .pi * 2
      let steps = 26
      for s in 0..<steps {
        let p0 = Float(s) / Float(steps) * .pi - .pi / 2
        let p1 = Float(s + 1) / Float(steps) * .pi - .pi / 2
        let y0 = sin(p0) * hullAt
        let y1 = sin(p1) * hullAt
        if abs(y0) < halfWidth || abs(y1) < halfWidth { continue }
        line(at(ang, y0, cos(p0) * hullAt), at(ang, y1, cos(p1) * hullAt), 0)
      }
    }

    // --- The dish, sunk into the northern hemisphere. Concentric rings and spokes, which is
    // how a vector machine would have drawn a crater.
    //
    // Placed on the arc the approach sweeps over rather than aimed at a single starting angle.
    // The camera swings through `approachSweep` radians before the dive, so a dish sitting near
    // the middle of that arc is carried across the frame as the hull turns — which is a
    // property of the flight path, not a coincidence of where the run begins.
    let lat: Float = 0.5
    let lon: Float = 2.12
    let normal = SIMD3<Float>(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))
    let centre = normal * (hullAt * 0.93)
    let right = SIMD3<Float>(0, 1, 0).cross(normal).normalized
    let over = normal.cross(right).normalized
    func dishAt(_ radius: Float, _ angle: Float, _ sink: Float) -> SIMD3<Float> {
      centre + right * (cos(angle) * radius) + over * (sin(angle) * radius) - normal * sink
    }
    // Scaled with the station, and about a fifth of its radius across — the dish is the one
    // silhouette detail that says which battle station this is, so it has to read from orbit
    // rather than being a technically-present ring.
    for ring in [
      SIMD2<Float>(hullAt * 0.2, 0), SIMD2(hullAt * 0.13, hullAt * 0.045),
      SIMD2(hullAt * 0.055, hullAt * 0.075),
    ] {
      for i in 0..<32 {
        line(
          dishAt(ring.x, Float(i) / 32 * .pi * 2, ring.y),
          dishAt(ring.x, Float(i + 1) / 32 * .pi * 2, ring.y), 0)
      }
    }
    for i in 0..<10 {
      let a = Float(i) / 10 * .pi * 2
      line(dishAt(hullAt * 0.2, a, 0), dishAt(hullAt * 0.055, a, hullAt * 0.075), 0)
    }

    return (positions, kinds)
  }
}
