#if canImport(AVFoundation)
  import AVFoundation
  import DriftboxRack
  import Foundation
  import Testing

  @testable import DriftboxApp

  /// Samples in the rack: the reference's arithmetic, a file read at the rack's rate and its own
  /// pitch, the breaks the factory patches are built around, and audio that lasts through edits.
  @MainActor
  struct RackSampleTests {
    @Test func aLoopsTempoIsTheOneAtWhichItIsWholeBars() {
      #expect(abs(SampleMath.tempoForBars(1.3793, 1) - 174) < 0.05)
      #expect(SampleMath.tempoForBars(2, 1) == 120)
      #expect(SampleMath.tempoForBars(4, 2) == 120)
      #expect(SampleMath.tempoForBars(2, 2) == SampleMath.tempoForBars(2, 1) * 2)
      #expect(SampleMath.tempoForBars(0, 1) == 0)
      #expect(SampleMath.tempoForBars(-1, 1) == 0)
      #expect(SampleMath.guessBars(1.3793, tempo: 174) == 1)
      #expect(SampleMath.guessBars(2.7586, tempo: 174) == 2)
      #expect(SampleMath.guessBars(4, tempo: 120) == 2)
      #expect(SampleMath.guessBars(5.5172, tempo: 174) == 4)
      #expect(SampleMath.guessBars(11.03, tempo: 174) == 8)
      // By ratio: a bar and a half at 174 is nearer two bars than one.
      #expect(SampleMath.guessBars(1.5 * 240 / 174, tempo: 174) == 2)
      for seconds in [0.0, -3, 0.001, 1e6] { #expect([1, 2, 4, 8].contains(SampleMath.guessBars(seconds))) }
    }

    @Test func aFileIsMadeMonoLoudAndDrawn() {
      #expect(SampleMath.toMono([[1, 0.5, 0], [1, 0.5, 0]]) == [1, 0.5, 0])
      #expect(SampleMath.toMono([[1, 0, 0], [1, 1, 0]]) == [1, 0.5, 0])
      #expect(SampleMath.toMono([[0.2, -0.4]]) == [0.2, -0.4])
      #expect(SampleMath.toMono([]).isEmpty)
      let loud = SampleMath.normalise([0.1, -0.5, 0.25])
      #expect(abs(loud.map { abs($0) }.max()! - 0.9) < 1e-6)
      #expect(SampleMath.normalise([0, 0]) == [0, 0])
      #expect(
        SampleMath.waveformPeaks([0, 0.25, -0.5, 0, 1, 0.5, 0, -0.25], buckets: 4) == [0.25, 0.5, 1, 0.25])
      #expect(SampleMath.waveformPeaks([], buckets: 3) == [0, 0, 0])
      #expect(SampleMath.name("Amen Brother.wav") == "Amen Brother")
      #expect(SampleMath.name(".wav") == "sample")
      #expect(SampleMath.name(String(repeating: "x", count: 80) + ".aif").count == 60)
    }

    @Test func theBreaksAreTheReferences() throws {
      #expect(RackBreak.barFrames(174, 44100) == 60828)
      #expect(RackBreak.barFrames(174, 48000) == 66207)
      #expect(RackBreak.barFrames(120, 44100) == 88200)
      #expect(RackBreak.steps("X... x.x.") == [.accent, .off, .off, .off, .on, .off, .on, .off])
      for entry in RackBreak.all {
        #expect(entry.tempo >= 160 && entry.tempo <= 180)
        for (voice, line) in entry.tracks {
          #expect(voice.hasPrefix("909."))
          #expect(RackBreak.steps(line).count == 16)
        }
        let audio = entry.render(sampleRate: 48000)
        #expect(audio.count == RackBreak.barFrames(entry.tempo, 48000))
        #expect(abs(audio.map { abs($0) }.max()! - 0.9) < 1e-5, "\(entry.id)")
      }
    }

    /// A file at 44.1kHz, read into a rack at 48kHz, is as long and as high as it was.
    @Test func aFileIsReadAtTheRacksRateAndItsOwnPitch() throws {
      let url = try Self.sine(seconds: 0.5, frequency: 441, rate: 44100)
      defer { try? FileManager.default.removeItem(at: url) }
      let channels = try SampleMath.decode(url, sampleRate: 48000)
      #expect(channels.count == 2)
      #expect(abs(channels[0].count - 24000) < 64, "\(channels[0].count)")
      // 441 cycles a second is 220 or so rising zero crossings in half a second.
      var crossings = 0
      for i in 1..<channels[0].count where channels[0][i - 1] < 0 && channels[0][i] >= 0 { crossings += 1 }
      #expect(abs(crossings - 220) <= 2, "\(crossings)")
    }

    /// A patch built on a break has its break: the factory ones sound, and say so on their face.
    @Test func aBreakPatchSounds() async throws {
      let model = RackModel()
      let entry = try #require(PatchEntry.all.first { $0.load()?.breakId != nil })
      model.open(entry)
      await model.breaksReady()
      let samplers = model.patch.modules.filter { $0.type == "sampler" }.map(\.id)
      #expect(!samplers.isEmpty)
      for id in samplers { #expect(model.samples[id]?.source == .break) }
      model.listen()
      model.toggleRunning()
      #expect(Self.loud(model, seconds: 2))
    }

    /// A file loaded into a sampler plays, sets the tempo to whole bars, starts the transport, and
    /// lasts through an edit that rebuilds the patch; another patch does not keep it.
    @Test func aLoadedFilePlaysAndLasts() async throws {
      let url = try Self.sine(seconds: 240.0 / 150, frequency: 220, rate: 48000)
      defer { try? FileManager.default.removeItem(at: url) }
      let model = RackModel()
      model.open(
        Patch(
          modules: [
            PatchModule(id: "clock", type: "transport"),
            PatchModule(id: "sampler-1", type: "sampler", params: ["slices": 1]),
            PatchModule(id: "out", type: "out"),
          ],
          cables: [
            PatchCable(from: PortReference("clock", "bar"), to: PortReference("sampler-1", "trig")),
            PatchCable(from: PortReference("sampler-1", "out"), to: PortReference("out", "in")),
          ], tempo: 120), name: "Loop")
      model.listen()
      await model.load(url, into: "sampler-1")
      let info = try #require(model.samples["sampler-1"])
      #expect(info.source == .file && info.bars == 1)
      #expect(abs(model.tempo - 150) < 0.01)
      #expect(model.running)
      #expect(Self.loud(model, seconds: 1))
      // A structural edit rebuilds the graph; the sample is still there.
      model.add("noise")
      #expect(model.samples["sampler-1"] != nil)
      #expect(Self.loud(model, seconds: 1))
      model.setSampleBars("sampler-1", 2)
      #expect(abs(model.tempo - 300) < 0.01)
      // A file that is not audio says why.
      let junk = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
      try Data("not audio".utf8).write(to: junk)
      defer { try? FileManager.default.removeItem(at: junk) }
      await model.load(junk, into: "sampler-1")
      #expect(model.loadFailure?.module == "sampler-1")
      #expect(model.samples["sampler-1"]?.source == .file)
      model.open(Patch(modules: [PatchModule(id: "sampler-1", type: "sampler")], cables: []), name: "Other")
      #expect(model.samples.isEmpty)
    }

    @Test func aTrackStartsAtABarAndAStep() {
      #expect(AudioTrackFace.position(0) == (1, 1))
      #expect(AudioTrackFace.position(16) == (2, 1))
      #expect(AudioTrackFace.position(2000) == (64, 16))
      #expect(AudioTrackFace.start(bar: 4, step: 16) == 63)
      #expect(AudioTrackFace.start(bar: 80, step: 20) == 1023)
      #expect(AudioTrackFace.start(bar: 1, step: 1) == 0)
    }

    /// Three recordings named for their notes map themselves and play: a note on the keyboard
    /// sounds the zone it falls in. The map is the patch's; the audio goes with the module.
    @Test func anInstrumentSetMapsItselfAndPlays() async throws {
      let urls = try ["Piano_C3.wav", "Piano_C4.wav", "Piano_C5.wav"].map { name in
        try Self.sine(seconds: 0.5, frequency: 220, rate: 48000, name: name)
      }
      defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
      let model = RackModel()
      model.open(
        Patch(
          modules: [
            PatchModule(id: "keys", type: "midi"), PatchModule(id: "piano", type: "multisampler"),
            PatchModule(id: "out", type: "out"),
          ],
          cables: [
            PatchCable(from: PortReference("keys", "pitch"), to: PortReference("piano", "pitch")),
            PatchCable(from: PortReference("keys", "gate"), to: PortReference("piano", "gate")),
            PatchCable(from: PortReference("keys", "vel"), to: PortReference("piano", "velocity")),
            PatchCable(from: PortReference("piano", "out"), to: PortReference("out", "in")),
          ]), name: "Piano")
      model.listen()
      await model.loadInstrument(urls, into: "piano")
      let zones = MultisampleZone.unpack(try #require(model.patch.modules[1].data["zones"]))
      #expect(zones.map(\.root) == [48, 60, 72])
      #expect(model.recordings["piano"]?.map(\.name) == ["Piano_C3", "Piano_C4", "Piano_C5"])
      #expect(!Self.loud(model, seconds: 0.2))
      model.noteDown(60)
      #expect(Self.loud(model, seconds: 0.2))
      model.undo()
      #expect(model.patch.modules[1].data["zones"] == nil)
      model.remove("piano")
      #expect(model.recordings["piano"] == nil)
    }

    /// A track plays from its start with the transport, stereo or mono on both sides.
    @Test func aTrackPlaysWithTheTransport() async throws {
      let url = try Self.sine(seconds: 1, frequency: 330, rate: 44100)
      defer { try? FileManager.default.removeItem(at: url) }
      let model = RackModel()
      model.open(
        Patch(
          modules: [PatchModule(id: "track", type: "audio-track"), PatchModule(id: "out", type: "out")],
          cables: [PatchCable(from: PortReference("track", "out"), to: PortReference("out", "in"))],
          tempo: 120),
        name: "Track")
      model.listen()
      await model.loadTrack(url, into: "track")
      let track = try #require(model.tracks["track"])
      #expect(track.stereo && abs(track.seconds - 1) < 0.01)
      #expect(!Self.loud(model, seconds: 0.2), "silent while the transport is stopped")
      model.toggleRunning()
      #expect(Self.loud(model, seconds: 0.2))
    }

    static func loud(_ model: RackModel, seconds: Double) -> Bool {
      let frames = Int(48000 * seconds)
      let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
      let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
      defer {
        left.deallocate()
        right.deallocate()
      }
      model.host.render(frames: frames, left: left, right: right)
      return (0..<frames).contains { abs(left[$0]) > 0.01 }
    }

    /// A stereo sine written to a temporary WAV file.
    static func sine(seconds: Double, frequency: Double, rate: Double, name: String? = nil) throws -> URL {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let url = folder.appendingPathComponent(name ?? "\(UUID()).wav")
      let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
      let file = try AVAudioFile(forWriting: url, settings: format.settings)
      let frames = AVAudioFrameCount(seconds * rate)
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
      buffer.frameLength = frames
      for channel in 0..<2 {
        for i in 0..<Int(frames) {
          buffer.floatChannelData![channel][i] = Float(
            0.5 * sin(2 * Double.pi * frequency * Double(i) / rate))
        }
      }
      try file.write(from: buffer)
      return url
    }
  }
#endif
