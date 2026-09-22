#if canImport(Metal)
  import Metal
  import simd

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
  /// own `LineBasicMaterial`, which has no shader to copy — the two line pipelines here are the
  /// smallest Metal that does what it does, a flat colour at an opacity or one interpolated from
  /// the vertices.
  public final class Defcon: GeometryScene {
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

    struct LandUniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var bass: Float = 0
      var alert: Float = 0
    }

    /// One flat colour at one opacity: three's `LineBasicMaterial` without vertex colours.
    struct LineUniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var colour = SIMD3<Float>(1, 1, 1)
      var opacity: Float = 1
    }

    /// The same material with `vertexColors` on, where the colour arrives per vertex instead.
    struct TintUniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var opacity: Float = 1
    }

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

    var land = LandUniforms()
    var line = LineUniforms()
    var tint = TintUniforms()

    var landMesh: MTLBuffer!
    var landCount = 0
    var coastMesh: MTLBuffer!
    var coastCount = 0
    var graticuleMesh: MTLBuffer!
    var graticuleCount = 0
    var glyphMesh: MTLBuffer!
    var glyphColours: MTLBuffer!
    var glyphCount = 0
    var arcMesh: MTLBuffer!
    var arcColours: MTLBuffer!
    var ringMesh: MTLBuffer!
    var ringColours: MTLBuffer!

    var landPipeline: MTLRenderPipelineState!
    var linePipeline: MTLRenderPipelineState!
    var tintPipeline: MTLRenderPipelineState!

    var cities: [City] = []
    var flight: [Missile] = []
    var hits = [Impact](repeating: Impact(), count: Defcon.impacts)
    var nextMissile = 0
    var nextImpact = 0
    var clock: Float = 0
    var alert: Float = 0
    var onLaunch = Onset(rise: 1.45, refractory: 0.3)
    var roll = Noise(seed: 20240)

    override public func build() throws {
      let world = Self.world()
      cities = world.cities
      landMesh = buffer(world.land)
      landCount = world.land.count
      coastMesh = buffer(world.coast)
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
      graticuleMesh = buffer(grid)
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
      glyphMesh = buffer(glyphs)
      glyphColours = buffer(colours)
      glyphCount = glyphs.count

      // The arcs and the rings are rewritten every frame, so they are allocated once at full size
      // and filled in place rather than rebuilt.
      let vector = MemoryLayout<SIMD3<Float>>.stride
      arcMesh = device.makeBuffer(length: vector * Self.arcVertices, options: .storageModeShared)!
      arcColours = device.makeBuffer(length: vector * Self.arcVertices, options: .storageModeShared)!
      ringMesh = device.makeBuffer(length: vector * Self.ringVertices, options: .storageModeShared)!
      ringColours = device.makeBuffer(
        length: vector * Self.ringVertices, options: .storageModeShared)!

      flight = [Missile](
        repeating: Missile(from: cities[0], to: cities[0], t: -1, speed: 0.25), count: Self.missiles)

      landPipeline = try pipeline(
        vertex: "defconLandVertex", fragment: "defconLandFragment", blend: .additive)
      linePipeline = try pipeline(
        vertex: "defconLineVertex", fragment: "defconLineFragment", blend: .normal)
      tintPipeline = try pipeline(
        vertex: "defconTintVertex", fragment: "defconTintFragment", blend: .additive)
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

      land.bass += (bass - land.bass) * min(1, dt * 4)

      // Launch on the beat. Two at a time when it is loud, which is what turns an exchange into a
      // war over the course of a section.
      let kick = onLaunch.detect(bass, dt: dt)
      if kick > 0 {
        let salvo = kick > 0.5 ? 2 : 1
        for _ in 0..<salvo {
          let west = roll.next() < 0.5
          let from = cities[
            (west ? 0 : Self.citiesPerSide) + Int(roll.next() * Float(Self.citiesPerSide))]
          let to = cities[
            (west ? Self.citiesPerSide : 0) + Int(roll.next() * Float(Self.citiesPerSide))]
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
      let arcPositions = arcMesh.contents().bindMemory(
        to: SIMD3<Float>.self, capacity: Self.arcVertices)
      let arcTints = arcColours.contents().bindMemory(
        to: SIMD3<Float>.self, capacity: Self.arcVertices)
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
          let tip = simd_mix(colour, Self.white, SIMD3(repeating: lead * 0.35))
          let shade = tip * (missile.t < 0 ? 0 : 0.3 + lead * 1.4)
          arcTints[v] = shade
          arcTints[v + 1] = shade
          v += 2
        }
      }

      // Impacts: a ring that expands and dies.
      let ringPositions = ringMesh.contents().bindMemory(
        to: SIMD3<Float>.self, capacity: Self.ringVertices)
      let ringTints = ringColours.contents().bindMemory(
        to: SIMD3<Float>.self, capacity: Self.ringVertices)
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
        let shade =
          simd_mix(Self.white, side, SIMD3(repeating: 1 - fade)) * (fade * fade * fade * 3.4)
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

      // How bad it has got. Rises on every impact and decays slowly, and the land runs from blue
      // toward red with it — the DEFCON level, without a readout saying so.
      alert = max(0, alert - dt * 0.14)
      let level = min(1, alert + Float(airborne) / Float(Self.missiles))
      land.alert += (level - land.alert) * min(1, dt * 1.5)

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

      land.projectionMatrix = camera.projection(aspect: aspect)
      // three turns the group the whole board is in, which is a model matrix in front of the view.
      land.modelViewMatrix = camera.view * modelMatrix(position: .zero, rotation: SIMD3(0, yaw, 0))
      line.projectionMatrix = land.projectionMatrix
      line.modelViewMatrix = land.modelViewMatrix
      tint.projectionMatrix = land.projectionMatrix
      tint.modelViewMatrix = land.modelViewMatrix
    }

    /// Graticule, land, coast, glyphs, arcs, rings — three's own order, which here is the order
    /// the objects are declared in: everything is transparent and everything sits at the group's
    /// origin, so the depth sort finds nothing to sort by and falls back on how they were added.
    /// Nothing asks for `depthState`: the camera is above a board that is flat to within a tenth
    /// of a unit, so every later object is nearer than the one before it and the order alone
    /// decides what covers what.
    override public func encode(_ encoder: MTLRenderCommandEncoder) {
      encoder.setRenderPipelineState(linePipeline)
      line.colour = SIMD3(0x12, 0x3a, 0x6b) / 255
      line.opacity = 0.32
      encoder.setVertexBytes(&line, length: MemoryLayout<LineUniforms>.stride, index: 0)
      encoder.setVertexBuffer(graticuleMesh, offset: 0, index: 1)
      encoder.setFragmentBytes(&line, length: MemoryLayout<LineUniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: graticuleCount)

      encoder.setRenderPipelineState(landPipeline)
      encoder.setVertexBytes(&land, length: MemoryLayout<LandUniforms>.stride, index: 0)
      encoder.setVertexBuffer(landMesh, offset: 0, index: 1)
      encoder.setFragmentBytes(&land, length: MemoryLayout<LandUniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: landCount)

      encoder.setRenderPipelineState(linePipeline)
      line.colour = SIMD3(0x8f, 0xd0, 0xff) / 255
      line.opacity = 0.5
      encoder.setVertexBytes(&line, length: MemoryLayout<LineUniforms>.stride, index: 0)
      encoder.setVertexBuffer(coastMesh, offset: 0, index: 1)
      encoder.setFragmentBytes(&line, length: MemoryLayout<LineUniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: coastCount)

      encoder.setRenderPipelineState(tintPipeline)
      tint.opacity = 0.9
      encoder.setVertexBytes(&tint, length: MemoryLayout<TintUniforms>.stride, index: 0)
      encoder.setVertexBuffer(glyphMesh, offset: 0, index: 1)
      encoder.setVertexBuffer(glyphColours, offset: 0, index: 2)
      encoder.setFragmentBytes(&tint, length: MemoryLayout<TintUniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: glyphCount)

      tint.opacity = 1
      encoder.setVertexBytes(&tint, length: MemoryLayout<TintUniforms>.stride, index: 0)
      encoder.setVertexBuffer(arcMesh, offset: 0, index: 1)
      encoder.setVertexBuffer(arcColours, offset: 0, index: 2)
      encoder.setFragmentBytes(&tint, length: MemoryLayout<TintUniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: Self.arcVertices)

      encoder.setVertexBuffer(ringMesh, offset: 0, index: 1)
      encoder.setVertexBuffer(ringColours, offset: 0, index: 2)
      encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: Self.ringVertices)
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
          coast.append(contentsOf: [SIMD3(a.x, 0.02, a.y), SIMD3(b.x, 0.02, b.y)])
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

    static let source = """

      struct DefconLandUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float uBass;
        float uAlert;
      };
      struct DefconLandVarying {
        float4 position [[position]];
      };

      vertex DefconLandVarying defconLandVertex(
        uint vid [[vertex_id]], constant DefconLandUniforms &u [[buffer(0)]],
        constant float3 *vertices [[buffer(1)]]
      ) {
        DefconLandVarying out;
        out.position = u.projectionMatrix * u.modelViewMatrix * float4(vertices[vid], 1.0);
        return out;
      }

      fragment float4 defconLandFragment(
        DefconLandVarying in [[stage_in]], constant DefconLandUniforms &u [[buffer(0)]]
      ) {
        // The glow the original has under its landmasses. Brightest inland and falling away at the
        // coast, so the fill and the outline are the same object rather than a shape with a line
        // drawn round it.
        float3 blue = float3(0.05, 0.21, 0.72);
        float3 hot = float3(0.35, 0.12, 0.30);
        float3 colour = mix(blue, hot, u.uAlert * 0.6);
        return float4(colour * (0.62 + u.uBass * 0.5), 0.55);
      }

      struct DefconLineUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float3 uColour;
        float uOpacity;
      };
      struct DefconLineVarying {
        float4 position [[position]];
      };

      vertex DefconLineVarying defconLineVertex(
        uint vid [[vertex_id]], constant DefconLineUniforms &u [[buffer(0)]],
        constant float3 *vertices [[buffer(1)]]
      ) {
        DefconLineVarying out;
        out.position = u.projectionMatrix * u.modelViewMatrix * float4(vertices[vid], 1.0);
        return out;
      }

      // Everything three's LineBasicMaterial does when it is given a colour and an opacity, which
      // is the whole of what the graticule and the coast ask of it.
      fragment float4 defconLineFragment(
        DefconLineVarying in [[stage_in]], constant DefconLineUniforms &u [[buffer(0)]]
      ) {
        return float4(u.uColour, u.uOpacity);
      }

      struct DefconTintUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float uOpacity;
      };
      struct DefconTintVarying {
        float4 position [[position]];
        float3 vColour;
      };

      vertex DefconTintVarying defconTintVertex(
        uint vid [[vertex_id]], constant DefconTintUniforms &u [[buffer(0)]],
        constant float3 *vertices [[buffer(1)]], constant float3 *aColour [[buffer(2)]]
      ) {
        DefconTintVarying out;
        out.vColour = aColour[vid];
        out.position = u.projectionMatrix * u.modelViewMatrix * float4(vertices[vid], 1.0);
        return out;
      }

      // And the same material with `vertexColors` on. The trails carry brightness well past one,
      // as they do on the web: the target clamps it on the way out rather than the shader.
      fragment float4 defconTintFragment(
        DefconTintVarying in [[stage_in]], constant DefconTintUniforms &u [[buffer(0)]]
      ) {
        return float4(in.vColour, u.uOpacity);
      }

      """
  }
#endif
