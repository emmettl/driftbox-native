#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxSeq
  import DriftboxSession

  /// What a knob or a dragged number on the groovebox's face turns, in the song: what its edit is
  /// called, the automation lane it is, and how the song takes it. The same lanes the Windows and
  /// Android faces record into, and an app's automation moves (`GrooveboxKnob`).
  struct FaceKnob {
    /// What undoing it is called.
    let name: String
    /// Its lane in the song's automation, in `AutomationTarget`'s names.
    let lane: String
    /// Whether its recorded points hold until the next, as the tempo's do, rather than ramp.
    var holds = false
    /// What the song holds with it at a value, where that is not the value itself.
    var songValue: @Sendable (Double) -> Double = { $0 }
    let write: @Sendable (inout Song, Double) -> Void

    /// One of a drum voice's six.
    static func voice(_ id: String, _ knob: Int) -> FaceKnob {
      FaceKnob(
        name: "Set \(KnobSpec.voice[knob].label)", lane: AutomationTarget.voice(id, VoiceParams.names[knob])
      ) { song, value in
        var edited = song.kit.params[id] ?? VoiceParams()
        edited[knob] = value
        song.kit.params[id] = edited
      }
    }

    /// One of a 303's eight.
    static func bass(_ id: String, _ knob: Int) -> FaceKnob {
      FaceKnob(
        name: "Set \(KnobSpec.bass[knob].label)", lane: AutomationTarget.bass(id, BassParams.names[knob])
      ) { song, value in
        var edited = song.kit.bass[id] ?? BassParams()
        edited[knob] = value
        song.kit.bass[id] = edited
      }
    }

    /// A voice's send to the delay or the reverb.
    static func send(_ id: String, _ knob: Int) -> FaceKnob {
      FaceKnob(
        name: "Set \(KnobSpec.sends[knob].label) Send",
        lane: AutomationTarget.send(id, SendLevels.names[knob])
      ) { song, value in
        var edited = song.kit.sends[id] ?? SendLevels()
        edited[knob] = value
        song.kit.sends[id] = edited
      }
    }

    /// A voice's swing, as an offset from the song's.
    static func swing(_ id: String) -> FaceKnob {
      FaceKnob(name: "Set Voice Swing", lane: AutomationTarget.voiceSwing(id)) { $0.kit.swing[id] = $1 }
    }

    /// One of the song's effects.
    static func fx(_ knob: Int) -> FaceKnob {
      FaceKnob(name: "Set \(KnobSpec.fx[knob].label)", lane: AutomationTarget.fx(FxParams.names[knob])) {
        $0.fx[knob] = $1
      }
    }

    /// The tempo, in whole beats a minute, which holds until the next point, as the reference
    /// records it.
    static let tempo = FaceKnob(
      name: "Set Tempo", lane: AutomationTarget.bpm, holds: true, songValue: { $0.rounded() },
      write: { $0.bpm = $1.rounded() })

    /// The song's swing, dragged in whole percent and kept as a fraction.
    static let songSwing = FaceKnob(
      name: "Set Swing", lane: AutomationTarget.swing, songValue: { $0.rounded() / 100 },
      write: { $0.swing = $1.rounded() / 100 })
  }

  extension Session {
    /// `knob` moved to `value` by a hand: heard at once, written into the song's automation where
    /// the transport is while recording is armed, and one step of undo once it is let go
    /// (`endTurn`).
    func turn(_ knob: FaceKnob, to value: Double) {
      turn(
        knob.name, automating: knob.lane, value: knob.songValue(value),
        interpolation: knob.holds ? .hold : .linear
      ) { knob.write(&$0, value) }
    }

    /// `knob` set to `value` at once, as a double-click or an arrow key sets it: one step of undo.
    func set(_ knob: FaceKnob, to value: Double) {
      turn(knob, to: value)
      endTurn()
    }
  }
#endif
