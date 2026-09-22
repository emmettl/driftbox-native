#if canImport(Metal)
  import DriftboxEngine
  import Metal
  import Testing

  @testable import DriftboxScenes

  /// Jump Man's game, which a picture alone would not pin down.
  struct JumpmanTests {
    /// A stomped monster comes apart from where it is drawn. The web first spawned its pieces
    /// without the half of the view its draw call subtracts, so they burst out of empty air
    /// about a fifth of a screen right of centre while he stood left of it — fixed there as
    /// emmettl/driftbox#301 and here with it.
    @Test func aStompedMonsterComesApartUnderHisFeet() throws {
      guard let device = MTLCreateSystemDefaultDevice() else { return }
      let renderer = try SceneRenderer(device: device, sceneId: "jumpman", now: 0)
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: 960, height: 540, mipmapped: false)
      descriptor.usage = [.renderTarget, .shaderRead]
      descriptor.storageMode = .private
      let texture = try #require(device.makeTexture(descriptor: descriptor))
      var time = 0.0
      func frame() {
        renderer.draw(SceneInput(time: time, running: true, bpm: 120), into: texture)
        time += 1.0 / 60
      }
      for _ in 0..<30 { frame() }

      let scene = try #require(renderer.scene as? Jumpman)
      // Landscape, so the view is the wide one, and he stands at his usual place in it.
      let across = Jumpman.viewWide
      let runnerX = across * Jumpman.runnerAt
      // Airborne above a monster standing exactly where he is: a stomp, on the next frame.
      scene.monsters = [Jumpman.Monster(x: scene.scroll + runnerX + across / 2, alive: true)]
      scene.hop = 4
      scene.hopVel = 0
      frame()

      #expect(scene.monsters.first?.alive == false, "stomped")
      let xs = scene.shards.map(\.x)
      #expect(!xs.isEmpty)
      // The monster is eight cells wide and drawn centred on him; its pieces have had one frame
      // to scatter. Anywhere near half a view away is the fault.
      #expect(xs.allSatisfy { abs($0 - runnerX) < 8 }, "from under him at \(runnerX), not \(xs)")
    }
  }
#endif
