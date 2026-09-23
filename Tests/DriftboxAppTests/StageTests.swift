#if canImport(AVFoundation) && canImport(Metal)
  import AppKit
  import DriftboxEngine
  import DriftboxHost
  import DriftboxScenes
  import DriftboxSeq
  import Foundation
  import Metal
  import Testing

  @testable import DriftboxApp

  /// The stage: one renderer drawing each frame once, however many views are showing it, and the
  /// window it goes out to.
  @MainActor
  struct StageTests {
    @Test func aFrameIsDrawnAtTheSizeAskedForAndTheTwoTakeTurns() throws {
      try withTemporaryDirectory { directory in
        let (player, _) = try openedPlayer(steadySong(), in: directory)
        let stage = Stage(player: player)
        guard stage.renderer != nil else { return }

        stage.render(size: SIMD2(320, 180), pixelRatio: 2)
        let first = try #require(stage.latest)
        #expect(first.width == 320 && first.height == 180)
        stage.render(size: SIMD2(320, 180), pixelRatio: 2)
        let second = try #require(stage.latest)
        // Two frames in turn, so a view can still be showing one while the next is drawn.
        #expect(first !== second)
        stage.render(size: SIMD2(320, 180), pixelRatio: 2)
        #expect(stage.latest === first)

        // A new size is a new pair, at that size.
        stage.render(size: SIMD2(200, 200), pixelRatio: 1)
        #expect(stage.latest?.width == 200 && stage.latest?.height == 200)
        // And a view with no size yet draws nothing rather than a frame of no pixels.
        let before = stage.latest
        stage.render(size: SIMD2(0, 200), pixelRatio: 1)
        #expect(stage.latest === before)
      }
    }

    /// One reader of the engine's events. Two renderers would each have been handed half the
    /// hits, which is exactly why there is one.
    @Test func drawingTakesTheEventsSoNothingElseCan() throws {
      try withTemporaryDirectory { directory in
        let (player, host) = try openedPlayer(steadySong(), in: directory)
        let stage = Stage(player: player)
        guard stage.renderer != nil else { return }
        renderAudio(host, frames: 4800)
        player.tick()
        stage.render(size: SIMD2(64, 64), pixelRatio: 1)
        #expect(player.takeEvents().isEmpty)
      }
    }

    @Test func itDrawsTheSceneTheSongAsksFor() throws {
      try withTemporaryDirectory { directory in
        var song = steadySong()
        song.visual = "saturn"
        let (player, _) = try openedPlayer(song, in: directory)
        let stage = Stage(player: player)
        guard let renderer = stage.renderer else { return }
        stage.render(size: SIMD2(64, 64), pixelRatio: 1)
        #expect(renderer.sceneType.id == "saturn")
      }
    }

    /// A scene chosen over the song's own is the one drawn; the next one goes round the list and
    /// back to the start; nil is the song's own again.
    @Test func aChosenSceneIsDrawnAndTheListGoesRound() throws {
      try withTemporaryDirectory { directory in
        var song = steadySong()
        song.visual = "saturn"
        let (player, _) = try openedPlayer(song, in: directory)
        let stage = Stage(player: player)
        #expect(stage.sceneId == "saturn")
        stage.sceneChoice = "orrery"
        #expect(stage.sceneId == "orrery")
        #expect(stage.sceneName == "Orrery")
        if let renderer = stage.renderer {
          stage.render(size: SIMD2(64, 64), pixelRatio: 1)
          #expect(renderer.sceneType.id == "orrery")
        }
        let all = Scenes.all.map { $0.id }
        stage.sceneChoice = all.last
        stage.cycleScene()
        #expect(stage.sceneId == all.first)
        stage.cycleScene(by: -1)
        #expect(stage.sceneId == all.last)
        stage.sceneChoice = nil
        #expect(stage.sceneId == "saturn")
      }
    }

    /// The scope's line is the mix: moving while the song plays.
    @Test func theScopeReadsTheMix() throws {
      try withTemporaryDirectory { directory in
        let (player, host) = try openedPlayer(steadySong(), in: directory)
        renderAudio(host, frames: 4800)
        let samples = player.recentMix(512)
        #expect(samples.count == 512)
        #expect(samples.contains { abs($0) > 0.01 })
      }
    }

    /// Web Audio answers two reads inside one render quantum with the same spectrum, and the
    /// smoothing is applied per analysis. Asking twice before any new audio has arrived must
    /// not smooth twice, or the bands fall faster than they do on the web — which is what a
    /// display faster than the audio blocks, or two views in one frame, would otherwise do.
    @Test func theSpectrumOnlyMovesWhenTheAudioDoes() throws {
      try withTemporaryDirectory { directory in
        let (player, host) = try openedPlayer(steadySong(), in: directory)
        renderAudio(host, frames: 4800)
        let first = try #require(player.analyse()).bands(8)
        #expect(first.contains { $0 > 0 }, "a kick every step is something to see")
        let again = try #require(player.analyse()).bands(8)
        #expect(again == first)

        player.stop()
        renderAudio(host, frames: 48000)
        let later = try #require(player.analyse()).bands(8)
        #expect(later != first)
      }
    }

    /// The window's bookkeeping, which is what the menu and the next launch both read: open is
    /// open everywhere it is asked, and closed is closed everywhere too.
    @Test func theVisualsWindowOpensClosesAndIsRemembered() throws {
      try withTemporaryDirectory { directory in
        let (player, _) = try openedPlayer(steadySong(), in: directory)
        let stage = Stage(player: player)
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: Defaults.outputOpen)
        defer { defaults.set(saved, forKey: Defaults.outputOpen) }

        #expect(!stage.output.isOpen && !stage.outputOpen)
        stage.output.show()
        #expect(stage.output.isOpen && stage.outputOpen)
        #expect(defaults.bool(forKey: Defaults.outputOpen))
        stage.output.close()
        #expect(!stage.output.isOpen && !stage.outputOpen)
        #expect(!defaults.bool(forKey: Defaults.outputOpen))

        // Closed by the application rather than by a person — which is what quitting does to
        // every window — it stays remembered as open, so it comes back at the next launch. The
        // first version recorded this in `windowWillClose` and forgot it on every quit.
        stage.output.show()
        let window = try #require(NSApp.windows.first { $0.title == "Visuals" && $0.isVisible })
        window.close()
        #expect(!stage.output.isOpen)
        #expect(defaults.bool(forKey: Defaults.outputOpen))
        defaults.set(false, forKey: Defaults.outputOpen)

        // Nothing is reopened that was not open.
        stage.restore()
        #expect(!stage.output.isOpen)
        // And what was open comes back.
        defaults.set(true, forKey: Defaults.outputOpen)
        stage.restore()
        #expect(stage.output.isOpen)
        stage.output.close()
      }
    }
  }
#endif
