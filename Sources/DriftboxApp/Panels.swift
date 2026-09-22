#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxEngine
  import DriftboxSeq
  import SwiftUI

  /// The column down the right of the window: the strip for whatever lane is selected, the
  /// master effects, and the pad.
  struct Inspector: View {
    let player: Player
    let song: Song

    var body: some View {
      ScrollView {
        VStack(spacing: 12) {
          if let id = player.selectedVoice {
            if let voice = voice(id: id) {
              VoicePanel(
                player: player, voice: voice, params: song.kit.params[id] ?? VoiceParams(),
                sends: song.kit.sends[id] ?? SendLevels())
            } else if id.hasPrefix("303.") {
              BassPanel(
                player: player, voiceId: id, params: song.kit.bass[id] ?? BassParams(),
                sends: song.kit.sends[id] ?? SendLevels())
            }
          }
          FxPanel(player: player, fx: song.fx)
          PadPanel(player: player)
        }
        .padding(.bottom, 2)
      }
      .scrollIndicators(.never)
      .animation(.spring(response: 0.3, dampingFraction: 0.85), value: player.selectedVoice)
    }
  }

  /// A panel's head: which machine, in its colour, over what is on it.
  struct PanelHead<Trailing: View>: View {
    let machine: String
    let title: String
    let tint: Color
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 1) {
          Text(machine).font(Theme.mono(9.5, .semibold)).tracking(1).foregroundStyle(tint)
          Text(title).font(Theme.mono(15, .semibold)).foregroundStyle(Theme.ink)
        }
        Spacer()
        trailing()
      }
    }
  }

  /// Knobs three to a row, as on the web's panels.
  struct KnobRack: View {
    let specs: [KnobSpec]
    let indices: [Int]
    let values: (Int) -> Double
    let rests: (Int) -> Double
    let tint: Color
    var columns = 3
    var diameter: CGFloat = 40
    let commit: (Int, Double) -> Void

    var body: some View {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 10) {
        ForEach(indices, id: \.self) { knob in
          RotaryKnob(
            spec: specs[knob], value: values(knob), tint: tint, rest: rests(knob), diameter: diameter
          ) {
            value in
            commit(knob, value)
          }
        }
      }
    }
  }

  /// A voice's sends, set apart below its knobs: they change where it goes, not how it sounds.
  struct SendsRow: View {
    let player: Player
    let voiceId: String
    let sends: SendLevels
    let tint: Color

    var body: some View {
      HStack(alignment: .center, spacing: 10) {
        FieldLabel("Out").rotationEffect(.degrees(-90)).fixedSize().frame(width: 12)
        ForEach(Array(KnobSpec.sends.enumerated()), id: \.offset) { knob, spec in
          RotaryKnob(
            spec: spec, value: sends[knob], tint: tint.opacity(0.8), rest: SendLevels.defaults[knob],
            diameter: 32
          ) { value in
            player.edit("Set \(spec.label) Send") { song in
              var edited = song.kit.sends[voiceId] ?? SendLevels()
              edited[knob] = value
              song.kit.sends[voiceId] = edited
            }
          }
        }
        Spacer()
      }
      .padding(.top, 8)
      .overlay(alignment: .top) { Rectangle().fill(Theme.edge).frame(height: 1) }
    }
  }

  /// One drum voice's strip.
  struct VoicePanel: View {
    let player: Player
    let voice: Voice
    let params: VoiceParams
    let sends: SendLevels

    var tint: Color { Theme.color(voice.machine) }

    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        PanelHead(machine: voice.machine == .tr808 ? "TR-808" : "TR-909", title: voice.name, tint: tint) {
          HStack(spacing: 6) {
            Button("hit it") {
              if let index = player.usedVoices.firstIndex(where: { $0.id == voice.id }) {
                player.strike(index: index, accent: false)
              }
            }
            .buttonStyle(.chip)
            CloseButton { player.selectedVoice = nil }
          }
        }
        KnobRack(
          specs: KnobSpec.voice, indices: Array(KnobSpec.voice.indices), values: { params[$0] },
          rests: { VoiceParams.defaults[$0] }, tint: tint
        ) { knob, value in
          player.edit("Set \(KnobSpec.voice[knob].label)") { song in
            var edited = song.kit.params[voice.id] ?? VoiceParams()
            edited[knob] = value
            song.kit.params[voice.id] = edited
          }
        }
        SendsRow(player: player, voiceId: voice.id, sends: sends, tint: tint)
      }
      .padding(14)
      .panel()
      .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
    }
  }

  /// A 303's strip, and the switch between the two.
  struct BassPanel: View {
    let player: Player
    let voiceId: String
    let params: BassParams
    let sends: SendLevels

    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        PanelHead(machine: "TB-303", title: voiceId == "303.a" ? "303 A" : "303 B", tint: Theme.three) {
          HStack(spacing: 4) {
            ForEach(["303.a", "303.b"], id: \.self) { id in
              Button(id == "303.a" ? "A" : "B") { player.selectedVoice = id }
                .buttonStyle(.chip(on: id == voiceId, tint: Theme.three))
            }
            CloseButton { player.selectedVoice = nil }
          }
        }
        KnobRack(
          specs: KnobSpec.bass, indices: Array(KnobSpec.bass.indices), values: { params[$0] },
          rests: { BassParams.defaults[$0] }, tint: Theme.three
        ) { knob, value in
          player.edit("Set \(KnobSpec.bass[knob].label)") { song in
            var edited = song.kit.bass[voiceId] ?? BassParams()
            edited[knob] = value
            song.kit.bass[voiceId] = edited
          }
        }
        SendsRow(player: player, voiceId: voiceId, sends: sends, tint: Theme.three)
      }
      .padding(14)
      .panel()
      .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
    }
  }

  struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
      Button(action: action) {
        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
          .foregroundStyle(hovering ? Theme.ink : Theme.dim)
          .frame(width: 22, height: 22)
          .background(Circle().fill(Color.white.opacity(hovering ? 0.1 : 0.04)))
      }
      .buttonStyle(.plain)
      .onHover { hovering = $0 }
      .help("Close the strip")
    }
  }

  /// The song's effects: drive and the compressor, the pattern-controlled filter, the two sends.
  struct FxPanel: View {
    let player: Player
    let fx: FxParams

    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        PanelHead(machine: "MASTER", title: "Effects", tint: Theme.dim) { EmptyView() }
        ForEach(KnobSpec.fxGroups, id: \.name) { group in
          VStack(alignment: .leading, spacing: 6) {
            FieldLabel(group.name)
            KnobRack(
              specs: KnobSpec.fx, indices: group.knobs, values: { fx[$0] }, rests: { FxParams.defaults[$0] },
              tint: Theme.violet, columns: group.knobs.count > 3 ? 5 : 3,
              diameter: group.knobs.count > 3 ? 34 : 40
            ) { knob, value in
              player.edit("Set \(KnobSpec.fx[knob].label)") { song in song.fx[knob] = value }
            }
          }
        }
      }
      .padding(14)
      .panel()
    }
  }

  /// The pad: across is cutoff, up is resonance, and letting go glides back to nothing. Talks to
  /// the engine directly, since it is a performance control and not part of the song. The
  /// finger leaves a short glowing trail, which fades after it, so a sweep can be seen as one.
  struct PadPanel: View {
    let player: Player
    @State private var touch: CGPoint?
    @State private var trail: [CGPoint] = []
    @State private var pressed = false

    var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          FieldLabel("Filter pad")
          Spacer()
          Text(touch == nil ? "drag to sweep" : "cutoff → · reso ↑")
            .font(Theme.mono(9)).foregroundStyle(Theme.dim.opacity(0.8))
        }
        GeometryReader { geometry in
          ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.45))
            grid(in: geometry.size)
            trailPath
              .stroke(
                LinearGradient(
                  colors: [Theme.nine.opacity(0), Theme.nine.opacity(0.7)], startPoint: .leading,
                  endPoint: .trailing),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
              )
              .blur(radius: 1.5)
            if let touch {
              Circle().fill(Theme.nine.opacity(0.25)).frame(width: 46, height: 46).blur(radius: 8)
                .position(touch)
              Circle().fill(Color.white).frame(width: 12, height: 12)
                .shadow(color: Theme.nine, radius: 8)
                .scaleEffect(pressed ? 1 : 0.4)
                .position(touch)
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
              .strokeBorder(touch == nil ? Theme.edge : Theme.nine.opacity(0.5))
          )
          .contentShape(Rectangle())
          .gesture(
            DragGesture(minimumDistance: 0)
              .onChanged { value in
                let point = CGPoint(
                  x: max(0, min(geometry.size.width, value.location.x)),
                  y: max(0, min(geometry.size.height, value.location.y)))
                if touch == nil {
                  withAnimation(.spring(response: 0.2, dampingFraction: 0.55)) { pressed = true }
                }
                touch = point
                trail.append(point)
                if trail.count > 18 { trail.removeFirst(trail.count - 18) }
                player.pad(x: point.x / geometry.size.width, y: 1 - point.y / geometry.size.height)
              }
              .onEnded { _ in
                player.padRelease()
                withAnimation(.easeOut(duration: 0.35)) {
                  pressed = false
                  touch = nil
                  trail = []
                }
              })
        }
        .frame(height: 150)
      }
      .padding(14)
      .panel()
    }

    private var trailPath: Path {
      Path { path in
        guard let first = trail.first else { return }
        path.move(to: first)
        for point in trail.dropFirst() { path.addLine(to: point) }
      }
    }

    private func grid(in size: CGSize) -> some View {
      Path { path in
        for index in 1..<4 {
          let x = size.width * Double(index) / 4
          let y = size.height * Double(index) / 4
          path.move(to: CGPoint(x: x, y: 0))
          path.addLine(to: CGPoint(x: x, y: size.height))
          path.move(to: CGPoint(x: 0, y: y))
          path.addLine(to: CGPoint(x: size.width, y: y))
        }
      }
      .stroke(Color.white.opacity(0.05), lineWidth: 1)
    }
  }
#endif
