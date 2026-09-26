#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxEngine
  import DriftboxHost
  import DriftboxSeq
  import DriftboxSession
  import Foundation
  import Testing

  @testable import DriftboxApp

  /// The groovebox's face on the Mac records a knob as the Windows and Android faces do: heard as
  /// it turns, written into the song's automation while armed and playing, one step of undo when
  /// let go; and into the lanes an app's automation moves too.
  @MainActor
  struct FaceKnobTests {
    func fourBars() -> Song {
      var song = steadySong()
      song.chain = (0..<4).map { _ in ChainStep(pattern: "p") }
      return song
    }

    /// Every knob and number on the face is a lane an app's automation knows, by the same name.
    @Test func itsLanesAreTheGrooveboxs() {
      let lanes = Set(GrooveboxKnob.all.map(\.target))
      var knobs: [FaceKnob] = [.songSwing] + FxParams.names.indices.map { .fx($0) }
      for id in ["303.a", "303.b"] { knobs += BassParams.names.indices.map { .bass(id, $0) } }
      for id in ["808.bd", "909.sd"] {
        knobs += VoiceParams.names.indices.map { .voice(id, $0) }
        knobs += SendLevels.names.indices.map { .send(id, $0) }
        knobs.append(.swing(id))
      }
      for knob in knobs { #expect(lanes.contains(knob.lane), "\(knob.lane)") }
      #expect(FaceKnob.tempo.lane == AutomationTarget.bpm)
    }

    /// Armed and playing, a 303's knob turned is a point in its lane where the song is, heard at
    /// once, and the turn one step of undo.
    @Test func anArmedTurnIsRecordedInItsLane() throws {
      try withTemporaryDirectory { directory in
        let (player, host) = try openedPlayer(fourBars(), in: directory)
        player.recordsAutomation = true
        player.seek(toBar: 2)
        player.play()
        renderAudio(host, frames: 12000)
        player.tick()
        let position = try #require(player.position)
        let cutoff = FaceKnob.bass("303.a", 0)
        player.turn(cutoff, to: 0.3)
        player.turn(cutoff, to: 0.8)
        #expect(player.song?.kit.bass["303.a"]?[0] == 0.8, "heard as it turns")
        player.endTurn()

        let lane = try #require(player.song?.automation.first { $0.target == cutoff.lane })
        #expect(lane.interpolation == .linear)
        #expect(lane.points == [AutomationPoint(bar: 2, index: position.step, value: 0.8)])
        #expect(player.undoTitle == "Undo \(cutoff.name)")
        player.undo()
        #expect(player.song?.automation.isEmpty == true, "the turn and its points, undone at once")
      }
    }

    /// The tempo is recorded in whole beats, holding until the next point; and a value set at once,
    /// as a double-click or an arrow key sets it, is one step of undo and, stopped, no automation.
    @Test func theTempoHoldsAndASetIsOneUndo() throws {
      try withTemporaryDirectory { directory in
        let (player, host) = try openedPlayer(fourBars(), in: directory)
        player.recordsAutomation = true
        player.play()
        renderAudio(host, frames: 12000)
        player.tick()
        player.turn(.tempo, to: 133.4)
        player.endTurn()
        #expect(player.song?.bpm == 133)
        let lane = try #require(player.song?.automation.first { $0.target == AutomationTarget.bpm })
        #expect(lane.interpolation == .hold && lane.points.map(\.value) == [133])

        player.stop()
        renderAudio(host, frames: 512)
        player.tick()
        player.clearAutomation()
        player.set(.fx(0), to: 0.25)
        #expect(player.song?.fx[0] == 0.25 && player.song?.automation.isEmpty == true)
        #expect(player.undoTitle == "Undo \(FaceKnob.fx(0).name)")
      }
    }
  }
#endif
