#if canImport(AVFoundation) && canImport(Metal)
  import AVFoundation
  import DriftboxEngine
  import DriftboxHost
  import DriftboxSeq
  import DriftboxSession
  import Foundation
  import Testing

  @testable import DriftboxApp

  /// A performance recorded, played again for a movie: what is heard again is what was heard. How a
  /// take is recorded is the session's `TakeTests`.
  @MainActor
  struct TakeTests {
    /// The engine rendered as a device would, in blocks of 512, with what it rendered kept.
    @MainActor
    final class Live {
      let session: Session
      var host: EngineHost { session.host }
      var left: [Float] = []
      var right: [Float] = []

      init(_ session: Session) { self.session = session }

      func play(_ frames: Int) {
        var l = [Float](repeating: 0, count: 512)
        var r = [Float](repeating: 0, count: 512)
        var done = 0
        while done < frames {
          let count = min(512, frames - done)
          l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
              host.render(frames: count, left: lp.baseAddress!, right: rp.baseAddress!)
            }
          }
          left += l.prefix(count)
          right += r.prefix(count)
          done += count
        }
        // As the app ticks the session while it draws: how it learns the engine is playing.
        session.tick()
      }
    }

    /// A performance: play, the pad swept and let go, a key struck, a step edited as it plays, a
    /// jump back to the top, and a stop — recorded, and played again.
    static func performed() throws -> (take: Take, heard: (left: [Float], right: [Float]), start: Int) {
      let host = EngineHost(sampleRate: 48000)
      let session = Session(host: host)
      session.open(steadySong(), named: "Steady")
      let live = Live(session)
      live.play(4000)
      session.play()
      live.play(512)
      session.startRecording()
      let start = live.left.count
      live.play(30000)
      session.pad(x: 0.2, y: 0.8)
      live.play(3000)
      session.pad(x: 0.7, y: 0.3)
      live.play(6000)
      session.padRelease()
      live.play(4000)
      session.strike(index: 0, accent: true)
      live.play(7000)
      session.editShown("Set Step") { pattern in
        var pattern = pattern
        pattern.tracks["909.bd"]?[3] = .off
        return pattern
      }
      live.play(12000)
      session.seek(toStep: 0)
      live.play(8000)
      session.stop()
      live.play(10000)
      let take = try #require(session.stopRecording())
      return (take, (Array(live.left[start...]), Array(live.right[start...])), start)
    }

    /// Played again on an engine of its own, the take is heard as it was: sample for sample, once the
    /// engine's own free-running state — the tails, the noise, the modulation it had before the take,
    /// which a take does not keep — has settled, well inside half a second. The pad, the key, the
    /// edit, the jump and the stop all land after that, on the frames they landed on live.
    @Test func aTakePlayedAgainIsWhatWasHeard() async throws {
      let (take, heard, _) = try Self.performed()
      let played = try await MovieExport.perform(take, format: MovieExportTests.small)
      let count = heard.left.count
      #expect(played.left.count >= count)
      let loudest = heard.left.map(abs).max() ?? 0
      #expect(loudest > 0.05, "something was heard: \(loudest)")
      let settled = 24000
      // Sample for sample, bar the last place of a float where a render call ends: the device cuts
      // its calls one way and the movie another, and a sum carried across a boundary rounds once
      // differently. A millionth is a thousand times louder than that and a thousand times quieter
      // than anything heard.
      let different = (settled..<count).filter {
        abs(played.left[$0] - heard.left[$0]) > 1e-6 || abs(played.right[$0] - heard.right[$0]) > 1e-6
      }
      #expect(
        different.isEmpty, "\(different.count) samples differ after settling, from \(different.first ?? -1)")
      #expect(
        take.events.first.map { $0.frame - take.start } ?? 0 > settled, "the test's first touch is after it")
    }

    /// Through the stage, as the File menu does it: recorded with the scene switched part way, and
    /// written as a movie as long as the take.
    @Test func aRecordedPerformanceIsWrittenWithItsSwitches() async throws {
      try await withTemporaryDirectoryAsync { directory in
        let (player, host) = try openedPlayer(steadySong(), in: directory)
        let stage = Stage(player: player)
        stage.movieFormat = MovieExportTests.small
        var revealed: [URL] = []
        stage.reveal = { revealed.append($0) }
        player.play()
        renderAudio(host, frames: 4800)
        player.tick()
        stage.startRecording()
        #expect(player.isRecording)
        renderAudio(host, frames: 24000)
        stage.sceneChoice = "pulse"
        renderAudio(host, frames: 24000)
        let take = try #require(player.stopRecording())
        #expect(take.events.contains { if case .scene("pulse") = $0.event { true } else { false } })

        let url = directory.appendingPathComponent("Performance.mov")
        stage.exportPerformance(take, to: url)
        for _ in 0..<3000 where stage.exporting != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(stage.exportFailure == nil)
        #expect(revealed == [url])
        let seconds = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(seconds - 1) < 0.1, "a second of performance: \(seconds)")
      }
    }

  }
#endif
