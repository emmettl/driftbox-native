#if canImport(Metal)
  import Metal
  import simd

  /// Jump Man. An 80s platformer, run on hardware that would have been a supercomputer then.
  ///
  /// The homage is the sprite work: everything on screen is drawn on a grid at one colour per
  /// cell, animated on twos, with a two-frame run cycle and a landscape that scrolls in parallax
  /// layers. None of that has changed since 1985 and none of it should.
  ///
  /// The twist is that a pixel here is not a pixel. Every cell is a POINT IN SPACE with its own
  /// depth, lit with a bevel, and the whole sprite is a particle system that happens to be
  /// standing in formation — so when the character dies it does not blink out, it comes apart
  /// into a few hundred cubes that tumble, fall and are gathered back up on the respawn. A 6502
  /// could draw the sprite; it could not throw it in the air.
  ///
  /// And it runs on the RECORD. He jumps on the kick and his legs change frame on the hat, so the
  /// run cycle is the drum pattern rather than a timer that happens to be nearby. Stop the
  /// transport and he stands still, which is the honest version of the joke.
  ///
  /// The web scene has no `<fog>` of any kind, so there is none to port; and its one material is a
  /// `ShaderMaterial` with blending off and depth written, because these are opaque blocks stacked
  /// in layers and the whole point of the bevel is that a nearer cell covers the one behind it.
  /// The palette is used here in display values, as the other ported geometry scenes do, rather
  /// than pushed through three's sRGB-to-linear conversion and the canvas's ACES tail — see the
  /// note in the report; a flat sprite colour is the thing being drawn.
  public final class Jumpman: GeometryScene {
    override public class var id: String { "jumpman" }
    override public class var name: String { "Jump Man" }
    override public class var accent: SIMD3<Float> { SIMD3(1, 1, 1) }
    override public class var background: SIMD3<Float> { SIMD3(0x0a, 0x0f, 0x2a) / 255 }

    /// One cell of the sprite grid, in world units.
    static let cell: Float = 1
    /// How much of the world is on screen, in cells.
    ///
    /// A side-scroller is a wide composition and a phone is a tall screen, so this is the number
    /// that has to give — showing seventy-six cells across a 0.46-aspect frame means backing off
    /// until the runner is a thumbnail with two-thirds of the screen empty sky above him. Fewer
    /// cells on a phone is the same call the Defcon board and the Lifeforms bodies both make:
    /// reshape the subject, not the lens.
    static let viewWide: Float = 76
    static let viewTall: Float = 34
    static let groundY: Float = -9
    /// Where the runner stands, as a fraction of the visible width. Left of centre, because a
    /// platformer needs to show what is coming rather than what you have passed — and a fraction
    /// rather than a number of cells, or he walks off the edge of a phone the moment the view
    /// narrows.
    static let runnerAt: Float = -0.28
    static let maxPoints = 4000

    /// The jump.
    ///
    /// Tuned as a pair against the two things it has to do: CLEAR the lower platform, and be over
    /// in time to happen again on the next kick. The old numbers gave an apex of 4.6 cells — 42%
    /// of his own height, a skip rather than a jump — over 0.70s, which at 162bpm is longer than
    /// the gap between kicks, so he also spent half of them stuck on the ground unable to go
    /// again.
    ///
    /// Higher AND faster means raising both: apex is v²/2g and air time is 2v/g, so cranking
    /// gravity alongside velocity buys the height without the float. These give 8.5 cells in
    /// 0.72s.
    static let gravity: Float = 130
    static let jumpVelocity: Float = 47
    /// Heights a platform can sit at.
    ///
    /// The lower one is deliberately well under the 8.5-cell apex, because what matters is not
    /// whether he can reach it but how LONG he spends above it: he clears 7 cells for 0.30s and 5
    /// cells for 0.46s, which at this pace is the difference between a six-cell landing window and
    /// a nine-cell one. Half a platform's width, bought by lowering it two cells.
    ///
    /// The upper one is out of reach from the ground and reachable from the lower, which is the
    /// entire reason to have two.
    static let platformHeights: [Float] = [5, 11]

    private static func rgb(_ hex: Int) -> SIMD3<Float> {
      SIMD3(Float((hex >> 16) & 0xff), Float((hex >> 8) & 0xff), Float(hex & 0xff)) / 255
    }

    /// The palette. Deliberately few and deliberately flat — a sprite reads by its silhouette and
    /// its two or three colours, and every extra shade costs more than it gives.
    static let palette: [Character: SIMD3<Float>] = [
      "H": rgb(0xff_4d5a),  // helmet
      "V": rgb(0x24_1a33),  // visor
      "W": rgb(0xff_ffff),  // glint
      "S": rgb(0xff_c38a),  // skin
      "G": rgb(0x3b_a7ff),  // suit
      "B": rgb(0x2b_3a6b),  // boots
      "M": rgb(0x7b_dc52),  // monster
      "E": rgb(0x16_1022),  // monster eye
      "F": rgb(0x3f_8f26),  // monster foot
      "P": rgb(0xff_e14d),  // pick-up
      "K": rgb(0xc9_7b38),  // brick
      "k": rgb(0x92_5025),  // brick shadow
      "C": rgb(0xcf_e8ff),  // cloud
      "L": rgb(0x2a_5f8f),  // far hills
    ]

    /// Sprite art, top row first. A dot is a hole.
    static let runArtA = [
      "..HHHH....",
      ".HHHHHH...",
      ".HVVVVH...",
      ".HVWWVH...",
      "..SSSS....",
      ".GGGGGG...",
      "GGGGGGGG..",
      "GG.GG.GG..",
      "..GGGG....",
      "..B..B....",
      ".BB..BB...",
    ]
    static let runArtB = [
      "..HHHH....",
      ".HHHHHH...",
      ".HVVVVH...",
      ".HVWWVH...",
      "..SSSS....",
      ".GGGGGG...",
      "GGGGGGGG..",
      "GG.GG.GG..",
      "..GGGG....",
      "...B..B...",
      "..BB...BB.",
    ]
    static let jumpArt = [
      "..HHHH....",
      ".HHHHHH...",
      ".HVVVVH...",
      ".HVWWVH...",
      "S.SSSS.S..",
      "SGGGGGGS..",
      ".GGGGGG...",
      "..GGGG....",
      "..BB.BB...",
      ".BB...BB..",
    ]
    static let monsterArt = [
      "..MMMM..",
      ".MMMMMM.",
      "MMEMMEMM",
      "MMEMMEMM",
      "MMMMMMMM",
      ".MMMMMM.",
      "..F..F..",
    ]
    static let pickupArt = [
      "...P....",
      "..PPP...",
      ".PPPPP..",
      "PPPPPPP.",
      ".PPPPP..",
      "..P.P...",
      ".P...P..",
    ]

    struct Cell {
      var x: Float
      var y: Float
      var colour: SIMD3<Float>
    }

    /// Turn art into cells, with the origin at the bottom-left of the sprite.
    private static func cellsOf(_ art: [String]) -> [Cell] {
      var out: [Cell] = []
      let height = art.count
      for row in 0..<height {
        for (col, character) in art[row].enumerated() where character != "." {
          out.append(
            Cell(
              x: Float(col), y: Float(height - 1 - row),
              colour: palette[character] ?? SIMD3(1, 1, 1)))
        }
      }
      return out
    }

    static let runCellsA = cellsOf(runArtA)
    static let runCellsB = cellsOf(runArtB)
    static let jumpCells = cellsOf(jumpArt)
    static let monsterCells = cellsOf(monsterArt)
    static let pickupCells = cellsOf(pickupArt)

    struct Monster {
      var x: Float
      var alive: Bool
    }
    struct Pickup {
      var x: Float
      /// Cells above the ground. A pick-up on a platform is a reason to go up there.
      var y: Float
      var taken: Bool
    }
    struct Platform {
      var x: Float
      var width: Float
      /// Cells above the ground.
      var top: Float
    }
    struct Shard {
      var x: Float
      var y: Float
      var vx: Float
      var vy: Float
      var life: Float
      var colour: SIMD3<Float>
    }

    struct PixelUniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var pixelRatio: Float = 1
    }

    var uniforms = PixelUniforms()
    var positionBuffer: MTLBuffer!
    var colourBuffer: MTLBuffer!
    var sizeBuffer: MTLBuffer!
    var glowBuffer: MTLBuffer!
    var pixelPipeline: MTLRenderPipelineState!
    var drawCount = 0

    // The game.
    var scroll: Float = 0
    /// Height above the ground, in cells.
    var hop: Float = 0
    var hopVel: Float = 0
    /// World x of his last touchdown, and the smoothed distance between touchdowns.
    var lastLand: Float = 0
    var stride: Float = 0
    var frame = 0
    /// Seconds left of being dead. Zero means alive.
    var dead: Float = 0
    var powered: Float = 0
    var monsters: [Monster] = []
    var pickups: [Pickup] = []
    var platforms: [Platform] = []
    var shards: [Shard] = []
    var spawnedTo: Float = 0
    var onKick = Onset(rise: 1.35, refractory: 0.14)
    var onHat = Onset(rise: 1.5, refractory: 0.08)
    var random = Noise(seed: 1985)

    override public func build() throws {
      positionBuffer = device.makeBuffer(
        length: MemoryLayout<SIMD3<Float>>.stride * Self.maxPoints, options: .storageModeShared)!
      colourBuffer = device.makeBuffer(
        length: MemoryLayout<SIMD3<Float>>.stride * Self.maxPoints, options: .storageModeShared)!
      sizeBuffer = device.makeBuffer(
        length: MemoryLayout<Float>.stride * Self.maxPoints, options: .storageModeShared)!
      glowBuffer = device.makeBuffer(
        length: MemoryLayout<Float>.stride * Self.maxPoints, options: .storageModeShared)!
      pixelPipeline = try pipeline(vertex: "jumpmanVertex", fragment: "jumpmanFragment", blend: .none)
    }

    /// What holds him up here: the highest platform top he is above, or the ground. Tested against
    /// the height he is falling FROM, so a platform cannot catch him on the way up through it —
    /// you land on things, you do not stick to their undersides.
    private func supportAt(_ worldX: Float, from: Float) -> Float {
      var best: Float = 0
      for pf in platforms {
        if worldX < pf.x - 1 || worldX > pf.x + pf.width + 1 { continue }
        if pf.top > best && from >= pf.top - 0.6 { best = pf.top }
      }
      return best
    }

    /// Extrapolating his own stride costs nothing and needs no knowledge of the tempo or the
    /// scroll speed, both of which move with the bass.
    private func onHisStride(_ from: Float) -> Float {
      if stride < 4 || lastLand <= 0 { return from }
      var x = lastLand
      while x < from { x += stride }
      return x
    }

    override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
      let (bass, high) = input.wideLevels
      uniforms.pixelRatio = input.pixelRatio
      let step = min(0.05, dt)

      // Scrolling, and everything else, only happens while the record does. Standing still when
      // the music stops is the point rather than an oversight.
      let pace: Float = input.running ? 15 + bass * 10 : 0
      scroll += step * pace

      // Worked out before the physics, because how wide the view is decides where he stands, and
      // where he stands decides what is under his feet.
      let portrait = aspect < 0.85
      let across = portrait ? Self.viewTall : Self.viewWide
      let runnerX = across * Self.runnerAt

      let here = scroll + runnerX + across / 2
      let grounded = hop <= supportAt(here, from: hop) + 0.02

      // He jumps on the kick and changes leg on the hat. The run cycle IS the drum pattern.
      //
      // Every kick he is standing for. The first version made him skip kicks that would miss a
      // platform, which is what a player does and is wrong here: the kick fires about twice a
      // second, so there are only eight jump opportunities in sixteen seconds and filtering them
      // left him jumping once. Scarce opportunities cannot be rationed, so he takes every one of
      // them and the platforms are placed to meet HIM instead — see the spawner.
      if onKick.detect(bass, dt: step) > 0 && dead <= 0 && grounded { hopVel = Self.jumpVelocity }
      if onHat.detect(high, dt: step) > 0 { frame = 1 - frame }

      let was = hop
      hopVel -= step * Self.gravity
      hop += step * hopVel
      let support = supportAt(here, from: was)
      if hop <= support {
        // Touchdown. Where he lands is the one number the platforms need — see below.
        if was > support + 0.05 {
          let gap = here - lastLand
          if lastLand > 0 && gap > 4 { stride = stride > 0 ? stride * 0.6 + gap * 0.4 : gap }
          lastLand = here
        }
        hop = support
        hopVel = 0
      }

      if dead > 0 {
        dead -= step
        if dead <= 0 {
          // Respawn: clear the road ahead so he does not land on the thing that killed him.
          monsters = monsters.filter { $0.x - scroll > 26 }
          hop = 0
          hopVel = 0
        }
      }
      if powered > 0 { powered -= step }

      spawn(across: across)
      collide(runnerWorldX: scroll + runnerX + across / 2, runnerX: runnerX, grounded: grounded)

      // Shards fall and fade.
      for index in shards.indices {
        shards[index].life -= step
        shards[index].vy -= step * 62
        shards[index].x += shards[index].vx * step - step * pace
        shards[index].y += shards[index].vy * step
      }
      shards.removeAll { $0.life <= 0 }

      draw(across: across, runnerX: runnerX, high: high)

      // A flat, side-on camera. The scene is authored in cells, so the framing is a matter of
      // fitting the visible width of them across — which on a tall phone means backing off, and on
      // a wide window means the height binds instead.
      let halfFov = tan(camera.fovDegrees * .pi / 360)
      let forWidth = across / 2 / (halfFov * aspect)
      let forHeight = 17 / halfFov
      let side = (touchAt.x - 0.5) * 6 * touchEnergy
      camera.position = SIMD3(side, Self.groundY + 11, max(forWidth, forHeight))
      camera.target = SIMD3(side, Self.groundY + 11, 0)
      uniforms.projectionMatrix = camera.projection(aspect: aspect)
      uniforms.modelViewMatrix = camera.view
    }

    /// Populate the road ahead. Deterministic, so the same run happens every time — which matters
    /// more than variety here, because a scene that is different every mount is one you cannot
    /// compare screenshots of.
    ///
    /// Platforms are placed ON his landings rather than at random. He jumps on the kick, so his
    /// touchdowns fall on a grid — one measured above as `stride` — and scattering platforms
    /// independently of it means the phase between the two is luck. Measured: he spent 20% of the
    /// time over a platform, 36% of it airborne, and the two coincided 7%, which is exactly the
    /// product. Independent, so he never landed on one. He lands a little before the ground
    /// touchdown because the platform top gets in the way, so the prediction goes 45% of the way
    /// in rather than at the leading edge.
    private func spawn(across: Float) {
      while spawnedTo < scroll + across + 24 {
        // A real gap, measured from the previous object's far end. Centre-to-centre spacing lets
        // wide platforms run into each other, and a row of abutting platforms stops reading as
        // platforms and starts reading as a ceiling.
        spawnedTo += 13 + random.next() * 16
        let roll = random.next()
        if roll < 0.2 {
          monsters.append(Monster(x: spawnedTo, alive: true))
        } else if roll < 0.82 {
          // A platform, and usually something on it worth climbing for. Wide, because the width is
          // what he has to land in and a jump only carries him so far.
          let top = Self.platformHeights[random.next() < 0.7 ? 0 : 1]
          // Clamped: the web's generator is a double and never reaches one, but rounded to a
          // Float the top of its range does, and an unclamped floor would give a 27-wide brick.
          let width = Float(16 + min(10, Int(random.next() * 11)))
          let x = onHisStride(spawnedTo) - width * 0.45
          platforms.append(Platform(x: x, width: width, top: top))
          spawnedTo = x + width
          if random.next() < 0.7 {
            pickups.append(Pickup(x: x + width / 2, y: top + 2, taken: false))
          }
        } else {
          pickups.append(Pickup(x: spawnedTo, y: 9, taken: false))
        }
      }
      monsters = monsters.filter { $0.x - scroll > -Self.viewWide }
      pickups = pickups.filter { $0.x - scroll > -Self.viewWide }
      platforms = platforms.filter { $0.x + $0.width - scroll > -Self.viewWide }
    }

    /// Collisions. Being in the air clears a monster; being on the ground does not.
    private func collide(runnerWorldX: Float, runnerX: Float, grounded: Bool) {
      for index in monsters.indices {
        if !monsters[index].alive { continue }
        // Standing on a platform is safety, not a weapon: a monster passing underneath is out of
        // reach in both directions. Otherwise, above it kills it and level with it kills you.
        if grounded && hop > 0.5 { continue }
        guard abs(monsters[index].x - runnerWorldX) < 4 && hop < 6 && dead <= 0 else { continue }
        if hop > 2.5 || powered > 0 {
          monsters[index].alive = false
          // Stamped: the monster comes apart instead of vanishing. The web spawns these without
          // the `- across / 2` its draw call uses, so the pieces land half a screen to the right
          // of the monster; kept, because this is what the web does.
          for c in Self.monsterCells {
            let vx = (random.next() - 0.5) * 26
            let vy = 8 + random.next() * 26
            shards.append(
              Shard(
                x: monsters[index].x - scroll + c.x - 4, y: Self.groundY + c.y, vx: vx, vy: vy,
                life: 1.1, colour: c.colour))
          }
        } else {
          // Death. Every cell of him becomes a shard — the sprite was always a particle system,
          // this is just the frame where it stops pretending otherwise.
          dead = 1.5
          for c in Self.runCellsA {
            let vx = (random.next() - 0.5) * 30 - 6
            let vy = 18 + random.next() * 30
            shards.append(
              Shard(
                x: runnerX + c.x, y: Self.groundY + hop + c.y, vx: vx, vy: vy, life: 1.5,
                colour: c.colour))
          }
        }
      }
      for index in pickups.indices {
        let p = pickups[index]
        guard !p.taken, abs(p.x - runnerWorldX) < 4, abs(p.y - hop) < 6, dead <= 0 else { continue }
        pickups[index].taken = true
        powered = 6
        // Offset the same way the monster's pieces are, and for the same reason.
        for c in Self.pickupCells {
          let vx = (random.next() - 0.5) * 20
          let vy = 14 + random.next() * 22
          shards.append(
            Shard(
              x: p.x - scroll + c.x - 4, y: Self.groundY + p.y + c.y, vx: vx, vy: vy, life: 0.9,
              colour: c.colour))
        }
      }
    }

    /// Everything on screen is one buffer of points, refilled from scratch every frame.
    private func draw(across: Float, runnerX: Float, high: Float) {
      let pos = positionBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: Self.maxPoints)
      let col = colourBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: Self.maxPoints)
      let siz = sizeBuffer.contents().bindMemory(to: Float.self, capacity: Self.maxPoints)
      let glo = glowBuffer.contents().bindMemory(to: Float.self, capacity: Self.maxPoints)
      var n = 0
      func put(_ x: Float, _ y: Float, _ z: Float, _ c: SIMD3<Float>, _ sizePx: Float, _ glow: Float) {
        if n >= Self.maxPoints { return }
        pos[n] = SIMD3(x, y, z)
        col[n] = c
        siz[n] = sizePx
        glo[n] = glow
        n += 1
      }
      func stamp(_ cells: [Cell], _ ox: Float, _ oy: Float, _ z: Float, _ glow: Float) {
        for c in cells {
          put(ox + c.x * Self.cell, oy + c.y * Self.cell, z, c.colour, Self.cell, glow)
        }
      }
      let ground = Self.groundY

      // Far hills, then clouds: two parallax layers at different depths and different rates, which
      // is the oldest trick there is and still the one that makes a flat world deep. The wrap is
      // JavaScript's truncating remainder, which keeps its sign — the layers run from the negative
      // side of the screen, so flooring here would shift both of them by a full period.
      var colour = Self.palette["L"]!
      for i in 0..<90 {
        let x =
          (Float(i) * 7 - scroll * 0.12).truncatingRemainder(dividingBy: across * 1.9) - across * 0.95
        let h = 5 + abs(sin(Float(i) * 1.7)) * 9
        var y: Float = 0
        while y < h {
          put(x, ground + 2 + y, -16, colour, Self.cell * 1.6, 0)
          y += 1
        }
      }
      colour = Self.palette["C"]!
      for i in 0..<26 {
        let x =
          (Float(i) * 23 - scroll * 0.3).truncatingRemainder(dividingBy: across * 2.1) - across * 1.05
        let y = ground + 22 + Float((i * 5) % 9)
        for k in 0..<5 {
          put(x + Float(k), y + (k == 2 ? 1 : 0), -9, colour, Self.cell * 1.3, 0)
        }
      }

      // The ground. Bricks, with a darker course under them.
      let brickLight = Self.palette["K"]!
      let brickDark = Self.palette["k"]!
      for i in -2..<(Int(across) + 4) {
        let x = Float(i) - across / 2 - scroll.truncatingRemainder(dividingBy: 4)
        let brick = (i + Int(floor(scroll / 4))) % 4 == 0
        colour = brick ? brickDark : brickLight
        put(x, ground - 1, 0, colour, Self.cell, 0)
        put(x, ground - 2, 0, colour, Self.cell, 0)
      }

      // Platforms. Two courses like the ground, so they read as the same material rather than as
      // floating lines.
      for pf in platforms {
        let left = pf.x - scroll - across / 2
        for i in 0..<Int(pf.width) {
          colour = i % 4 == 0 ? brickDark : brickLight
          put(left + Float(i), ground + pf.top, 0, colour, Self.cell, 0)
          put(left + Float(i), ground + pf.top - 1, 0, colour, Self.cell, 0)
        }
      }

      // Monsters and pick-ups.
      for m in monsters where m.alive {
        stamp(Self.monsterCells, m.x - scroll - across / 2 - 4, ground, 0, 0)
      }
      for p in pickups where !p.taken {
        let bob = sin(scroll * 0.2 + p.x) * 1.2
        stamp(Self.pickupCells, p.x - scroll - across / 2 - 4, ground + p.y + bob, 0, 0.5 + high)
      }

      // The runner, unless he is currently in pieces.
      if dead <= 0 {
        let cells = hop > 0.6 ? Self.jumpCells : (frame == 0 ? Self.runCellsA : Self.runCellsB)
        let glow = powered > 0 ? 0.6 + sin(powered * 22) * 0.4 : 0.12
        stamp(cells, runnerX, ground + hop, 1, glow)
      }

      // Shards.
      for sh in shards {
        put(sh.x, sh.y, 1, sh.colour, Self.cell * (0.7 + sh.life * 0.5), sh.life * 0.7)
      }
      drawCount = n
    }

    override public func encode(_ encoder: MTLRenderCommandEncoder) {
      guard drawCount > 0 else { return }
      // Depth written, because a nearer cell has to cover the one behind it — the layers are a
      // long way apart in z and the bevel only reads if they occlude.
      encoder.setDepthStencilState(depthState)
      encoder.setRenderPipelineState(pixelPipeline)
      encoder.setVertexBytes(&uniforms, length: MemoryLayout<PixelUniforms>.stride, index: 0)
      encoder.setVertexBuffer(positionBuffer, offset: 0, index: 1)
      encoder.setVertexBuffer(colourBuffer, offset: 0, index: 2)
      encoder.setVertexBuffer(sizeBuffer, offset: 0, index: 3)
      encoder.setVertexBuffer(glowBuffer, offset: 0, index: 4)
      encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: drawCount)
    }

    static let source = """

      struct JumpmanUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float uPixelRatio;
      };
      struct JumpmanVarying {
        float4 position [[position]];
        float pointSize [[point_size]];
        float3 vColour;
        float vGlow;
      };

      vertex JumpmanVarying jumpmanVertex(
        uint vid [[vertex_id]], constant JumpmanUniforms &u [[buffer(0)]],
        constant float3 *vertices [[buffer(1)]], constant float3 *aColour [[buffer(2)]],
        constant float *aSize [[buffer(3)]], constant float *aGlow [[buffer(4)]]
      ) {
        JumpmanVarying out;
        out.vColour = aColour[vid];
        out.vGlow = aGlow[vid];
        float4 view = u.modelViewMatrix * float4(vertices[vid], 1.0);
        out.position = u.projectionMatrix * view;
        out.pointSize = aSize[vid] * u.uPixelRatio * (520.0 / max(1.0, -view.z));
        return out;
      }

      fragment float4 jumpmanFragment(JumpmanVarying in [[stage_in]], float2 pointCoord [[point_coord]]) {
        // Square, not round: this is a pixel. The bevel is the modern part — a light top-left edge
        // and a dark bottom-right one, so each cell reads as a little block with a thickness rather
        // than as a flat swatch. That is the whole "extruded sprite" idea in four lines of shader.
        float2 p = pointCoord;
        float lit = smoothstep(0.42, 0.06, max(p.x, p.y));
        float shade = smoothstep(0.58, 0.94, max(1.0 - p.x, 1.0 - p.y));
        float3 colour = in.vColour * (0.82 + lit * 0.5 - shade * 0.28) + in.vColour * in.vGlow;
        return float4(colour, 1.0);
      }

      """
  }
#endif
