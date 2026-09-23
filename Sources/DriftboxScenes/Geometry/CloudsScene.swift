import DriftboxGPU
import Foundation

// C's maths, which Foundation brings with it on Apple's platforms and not on Android.
#if canImport(Android)
  import Android
#endif

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
public final class CloudsScene: GPUGeometryScene {
  override public class var id: String { "clouds" }
  override public class var name: String { "Clouds" }
  /// The only dark accent in the set, and the only ring: a dark blob on a bright sky is a
  /// smudge on the lens, whereas an outline reads as something drawn on top of it.
  override public class var accent: SIMD3<Float> { SIMD3(40, 70, 130) / 255 }
  /// The sky sphere is guaranteed to cover the frame, so the clear colour is never seen. It
  /// is the pale end of the sky's own gradient rather than black all the same, because black
  /// is what would show if that ever stopped being true.
  override public class var background: SIMD3<Float> { SIMD3(0.72, 0.88, 0.98) }

  /// `cloudsPuff.glsl` has room for exactly this many.
  static let clouds = 7
  static let puffs = 24
  /// How far out the clouds drift before wrapping round to the other side.
  static let span: Float = 46
  static let rainbowBands = 7
  static let rainbowSegments = 40
  static let puffCount = clouds * puffs
  static let bowCount = rainbowBands * rainbowSegments * 2

  /// Where one cloud lives, how fast it drifts, and how squashed it is right now.
  struct Drift {
    var x: Float
    var y: Float
    var z: Float
    var speed: Float
    var squash: Float = 1
    var phase: Float
  }

  var sky = CloudsSkyUniforms()
  /// Carries each cloud's placement and squash, `(x, y, z, squash)`, in `uClouds`, as the puff
  /// shader reads it: a small table updated every frame, so it goes in the uniforms rather than
  /// in a buffer of its own as Metal had it.
  var puff = CloudsPuffUniforms()
  var bow = CloudsBowUniforms()
  var drift: [Drift] = []

  var skyMesh: (positions: any GPUBuffer, indices: any GPUBuffer, count: Int)!
  var puffMesh: (positions: any GPUBuffer, cloud: any GPUBuffer, size: any GPUBuffer, top: any GPUBuffer)!
  var bowMesh: (positions: any GPUBuffer, colours: any GPUBuffer)!
  var skyPipeline: (any GPUPipeline)!
  var puffPipeline: (any GPUPipeline)!
  var bowPipeline: (any GPUPipeline)!

  var clock: Float = 0
  /// How much rainbow there is to fade toward; `bow.uShow` chases it.
  var showing: Float = 0
  var onBeat = Onset(rise: 1.4, refractory: 0.16)
  var onBow = Onset(rise: 2.4, refractory: 6)

  override public func build() throws {
    sky.uSun = SIMD3(0.2, 0.44, -1)
    puff.uPixelRatio = 1
    for i in 0..<Self.clouds { puff.uClouds[i] = SIMD4(0, 0, 0, 1) }

    // The sky is a sphere around everything rather than a background colour, because a
    // gradient needs somewhere to be drawn and this guarantees it covers the frame at any
    // aspect without any arithmetic.
    let ball = Self.sphere(radius: 140, widthSegments: 24, heightSegments: 16)
    skyMesh = try (buffer(ball.positions), indices(ball.indices), ball.indices.count)

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
    puffMesh = try (buffer(positions), buffer(cloud), buffer(size), buffer(top))

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
    bowMesh = try (buffer(bowPositions), buffer(bowColours))

    var place = Noise(seed: 4223)
    drift = (0..<Self.clouds).map { i in
      Drift(
        x: (Float(i) / Float(Self.clouds) - 0.5) * Self.span * 2 + place.next() * 6,
        y: -8 + place.next() * 22, z: -20 - place.next() * 34, speed: 0.9 + place.next() * 1.5,
        phase: place.next() * 6.28)
    }

    skyPipeline = try pipeline(
      .cloudsSky, primitive: .triangles, blend: .none, vertexBuffers: [.single(.float3, location: 0)])
    bowPipeline = try pipeline(
      .cloudsBow, primitive: .lines, blend: .normal,
      vertexBuffers: [.single(.float3, location: 0), .single(.float3, location: 1)])
    // Sprites rather than points: a puff is an instance, and everything it carries steps per
    // instance.
    puffPipeline = try pipeline(
      .cloudsPuff, blend: .normal,
      vertexBuffers: [
        .single(.float3, location: 0, perInstance: true), .single(.float, location: 1, perInstance: true),
        .single(.float, location: 2, perInstance: true), .single(.float, location: 3, perInstance: true),
      ])
  }

  override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
    let (bass, high) = input.wideLevels
    clock += dt
    sky.uBass += (bass - sky.uBass) * min(1, dt * 4)
    puff.uPixelRatio = input.pixelRatio

    let kick = onBeat.detect(bass, dt: dt) > 0
    if onBow.detect(high, dt: dt) > 0 { showing = 1 }
    // Long enough to enjoy, short enough that it is an event. At 0.12 it outlasted its own
    // refractory period and simply never left.
    showing = max(0, showing - dt * 0.28)
    bow.uShow += (showing - bow.uShow) * min(1, dt * 2)

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

      puff.uClouds[i] = SIMD4(
        drift[i].x + (away < 0 ? -1 : 1) * shove, drift[i].y + bob, drift[i].z, drift[i].squash)
    }

    // Barely moves. The clouds do the drifting; a camera that also drifts just makes it hard
    // to tell which is which.
    let portrait = aspect < 0.85
    camera.position = SIMD3(
      (touchAt.x - 0.5) * 2 * touchEnergy, 2 + high * 0.6, portrait ? 34 : 26)
    camera.rotation = SIMD3(0.06, 0, 0)
    let projection = camera.projectionMatrix(aspect: aspect)
    sky.projectionMatrix = projection
    // The sky follows the camera. `vDir` is the direction from the sphere's own centre, so it
    // only equals the direction you are actually looking if the two coincide — left at the
    // origin with the camera thirty units away, the gradient skews and the sun smears into a
    // vertical band down one side of the frame.
    sky.modelViewMatrix = camera.viewMatrix * Matrix4.model(position: camera.position)
    puff.projectionMatrix = projection
    puff.modelViewMatrix = camera.viewMatrix
    bow.projectionMatrix = projection
    bow.modelViewMatrix = camera.viewMatrix
  }

  /// Sky, rainbow, then puffs — three's own order, the opaque sphere ahead of the two
  /// transparent objects and those two in the order they are added. No pipeline asks for
  /// depth: every material here writes no depth, so there is nothing for a depth test
  /// to read and the order on its own decides what covers what.
  override public func encode(_ pass: any GPUPass) {
    pass.setPipeline(skyPipeline)
    pass.setUniforms(sky, binding: 0)
    pass.setVertexBuffer(skyMesh.positions, slot: 0)
    pass.drawIndexed(skyMesh.indices, count: skyMesh.count, instanceCount: 1)

    pass.setPipeline(bowPipeline)
    pass.setUniforms(bow, binding: 0)
    pass.setVertexBuffer(bowMesh.positions, slot: 0)
    pass.setVertexBuffer(bowMesh.colours, slot: 1)
    pass.draw(vertexCount: Self.bowCount)

    // Not additive, and not depth-written. Clouds are opaque white on a bright sky, so adding
    // them just blows out to a flat sheet; and writing depth makes the puffs within one cloud
    // cut circular holes in each other.
    pass.setPipeline(puffPipeline)
    pass.setUniforms(puff, binding: 0)
    pass.setVertexBuffer(puffMesh.positions, slot: 0)
    pass.setVertexBuffer(puffMesh.cloud, slot: 1)
    pass.setVertexBuffer(puffMesh.size, slot: 2)
    pass.setVertexBuffer(puffMesh.top, slot: 3)
    pass.draw(vertexCount: Self.spriteVertices, instanceCount: Self.puffCount)
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
}
