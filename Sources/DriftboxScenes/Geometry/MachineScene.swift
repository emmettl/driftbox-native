import DriftboxGPU
import Foundation

// C's maths, which Foundation brings with it on Apple's platforms and not on Android.
#if canImport(Android)
  import Android
#endif

/// A production line seen from close enough to feel its weight.
///
/// The set already has landscapes, bodies, boards, journeys and isolated objects. What it did
/// not have was a PROCESS: parts visibly causing other parts to move. The kick drives the
/// press, the low mids turn the flywheel and interlocked gears, hats run the rollers, and
/// stamped billets keep travelling after the hit that made them. The picture therefore has the
/// same argument as the techno record written for it — repetition is not stasis when every
/// repetition advances the line.
///
/// Solid metal under sodium light, deliberately. Another cyan wireframe machine would be the
/// old visual language wearing a new subject.
///
/// It is also the one scene in the set that is *lit* rather than shaded by a formula: the web
/// builds it from three's own `MeshStandardMaterial` under an ambient light, a directional
/// light and a point light, so the port carries a small standard-material shader of its own.
/// What it approximates is written out above `solidPipeline`.
public final class MachineScene: GPUGeometryScene {
  override public class var id: String { "machine" }
  override public class var name: String { "Machine" }
  override public class var accent: SIMD3<Float> { SIMD3(225, 240, 255) / 255 }
  /// three clears with the background colour in the output's own space, so this is the hex as
  /// written rather than the light behind it.
  override public class var background: SIMD3<Float> { SIMD3(0x10, 0x0e, 0x0b) / 255 }

  static let workpieces = 8
  static let rollers = 7
  static let sparks = 42
  /// The web reads six bands, and `SceneInput` carries sixteen. Both are constant-ratio splits
  /// of the same spectrum, so band `b` of six covers exactly bands `16b/6 ..< 16(b+1)/6` of
  /// sixteen and the six are recovered by averaging — rather than by reading lanes 1, 2 and 4
  /// of sixteen, which are three entirely different frequencies.
  static let bandCount = 6

  static let steel = machineInk(0x393733)
  static let darkSteel = machineInk(0x171716)
  static let edge = machineInk(0x777066)
  static let hot = machineInk(0xff8a24)
  static let paper = machineInk(0xc9b9a0)
  static let bed = machineInk(0x12110f)
  static let ramSteel = machineInk(0x4a4741)

  /// The exposed drive train. Every wheel turns at a related speed and direction, so it reads
  /// as one mechanism; the radii and tooth counts are what makes the three look geared to
  /// each other rather than merely adjacent.
  static let gears: [(at: SIMD3<Float>, radius: Float, teeth: Int, colour: SIMD3<Float>)] = [
    (SIMD3(-3.35, 2.55, 0.72), 1.38, 16, machineInk(0x49453e)),
    (SIMD3(-1.36, 2.02, 0.76), 0.63, 10, machineInk(0x696158)),
    (SIMD3(-0.55, 3.15, 0.72), 0.9, 12, machineInk(0x34322f)),
  ]
  /// Bed, belt, two belt edges, eight billets, two press uprights, the crown, and the ram's
  /// two blocks — then a gear's teeth and its two spokes.
  static let boxCount = 9 + workpieces + gears.reduce(0) { $0 + $1.teeth + 2 }

  /// One of the machine's parts: where it is and the four numbers its material is. The web has
  /// seventy-odd separate `Mesh` objects here, which differ only in those, so each shape is
  /// drawn once with the parts as instances.
  struct Part {
    var model = Matrix4.identity
    var normal = Matrix4.identity
    var colour = SIMD3<Float>(1, 1, 1)
    var roughness: Float = 0.5
    var metalness: Float = 0
    /// three's `emissiveIntensity`, against the one emissive colour anything here uses.
    var emissive: Float = 0
  }

  /// A part as `machineSolid.vert` reads it: one element per instance, its fields at the
  /// locations after the shape's own position and normal. Metal read the parts out of a buffer
  /// by instance id; there are no such buffers here, so the same memory steps per instance.
  static let partLayout: GPUVertexLayout = {
    func offset(_ field: PartialKeyPath<Part>) -> Int { MemoryLayout<Part>.offset(of: field)! }
    var attributes: [GPUVertexLayout.Attribute] = []
    for column in 0..<4 {
      attributes.append(
        GPUVertexLayout.Attribute(
          location: 2 + column, format: .float4, offset: offset(\Part.model) + column * 16))
    }
    for column in 0..<4 {
      attributes.append(
        GPUVertexLayout.Attribute(
          location: 6 + column, format: .float4, offset: offset(\Part.normal) + column * 16))
    }
    attributes += [
      GPUVertexLayout.Attribute(location: 10, format: .float3, offset: offset(\Part.colour)),
      GPUVertexLayout.Attribute(location: 11, format: .float, offset: offset(\Part.roughness)),
      GPUVertexLayout.Attribute(location: 12, format: .float, offset: offset(\Part.metalness)),
      GPUVertexLayout.Attribute(location: 13, format: .float, offset: offset(\Part.emissive)),
    ]
    return GPUVertexLayout(stride: MemoryLayout<Part>.stride, perInstance: true, attributes: attributes)
  }()

  /// The shapes the machine is made of. The three cylinders are one shape in three but three
  /// different radial segment counts — 16 for the rollers, 18 for the gear hubs, 14 for the
  /// flywheel shaft — and a mesh is per segment count, so they cannot share a draw.
  enum Kind: Int, CaseIterable {
    case box
    case roller
    case hub
    case shaft
    case ring
  }

  struct Shape {
    var positions: any GPUBuffer
    var normals: any GPUBuffer
    var indices: any GPUBuffer
    var indexCount: Int
    var parts: any GPUBuffer
  }

  /// three's `Object3D.matrix` with a scale on it: the scale, then the XYZ Euler turn, then
  /// the position, with a parent group already multiplied in front. The turn is kept apart
  /// from the model matrix because it is the normal matrix — every shape here is scaled along
  /// its own axes, and a box, a cylinder and a torus all have normals that survive that, so
  /// the rotations alone are enough and no inverse transpose is needed.
  struct Placement {
    var model: Matrix4
    var turn: Matrix4

    init(
      parent: Matrix4 = .identity, parentTurn: Matrix4 = .identity, at: SIMD3<Float> = .zero,
      rotation: SIMD3<Float> = .zero, scale: SIMD3<Float> = SIMD3(repeating: 1)
    ) {
      var local = Matrix4.model(position: at, rotation: rotation)
      local.columns.0 *= scale.x
      local.columns.1 *= scale.y
      local.columns.2 *= scale.z
      model = parent * local
      turn = parentTurn * Matrix4.model(position: .zero, rotation: rotation)
    }
  }

  var uniforms = MachineSolidUniforms()
  var spark = MachineSparkUniforms()
  var shapes: [Shape] = []
  var parts: [[Part]] = Array(repeating: [], count: Kind.allCases.count)
  /// What the machine's shader approximates, and why.
  ///
  /// three's `MeshStandardMaterial` is a full physically based model: a Lambert diffuse lobe
  /// and a GGX specular one, split by metalness, plus image based lighting from an environment
  /// map and a multi-scatter energy compensation term. This scene has no environment map, so
  /// the two missing pieces are exactly the ones that need one — what is left is the direct
  /// lighting from the three lights, which is reproduced as three writes it: the same
  /// Smith-correlated GGX visibility, the same Trowbridge-Reitz distribution, the same Schlick
  /// fresnel, the same `roughness` floor of 0.0525, and the same split of the albedo into a
  /// diffuse colour scaled by `1 - metalness` and an `f0` mixed from 0.04 toward the albedo.
  /// That split is why the machine is mostly dark with bright glints rather than evenly grey:
  /// metal at 0.8 has almost no diffuse, and with no environment to reflect it has only what
  /// the three lights give it. That is what the web looks like, so it is kept.
  ///
  /// The ambient light is the flat term three makes of it — irradiance through the same
  /// Lambert lobe, hence the `1/pi` — and contributes no specular, because without a probe
  /// three has no radiance to reflect. The point light uses three's physical falloff:
  /// inverse square, windowed to nothing at its `distance` by the same quartic.
  ///
  /// The tail is the part that is easy to leave out and impossible to miss once it is wrong.
  /// r3f's canvas defaults to ACES filmic tone mapping and an sRGB output, and three's fog is
  /// mixed in *after* both — so the fog colour is the hex as written rather than the light
  /// behind it, which is what makes the far end of the belt fade to exactly the background
  /// rather than to something darker. Colours written as `#rrggbb` are converted out of sRGB
  /// on the way in, on the CPU here, for the same reason.
  ///
  /// Not reproduced: three's dithering, and the `roughness` used for the specular is the
  /// material's flat value, since there are no maps of any kind in this scene to vary it.
  /// The shaders are `machineSolid.*`, `machineSpark.*` and the `machine.glsl` they share.
  var solidPipeline: (any GPUPipeline)!
  /// The sparks are depth tested against the machine, as three's additive points material is,
  /// and write no depth, so one spark never punches a hole in the next.
  var sparkPipeline: (any GPUPipeline)!
  var sparkBuffer: (any GPUBuffer)!

  var bands = [Float](repeating: 0, count: MachineScene.bandCount)
  var onKick = Onset(rise: 1.48, refractory: 0.2, rates: SIMD2(30, 2.1), floor: 0.065)
  var elapsed: Float = 0
  var belt: Float = 0
  var strike: Float = 0
  var shake: Float = 0
  var spin: Float = 0
  var rollerSpin: Float = 0
  var gearSpin = [Float](repeating: 0, count: MachineScene.gears.count)
  var ramHeight: Float = 2.74
  var sparkPosition = [SIMD3<Float>](repeating: SIMD3(0, -20, 0), count: MachineScene.sparks)
  var sparkVelocity = [SIMD3<Float>](repeating: .zero, count: MachineScene.sparks)
  var sparkLife = [Float](repeating: 0, count: MachineScene.sparks)
  var sparkRoll = Noise(seed: 0x51a7)
  /// The drawing buffer's height, which three sizes an attenuated point sprite against: the
  /// target's, which the base class keeps as `viewport`.
  var pixels: Float = 900

  override public func build() throws {
    uniforms.uSunDirection = SIMD3(0, 1, 0)
    uniforms.uLampPosition = SIMD3(0, 5, 3)
    uniforms.uLampRange = 12
    spark.uColour = SIMD3(1, 1, 1)
    spark.uScale = 450
    spark.uOpacity = 0

    // A unit cube, a unit cylinder and a unit torus, each scaled per instance. The torus can
    // be shared across the three gears because the web writes its tube as `radius * 0.18` —
    // the ratio is constant, so the three differ by a uniform scale and nothing else.
    let cube = Box.build(width: 1, height: 1, depth: 1)
    let meshes = [
      cube, Self.cylinder(segments: 16), Self.cylinder(segments: 18), Self.cylinder(segments: 14),
      Self.torus(tube: 0.18, radial: 8, tubular: 32),
    ]
    let counts = [Self.boxCount, Self.rollers, Self.gears.count, 1, Self.gears.count]
    for (index, mesh) in meshes.enumerated() {
      let slots = try buffer([Part](repeating: Part(), count: counts[index]))
      let positions = try buffer(mesh.positions)
      let normals = try buffer(mesh.normals)
      let shapeIndices = try indices(mesh.indices)
      shapes.append(
        Shape(
          positions: positions, normals: normals, indices: shapeIndices,
          indexCount: mesh.indices.count, parts: slots))
    }

    sparkBuffer = try buffer(sparkPosition)
    spark.uColour = machineInk(0xffb14a)

    solidPipeline = try pipeline(
      .machineSolid, blend: .none, depth: .testAndWrite,
      vertexBuffers: [.single(.float3, location: 0), .single(.float3, location: 1), Self.partLayout])
    // A sprite rather than a point: the layer has no points with a size.
    sparkPipeline = try pipeline(
      .machineSpark, blend: .additive, depth: .test,
      vertexBuffers: [.single(.float3, location: 0, perInstance: true)])

    uniforms.uAmbient = machineInk(0x9c9181) * 0.42
    uniforms.uSun = machineInk(0xe1ceb1) * 2.8
    uniforms.uSunDirection = SIMD3<Float>(4, 9, 7).normalized
    uniforms.uGlow = Self.hot
  }

  override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
    pixels = viewport.y
    let (bass, high) = input.wideLevels
    elapsed += dt
    for b in 0..<Self.bandCount {
      var sum: Float = 0
      var taken = 0
      let from = input.bands.count * b / Self.bandCount
      let to = min(input.bands.count, max(from + 1, input.bands.count * (b + 1) / Self.bandCount))
      for lane in from..<max(from, to) {
        sum += input.bands[lane]
        taken += 1
      }
      let raw = taken > 0 ? sum / Float(taken) : 0
      bands[b] = machineEase(bands[b], toward: raw, dt: dt, rate: 5.5)
    }

    let hit = onKick.detect(bass, dt: dt)
    if hit > 0 {
      strike = 1
      shake = max(shake, hit)
      // Thrown from under the ram, forward and up and mostly toward the camera. The sequence
      // is the web's own, taken in the same order so the shower is the same shower.
      for i in 0..<Self.sparks {
        let acrossX = sparkRoll.next()
        let up = sparkRoll.next()
        let acrossZ = sparkRoll.next()
        sparkPosition[i] = SIMD3(
          1.58 + (acrossX - 0.5) * 0.45, 0.72 + up * 0.28, 0.78 + (acrossZ - 0.5) * 0.26)
        let vx = sparkRoll.next()
        let vy = sparkRoll.next()
        let vz = sparkRoll.next()
        sparkVelocity[i] = SIMD3((vx - 0.58) * 3.4, 1.2 + vy * 3.2, (vz - 0.5) * 2.4)
        sparkLife[i] = 0.18 + sparkRoll.next() * 0.34
      }
    }

    strike = max(0, strike - dt * 5.8)
    shake = max(0, shake - dt * 7)
    let speed = 0.55 + bands[4] * 2.5 + high * 1.4
    belt += dt * speed
    rollerSpin -= dt * speed * 2.4
    gearSpin[0] -= dt * (1.2 + bands[1] * 6)
    gearSpin[1] += dt * (1.8 + bands[2] * 7)
    gearSpin[2] -= dt * (1.1 + bands[2] * 4.4)
    // A cam-like stroke: fast down on the onset, slower return.
    ramHeight = 2.74 - sin(strike * .pi) * 1.34

    for i in 0..<Self.sparks {
      if sparkLife[i] <= 0 {
        sparkPosition[i].y = -20
        continue
      }
      sparkLife[i] -= dt
      sparkVelocity[i].y -= dt * 5.5
      sparkPosition[i] += sparkVelocity[i] * dt
    }
    spark.uOpacity = min(1, strike * 2.2)
    spark.uScale = pixels * 0.5

    uniforms.uLampPosition = SIMD3((touchAt.x - 0.5) * 7, 2.8 + touchAt.y * 2.4, 3)
    uniforms.uLamp = Self.hot * (24 + touchEnergy * 42 + high * 12)
    spin += ((touchAt.x - 0.5) * touchEnergy * 0.16 - spin) * min(1, dt * 2.5)

    // Portrait is a detail shot, not the desktop view moved backwards until all twelve metres
    // of belt fit. The latter technically frames the subject and turns it into a model on a
    // shelf. Crop the ends and keep the press and drive train large.
    let narrow = aspect < 0.85
    let target = SIMD3<Float>(narrow ? 6.4 : 8.6, narrow ? 5.1 : 5.5, narrow ? 8.2 : 10.5)
    let jitter = shake * 0.055
    let follow = min(1, dt * 2)
    camera.position.x += (target.x + (touchAt.x - 0.5) * touchEnergy * 1.8 - camera.position.x) * follow
    camera.position.y += (target.y + (touchAt.y - 0.5) * touchEnergy * 1.2 - camera.position.y) * follow
    camera.position.z += (target.z - camera.position.z) * follow
    // Added to the smoothed position rather than to a copy of it, as the web does: the shake
    // is therefore something the camera has to recover from, which is what a real knock is.
    camera.position.x += sin(elapsed * 83) * jitter
    camera.position.y += cos(elapsed * 71) * jitter
    camera.target = SIMD3(0.2, 1.35, 0)
    camera.fovDegrees = narrow ? 48 : 44
    camera.far = 70

    uniforms.projectionMatrix = camera.projectionMatrix(aspect: aspect)
    uniforms.modelViewMatrix = camera.viewMatrix
    uniforms.uEye = camera.position
    spark.projectionMatrix = uniforms.projectionMatrix
    // The sparks live inside the group, so the group's turn is folded into their view matrix
    // rather than into every point on the CPU.
    spark.modelViewMatrix =
      camera.viewMatrix * Matrix4.model(position: .zero, rotation: SIMD3(0, spin, 0))
    uploadSparks()

    layout()
    for kind in Kind.allCases where !parts[kind.rawValue].isEmpty {
      try? parts[kind.rawValue].withUnsafeBytes { try shapes[kind.rawValue].parts.update($0) }
    }
  }

  /// The sparks as they are this frame, into their buffer.
  private func uploadSparks() {
    try? sparkPosition.withUnsafeBytes { try sparkBuffer.update($0) }
  }

  /// Every part, rebuilt from the frame's state. The whole machine is walked rather than only
  /// the moving pieces because the group's own turn moves all of them anyway, and seventy-odd
  /// matrices a frame costs less than the bookkeeping to avoid them.
  private func layout() {
    for kind in Kind.allCases { parts[kind.rawValue].removeAll(keepingCapacity: true) }
    let group = Matrix4.model(position: .zero, rotation: SIMD3(0, spin, 0))

    add(.box, at: SIMD3(0, -0.48, 0), scale: SIMD3(16, 0.5, 8), Self.bed, 0.88, 0.24, group: group)

    // The belt runs across the frame. Rollers remain visible below it, so motion has a source
    // rather than workpieces mysteriously sliding over a slab.
    add(
      .box, at: SIMD3(0, 0.2, 0), scale: SIMD3(12.6, 0.18, 2.15), Self.darkSteel, 0.82, 0.52,
      group: group)
    for z in [Float(-1.14), 1.14] {
      add(
        .box, at: SIMD3(0, 0.42, z), scale: SIMD3(12.9, 0.18, 0.13), Self.edge, 0.58, 0.78,
        group: group)
    }
    for i in 0..<Self.rollers {
      add(
        .roller, at: SIMD3(-5.2 + Float(i) * 1.74, 0.05, 0),
        rotation: SIMD3(.pi / 2, 0, rollerSpin), scale: SIMD3(0.32, 2.35, 0.32), Self.steel, 0.68,
        0.78, group: group)
    }
    for i in 0..<Self.workpieces {
      let lane = ((Float(i) * 1.45 + belt).truncatingRemainder(dividingBy: 11.6)) - 5.8
      // Squashed only while it is under the ram, and glowing by exactly as much: the billet
      // keeps travelling afterwards, which is what makes the line a process and not a loop.
      let underPress = max(0, 1 - abs(lane - 1.55) * 3)
      let squash = 0.72 - underPress * strike * 0.26
      add(
        .box, at: SIMD3(lane, 0.58, 0), scale: SIMD3(0.78, 0.48 * squash, 1.28), Self.paper, 0.48,
        0.66, emissive: underPress * strike * 1.8, group: group)
    }

    // Press frame and descending ram.
    for x in [Float(-0.05), 3.2] {
      add(
        .box, at: SIMD3(x, 2.25, 0), scale: SIMD3(0.42, 4.35, 2.75), Self.steel, 0.74, 0.7,
        group: group)
    }
    add(
      .box, at: SIMD3(1.58, 4.28, 0), scale: SIMD3(3.7, 0.6, 2.9), Self.steel, 0.72, 0.72,
      group: group)
    add(
      .box, at: SIMD3(1.58, ramHeight, 0), scale: SIMD3(1.22, 2.55, 1.62), Self.ramSteel, 0.62, 0.8,
      group: group)
    add(
      .box, at: SIMD3(1.58, ramHeight - 1.38, 0), scale: SIMD3(1.72, 0.28, 1.9), Self.edge, 0.54,
      0.84, group: group)

    for (index, gear) in Self.gears.enumerated() {
      let turn = Matrix4.model(position: .zero, rotation: SIMD3(0, 0, gearSpin[index]))
      var hub = turn
      hub.columns.3 = SIMD4(gear.at.x, gear.at.y, gear.at.z, 1)
      let shaft = group * hub
      let shaftTurn = group * turn
      let r = gear.radius
      add(.ring, scale: SIMD3(repeating: r), gear.colour, 0.72, 0.76, group: shaft, turn: shaftTurn)
      add(
        .hub, rotation: SIMD3(.pi / 2, 0, 0), scale: SIMD3(r * 0.24, 0.32, r * 0.24), Self.edge,
        0.58, 0.82, group: shaft, turn: shaftTurn)
      for tooth in 0..<gear.teeth {
        let angle = Float(tooth) / Float(gear.teeth) * .pi * 2
        add(
          .box, at: SIMD3(cos(angle) * r, sin(angle) * r, 0), rotation: SIMD3(0, 0, angle),
          scale: SIMD3(r * 0.34, r * 0.2, 0.38), gear.colour, 0.72, 0.76, group: shaft,
          turn: shaftTurn)
      }
      for angle in [Float(0), .pi / 2] {
        add(
          .box, rotation: SIMD3(0, 0, angle), scale: SIMD3(r * 1.55, r * 0.12, 0.18), Self.edge,
          0.62, 0.82, group: shaft, turn: shaftTurn)
      }
    }
    add(
      .shaft, at: SIMD3(-3.35, 2.55, 0.08), rotation: SIMD3(.pi / 2, 0, 0),
      scale: SIMD3(0.18, 2.2, 0.18), Self.edge, 0.54, 0.86, group: group)
  }

  private func add(
    _ kind: Kind, at position: SIMD3<Float> = .zero, rotation: SIMD3<Float> = .zero,
    scale: SIMD3<Float> = SIMD3(repeating: 1), _ colour: SIMD3<Float>, _ roughness: Float,
    _ metalness: Float, emissive: Float = 0, group: Matrix4,
    turn: Matrix4? = nil
  ) {
    let place = Placement(
      parent: group, parentTurn: turn ?? group, at: position, rotation: rotation, scale: scale)
    parts[kind.rawValue].append(
      Part(
        model: place.model, normal: place.turn, colour: colour, roughness: roughness,
        metalness: metalness, emissive: emissive))
  }

  /// The machine first, then the sparks — three's own order, the opaque meshes before the one
  /// transparent object.
  override public func encode(_ pass: any GPUPass) {
    pass.setPipeline(solidPipeline)
    pass.setUniforms(uniforms, binding: 0)
    for kind in Kind.allCases {
      let shape = shapes[kind.rawValue]
      let count = parts[kind.rawValue].count
      if count == 0 { continue }
      pass.setVertexBuffer(shape.positions, slot: 0)
      pass.setVertexBuffer(shape.normals, slot: 1)
      pass.setVertexBuffer(shape.parts, slot: 2)
      pass.drawIndexed(shape.indices, count: shape.indexCount, instanceCount: count)
    }

    pass.setPipeline(sparkPipeline)
    pass.setUniforms(spark, binding: 0)
    pass.setVertexBuffer(sparkBuffer, slot: 0)
    pass.draw(vertexCount: Self.spriteVertices, instanceCount: Self.sparks)
  }

  /// three's `CylinderGeometry` at radius and height one, so an instance carries both as a
  /// scale: a torso of `segments` columns, then a fan for each cap. The caps are built out
  /// rather than left off because a roller seen end-on would otherwise be a hole.
  private static func cylinder(segments: Int) -> (
    positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32]
  ) {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var indices: [UInt32] = []
    var rows: [[UInt32]] = []
    for y in 0...1 {
      var row: [UInt32] = []
      for x in 0...segments {
        let theta = Float(x) / Float(segments) * .pi * 2
        positions.append(SIMD3(sin(theta), 0.5 - Float(y), cos(theta)))
        // The sides are parallel, so there is no slope in the normal — which is also why a
        // non-uniform scale later leaves these pointing where they already point.
        normals.append(SIMD3(sin(theta), 0, cos(theta)))
        row.append(UInt32(positions.count - 1))
      }
      rows.append(row)
    }
    for x in 0..<segments {
      let a = rows[0][x]
      let b = rows[1][x]
      let c = rows[1][x + 1]
      let d = rows[0][x + 1]
      indices.append(contentsOf: [a, b, d, b, c, d])
    }
    for top in [true, false] {
      let sign: Float = top ? 1 : -1
      // three gives each cap triangle its own centre vertex rather than sharing one, so that
      // a textured cap can have its own uv there. Kept, so the vertex order is three's.
      let centres = UInt32(positions.count)
      for _ in 0..<segments {
        positions.append(SIMD3(0, 0.5 * sign, 0))
        normals.append(SIMD3(0, sign, 0))
      }
      let rim = UInt32(positions.count)
      for x in 0...segments {
        let theta = Float(x) / Float(segments) * .pi * 2
        positions.append(SIMD3(sin(theta), 0.5 * sign, cos(theta)))
        normals.append(SIMD3(0, sign, 0))
      }
      for x in 0..<segments {
        let centre = centres + UInt32(x)
        let edge = rim + UInt32(x)
        indices.append(contentsOf: top ? [edge, edge + 1, centre] : [edge + 1, edge, centre])
      }
    }
    return (positions, normals, indices)
  }

  /// three's `TorusGeometry` at radius one, lying in the xy plane: a grid of `radial` rings
  /// around the tube by `tubular` steps around the ring, with the normal taken from the tube's
  /// own centre line.
  private static func torus(tube: Float, radial: Int, tubular: Int) -> (
    positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32]
  ) {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var indices: [UInt32] = []
    for j in 0...radial {
      for i in 0...tubular {
        let u = Float(i) / Float(tubular) * .pi * 2
        let v = Float(j) / Float(radial) * .pi * 2
        let reach = 1 + tube * cos(v)
        let point = SIMD3(reach * cos(u), reach * sin(u), tube * sin(v))
        positions.append(point)
        normals.append((point - SIMD3(cos(u), sin(u), 0)).normalized)
      }
    }
    for j in 1...radial {
      for i in 1...tubular {
        let a = UInt32((tubular + 1) * j + i - 1)
        let b = UInt32((tubular + 1) * (j - 1) + i - 1)
        let c = UInt32((tubular + 1) * (j - 1) + i)
        let d = UInt32((tubular + 1) * j + i)
        indices.append(contentsOf: [a, b, d, b, c, d])
      }
    }
    return (positions, normals, indices)
  }
}

/// three converts a colour written as `#rrggbb` out of sRGB before it lights anything, so the
/// numbers a material shades with are not the numbers in the source.
private func machineInk(_ hex: Int) -> SIMD3<Float> {
  let sRGB = SIMD3(Float((hex >> 16) & 0xff), Float((hex >> 8) & 0xff), Float(hex & 0xff)) / 255
  return SIMD3(machineLight(sRGB.x), machineLight(sRGB.y), machineLight(sRGB.z))
}

private func machineLight(_ channel: Float) -> Float {
  channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
}

/// The web's `ease`: snap up on a transient, fall back at `rate`. Asymmetric on purpose —
/// smoothing a spectrum both ways turns every hit into a slow swell.
private func machineEase(_ current: Float, toward target: Float, dt: Float, rate: Float) -> Float {
  target > current ? target : current + (target - current) * min(1, dt * rate)
}
