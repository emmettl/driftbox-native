#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxRack
  import DriftboxSeq
  import SwiftUI

  /// The Groovebox: the rack's window onto the song it carries. Four strips, one a machine, each
  /// with its meter, level, pan and mute; what the song is; and its arrangement, section by
  /// section, to start the song from or loop. The song is edited in the groovebox window, which
  /// is the editor, linked to the rack's copy so each edit plays on here in place — rather than a
  /// second editor in the faceplate, which the reference has because it has no other window.
  struct GrooveboxFace: View {
    let face: FaceContext
    nonisolated static let machines = [
      ("tr808", "tr808", "808"), ("tr909", "tr909", "909"), ("303.a", "303-a", "303 A"),
      ("303.b", "303-b", "303 B"),
    ]

    var body: some View {
      let song = face.model.song
      PanelTitle(name: "Groovebox", words: "4 stereo sources")
      if let song {
        HStack(spacing: 8) {
          Text(
            "\(song.patterns.count) pattern\(song.patterns.count == 1 ? "" : "s") · "
              + "\(RackDisplay.fixed(face.model.tempo, 0)) BPM · \(max(1, song.bars)) bars"
          )
          .font(Theme.mono(9.5)).foregroundStyle(Theme.ink)
          Spacer(minLength: 4)
          Button(face.model.songLinked ? "Editing in Groovebox" : "Edit in Groovebox") {
            face.model.editInGroovebox()
          }
          .buttonStyle(OptionStyle(on: face.model.songLinked, tint: Theme.nine))
          .disabled(face.model.songLinked)
          .help("Open this song in the groovebox window; its edits play on here as you make them")
        }
      } else {
        Text("No song: choose one under Groovebox Songs in the Patch menu, and its machines come in here.")
          .font(Theme.mono(9)).foregroundStyle(Theme.dim)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(alignment: .top, spacing: 0) {
        ForEach(Self.machines, id: \.0) { section, id, name in
          VStack(spacing: 4) {
            Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink)
            Meter(reading: face.model.readings["\(face.module.id):\(section)"])
              .accessibilityLabel("\(name) output level")
            face.control("\(id)-level", tint: Theme.nine, named: "Level")
            face.control("\(id)-pan", tint: Theme.eight, named: "Pan")
            face.control("\(id)-mute", named: "Mute")
          }
          .frame(maxWidth: .infinity)
        }
      }
      if let song {
        Arrangement(model: face.model, song: song)
      }
    }

    /// A machine's level after its strip: a bar from −48 dB to +3, lit where it clipped.
    struct Meter: View {
      let reading: MeterReading?

      var body: some View {
        let position = RackDisplay.meterPosition(reading?.envelope ?? 0)
        GeometryReader { geometry in
          ZStack(alignment: .leading) {
            Capsule().fill(Color.black.opacity(0.35))
            Capsule().fill((reading?.peak ?? 0) > 1 ? Theme.eight : Theme.nine)
              .frame(width: geometry.size.width * position)
          }
        }
        .frame(width: 70, height: 5)
        .animation(.linear(duration: 0.05), value: position)
      }
    }

    /// The song's sections in order: which pattern, for how many bars, lit while it plays. Click
    /// one to start the song there, or loop its bars.
    struct Arrangement: View {
      let model: RackModel
      let song: Song

      /// Each section's first bar and how many bars it runs.
      var sections: [(index: Int, name: String, start: Int, bars: Int)] {
        var start = 0
        return song.chain.enumerated().map { index, step in
          let bars = max(1, step.repeat)
          defer { start += bars }
          let name = song.patterns.first { $0.id == step.pattern }?.name ?? step.pattern
          return (index, name, start, bars)
        }
      }

      var body: some View {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            FieldLabel("Arrangement")
            Spacer()
            if let loop = model.songLoop {
              Button("Loop bars \(loop.start + 1)–\(loop.start + loop.bars) ×") { model.clearSongLoop() }
                .buttonStyle(OptionStyle(on: true, tint: Theme.three))
                .help("Stop looping")
            }
          }
          if song.chain.isEmpty {
            Text("One pattern, round and round.").font(Theme.mono(9)).foregroundStyle(Theme.dim)
          }
          // Laid out plainly while they fit, and scrolled only when a long song's do not.
          ViewThatFits(in: .vertical) {
            rows
            ScrollView { rows }.scrollIndicators(.automatic)
          }
        }
        .frame(maxHeight: .infinity, alignment: .top)
      }

      private var rows: some View {
        VStack(spacing: 2) {
          ForEach(sections, id: \.index) { section in row(section) }
        }
      }

      private func row(_ section: (index: Int, name: String, start: Int, bars: Int)) -> some View {
        let playing = model.songBar.map { $0 >= section.start && $0 < section.start + section.bars } ?? false
        let looped = model.songLoop.map { $0.start == section.start && $0.bars == section.bars } ?? false
        return HStack(spacing: 8) {
          Text("\(section.index + 1)").font(Theme.mono(9)).foregroundStyle(Theme.dim).frame(width: 18)
          Text(section.name).font(Theme.mono(10, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
          Spacer(minLength: 4)
          Text(
            section.bars == 1
              ? "bar \(section.start + 1)" : "bars \(section.start + 1)–\(section.start + section.bars)"
          )
          .font(Theme.mono(9)).foregroundStyle(Theme.dim)
          Button {
            model.startSong(atBar: section.start)
          } label: {
            Image(systemName: "play.fill")
          }
          .buttonStyle(OptionStyle(on: false, tint: Theme.nine))
          .help("Play the song from here")
          .accessibilityLabel("Play from section \(section.index + 1)")
          Button {
            if looped {
              model.clearSongLoop()
            } else {
              model.loopSong(start: section.start, bars: section.bars)
            }
          } label: {
            Image(systemName: "repeat")
          }
          .buttonStyle(OptionStyle(on: looped, tint: Theme.three))
          .help(looped ? "Stop looping" : "Loop this section")
          .accessibilityLabel("Loop section \(section.index + 1)")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(playing ? Theme.nine.opacity(0.14) : Color.white.opacity(0.03))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(playing ? Theme.nine.opacity(0.5) : Color.clear))
      }
    }
  }
#endif

#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxRack

  /// What the rack says about a document it did not author: the reference's `documentNotice`,
  /// with "Sequencer →" become the groovebox window, since here the rack does not leave for the
  /// song but opens it beside itself. Nothing for a patch built here.
  struct DocumentNotice: Equatable {
    var label: String
    var retained: String
    var guidance: String

    /// `song` is the patterns and tempo of the song carried, or nil when this build cannot read it.
    static func notice(_ compatibility: PatchCompatibility, song: (patterns: Int, bpm: Double)?)
      -> DocumentNotice?
    {
      let label: String
      switch compatibility {
      case .rackNative: return nil
      case .grooveboxCompatible: label = "groovebox compatible"
      case .rackExtended: label = "rack extended"
      }
      guard let song else {
        return DocumentNotice(
          label: label,
          retained: "A song from a newer groovebox build is retained exactly but cannot be edited here.",
          guidance: "This build keeps it as it is, but cannot play or edit it.")
      }
      let bpm = song.bpm == song.bpm.rounded() ? "\(Int(song.bpm))" : "\(song.bpm)"
      return DocumentNotice(
        label: label, retained: "\(song.patterns) patterns at \(bpm) BPM retained exactly.",
        guidance: compatibility == .rackExtended
          ? "The song plays here; cabled machines run through the Groovebox source, and editing it in the "
            + "groovebox window keeps the rack's additions here."
          : "The song plays through its own mix; patch a Groovebox output to take that machine through the "
            + "rack. Editing it in the groovebox window loses nothing.")
    }
  }
#endif
