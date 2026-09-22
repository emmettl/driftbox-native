#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxEngine
  import DriftboxSeq
  import SwiftUI

  /// The pad: across is cutoff, up is resonance, and letting go glides back to nothing. Talks to
  /// the engine directly, since it is a performance control and not part of the song.
  struct KaossPad: View {
    let player: Player
    @State private var touch: CGPoint?

    var body: some View {
      GeometryReader { geometry in
        ZStack {
          RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85))
          if let touch {
            Circle().fill(Color.orange.opacity(0.8)).frame(width: 18, height: 18).position(touch)
          }
          Text(touch == nil ? "filter" : "").foregroundStyle(.secondary).font(.caption)
        }
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in
              touch = value.location
              let x = max(0, min(1, value.location.x / geometry.size.width))
              let y = max(0, min(1, 1 - value.location.y / geometry.size.height))
              player.pad(x: x, y: y)
            }
            .onEnded { _ in
              touch = nil
              player.padRelease()
            })
      }
    }
  }

  /// One voice's knobs, and its sends. A change goes into the song when the slider is let go.
  struct VoicePanel: View {
    let player: Player
    let voice: Voice
    let params: VoiceParams
    let sends: SendLevels

    var body: some View {
      VStack(alignment: .leading, spacing: 6) {
        Text(voice.name).font(.headline)
        ForEach(Array(VoiceParams.names.enumerated()), id: \.offset) { knob, name in
          Knob(name: name, value: params[knob]) { value in
            player.edit("Set \(name)") { song in
              var edited = song.kit.params[voice.id] ?? VoiceParams()
              edited[knob] = value
              song.kit.params[voice.id] = edited
            }
          }
        }
        Divider()
        ForEach(Array(SendLevels.names.enumerated()), id: \.offset) { knob, name in
          Knob(name: name, value: sends[knob]) { value in
            player.edit("Set \(name)") { song in
              var edited = song.kit.sends[voice.id] ?? SendLevels()
              edited[knob] = value
              song.kit.sends[voice.id] = edited
            }
          }
        }
      }
      .padding(12)
      .frame(width: 220)
    }
  }

  /// A 0...1 knob, drawn as a slider for now. Reports on release, not on every pixel.
  struct Knob: View {
    let name: String
    let value: Double
    let commit: (Double) -> Void
    @State private var dragging: Double?

    var body: some View {
      HStack {
        Text(name).font(.caption).frame(width: 60, alignment: .leading)
        Slider(
          value: Binding(get: { dragging ?? value }, set: { dragging = $0 }), in: 0...1,
          onEditingChanged: { editing in
            if !editing, let dragging {
              commit(dragging)
              self.dragging = nil
            }
          })
        Text(String(format: "%.2f", dragging ?? value)).font(.caption.monospacedDigit()).frame(width: 36)
      }
    }
  }

  /// The song's effects: drive, the pattern-controlled filter, the compressor, the two sends.
  struct FxPanel: View {
    let player: Player
    let fx: FxParams

    var body: some View {
      VStack(alignment: .leading, spacing: 6) {
        Text("Effects").font(.headline)
        ForEach(Array(FxParams.names.enumerated()), id: \.offset) { knob, name in
          Knob(name: name, value: fx[knob]) { value in
            player.edit("Set \(name)") { song in song.fx[knob] = value }
          }
        }
      }
      .padding(12)
      .frame(width: 220)
    }
  }
#endif
