#if canImport(Metal)
  import Metal
  import simd

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
  public final class Cycles: GeometryScene {
    override public class var id: String { "cycles" }
    override public class var name: String { "Light Cycles" }
    override public class var accent: SIMD3<Float> { SIMD3(1, 1, 1) }
    override public class var background: SIMD3<Float> { SIMD3(0x01, 0x05, 0x0c) / 255 }

    /// Sized against a PORTRAIT frame, which is the tight one by a long way: a phone's
    /// horizontal field of view is about 0.6 of its vertical, and at the first size this was,
    /// the distance needed to fit the arena was past the canvas's 200-unit far plane. The
    /// arena had to come in rather than the camera going back.
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

    struct WallUniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var colour = SIMD3<Float>(1, 1, 1)
      var time: Float = 0
      var bass: Float = 0
      var derez: Float = 0
    }

    struct GridUniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var bass: Float = 0
      var derez: Float = 0
      var pixel: Float = 1
    }

    struct Bike {
      var x: Float
      var z: Float
      var facing: Int
      /// Corners behind it, oldest first, as x/z/time triples.
      var corners: [SIMD3<Float>] = []
      var positions: MTLBuffer
      var ages: MTLBuffer
      /// How many indices to draw this frame.
      var indexCount = 0
    }

    var wall = WallUniforms()
    var grid = GridUniforms()
    var bikes: [Bike] = []
    var wallIndices: MTLBuffer!
    var gridLines: MTLBuffer!
    var gridCount = 0
    var riderPositions: MTLBuffer!
    var riderColours: MTLBuffer!
    var wallPipeline: MTLRenderPipelineState!
    var gridPipeline: MTLRenderPipelineState!
    var riderPipeline: MTLRenderPipelineState!
    var clock: Float = 0
    var derez: Float = 0
    var onTurn = Onset(rise: 1.4, refractory: 0.13)
    var onDerez = Onset(rise: 2.6, refractory: 3.5)
    var roll = Roll(seed: 0.2718)

    static var wallVertices: Int { (trailCorners + 1) * 2 }

    override public func build() throws {
      var lines: [SIMD3<Float>] = []
      var g = -Self.arena
      while g <= Self.arena {
        lines.append(contentsOf: [SIMD3(g, 0, -Self.arena), SIMD3(g, 0, Self.arena)])
        lines.append(contentsOf: [SIMD3(-Self.arena, 0, g), SIMD3(Self.arena, 0, g)])
        g += Self.gridStep
      }
      gridLines = buffer(lines)
      gridCount = lines.count

      // Two vertices per corner — floor and top — and two triangles per segment between them.
      // Allocated once at full size and drawn with a varying index count, because a trail that
      // reallocated its buffers every time it turned would allocate on the beat.
      var indices: [UInt32] = []
      for segment in 0..<Self.trailCorners {
        let a = UInt32(segment * 2)
        indices.append(contentsOf: [a, a + 1, a + 2, a + 1, a + 3, a + 2])
      }
      wallIndices = buffer(indices)

      bikes = (0..<Self.bikes).map { index in
        // Spread around the arena, each already pointing somewhere different.
        let a = Float(index) / Float(Self.bikes) * .pi * 2
        return Bike(
          x: cos(a) * Self.arena * 0.55, z: sin(a) * Self.arena * 0.55, facing: index % 4,
          positions: device.makeBuffer(
            length: MemoryLayout<SIMD3<Float>>.stride * Self.wallVertices, options: .storageModeShared)!,
          ages: device.makeBuffer(
            length: MemoryLayout<Float>.stride * Self.wallVertices, options: .storageModeShared)!)
      }
      riderPositions = device.makeBuffer(
        length: MemoryLayout<SIMD3<Float>>.stride * Self.bikes, options: .storageModeShared)!
      riderColours = buffer((0..<Self.bikes).map { Self.colours[$0 % Self.colours.count] })

      wallPipeline = try pipeline(
        vertex: "cyclesWallVertex", fragment: "cyclesWallFragment", blend: .additive)
      gridPipeline = try pipeline(
        vertex: "cyclesGridVertex", fragment: "cyclesGridFragment", blend: .additive)
      riderPipeline = try pipeline(
        vertex: "cyclesRiderVertex", fragment: "cyclesRiderFragment", blend: .additive)
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
      wall.time = clock
      wall.bass += (bass - wall.bass) * min(1, dt * 6)
      grid.bass = wall.bass
      grid.pixel = input.pixelRatio

      // The derez. Rare and loud, so it lands on a crash rather than on every kick.
      if onDerez.detect(high, dt: dt) > 0 {
        derez = 1
        for index in bikes.indices { bikes[index].corners.removeAll(keepingCapacity: true) }
      }
      derez = max(0, derez - dt * 1.6)
      wall.derez = derez
      grid.derez = derez

      // One turn signal for the whole grid, so every bike corners on the same beat and the
      // arena fills with parallel right angles rather than with noise.
      let beat = onTurn.detect(bass, dt: dt) > 0
      let speed = 17 + wall.bass * 13
      let riders = riderPositions.contents().bindMemory(to: SIMD3<Float>.self, capacity: Self.bikes)

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
        let positions = bikes[index].positions.contents().bindMemory(
          to: SIMD3<Float>.self, capacity: Self.wallVertices)
        let ages = bikes[index].ages.contents().bindMemory(to: Float.self, capacity: Self.wallVertices)
        let count = bikes[index].corners.count
        for corner in 0..<count {
          let at = bikes[index].corners[corner]
          for vertex in [corner * 2, corner * 2 + 1] {
            positions[vertex] = SIMD3(at.x, vertex % 2 == 1 ? Self.wallHeight : 0, at.y)
            ages[vertex] = clock - at.z
          }
        }
        for vertex in [count * 2, count * 2 + 1] {
          positions[vertex] = SIMD3(bikes[index].x, vertex % 2 == 1 ? Self.wallHeight : 0, bikes[index].z)
          ages[vertex] = 0
        }
        bikes[index].indexCount = count * 6
        riders[index] = SIMD3(bikes[index].x, Self.wallHeight * 0.5, bikes[index].z)
      }

      // High and slightly off, which is the board view. A finger walks the camera round the
      // arena and drops it toward the deck, so you can go from the map to the chase.
      let orbit = clock * 0.045 + (touchAt.x - 0.5) * 2.4 * touchEnergy
      // The floor is square, but seen from this angle its depth is foreshortened to roughly
      // three quarters — so it is a wide, shallow subject however square it is on the ground.
      let fit = fitDistance(
        camera: camera, aspect: aspect, halfWidth: Self.arena * 1.45, halfHeight: Self.arena * 1.1)
      let height = fit * 0.76 - touchEnergy * (touchAt.y - 0.5) * 80
      let range = fit * 0.7 + wall.bass * 3
      camera.position = SIMD3(sin(orbit) * range, max(9, height), cos(orbit) * range)
      // Aimed a little NEARER than the middle. Looking down at a floor, the near half is much
      // larger on screen than the far half, so centring on the origin leaves the visual mass in
      // the bottom third with empty sky above it.
      let nearer = Self.arena * 0.3
      camera.target = SIMD3(sin(orbit) * nearer, 0, cos(orbit) * nearer)
      wall.projectionMatrix = camera.projection(aspect: aspect)
      wall.modelViewMatrix = camera.view
      grid.projectionMatrix = wall.projectionMatrix
      grid.modelViewMatrix = wall.modelViewMatrix
    }

    override public func encode(_ encoder: MTLRenderCommandEncoder) {
      encoder.setRenderPipelineState(gridPipeline)
      encoder.setVertexBytes(&grid, length: MemoryLayout<GridUniforms>.stride, index: 0)
      encoder.setVertexBuffer(gridLines, offset: 0, index: 1)
      encoder.setFragmentBytes(&grid, length: MemoryLayout<GridUniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: gridCount)

      encoder.setRenderPipelineState(wallPipeline)
      for (index, bike) in bikes.enumerated() where bike.indexCount > 0 {
        wall.colour = Self.colours[index % Self.colours.count]
        encoder.setVertexBytes(&wall, length: MemoryLayout<WallUniforms>.stride, index: 0)
        encoder.setVertexBuffer(bike.positions, offset: 0, index: 1)
        encoder.setVertexBuffer(bike.ages, offset: 0, index: 2)
        encoder.setFragmentBytes(&wall, length: MemoryLayout<WallUniforms>.stride, index: 0)
        encoder.drawIndexedPrimitives(
          type: .triangle, indexCount: bike.indexCount, indexType: .uint32, indexBuffer: wallIndices,
          indexBufferOffset: 0)
      }

      encoder.setRenderPipelineState(riderPipeline)
      encoder.setVertexBytes(&grid, length: MemoryLayout<GridUniforms>.stride, index: 0)
      encoder.setVertexBuffer(riderPositions, offset: 0, index: 1)
      encoder.setVertexBuffer(riderColours, offset: 0, index: 2)
      encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Self.bikes)
    }

    static let source = """

      struct CyclesWallUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float3 uColour;
        float uTime;
        float uBass;
        float uDerez;
      };
      struct CyclesWallVarying {
        float4 position [[position]];
        float3 vColour;
        float vUp;
        float vFade;
      };

      vertex CyclesWallVarying cyclesWallVertex(
        uint vid [[vertex_id]], constant CyclesWallUniforms &u [[buffer(0)]],
        constant float3 *vertices [[buffer(1)]], constant float *aAge [[buffer(2)]]
      ) {
        // Every other vertex is the top of the wall, which is what the index list assumes.
        float aUp = float(vid % 2);
        float3 pos = vertices[vid];
        // The derez lifts the walls off the floor as they go, so the arena empties upward
        // instead of simply switching off.
        pos.y += u.uDerez * u.uDerez * 26.0 * aUp;
        CyclesWallVarying out;
        out.vColour = u.uColour;
        out.vUp = aUp;
        // Older wall is dimmer, so the freshest corner is always the brightest thing on the
        // grid and the eye follows the bike rather than the mess behind it.
        out.vFade = clamp(1.0 - aAge[vid] * 0.11, 0.06, 1.0);
        out.position = u.projectionMatrix * u.modelViewMatrix * float4(pos, 1.0);
        return out;
      }

      fragment float4 cyclesWallFragment(
        CyclesWallVarying in [[stage_in]], constant CyclesWallUniforms &u [[buffer(0)]]
      ) {
        // Brightest along the top edge and at the floor line, dimmer through the middle. A
        // flat-shaded slab reads as coloured glass; a light wall is an edge with a glow hanging
        // off it, and those two bands are the whole difference.
        float edge = pow(in.vUp, 3.0) + pow(1.0 - in.vUp, 6.0) * 0.7;
        float3 colour = mix(in.vColour, float3(1.0), edge * 0.55 + u.uDerez);
        float alpha = (0.13 + edge * 0.75) * in.vFade * (1.0 - u.uDerez * 0.75);
        return float4(colour * (0.8 + edge * 1.7 + u.uBass * 0.5 + u.uDerez * 3.0), alpha);
      }

      struct CyclesGridUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float uBass;
        float uDerez;
        float uPixel;
      };
      struct CyclesGridVarying {
        float4 position [[position]];
        float2 vPos;
      };

      vertex CyclesGridVarying cyclesGridVertex(
        uint vid [[vertex_id]], constant CyclesGridUniforms &u [[buffer(0)]],
        constant float3 *vertices [[buffer(1)]]
      ) {
        // The fade has to be worked out from the fragment's own position, not handed in per
        // vertex: every line across this grid has BOTH ends on the boundary, so an attribute
        // would interpolate from "fully faded" to "fully faded" and the whole grid would render
        // at zero alpha — invisible, with no error anywhere to say so.
        CyclesGridVarying out;
        out.vPos = vertices[vid].xz;
        out.position = u.projectionMatrix * u.modelViewMatrix * float4(vertices[vid], 1.0);
        return out;
      }

      fragment float4 cyclesGridFragment(
        CyclesGridVarying in [[stage_in]], constant CyclesGridUniforms &u [[buffer(0)]]
      ) {
        // Fading toward the edge of the arena, so the grid has no visible border. A hard edge
        // turns the game board into a rug on a floor.
        float away = length(in.vPos) / \(arena);
        float fade = 1.0 - smoothstep(0.45, 1.05, away);
        float3 colour = mix(float3(0.10, 0.42, 0.62), float3(0.4, 0.92, 1.0), u.uBass);
        return float4(
          colour * (1.0 + u.uBass + u.uDerez * 2.0), fade * (0.34 + u.uBass * 0.5 + u.uDerez * 0.7));
      }

      struct CyclesRiderVarying {
        float4 position [[position]];
        float pointSize [[point_size]];
        float3 vColour;
      };

      vertex CyclesRiderVarying cyclesRiderVertex(
        uint vid [[vertex_id]], constant CyclesGridUniforms &u [[buffer(0)]],
        constant float3 *vertices [[buffer(1)]], constant float3 *colours [[buffer(2)]]
      ) {
        CyclesRiderVarying out;
        out.vColour = colours[vid];
        out.position = u.projectionMatrix * u.modelViewMatrix * float4(vertices[vid], 1.0);
        // Sized in device pixels and not attenuated, so a rider is the same dot on a phone as
        // on a desktop.
        out.pointSize = 3.2 * u.uPixel;
        return out;
      }

      fragment float4 cyclesRiderFragment(CyclesRiderVarying in [[stage_in]]) {
        return float4(in.vColour, 1.0);
      }

      """
  }
#endif
