#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxRackSession
  import SwiftUI
  import UniformTypeIdentifiers

  /// The Key Atlas: every zone of the Multisampler on a map of keys across and velocity up — click
  /// one to edit it — a set of recordings dropped anywhere on it, and the instrument's controls.
  struct MultisamplerFace: View {
    let face: FaceContext
    nonisolated static let knobs = ["tune", "attack", "release", "velocity", "level"]

    @State private var selected = 0
    @State private var choosing = false
    @State private var dropping = false

    var body: some View {
      let recordings = face.model.recordings[face.module.id] ?? []
      let busy = face.model.loading.contains(face.module.id)
      let zones = MultisampleZone.unpack(face.data("zones"))
      let at = min(selected, max(0, zones.count - 1))
      let zone = zones.isEmpty ? nil : zones[at]
      let recording = at < recordings.count ? recordings[at] : nil
      PanelTitle(name: "Key Atlas", mark: "MS—128") {
        Status(
          ready: !recordings.isEmpty,
          words: busy ? "decoding" : recordings.isEmpty ? "empty" : "\(recordings.count) zones")
      }
      ZStack {
        ScreenFrame(highlighted: dropping)
        if zones.isEmpty {
          Button {
            choosing = true
          } label: {
            EmptyPrompt(
              title: busy ? "Mapping recordings…" : "Drop an instrument set",
              detail: "names such as Piano_C3_pp.wav map themselves")
          }
          .buttonStyle(.plain)
          .disabled(busy)
        } else {
          GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
              ForEach(0..<11, id: \.self) { octave in
                Rectangle().fill(Theme.ink.opacity(0.06)).frame(width: 1)
                  .offset(x: size.width * Double(octave * 12) / 128)
              }
              ForEach(Array(zones.enumerated()), id: \.offset) { index, candidate in
                zoneButton(
                  index, candidate, selected: index == at, in: size,
                  name: index < recordings.count ? recordings[index].name : nil)
              }
            }
          }
          .padding(6)
        }
        if dropping { DropBadge(words: "DROP TO MAP FILES") }
      }
      .frame(height: 104)
      .dropDestination(for: URL.self) { urls, _ in
        guard !urls.isEmpty else { return false }
        Task {
          await face.model.loadInstrument(urls, into: face.module.id)
          selected = 0
        }
        return true
      } isTargeted: {
        dropping = $0
      }
      HStack(spacing: 6) {
        Button(busy ? "Loading…" : recordings.isEmpty ? "Load files" : "Replace set") { choosing = true }
          .buttonStyle(OptionStyle(on: false, tint: Theme.nine)).disabled(busy)
        if zone != nil {
          Button("‹") { selected = (at - 1 + zones.count) % zones.count }.buttonStyle(
            OptionStyle(on: false, tint: Theme.nine))
          Text(recording?.name ?? "Zone \(at + 1)").font(Theme.mono(9, .semibold)).foregroundStyle(Theme.ink)
            .lineLimit(1)
          Text(
            recording.map {
              "\(RackDisplay.fixed($0.seconds, 2))s · \(Int(face.model.host.sampleRate / 1000))kHz"
            } ?? "session audio unavailable"
          )
          .font(Theme.mono(7.5)).foregroundStyle(recording == nil ? Theme.eight : Theme.dim)
          Button("›") { selected = (at + 1) % zones.count }.buttonStyle(
            OptionStyle(on: false, tint: Theme.nine))
        } else if let failure = face.model.loadFailure, failure.module == face.module.id {
          Text(failure.reason).font(Theme.mono(7.5)).foregroundStyle(Theme.eight).lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .frame(height: 20)
      if let zone {
        editor(zone, zones: zones, at: at, recording: recording)
      }
      HStack(spacing: 0) {
        ForEach(Self.knobs, id: \.self) { id in face.control(id, tint: id == "level" ? Theme.nine : nil) }
        Spacer()
      }
      .fileImporter(isPresented: $choosing, allowedContentTypes: [.audio], allowsMultipleSelection: true) {
        result in
        guard case .success(let urls) = result else { return }
        Task {
          await face.model.loadInstrument(urls, into: face.module.id)
          selected = 0
        }
      }
    }

    private func zoneButton(
      _ index: Int, _ zone: MultisampleZone, selected: Bool, in size: CGSize, name: String?
    ) -> some View {
      let x = size.width * Double(zone.low) / 128
      let width = size.width * Double(zone.high - zone.low + 1) / 128
      let y = size.height * (1 - zone.velocityHigh)
      let height = size.height * max(0.04, zone.velocityHigh - zone.velocityLow)
      let root = max(0, min(1, Double(zone.root - zone.low) / Double(max(1, zone.high - zone.low + 1))))
      return Button {
        self.selected = index
      } label: {
        ZStack(alignment: .topLeading) {
          RoundedRectangle(cornerRadius: 3)
            .fill(selected ? Theme.nine.opacity(0.35) : Theme.violet.opacity(0.18))
          RoundedRectangle(cornerRadius: 3).strokeBorder(selected ? Theme.nine : Theme.violet.opacity(0.5))
          Rectangle().fill(selected ? Theme.nine : Theme.three).frame(width: 1.5)
            .offset(x: width * root)
          if width > 22 {
            Text(Multisample.noteName(zone.root)).font(Theme.mono(7)).foregroundStyle(Theme.ink.opacity(0.85))
              .padding(.leading, 3).padding(.top, 2)
          }
        }
        .frame(width: max(2, width), height: max(4, height))
      }
      .buttonStyle(.plain)
      .offset(x: x, y: y)
      .help("\(name ?? "Zone \(index + 1)") · root \(Multisample.noteName(zone.root))")
      .accessibilityLabel(
        "\(name ?? "Zone \(index + 1)"): \(Multisample.noteName(zone.low)) to \(Multisample.noteName(zone.high))"
      )
    }

    /// The selected zone's notes, velocities and loop.
    private func editor(
      _ zone: MultisampleZone, zones: [MultisampleZone], at: Int, recording: RackSession.Recording?
    ) -> some View {
      func edit(_ change: (inout MultisampleZone) -> Void) {
        var next = zones
        change(&next[at])
        face.setData("zones", MultisampleZone.pack(next), "Edit Zone")
        face.endGesture()
      }
      return VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 2) {
          DragNumber(
            label: "Root", value: Double(zone.root), range: 0...127, perPoint: 0.25,
            format: { Multisample.noteName(Int($0.rounded())) }
          ) {
            value in edit { $0.root = Int(value.rounded()) }
          }
          DragNumber(
            label: "Low", value: Double(zone.low), range: 0...127, perPoint: 0.25,
            format: { Multisample.noteName(Int($0.rounded())) }
          ) {
            value in edit { $0.low = min(Int(value.rounded()), $0.high) }
          }
          DragNumber(
            label: "High", value: Double(zone.high), range: 0...127, perPoint: 0.25,
            format: { Multisample.noteName(Int($0.rounded())) }
          ) {
            value in edit { $0.high = max(Int(value.rounded()), $0.low) }
          }
          DragNumber(
            label: "Vel", value: zone.velocityLow, range: 0...1, perPoint: 0.005,
            format: { RackDisplay.fixed($0, 2) }
          ) {
            value in edit { $0.velocityLow = min((value * 100).rounded() / 100, $0.velocityHigh) }
          }
          DragNumber(
            label: "to", value: zone.velocityHigh, range: 0...1, perPoint: 0.005,
            format: { RackDisplay.fixed($0, 2) }
          ) {
            value in edit { $0.velocityHigh = max((value * 100).rounded() / 100, $0.velocityLow) }
          }
        }
        HStack(spacing: 6) {
          Button(zone.loop ? "Sustain loop" : "No loop") { edit { $0.loop.toggle() } }
            .buttonStyle(OptionStyle(on: zone.loop, tint: Theme.three))
          DragNumber(
            label: "Loop", value: zone.loopStart * 100, range: 0...99, perPoint: 0.5,
            format: { "\(Int($0.rounded()))%" }
          ) {
            value in edit { $0.loopStart = min((value).rounded() / 100, $0.loopEnd - 0.01) }
          }
          DragNumber(
            label: "to", value: zone.loopEnd * 100, range: 1...100, perPoint: 0.5,
            format: { "\(Int($0.rounded()))%" }
          ) {
            value in edit { $0.loopEnd = max((value).rounded() / 100, $0.loopStart + 0.01) }
          }
          if let recording {
            ZStack(alignment: .leading) {
              SamplerFace.Wave(peaks: recording.peaks)
              if zone.loop {
                GeometryReader { geometry in
                  Rectangle().fill(Theme.three.opacity(0.18))
                    .overlay(Rectangle().strokeBorder(Theme.three.opacity(0.6), lineWidth: 1))
                    .frame(width: geometry.size.width * (zone.loopEnd - zone.loopStart))
                    .offset(x: geometry.size.width * zone.loopStart)
                }
              }
            }
            .frame(height: 24)
          }
        }
      }
    }
  }

  /// An audio track: one recording, placed on the timeline at a bar and step, playing from there
  /// with the transport.
  struct AudioTrackFace: View {
    let face: FaceContext

    @State private var choosing = false
    @State private var dropping = false

    /// Where `start`, in sixteenths, is as a bar and a step, both from one: the reference's
    /// `audioTrackPosition` and `audioTrackStart`.
    static func position(_ start: Double) -> (bar: Int, step: Int) {
      let safe = max(0, min(1023, Int(RackDisplay.jsRound(start))))
      return (safe / 16 + 1, safe % 16 + 1)
    }

    static func start(bar: Int, step: Int) -> Int {
      (max(1, min(64, bar)) - 1) * 16 + max(1, min(16, step)) - 1
    }

    var body: some View {
      let track = face.model.tracks[face.module.id]
      let busy = face.model.loading.contains(face.module.id)
      let position = Self.position(face.value("start"))
      PanelTitle(name: "Audio Track", mark: "AT—64", words: "stereo · timeline")
      ZStack {
        ScreenFrame(highlighted: dropping)
        if let track {
          SamplerFace.Wave(peaks: track.peaks).padding(.horizontal, 8).padding(.vertical, 6)
        } else {
          Button {
            choosing = true
          } label: {
            EmptyPrompt(
              title: busy ? "Reading audio…" : "Drop audio here", detail: "or choose a local recording")
          }
          .buttonStyle(.plain)
          .disabled(busy)
        }
        if dropping { DropBadge(words: "DROP TO PLACE") }
      }
      .frame(height: 86)
      .dropDestination(for: URL.self) { urls, _ in
        guard let url = urls.first else { return false }
        Task { await face.model.loadTrack(url, into: face.module.id) }
        return true
      } isTargeted: {
        dropping = $0
      }
      HStack(spacing: 8) {
        Button(busy ? "Loading…" : track == nil ? "Load audio" : "Replace") { choosing = true }
          .buttonStyle(OptionStyle(on: false, tint: Theme.nine)).disabled(busy)
        VStack(alignment: .leading, spacing: 0) {
          Text(track?.name ?? "No recording loaded").font(Theme.mono(9, .semibold)).foregroundStyle(Theme.ink)
            .lineLimit(1)
          if let track {
            Text("\(track.stereo ? "stereo" : "mono") · \(RackDisplay.fixed(track.seconds, 2))s")
              .font(Theme.mono(7.5)).foregroundStyle(Theme.dim)
          } else if let failure = face.model.loadFailure, failure.module == face.module.id {
            Text(failure.reason).font(Theme.mono(7.5)).foregroundStyle(Theme.eight).lineLimit(1)
          }
        }
        Spacer(minLength: 4)
        HStack(spacing: 4) {
          FieldLabel("Start")
          DragNumber(
            label: "Bar", value: Double(position.bar), range: 1...64, perPoint: 0.1,
            format: { "\(Int($0.rounded()))" }
          ) {
            value in face.set("start", Double(Self.start(bar: Int(value.rounded()), step: position.step)))
          }
          DragNumber(
            label: "Step", value: Double(position.step), range: 1...16, perPoint: 0.1,
            format: { "\(Int($0.rounded()))" }
          ) {
            value in face.set("start", Double(Self.start(bar: position.bar, step: Int(value.rounded()))))
          }
        }
        .fixedSize()
        face.control("level", tint: Theme.nine)
      }
      .fileImporter(isPresented: $choosing, allowedContentTypes: [.audio]) { result in
        guard case .success(let url) = result else { return }
        Task { await face.model.loadTrack(url, into: face.module.id) }
      }
    }
  }

  /// The recessed screen a recording is drawn on and dropped on.
  struct ScreenFrame: View {
    let highlighted: Bool

    var body: some View {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color(red: 4 / 255, green: 9 / 255, blue: 12 / 255))
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(
              highlighted ? Theme.nine : Theme.nine.opacity(0.2), lineWidth: highlighted ? 1.5 : 1))
    }
  }

  struct EmptyPrompt: View {
    let title: String
    let detail: String

    var body: some View {
      VStack(spacing: 3) {
        Text(title).font(Theme.mono(11, .semibold)).foregroundStyle(Theme.ink)
        Text(detail).font(Theme.mono(8)).foregroundStyle(Theme.dim)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
    }
  }

  struct DropBadge: View {
    let words: String

    var body: some View {
      Text(words).font(Theme.mono(9, .semibold)).tracking(1).foregroundStyle(Theme.nine)
        .padding(6).background(Capsule().fill(Theme.ground.opacity(0.9)))
    }
  }

  /// A status light and a word, for a face's title.
  struct Status: View {
    let ready: Bool
    let words: String

    var body: some View {
      HStack(spacing: 5) {
        Circle().fill(ready ? Theme.nine : Theme.dim.opacity(0.4)).frame(width: 5, height: 5)
          .shadow(color: ready ? Theme.nine : .clear, radius: 3)
        Text(words)
      }
      .font(Theme.mono(8)).foregroundStyle(Theme.dim)
    }
  }
#endif
