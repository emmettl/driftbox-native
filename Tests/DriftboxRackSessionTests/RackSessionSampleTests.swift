import DriftboxDocument
import DriftboxRack
import Foundation
import Testing

@testable import DriftboxRackSession

/// Samples in the rack: breaks, files read into samplers, instruments into a Multisampler, and
/// recordings into an Audio Track — read by the rack's own WAV decoder, and heard.
@MainActor
struct RackSessionSampleTests {
  /// A file at 44.1kHz, read into a rack at 48kHz, is as long and as high as it was.
  @Test func aFileIsReadAtTheRacksRateAndItsOwnPitch() throws {
    let url = try Self.sine(seconds: 0.5, frequency: 441, rate: 44100)
    defer { try? FileManager.default.removeItem(at: url) }
    let channels = try WAVDecoder().decode(url, sampleRate: 48000)
    #expect(channels.count == 2)
    #expect(abs(channels[0].count - 24000) < 64, "\(channels[0].count)")
    // 441 cycles a second is 220 or so rising zero crossings in half a second.
    var crossings = 0
    for i in 1..<channels[0].count where channels[0][i - 1] < 0 && channels[0][i] >= 0 { crossings += 1 }
    #expect(abs(crossings - 220) <= 2, "\(crossings)")
  }

  /// A patch built on a break has its break: the catalogue's ones sound, and say so on their face.
  @Test func aBreakPatchSounds() async throws {
    let rack = RackSession()
    let entry = try #require(PatchEntry.all.first { $0.load()?.breakId != nil })
    rack.open(entry)
    await rack.breaksReady()
    let samplers = rack.patch.modules.filter { $0.type == "sampler" }.map(\.id)
    #expect(!samplers.isEmpty)
    for id in samplers { #expect(rack.samples[id]?.source == .break) }
    rack.listen()
    rack.toggleRunning()
    #expect(Self.loud(rack, seconds: 2))
  }

  /// A file loaded into a sampler plays, sets the tempo to whole bars, starts the transport, and
  /// lasts through an edit that rebuilds the patch; another patch does not keep it.
  @Test func aLoadedFilePlaysAndLasts() async throws {
    let url = try Self.sine(seconds: 240.0 / 150, frequency: 220, rate: 48000)
    defer { try? FileManager.default.removeItem(at: url) }
    let rack = RackSession()
    rack.open(
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
    rack.listen()
    await rack.load(url, into: "sampler-1")
    let info = try #require(rack.samples["sampler-1"])
    #expect(info.source == .file && info.bars == 1)
    #expect(abs(rack.tempo - 150) < 0.01)
    #expect(rack.running)
    #expect(Self.loud(rack, seconds: 1))
    // A structural edit rebuilds the graph; the sample is still there.
    rack.add("noise")
    #expect(rack.samples["sampler-1"] != nil)
    #expect(Self.loud(rack, seconds: 1))
    rack.setSampleBars("sampler-1", 2)
    #expect(abs(rack.tempo - 300) < 0.01)
    // A file that is not audio says why.
    let junk = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
    try Data("not audio".utf8).write(to: junk)
    defer { try? FileManager.default.removeItem(at: junk) }
    await rack.load(junk, into: "sampler-1")
    #expect(rack.loadFailure?.module == "sampler-1")
    #expect(rack.samples["sampler-1"]?.source == .file)
    rack.open(Patch(modules: [PatchModule(id: "sampler-1", type: "sampler")], cables: []), name: "Other")
    #expect(rack.samples.isEmpty)
  }

  /// Three recordings named for their notes map themselves and play: a note on the keyboard
  /// sounds the zone it falls in. The map is the patch's; the audio goes with the module.
  @Test func anInstrumentSetMapsItselfAndPlays() async throws {
    let urls = try ["Piano_C3.wav", "Piano_C4.wav", "Piano_C5.wav"].map { name in
      try Self.sine(seconds: 0.5, frequency: 220, rate: 48000, name: name)
    }
    defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
    let rack = RackSession()
    rack.open(
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
    rack.listen()
    await rack.loadInstrument(urls, into: "piano")
    let zones = MultisampleZone.unpack(try #require(rack.patch.modules[1].data["zones"]))
    #expect(zones.map(\.root) == [48, 60, 72])
    #expect(rack.recordings["piano"]?.map(\.name) == ["Piano_C3", "Piano_C4", "Piano_C5"])
    #expect(!Self.loud(rack, seconds: 0.2))
    rack.noteDown(60)
    #expect(Self.loud(rack, seconds: 0.2))
    rack.undo()
    #expect(rack.patch.modules[1].data["zones"] == nil)
    rack.remove("piano")
    #expect(rack.recordings["piano"] == nil)
  }

  /// A track plays from its start with the transport, stereo or mono on both sides.
  @Test func aTrackPlaysWithTheTransport() async throws {
    let url = try Self.sine(seconds: 1, frequency: 330, rate: 44100)
    defer { try? FileManager.default.removeItem(at: url) }
    let rack = RackSession()
    rack.open(
      Patch(
        modules: [PatchModule(id: "track", type: "audio-track"), PatchModule(id: "out", type: "out")],
        cables: [PatchCable(from: PortReference("track", "out"), to: PortReference("out", "in"))],
        tempo: 120),
      name: "Track")
    rack.listen()
    await rack.loadTrack(url, into: "track")
    let track = try #require(rack.tracks["track"])
    #expect(track.stereo && abs(track.seconds - 1) < 0.01)
    #expect(!Self.loud(rack, seconds: 0.2), "silent while the transport is stopped")
    rack.toggleRunning()
    #expect(Self.loud(rack, seconds: 0.2))
  }

  static func loud(_ rack: RackSession, seconds: Double) -> Bool {
    let frames = Int(48000 * seconds)
    let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    defer {
      left.deallocate()
      right.deallocate()
    }
    rack.host.render(frames: frames, left: left, right: right)
    return (0..<frames).contains { abs(left[$0]) > 0.01 }
  }

  /// A stereo sine written to a temporary WAV file of 32-bit floats.
  static func sine(seconds: Double, frequency: Double, rate: Double, name: String? = nil) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name ?? "\(UUID()).wav")
    let frames = Int(seconds * rate)
    var body = Data()
    for i in 0..<frames {
      let value = Float(0.5 * sin(2 * Double.pi * frequency * Double(i) / rate))
      for _ in 0..<2 { withUnsafeBytes(of: value.bitPattern.littleEndian) { body.append(contentsOf: $0) } }
    }
    var file = Data()
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { file.append(contentsOf: $0) } }
    func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { file.append(contentsOf: $0) } }
    file.append(contentsOf: Array("RIFF".utf8))
    u32(UInt32(36 + body.count))
    file.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16)
    u16(3)  // IEEE float
    u16(2)
    u32(UInt32(rate))
    u32(UInt32(rate) * 8)
    u16(8)
    u16(32)
    file.append(contentsOf: Array("data".utf8))
    u32(UInt32(body.count))
    file.append(body)
    try file.write(to: url)
    return url
  }
}
