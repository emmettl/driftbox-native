#if canImport(Metal)
  import Metal
  import simd

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
  /// What it approximates is written out above `source`.
  public final class Machine: GeometryScene {
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

    struct Uniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var eye = SIMD3<Float>(0, 0, 0)
      var ambient = SIMD3<Float>(0, 0, 0)
      var sun = SIMD3<Float>(0, 0, 0)
      var sunDirection = SIMD3<Float>(0, 1, 0)
      var lamp = SIMD3<Float>(0, 0, 0)
      var lampPosition = SIMD3<Float>(0, 5, 3)
      var glow = SIMD3<Float>(0, 0, 0)
      var lampRange: Float = 12
    }

    struct SparkUniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var colour = SIMD3<Float>(1, 1, 1)
      var scale: Float = 450
      var opacity: Float = 0
    }

    /// One of the machine's parts: where it is and the four numbers its material is. The web has
    /// seventy-odd separate `Mesh` objects here, which differ only in those, so each shape is
    /// drawn once with the parts as instances.
    struct Part {
      var model = matrix_identity_float4x4
      var normal = matrix_identity_float4x4
      var colour = SIMD3<Float>(1, 1, 1)
      var roughness: Float = 0.5
      var metalness: Float = 0
      /// three's `emissiveIntensity`, against the one emissive colour anything here uses.
      var emissive: Float = 0
    }

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
      var positions: MTLBuffer
      var normals: MTLBuffer
      var indices: MTLBuffer
      var indexCount: Int
      var parts: MTLBuffer
    }

    /// three's `Object3D.matrix` with a scale on it: the scale, then the XYZ Euler turn, then
    /// the position, with a parent group already multiplied in front. The turn is kept apart
    /// from the model matrix because it is the normal matrix — every shape here is scaled along
    /// its own axes, and a box, a cylinder and a torus all have normals that survive that, so
    /// the rotations alone are enough and no inverse transpose is needed.
    struct Placement {
      var model: simd_float4x4
      var turn: simd_float4x4

      init(
        parent: simd_float4x4 = matrix_identity_float4x4,
        parentTurn: simd_float4x4 = matrix_identity_float4x4, at: SIMD3<Float> = .zero,
        rotation: SIMD3<Float> = .zero, scale: SIMD3<Float> = SIMD3(repeating: 1)
      ) {
        var local = modelMatrix(position: at, rotation: rotation)
        local.columns.0 *= scale.x
        local.columns.1 *= scale.y
        local.columns.2 *= scale.z
        model = parent * local
        turn = parentTurn * modelMatrix(position: .zero, rotation: rotation)
      }
    }

    var uniforms = Uniforms()
    var spark = SparkUniforms()
    var shapes: [Shape] = []
    var parts: [[Part]] = Array(repeating: [], count: Kind.allCases.count)
    var solidPipeline: MTLRenderPipelineState!
    var sparkPipeline: MTLRenderPipelineState!
    /// The sparks are depth tested against the machine but write no depth of their own, as
    /// three's additive points material does — so one spark never punches a hole in the next.
    var sparkDepth: MTLDepthStencilState?
    var sparkBuffer: MTLBuffer!

    var bands = [Float](repeating: 0, count: Machine.bandCount)
    var onKick = Onset(rise: 1.48, refractory: 0.2, rates: SIMD2(30, 2.1), floor: 0.065)
    var elapsed: Float = 0
    var belt: Float = 0
    var strike: Float = 0
    var shake: Float = 0
    var spin: Float = 0
    var rollerSpin: Float = 0
    var gearSpin = [Float](repeating: 0, count: Machine.gears.count)
    var ramHeight: Float = 2.74
    var sparkPosition = [SIMD3<Float>](repeating: SIMD3(0, -20, 0), count: Machine.sparks)
    var sparkVelocity = [SIMD3<Float>](repeating: .zero, count: Machine.sparks)
    var sparkLife = [Float](repeating: 0, count: Machine.sparks)
    var sparkRoll = Noise(seed: 0x51a7)
    /// The drawing buffer's height, which three sizes an attenuated point sprite against.
    var pixels: Float = 900

    override public func build() throws {
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
        let room = counts[index] * MemoryLayout<Part>.stride
        guard let slots = device.makeBuffer(length: room, options: .storageModeShared) else {
          throw SceneRenderer.SceneError.missingFunction("machine parts", library.functionNames)
        }
        shapes.append(
          Shape(
            positions: buffer(mesh.positions), normals: buffer(mesh.normals),
            indices: buffer(mesh.indices), indexCount: mesh.indices.count, parts: slots))
      }

      sparkBuffer = device.makeBuffer(
        length: Self.sparks * MemoryLayout<SIMD3<Float>>.stride, options: .storageModeShared)
      spark.colour = machineInk(0xffb14a)

      let descriptor = MTLDepthStencilDescriptor()
      descriptor.depthCompareFunction = .less
      descriptor.isDepthWriteEnabled = false
      sparkDepth = device.makeDepthStencilState(descriptor: descriptor)

      solidPipeline = try pipeline(vertex: "machineVertex", fragment: "machineFragment", blend: .none)
      sparkPipeline = try pipeline(
        vertex: "machineSparkVertex", fragment: "machineSparkFragment", blend: .additive)

      uniforms.ambient = machineInk(0x9c9181) * 0.42
      uniforms.sun = machineInk(0xe1ceb1) * 2.8
      uniforms.sunDirection = simd_normalize(SIMD3(4, 9, 7))
      uniforms.glow = Self.hot
    }

    /// three sizes an attenuated point against the drawing buffer's height in pixels, which is
    /// the one thing a frame's input does not carry. It is taken from the texture instead.
    override public func draw(
      _ input: SceneInput, into target: MTLTexture, size: SIMD2<Int>, commandBuffer: MTLCommandBuffer
    ) {
      pixels = Float(size.y)
      super.draw(input, into: target, size: size, commandBuffer: commandBuffer)
    }

    override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
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
      sparkPosition.withUnsafeBytes { raw in
        sparkBuffer.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
      }
      spark.opacity = min(1, strike * 2.2)
      spark.scale = pixels * 0.5

      uniforms.lampPosition = SIMD3((touchAt.x - 0.5) * 7, 2.8 + touchAt.y * 2.4, 3)
      uniforms.lamp = Self.hot * (24 + touchEnergy * 42 + high * 12)
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

      uniforms.projectionMatrix = camera.projection(aspect: aspect)
      uniforms.modelViewMatrix = camera.view
      uniforms.eye = camera.position
      spark.projectionMatrix = uniforms.projectionMatrix
      // The sparks live inside the group, so the group's turn is folded into their view matrix
      // rather than into every point on the CPU.
      spark.modelViewMatrix = camera.view * modelMatrix(position: .zero, rotation: SIMD3(0, spin, 0))

      layout()
      for kind in Kind.allCases {
        parts[kind.rawValue].withUnsafeBytes { raw in
          guard let base = raw.baseAddress else { return }
          shapes[kind.rawValue].parts.contents().copyMemory(from: base, byteCount: raw.count)
        }
      }
    }

    /// Every part, rebuilt from the frame's state. The whole machine is walked rather than only
    /// the moving pieces because the group's own turn moves all of them anyway, and seventy-odd
    /// matrices a frame costs less than the bookkeeping to avoid them.
    private func layout() {
      for kind in Kind.allCases { parts[kind.rawValue].removeAll(keepingCapacity: true) }
      let group = modelMatrix(position: .zero, rotation: SIMD3(0, spin, 0))

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
        let turn = modelMatrix(position: .zero, rotation: SIMD3(0, 0, gearSpin[index]))
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
      _ metalness: Float, emissive: Float = 0, group: simd_float4x4,
      turn: simd_float4x4? = nil
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
    override public func encode(_ encoder: MTLRenderCommandEncoder) {
      encoder.setDepthStencilState(depthState)
      encoder.setRenderPipelineState(solidPipeline)
      encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
      encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
      for kind in Kind.allCases {
        let shape = shapes[kind.rawValue]
        let count = parts[kind.rawValue].count
        if count == 0 { continue }
        encoder.setVertexBuffer(shape.positions, offset: 0, index: 1)
        encoder.setVertexBuffer(shape.normals, offset: 0, index: 2)
        encoder.setVertexBuffer(shape.parts, offset: 0, index: 3)
        encoder.drawIndexedPrimitives(
          type: .triangle, indexCount: shape.indexCount, indexType: .uint32, indexBuffer: shape.indices,
          indexBufferOffset: 0, instanceCount: count)
      }

      encoder.setDepthStencilState(sparkDepth)
      encoder.setRenderPipelineState(sparkPipeline)
      encoder.setVertexBytes(&spark, length: MemoryLayout<SparkUniforms>.stride, index: 0)
      encoder.setVertexBuffer(sparkBuffer, offset: 0, index: 1)
      encoder.setFragmentBytes(&spark, length: MemoryLayout<SparkUniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Self.sparks)
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
          normals.append(simd_normalize(point - SIMD3(cos(u), sin(u), 0)))
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

    /// What this shader approximates, and why.
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
    static let source = """

      constant float machineRecipPi = 0.31830988618379069;
      /// `#100e0b`, the background, in display values — see the note above.
      constant float3 machineFogColour = float3(0.0627451, 0.05490196, 0.04313725);

      float3 machineSpecular(float3 f0, float roughness, float3 n, float3 v, float3 l) {
        float alpha = roughness * roughness;
        float a2 = alpha * alpha;
        float3 h = normalize(l + v);
        float dotNL = saturate(dot(n, l));
        float dotNV = saturate(dot(n, v));
        float dotNH = saturate(dot(n, h));
        float dotVH = saturate(dot(v, h));
        // Smith's height-correlated visibility, which already carries the 1/(4 dotNL dotNV).
        float gv = dotNL * sqrt(a2 + (1.0 - a2) * dotNV * dotNV);
        float gl = dotNV * sqrt(a2 + (1.0 - a2) * dotNL * dotNL);
        float visibility = 0.5 / max(gv + gl, 1e-6);
        float denom = dotNH * dotNH * (a2 - 1.0) + 1.0;
        float distribution = machineRecipPi * a2 / max(denom * denom, 1e-6);
        float3 fresnel = f0 + (1.0 - f0) * pow(saturate(1.0 - dotVH), 5.0);
        return fresnel * (visibility * distribution);
      }

      float3 machineTonemap(float3 colour) {
        float3x3 toAces = float3x3(
          float3(0.59719, 0.07600, 0.02840), float3(0.35458, 0.90834, 0.13383),
          float3(0.04823, 0.01566, 0.83777));
        float3x3 fromAces = float3x3(
          float3(1.60475, -0.10208, -0.00327), float3(-0.53108, 1.10813, -0.07276),
          float3(-0.07367, -0.00605, 1.07602));
        float3 v = toAces * (colour / 0.6);
        float3 a = v * (v + 0.0245786) - 0.000090537;
        float3 b = v * (0.983729 * v + 0.4329510) + 0.238081;
        return saturate(fromAces * (a / b));
      }

      float3 machineEncode(float3 colour) {
        float3 curve = pow(colour, float3(0.41666)) * 1.055 - 0.055;
        return select(curve, colour * 12.92, colour <= 0.0031308);
      }

      float3 machineFog(float3 colour, float depth) {
        return mix(colour, machineFogColour, smoothstep(14.0, 31.0, depth));
      }

      struct MachineUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float3 uEye;
        float3 uAmbient;
        float3 uSun;
        float3 uSunDirection;
        float3 uLamp;
        float3 uLampPosition;
        float3 uGlow;
        float uLampRange;
      };
      struct MachinePart {
        float4x4 model;
        float4x4 normal;
        float3 colour;
        float roughness;
        float metalness;
        float emissive;
      };
      struct MachineVarying {
        float4 position [[position]];
        float3 vWorld;
        float3 vNormal;
        float3 vColour;
        float vRoughness;
        float vMetalness;
        float vEmissive;
        float vFogDepth;
      };

      vertex MachineVarying machineVertex(
        uint vid [[vertex_id]], uint iid [[instance_id]], constant MachineUniforms &u [[buffer(0)]],
        constant float3 *vertices [[buffer(1)]], constant float3 *vertexNormals [[buffer(2)]],
        constant MachinePart *parts [[buffer(3)]]
      ) {
        MachinePart part = parts[iid];
        float4 world = part.model * float4(vertices[vid], 1.0);
        float4 view = u.modelViewMatrix * world;

        MachineVarying out;
        out.position = u.projectionMatrix * view;
        out.vWorld = world.xyz;
        // Lit in world space rather than in view space as three does, because the lights are
        // outside the group that turns and this way neither they nor the shader have to know it.
        out.vNormal = normalize((part.normal * float4(vertexNormals[vid], 0.0)).xyz);
        out.vColour = part.colour;
        // three's own floor: below this the specular lobe is narrower than a pixel and aliases.
        out.vRoughness = max(part.roughness, 0.0525);
        out.vMetalness = part.metalness;
        out.vEmissive = part.emissive;
        out.vFogDepth = -view.z;
        return out;
      }

      fragment float4 machineFragment(
        MachineVarying in [[stage_in]], constant MachineUniforms &u [[buffer(0)]]
      ) {
        float3 n = normalize(in.vNormal);
        float3 v = normalize(u.uEye - in.vWorld);
        float roughness = in.vRoughness;
        // Metal has no diffuse and tints its own reflection; a dielectric reflects four percent
        // of everything and keeps its colour in the diffuse lobe.
        float3 diffuse = in.vColour * (1.0 - in.vMetalness);
        float3 f0 = mix(float3(0.04), in.vColour, in.vMetalness);

        float3 lit = u.uAmbient * diffuse * machineRecipPi;

        float3 l = u.uSunDirection;
        float dotNL = saturate(dot(n, l));
        lit += dotNL * u.uSun * (diffuse * machineRecipPi + machineSpecular(f0, roughness, n, v, l));

        float3 toLamp = u.uLampPosition - in.vWorld;
        float reach = length(toLamp);
        l = toLamp / max(reach, 1e-4);
        // Inverse square, windowed to nothing at the light's `distance` so it cannot light the
        // far end of the belt through the press.
        float window = saturate(1.0 - pow(reach / u.uLampRange, 4.0));
        float falloff = window * window / max(reach * reach, 0.01);
        dotNL = saturate(dot(n, l));
        lit += dotNL * u.uLamp * falloff
          * (diffuse * machineRecipPi + machineSpecular(f0, roughness, n, v, l));

        // The billet glows from inside while it is being struck, which is the one place in the
        // scene where a surface is a source rather than a receiver.
        lit += u.uGlow * in.vEmissive;

        return float4(machineFog(machineEncode(machineTonemap(lit)), in.vFogDepth), 1.0);
      }

      struct MachineSparkUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float3 uColour;
        float uScale;
        float uOpacity;
      };
      struct MachineSparkVarying {
        float4 position [[position]];
        float pointSize [[point_size]];
        float vFogDepth;
      };

      vertex MachineSparkVarying machineSparkVertex(
        uint vid [[vertex_id]], constant MachineSparkUniforms &u [[buffer(0)]],
        constant float3 *vertices [[buffer(1)]]
      ) {
        MachineSparkVarying out;
        float4 view = u.modelViewMatrix * float4(vertices[vid], 1.0);
        out.position = u.projectionMatrix * view;
        // three's size attenuation: the world size against half the drawing buffer's height,
        // divided by the distance — so a spark is the same size in metres at any depth.
        out.pointSize = 0.075 * u.uScale / max(1e-4, -view.z);
        out.vFogDepth = -view.z;
        return out;
      }

      fragment float4 machineSparkFragment(
        MachineSparkVarying in [[stage_in]], constant MachineSparkUniforms &u [[buffer(0)]]
      ) {
        // A points material is tone mapped, encoded and fogged like any other, so the sparks are
        // not the raw colour they are written as either.
        float3 colour = machineFog(machineEncode(machineTonemap(u.uColour)), in.vFogDepth);
        return float4(colour, u.uOpacity);
      }

      """
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
#endif
