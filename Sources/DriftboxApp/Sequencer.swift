#if canImport(SwiftUI) && canImport(AVFoundation)
  import AppKit
  import DriftboxEngine
  import DriftboxSeq
  import SwiftUI

  /// Where the grid's columns fall, shared by the drum lanes, the ruler over them and the 303
  /// lines under them, so a step lines up with the same step all the way down.
  struct GridMetrics {
    static let labelWidth = 112.0
    static let gap = 4.0
    static let minimumStride = 22.0
    static let maximumStride = 88.0

    let steps: Int
    /// From one column's left edge to the next.
    let stride: Double

    init(steps: Int, width: Double) {
      self.steps = max(1, steps)
      let room = (width - Self.labelWidth) / Double(self.steps)
      stride = min(Self.maximumStride, max(Self.minimumStride, room))
    }

    var cell: Double { stride - Self.gap }
    /// A step's height: a little taller than wide while the columns are narrow, and no taller
    /// than the web's thirty points once they are not.
    var stepHeight: Double { min(30, max(22, cell * 1.2)) }
    var width: Double { Self.labelWidth + stride * Double(steps) }
  }

  /// The step grid for the pattern the transport is in, or the one chosen to edit: a ruler with
  /// the playhead on it, a lane per drum voice, then the two 303 lines. Columns stretch with the
  /// window, down to a size that can still be hit, and scroll sideways past that.
  struct Sequencer: View {
    let player: Player
    let song: Song

    var body: some View {
      if let pattern = player.shownPattern {
        // The playhead only means something on the pattern that is playing, and only while
        // it is: stopped, there is nothing moving to follow.
        let playing = player.isPlaying && player.position?.pattern?.id == pattern.id
        let playhead = playing ? (player.position?.step ?? -1) : -1
        let voices = allVoices.filter { pattern.tracks[$0.id] != nil }
        GeometryReader { viewport in
          let metrics = GridMetrics(steps: pattern.length, width: viewport.size.width - 24)
          ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 5) {
              Ruler(metrics: metrics, playhead: playhead)
              ForEach(voices, id: \.id) { voice in
                let index = allVoices.firstIndex { $0.id == voice.id } ?? -1
                Lane(
                  player: player, pattern: pattern, voice: voice, metrics: metrics,
                  struck: player.struck.contains(index), selected: player.selectedVoice == voice.id,
                  playhead: playhead)
              }
              PCFLane(player: player, pattern: pattern, metrics: metrics, playhead: playhead)
              PatternFooter(player: player, song: song, pattern: pattern)
              ForEach(["303.a", "303.b"].filter { pattern.bass[$0] != nil }, id: \.self) { voiceId in
                BassGrid(
                  player: player, pattern: pattern, voiceId: voiceId, metrics: metrics, playhead: playhead,
                  selected: player.selectedVoice == voiceId
                )
                .padding(.top, 10)
              }
            }
            .padding(12)
            .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
          }
          .scrollIndicators(.automatic)
        }
      }
    }
  }

  /// The row of ticks over the grid: every fourth brighter, so a bar reads in beats without
  /// counting, and the playhead's tall and lit.
  struct Ruler: View {
    let metrics: GridMetrics
    let playhead: Int

    var body: some View {
      HStack(spacing: GridMetrics.gap) {
        ForEach(0..<metrics.steps, id: \.self) { step in
          let live = step == playhead
          RoundedRectangle(cornerRadius: 2)
            .fill(live ? Theme.live : Color.white.opacity(step % 4 == 0 ? 0.2 : 0.09))
            .frame(width: metrics.cell, height: live ? 8 : 4)
            .shadow(color: live ? Theme.live.opacity(0.85) : .clear, radius: 6)
        }
      }
      .frame(height: 8, alignment: .bottom)
      .padding(.leading, GridMetrics.labelWidth + 4)
    }
  }

  /// One voice's row of the grid. Its inputs are all plain values, so a step elsewhere, or a
  /// flash on another lane, leaves this one's body alone.
  struct Lane: View {
    let player: Player
    let pattern: DriftboxSeq.Pattern
    let voice: Voice
    let metrics: GridMetrics
    let struck: Bool
    let selected: Bool
    let playhead: Int

    var body: some View {
      let loop = pattern.trackLength(voice.id)
      HStack(spacing: 0) {
        LaneHeader(player: player, pattern: pattern, voice: voice, struck: struck, selected: selected)
          .frame(width: GridMetrics.labelWidth, alignment: .leading)
        HStack(spacing: GridMetrics.gap) {
          ForEach(0..<pattern.length, id: \.self) { index in
            StepButton(
              player: player, patternId: pattern.id, voiceId: voice.id, index: index,
              value: pattern.step(voice.id, at: index), playing: index == playhead,
              machine: voice.machine, flam: pattern.flam(voice.id, at: index), tail: index >= loop,
              width: metrics.cell, height: metrics.stepHeight)
          }
        }
      }
      .padding(.vertical, 2)
      .padding(.horizontal, 4)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(selected ? 0.06 : 0)))
    }
  }

  /// A lane's name, with a light that flashes in the machine's colour as the voice strikes, and
  /// its menu, which shows itself under the pointer.
  struct LaneHeader: View {
    let player: Player
    let pattern: DriftboxSeq.Pattern
    let voice: Voice
    let struck: Bool
    let selected: Bool
    @State private var hovering = false

    var body: some View {
      let tint = Theme.color(voice.machine)
      HStack(spacing: 7) {
        Circle()
          .fill(struck ? tint : Color.white.opacity(0.12))
          .frame(width: 6, height: 6)
          .shadow(color: struck ? tint : .clear, radius: 5)
          // On at once, off slowly: a light that has been struck, not a switch.
          .animation(struck ? nil : .easeOut(duration: 0.3), value: struck)
        Button {
          player.selectedVoice = selected ? nil : voice.id
        } label: {
          Text(voice.name)
            .font(Theme.mono(11, selected ? .semibold : .regular))
            .foregroundStyle(selected ? Theme.ink : hovering ? Theme.ink.opacity(0.85) : Theme.dim)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show \(voice.name)'s knobs")
      }
      // The menu sits over the end of the name rather than beside it, so the name has the
      // whole width until the pointer asks for the menu.
      .overlay(alignment: .trailing) {
        if hovering || selected {
          LaneMenu(player: player, pattern: pattern, voiceId: voice.id) {
            AnyView(
              Image(systemName: "ellipsis").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(red: 0.12, green: 0.1, blue: 0.2)))
                .contentShape(Rectangle()))
          }
          .transition(.opacity)
        }
      }
      .padding(.trailing, 4)
      .frame(height: 22)
      .onHover { hovering = $0 }
    }
  }

  /// The pattern-controlled filter's lane: strikes of the song-wide filter, on the drums'
  /// columns, in teal, as the web draws it.
  struct PCFLane: View {
    let player: Player
    let pattern: DriftboxSeq.Pattern
    let metrics: GridMetrics
    let playhead: Int

    var body: some View {
      HStack(spacing: 0) {
        HStack(spacing: 7) {
          Circle().fill(Theme.nine.opacity(0.35)).frame(width: 6, height: 6)
          Text("PCF").font(Theme.mono(11, .medium)).tracking(1.2).foregroundStyle(Theme.nine)
        }
        .frame(width: GridMetrics.labelWidth, alignment: .leading)
        .help("The pattern-controlled filter: each step strikes the song-wide filter's envelope")
        HStack(spacing: GridMetrics.gap) {
          ForEach(0..<pattern.length, id: \.self) { index in
            let value = pattern.pcf(at: index)
            Button {
              player.editPattern(pattern.id, "Set Filter Step") { $0.cyclingPCF(at: index) }
            } label: {
              StepFace(
                value: value, playing: index == playhead, machine: .tr909, onBeat: index % 4 == 0,
                flam: false,
                fill: Theme.gradient(
                  Color(red: 159 / 255, green: 1, blue: 240 / 255),
                  Color(red: 39 / 255, green: 185 / 255, blue: 159 / 255))
              )
              .frame(width: metrics.cell, height: metrics.stepHeight * 0.8)
            }
            .buttonStyle(StepPress())
          }
        }
      }
      .padding(.horizontal, 4)
      .padding(.top, 5)
      .overlay(alignment: .top) {
        Rectangle().fill(Theme.nine.opacity(0.18)).frame(height: 1).padding(.horizontal, 4)
      }
    }
  }

  /// A lane for a voice the pattern does not use yet, or a 303 line it has not got.
  struct AddLaneMenu: View {
    let player: Player
    let pattern: DriftboxSeq.Pattern

    var body: some View {
      let unused = allVoices.filter { pattern.tracks[$0.id] == nil }
      let lines = ["303.a", "303.b"].filter { pattern.bass[$0] == nil }
      Menu {
        Section("TR-808") {
          ForEach(unused.filter { $0.machine == .tr808 }, id: \.id) { voice in
            Button(voice.name) { add(voice.id) }
          }
        }
        Section("TR-909") {
          ForEach(unused.filter { $0.machine == .tr909 }, id: \.id) { voice in
            Button(voice.name) { add(voice.id) }
          }
        }
        if !lines.isEmpty {
          Section("TB-303") {
            ForEach(lines, id: \.self) { line in
              Button(line == "303.a" ? "303 A" : "303 B") {
                player.editShown("Add Line") { pattern in
                  var out = pattern
                  out.bass[line] = [BassStep](repeating: .rest, count: pattern.length)
                  return out
                }
              }
            }
          }
        }
      } label: {
        Label("lane", systemImage: "plus").font(Theme.mono(10)).foregroundStyle(Theme.dim)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Add a drum voice or a 303 line to this pattern")
      .disabled(unused.isEmpty && lines.isEmpty)
    }

    private func add(_ voiceId: String) {
      player.editShown("Add Lane") { pattern in
        var out = pattern
        out.tracks[voiceId] = [StepValue](repeating: .off, count: pattern.length)
        return out
      }
      player.selectedVoice = voiceId
    }
  }

  /// One step. Off, on, or accented, lit in its machine's colour; the playhead's column is
  /// outlined and glowing all the way down. A press gives under the pointer, and a change of
  /// state fades rather than snaps.
  struct StepButton: View {
    let player: Player
    let patternId: String
    let voiceId: String
    let index: Int
    let value: StepValue
    let playing: Bool
    var machine: Machine = .tr808
    var flam = false
    /// Past the end of a lane that loops shorter than the pattern: it plays the lane again
    /// from its start, so there is nothing here to set.
    var tail = false
    var width = 30.0
    var height = 30.0

    var onBeat: Bool { index % 4 == 0 }

    var body: some View {
      Button(action: cycle) {
        StepFace(value: value, playing: playing, machine: machine, onBeat: onBeat, flam: flam)
          .frame(width: width, height: height)
      }
      .buttonStyle(StepPress())
      .disabled(tail)
      .opacity(tail ? 0.28 : 1)
    }

    /// Cycle the step; or, on a 909 lane in flam mode or with Option held, mark a flam on it.
    func cycle() {
      let flamming = voiceId.hasPrefix("909.") && (player.flamMode || NSEvent.modifierFlags.contains(.option))
      player.editPattern(patternId, flamming ? "Set Flam" : "Set Step") {
        flamming ? $0.togglingFlam(voiceId, at: index) : $0.cyclingStep(voiceId, at: index)
      }
    }
  }

  /// A press that gives: down a little on the way in, and springing back.
  struct StepPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .scaleEffect(configuration.isPressed ? 0.9 : 1)
        .animation(.spring(response: 0.16, dampingFraction: 0.55), value: configuration.isPressed)
    }
  }

  struct StepFace: View {
    let value: StepValue
    let playing: Bool
    let machine: Machine
    let onBeat: Bool
    let flam: Bool
    /// A fill other than the machine's, for the PCF lane.
    var fill: LinearGradient?
    @State private var hovering = false

    var body: some View {
      let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
      ZStack {
        shape.fill(Color.white.opacity(onBeat ? 0.075 : 0.03))
        shape.fill(fill ?? Theme.stepFill(machine)).opacity(value == .on ? 1 : 0)
        shape.fill(Theme.accentFill).opacity(value == .accent ? 1 : 0)
        if playing {
          shape.fill(Theme.live.opacity(value == .off ? 0.2 : 0.12))
        }
        if flam {
          // A second bright edge, for the 909's second strike.
          HStack {
            Spacer()
            Rectangle().fill(Color.white.opacity(0.72)).frame(width: 4)
          }
          .clipShape(shape)
        }
      }
      .overlay(
        shape.strokeBorder(
          value == .accent
            ? Color.white
            : value == .on ? Color.white.opacity(0.5) : Color.white.opacity(hovering ? 0.45 : 0.1))
      )
      .overlay {
        if playing {
          shape.inset(by: -2.5).stroke(Theme.live, lineWidth: 2)
        }
      }
      .shadow(color: shadow, radius: playing ? (value == .off ? 9 : 13) : 7)
      .animation(.easeOut(duration: 0.12), value: value)
      .onHover { hovering = $0 }
    }

    var shadow: Color {
      if playing { return Theme.live.opacity(value == .off ? 0.45 : 0.75) }
      if value == .accent { return Theme.accentGlow.opacity(0.55) }
      return .clear
    }
  }
#endif
