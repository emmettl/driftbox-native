#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxRack
  import SwiftUI

  // The faces the reference builds by hand, one for one: each says something the definition
  // cannot — which knob matters, what a setting is doing, what is coming in — and the ones that
  // meter draw what the render thread last copied out, thirty times a second.
  //
  // A hand-built face names its params rather than walking them, which is the point of building
  // one and also its hazard: a param added to the module does not appear. So each says here what
  // it shows, and `RackFaceTests` holds that to the definition.
  enum HandBuilt {
    static let shows: [String: Set<String>] = [
      "vco": ["tune", "shape", "width"],
      "ladder": ["cutoff", "resonance"],
      "out": ["level", "pan", "mute", "solo"],
      "midi": Set(RackModules.registry["midi"]?.params.filter { !$0.hidden }.map(\.id) ?? []),
      "tuner": ["reference", "mute"],
      "meter": ["mode", "gain", "release"],
      "looper": ["mode", "clear", "feedback", "dry", "loop"],
    ]
  }

  /// The VCO: the tune knob big, because it is the one reached for; the shape named in the title;
  /// and the pulse width asleep when the shape is not a pulse.
  struct VcoFace: View {
    let face: FaceContext
    static let shapes = ["Saw", "Pulse", "Tri"]

    var body: some View {
      let shape = Int(face.value("shape").rounded())
      PanelTitle(name: "VCO", words: shape >= 0 && shape < Self.shapes.count ? Self.shapes[shape] : "—")
      HStack(alignment: .top, spacing: 0) {
        face.control("tune", tint: Theme.three, diameter: 46)
        face.control("shape")
        face.control("width", tint: Theme.three)
          .opacity(shape == 1 ? 1 : 0.35)
          .animation(.easeOut(duration: 0.2), value: shape)
      }
      Spacer(minLength: 0)
    }
  }

  /// The 303's filter, whose resonance turns pink where it starts to sing on its own.
  struct LadderFace: View {
    let face: FaceContext

    var body: some View {
      let squelch = face.value("resonance") > 0.75
      PanelTitle(name: "Ladder", words: squelch ? "squelch" : "4-pole")
      HStack(alignment: .top, spacing: 0) {
        face.control("cutoff", tint: Theme.three)
        face.control("resonance", tint: squelch ? Theme.eight : Theme.three)
      }
      Spacer(minLength: 0)
    }
  }

  /// A channel strip: level, pan, mute and solo.
  struct OutFace: View {
    let face: FaceContext

    var body: some View {
      PanelTitle(name: "Out", words: "")
      LazyVGrid(
        columns: Array(repeating: GridItem(.fixed(RackLayout.cellWidth), spacing: 0), count: 3), spacing: 0
      ) {
        face.control("level", tint: Theme.nine)
        face.control("pan", tint: Theme.eight)
        face.control("mute")
        face.control("solo")
      }
      Spacer(minLength: 0)
    }
  }

  /// The keyboard's module, and the answer to the first question anybody asks of one: is anything
  /// coming in? The last note played, or where the notes come from.
  struct MidiFace: View {
    let face: FaceContext

    var body: some View {
      PanelTitle(name: "MIDI") {
        Text(face.model.lastNote.map(RackKeyboard.name) ?? "keys")
          .font(Theme.mono(10, .semibold))
          .foregroundStyle(face.model.lastNote == nil ? Theme.dim : Theme.nine)
          .contentTransition(.numericText())
          .animation(.easeOut(duration: 0.12), value: face.model.lastNote)
      }
      HStack(alignment: .top, spacing: 0) {
        ForEach(face.def.params.filter { !$0.hidden }, id: \.id) { param in
          face.control(
            param.id, tint: param.id == "transpose" ? Theme.eight : nil,
            options: param.id == "channel" ? ["Omni"] + (1...16).map(String.init) : nil)
        }
      }
      Spacer(minLength: 0)
    }
  }

  /// The chromatic tuner: the note, big, with its octave; the frequency and the cents either side;
  /// and a needle across ±50 cents that lights the display when it is within five.
  struct TunerFace: View {
    let face: FaceContext

    var body: some View {
      let reading = face.reading
      let tuning = RackDisplay.tuning(
        frequency: reading?.frequency ?? 0, reference: face.value("reference"), clarity: reading?.clarity ?? 0
      )
      let inTune = tuning.detected && abs(tuning.cents) <= 5
      let colour = tuning.detected ? Theme.nine : Theme.ink.opacity(0.35)
      let cents = (tuning.cents >= 0 ? "+" : "") + String(format: "%.1f¢", tuning.cents)
      PanelTitle(name: "Chromatic Tuner", mark: "CT—40", markTint: Theme.nine, words: "55–2000 Hz")
      VStack(spacing: 6) {
        ZStack {
          Screen(
            border: Theme.nine.opacity(inTune ? 0.7 : 0.2), glow: inTune ? Theme.nine.opacity(0.22) : .clear)
          VStack(spacing: 0) {
            HStack(alignment: .top) {
              Text(tuning.detected ? String(format: "%.1f Hz", tuning.frequency) : "NO SIGNAL")
              Spacer()
              Text(tuning.detected ? cents : "—")
            }
            .font(Theme.mono(8)).tracking(0.6)
            .padding(.horizontal, 8).padding(.top, 12)
            Spacer(minLength: 0)
          }
          .foregroundStyle(colour)
          HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(tuning.note).font(Theme.mono(30, .bold))
            Text(tuning.octave.map(String.init) ?? "").font(Theme.mono(10)).baselineOffset(14)
          }
          .foregroundStyle(colour)
          .shadow(color: colour.opacity(0.8), radius: 9)
          .frame(maxHeight: .infinity, alignment: .top)
          .padding(.top, 4)
          CentsScale(cents: tuning.cents, colour: colour)
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 15)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(face.module.id) tuning")
        .accessibilityValue(tuning.detected ? "\(tuning.note)\(tuning.octave ?? 0) \(cents)" : "No signal")
        HStack(spacing: 0) {
          face.control("reference", tint: Theme.nine)
          face.control("mute")
        }
      }
    }

    struct CentsScale: View {
      let cents: Double
      let colour: Color

      var body: some View {
        GeometryReader { geometry in
          let width = geometry.size.width
          ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Theme.ink.opacity(0.18)).frame(height: 1)
            ForEach([-50, -25, 0, 25, 50], id: \.self) { tick in
              let x = width * Double(tick + 50) / 100
              Rectangle()
                .fill(tick == 0 ? Theme.nine.opacity(0.65) : Theme.ink.opacity(0.25))
                .frame(width: 1, height: tick == 0 ? 15 : 10)
                .offset(x: x, y: 4)
              Text(tick > 0 ? "+\(tick)" : "\(tick)")
                .font(Theme.mono(6)).foregroundStyle(Theme.ink.opacity(0.38))
                .fixedSize()
                .frame(width: 30)
                .offset(x: x - 15, y: 16)
            }
            Capsule().fill(colour).frame(width: 2, height: 17)
              .shadow(color: colour, radius: 3.5)
              .offset(x: width * (cents + 50) / 100 - 1, y: -1)
              .animation(.linear(duration: 0.055), value: cents)
          }
          .frame(width: width, height: 22, alignment: .bottomLeading)
        }
        .frame(height: 22)
      }
    }
  }

  /// A recessed screen, as the metering faces draw theirs.
  struct Screen: View {
    var border: Color = Theme.nine.opacity(0.2)
    var glow: Color = .clear
    var fill: Color = Color(red: 3 / 255, green: 12 / 255, blue: 12 / 255)

    var body: some View {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(
          RadialGradient(
            colors: [Color(red: 20 / 255, green: 74 / 255, blue: 65 / 255).opacity(0.24), fill],
            center: UnitPoint(x: 0.5, y: 0.45), startRadius: 0, endRadius: 140)
        )
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(border))
        .shadow(color: glow, radius: 5)
    }
  }

  /// A meter in a cable: a moving-coil needle, a bar of lights, or a scope, and a peak light.
  struct MeterFace: View {
    let face: FaceContext
    static let lights = 18

    var body: some View {
      let reading = face.reading
      let mode = max(0, min(2, Int(face.value("mode").rounded())))
      let level = reading?.level ?? 0
      let position = RackDisplay.meterPosition(mode == 0 ? reading?.envelope ?? 0 : level)
      PanelTitle(name: "Signal Bureau", mark: "VU—3") {
        let clipped = (reading?.peak ?? 0) > 1
        Text("PEAK")
          .font(Theme.mono(7)).tracking(0.8)
          .foregroundStyle(
            clipped ? Color(red: 1, green: 242 / 255, blue: 251 / 255) : Theme.eight.opacity(0.3)
          )
          .padding(.horizontal, 4).padding(.vertical, 1)
          .background(
            RoundedRectangle(cornerRadius: 3).fill(clipped ? Theme.eight : .clear)
              .shadow(color: clipped ? Theme.eight.opacity(0.75) : .clear, radius: 6)
          )
          .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.eight.opacity(clipped ? 1 : 0.2)))
        Text(RackDisplay.meterLabel(level))
          .font(Theme.mono(9)).foregroundStyle(Theme.dim.opacity(0.8))
          .frame(minWidth: 62, alignment: .trailing)
      }
      HStack(alignment: .center, spacing: 10) {
        ZStack {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color(red: 8 / 255, green: 7 / 255, blue: 11 / 255))
            .overlay(
              RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.18)))
          switch mode {
          case 0: Needle(position: position).padding(5)
          case 1:
            Lights(lit: Int((position * Double(Self.lights)).rounded())).padding(
              .init(top: 9, leading: 10, bottom: 7, trailing: 10))
          default: Scope(waveform: reading?.waveform ?? [], peak: reading?.peak ?? 0).padding(5)
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(face.module.id) signal level")
        .accessibilityValue(RackDisplay.meterLabel(level))
        HStack(spacing: 0) {
          face.control("mode")
          face.control("gain", tint: Theme.nine)
          face.control("release", tint: Theme.three)
        }
      }
      .frame(maxHeight: .infinity)
    }

    /// The moving-coil face: a cream dial, a scale from −40 to +3, and a red needle on a pivot
    /// below the bottom edge.
    struct Needle: View {
      let position: Double
      static let ticks: [(db: Double, label: String)] = [
        (-40, "−40"), (-20, "−20"), (-10, "−10"), (-5, "−5"), (0, "0"), (3, "+3"),
      ]

      var body: some View {
        GeometryReader { geometry in
          let size = geometry.size
          let pivot = CGPoint(x: size.width / 2, y: size.height + 17)
          ZStack {
            RoundedRectangle(cornerRadius: 4)
              .fill(
                RadialGradient(
                  colors: [
                    Color(red: 1, green: 247 / 255, blue: 206 / 255),
                    Color(red: 231 / 255, green: 215 / 255, blue: 153 / 255),
                    Color(red: 181 / 255, green: 154 / 255, blue: 88 / 255),
                  ], center: UnitPoint(x: 0.5, y: 1.18), startRadius: 0, endRadius: size.height * 1.4))
            ForEach(Self.ticks, id: \.db) { tick in
              let angle = -50 + RackDisplay.meterPosition(pow(10, tick.db / 20)) * 100
              let hot = tick.db > 0
              Rectangle().fill(
                hot
                  ? Color(red: 197 / 255, green: 59 / 255, blue: 52 / 255)
                  : Color(red: 81 / 255, green: 69 / 255, blue: 40 / 255)
              )
              .frame(width: 1, height: 9)
              .position(x: pivot.x, y: pivot.y - 104 + 9.5)
              .rotationEffect(
                .degrees(angle), anchor: UnitPoint(x: pivot.x / size.width, y: pivot.y / size.height))
              Text(tick.label).font(Theme.mono(7))
                .foregroundStyle(
                  hot
                    ? Color(red: 181 / 255, green: 47 / 255, blue: 43 / 255)
                    : Color(red: 81 / 255, green: 69 / 255, blue: 40 / 255)
                )
                .rotationEffect(.degrees(-angle))
                .position(x: pivot.x, y: pivot.y - 104 + 22)
                .rotationEffect(
                  .degrees(angle), anchor: UnitPoint(x: pivot.x / size.width, y: pivot.y / size.height))
            }
            Text("VU").font(Theme.mono(8, .bold)).tracking(1.6)
              .foregroundStyle(Color(red: 48 / 255, green: 40 / 255, blue: 23 / 255))
              .position(x: pivot.x, y: size.height - 21)
            Capsule().fill(Color(red: 209 / 255, green: 57 / 255, blue: 54 / 255))
              .frame(width: 2, height: 100)
              .shadow(color: Color(red: 92 / 255, green: 13 / 255, blue: 11 / 255).opacity(0.55), radius: 1)
              .position(x: pivot.x, y: pivot.y - 1 - 50)
              .rotationEffect(
                .degrees(-50 + position * 100),
                anchor: UnitPoint(x: pivot.x / size.width, y: (pivot.y - 1) / size.height)
              )
              .animation(.linear(duration: 0.055), value: position)
            Circle()
              .fill(
                RadialGradient(
                  colors: [
                    Color(red: 136 / 255, green: 124 / 255, blue: 95 / 255),
                    Color(red: 33 / 255, green: 30 / 255, blue: 24 / 255),
                  ],
                  center: UnitPoint(x: 0.4, y: 0.3), startRadius: 0, endRadius: 9)
              )
              .frame(width: 18, height: 18)
              .position(x: pivot.x, y: size.height + 15)
          }
          .clipShape(RoundedRectangle(cornerRadius: 4))
        }
      }
    }

    /// Eighteen lights: green, amber from the thirteenth, pink from the seventeenth.
    struct Lights: View {
      let lit: Int

      var body: some View {
        VStack(spacing: 3) {
          HStack(spacing: 3) {
            ForEach(0..<MeterFace.lights, id: \.self) { index in
              let colour = index >= 16 ? Theme.eight : index >= 12 ? Theme.three : Theme.nine
              let on = index < lit
              RoundedRectangle(cornerRadius: 2)
                .fill(on ? colour : colour.opacity(0.08))
                .overlay(
                  RoundedRectangle(cornerRadius: 2).strokeBorder(
                    on ? Color.white.opacity(0.7) : colour.opacity(0.11))
                )
                .shadow(color: on ? colour.opacity(0.7) : .clear, radius: 4)
            }
          }
          HStack {
            Text("−48")
            Spacer()
            Text("−18")
            Spacer()
            Text("−6")
            Spacer()
            Text("+3")
          }
          .font(Theme.mono(7)).foregroundStyle(Theme.ink.opacity(0.45))
          .frame(height: 13)
        }
        .animation(.linear(duration: 0.055), value: lit)
      }
    }

    /// The scope: the last block's shape on a green graticule.
    struct Scope: View {
      let waveform: [Float]
      let peak: Double

      var body: some View {
        ZStack(alignment: .bottomTrailing) {
          RoundedRectangle(cornerRadius: 4)
            .fill(
              RadialGradient(
                colors: [
                  Color(red: 31 / 255, green: 83 / 255, blue: 72 / 255).opacity(0.32),
                  Color(red: 2 / 255, green: 12 / 255, blue: 11 / 255).opacity(0.96),
                ],
                center: .center, startRadius: 0, endRadius: 160))
          Graticule(spacing: 18).stroke(Theme.nine.opacity(0.06), lineWidth: 1)
          Trace(waveform: waveform)
            .padding(.init(top: 5, leading: 6, bottom: 16, trailing: 6))
          Text(RackDisplay.meterLabel(peak) + " PEAK")
            .font(Theme.mono(7)).foregroundStyle(Theme.nine.opacity(0.65))
            .padding(.trailing, 7).padding(.bottom, 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
      }
    }
  }

  /// A waveform drawn across its box, over a faint centre line, glowing.
  struct Trace: View {
    let waveform: [Float]
    var head: Double?

    var body: some View {
      Canvas { context, size in
        var middle = Path()
        middle.move(to: CGPoint(x: 0, y: size.height / 2))
        middle.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        context.stroke(middle, with: .color(Theme.nine.opacity(0.18)), lineWidth: 0.7)
        var line = Path()
        line.addLines(RackDisplay.waveformPoints(waveform, width: size.width, height: size.height))
        context.drawLayer { layer in
          layer.addFilter(.shadow(color: Theme.nine.opacity(0.8), radius: 3))
          layer.stroke(line, with: .color(Theme.nine), lineWidth: 1.5)
        }
        if let head {
          var mark = Path()
          mark.move(to: CGPoint(x: head * size.width, y: 0))
          mark.addLine(to: CGPoint(x: head * size.width, y: size.height))
          context.drawLayer { layer in
            layer.addFilter(.shadow(color: Theme.three.opacity(0.8), radius: 2))
            layer.stroke(mark, with: .color(Theme.three), lineWidth: 1.2)
          }
        }
      }
    }
  }

  /// A square grid, for a screen's background.
  struct Graticule: Shape {
    let spacing: Double

    func path(in rect: CGRect) -> Path {
      var path = Path()
      var x = rect.minX
      while x <= rect.maxX {
        path.move(to: CGPoint(x: x, y: rect.minY))
        path.addLine(to: CGPoint(x: x, y: rect.maxY))
        x += spacing
      }
      var y = rect.minY
      while y <= rect.maxY {
        path.move(to: CGPoint(x: rect.minX, y: y))
        path.addLine(to: CGPoint(x: rect.maxX, y: y))
        y += spacing
      }
      return path
    }
  }

  /// The loop station: what is in the loop and where the playhead is, its transport, and its mix.
  struct LooperFace: View {
    let face: FaceContext
    static let modes = ["STOP", "REC", "PLAY", "DUB"]

    var body: some View {
      let reading = face.reading
      let mode = max(0, min(3, Int(face.value("mode").rounded())))
      let seconds = reading?.loopSeconds ?? 0
      let recording = mode == 1 || mode == 3
      PanelTitle(name: "Loop Station", mark: "LS—30", words: "stereo · session")
      HStack(alignment: .center, spacing: 9) {
        ZStack(alignment: .top) {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(red: 3 / 255, green: 16 / 255, blue: 14 / 255))
          Graticule(spacing: 15).stroke(Theme.nine.opacity(0.04), lineWidth: 1)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.nine.opacity(0.2))
          Trace(
            waveform: reading?.waveform ?? [],
            head: seconds > 0 ? max(0, min(1, reading?.loopPosition ?? 0)) : nil
          )
          .padding(.init(top: 18, leading: 7, bottom: 17, trailing: 7))
          // Pinned left, centre and right, as the reference places them, so a narrow screen
          // overlaps them rather than wrapping them.
          ZStack {
            Text(Self.modes[mode])
              .foregroundStyle(recording ? Theme.eight : Theme.nine.opacity(0.65))
              .shadow(color: recording ? Theme.eight.opacity(0.75) : .clear, radius: 3)
              .frame(maxWidth: .infinity, alignment: .leading)
            Text(RackDisplay.loopTime(seconds)).foregroundStyle(Theme.nine.opacity(0.65))
            Text("30s MAX").foregroundStyle(Theme.ink.opacity(0.32))
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
          .font(Theme.mono(7.5)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 7).padding(.top, 5)
        }
        .frame(maxHeight: .infinity)
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
          GridRow {
            transport(0)
            transport(1)
          }
          GridRow {
            transport(2)
            transport(3)
          }
          GridRow {
            Button("CLEAR") { face.set("clear", face.value("clear") >= 0.5 ? 0 : 1) }
              .buttonStyle(TransportStyle(on: false, tint: Theme.eight, text: Theme.eight.opacity(0.7)))
              .gridCellColumns(2)
          }
        }
        .frame(width: 168)
        HStack(spacing: 0) {
          face.control("feedback", tint: Theme.three)
          face.control("dry")
          face.control("loop", tint: Theme.nine)
        }
      }
      .frame(maxHeight: .infinity)
    }

    private func transport(_ index: Int) -> some View {
      let on = Int(face.value("mode").rounded()) == index
      return Button(Self.modes[index]) { face.set("mode", Double(index)) }
        .buttonStyle(TransportStyle(on: on, tint: index == 1 || index == 3 ? Theme.eight : Theme.nine))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    struct TransportStyle: ButtonStyle {
      let on: Bool
      let tint: Color
      var text: Color = Theme.ink.opacity(0.55)

      func makeBody(configuration: Configuration) -> some View {
        configuration.label
          .font(Theme.mono(7)).tracking(0.6)
          .foregroundStyle(on ? Theme.ground : text)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(
            RoundedRectangle(cornerRadius: 4).fill(
              on ? tint : Color.white.opacity(configuration.isPressed ? 0.08 : 0.025))
          )
          .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? tint : Theme.ink.opacity(0.14)))
          .shadow(color: on ? tint.opacity(0.4) : .clear, radius: 4)
          .scaleEffect(configuration.isPressed ? 0.95 : 1)
          .animation(.spring(response: 0.18, dampingFraction: 0.6), value: configuration.isPressed)
          .contentShape(Rectangle())
      }
    }
  }
#endif
