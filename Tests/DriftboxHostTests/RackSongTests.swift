import ConformanceSupport
import DriftboxDocument
import DriftboxEngine
import DriftboxHost
import DriftboxRack
import DriftboxSeq
import Foundation
import Testing

/// The patch's groovebox song, played beside the rack as the reference's rack mode plays it: its
/// mix added to the rack's, its machines on the `groovebox` module's buses, the ones the rack
/// patches taken out of its mix, and the whole of it going with the rack's transport.
struct RackSongTests {
  static let blocks = 200

  static func song() throws -> Song {
    try #require(SongCodec.decode(try Fixtures.text("documents/garage.song.json")))
  }

  /// `blocks` blocks of 128 from a host, left then right.
  static func render(_ render: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> Void) -> [Float]
  {
    let left = UnsafeMutablePointer<Float>.allocate(capacity: 128)
    let right = UnsafeMutablePointer<Float>.allocate(capacity: 128)
    defer {
      left.deallocate()
      right.deallocate()
    }
    var out: [Float] = []
    for _ in 0..<blocks {
      render(left, right)
      out += UnsafeBufferPointer(start: left, count: 128)
      out += UnsafeBufferPointer(start: right, count: 128)
    }
    return out
  }

  /// The song alone, on a host of its own, with `diverted` machines left out of its mix.
  static func alone(_ song: Song, diverted: UInt8) -> [Float] {
    let host = EngineHost(sampleRate: 48000)
    host.load(song)
    host.send(.seek(songFrame: 0))
    host.send(.play)
    let buffers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 8)
    for index in 0..<8 { buffers[index] = .allocate(capacity: 128) }
    defer {
      for index in 0..<8 { buffers[index].deallocate() }
      buffers.deallocate()
    }
    return render { left, right in
      host.render(
        frames: 128, left: left, right: right, sections: SectionOutputs(buffers: buffers, diverted: diverted))
    }
  }

  /// With nothing in the rack, what it plays is the song, to the bit.
  @Test func aSongBesideAnEmptyRackIsTheSong() throws {
    let song = try Self.song()
    let host = RackHost(sampleRate: 48000)
    host.load(Patch(modules: [], cables: []))
    host.setSong(song)
    host.setTransport(tempo: song.bpm, running: true, shuffle: song.swing)
    let rack = Self.render { host.render(frames: 128, left: $0, right: $1) }
    let expected = Self.alone(song, diverted: 0)
    #expect(rack == expected)
    #expect(rack.contains { $0 != 0 })
  }

  /// A machine the rack patches leaves the song's mix: here the 909 goes into a VCA shut to
  /// nothing, so what is heard is the song without its 909, exactly.
  @Test func aPatchedMachineLeavesTheSongsMix() throws {
    let song = try Self.song()
    let host = RackHost(sampleRate: 48000)
    host.load(
      Patch(
        modules: [
          PatchModule(id: "song", type: "groovebox"),
          PatchModule(id: "amp", type: "vca", params: ["gain": 0]),
        ],
        cables: [PatchCable(from: PortReference("song", "tr909-out"), to: PortReference("amp", "in"))]))
    host.setSong(song)
    host.setTransport(tempo: song.bpm, running: true, shuffle: song.swing)
    let rack = Self.render { host.render(frames: 128, left: $0, right: $1) }
    #expect(rack == Self.alone(song, diverted: 0b10))
    #expect(rack != Self.alone(song, diverted: 0))

    // And every machine the song plays is on the groovebox's buses, metered after its strip,
    // patched or not: a reading is one block's, so the loudest of them as it plays.
    var loudest: [String: Double] = [:]
    let left = UnsafeMutablePointer<Float>.allocate(capacity: 128)
    let right = UnsafeMutablePointer<Float>.allocate(capacity: 128)
    defer {
      left.deallocate()
      right.deallocate()
    }
    for _ in 0..<60 {
      for _ in 0..<RackHost.meterEvery { host.render(frames: 128, left: left, right: right) }
      for (id, reading) in host.readings() { loudest[id] = max(loudest[id] ?? 0, reading.peak) }
    }
    let seconds = Double(Self.blocks * 128 + 60 * RackHost.meterEvery * 128) / 48000
    let plan = song.plan(bars: song.bars)
    let voices = Set(
      plan.flatMap(\.drums).filter { $0.time < seconds - 0.1 }.map(\.voiceId)
        + plan.flatMap(\.bass).filter { $0.time < seconds - 0.1 }.map(\.voiceId))
    let plays = [
      "tr808": voices.contains { $0.hasPrefix("808.") }, "tr909": voices.contains { $0.hasPrefix("909.") },
      "303.a": voices.contains("303.a"), "303.b": voices.contains("303.b"),
    ]
    #expect(plays["tr909"] == true, "the test needs a song with a 909")
    for (machine, playing) in plays {
      let peak = loudest["song:\(machine)"] ?? -1
      #expect((peak > 0.01) == playing, "\(machine) plays \(playing), loudest \(peak)")
    }
  }

  /// The song goes with the rack's transport: stopped when it stops, and from its top when it
  /// starts again, as the rack's own clock is.
  @Test func theSongGoesWithTheTransport() throws {
    let song = try Self.song()
    let host = RackHost(sampleRate: 48000)
    host.load(Patch(modules: [], cables: []))
    host.setSong(song)
    _ = Self.render { host.render(frames: 128, left: $0, right: $1) }
    let waiting = host.song.playing.load(ordering: .relaxed)
    #expect(!waiting, "a song waits for the rack")

    host.setTransport(tempo: song.bpm, running: true, shuffle: song.swing)
    _ = Self.render { host.render(frames: 128, left: $0, right: $1) }
    let started = (host.song.playing.load(ordering: .relaxed), host.song.songFrame.load(ordering: .relaxed))
    #expect(started.0)
    #expect(started.1 == Self.blocks * 128)

    host.setTransport(tempo: song.bpm, running: false, shuffle: song.swing)
    _ = Self.render { host.render(frames: 128, left: $0, right: $1) }
    let stopped = host.song.playing.load(ordering: .relaxed)
    #expect(!stopped)

    host.setTransport(tempo: song.bpm, running: true, shuffle: song.swing)
    let block = Self.render { host.render(frames: 128, left: $0, right: $1) }
    let again = host.song.songFrame.load(ordering: .relaxed)
    #expect(again == Self.blocks * 128, "from the top again")
    #expect(block.contains { $0 != 0 })

    // No song: the rack alone, its groovebox silent.
    host.setSong(nil)
    let none = Self.render { host.render(frames: 128, left: $0, right: $1) }
    #expect(none.allSatisfy { $0 == 0 })
  }

  /// A song replacing the one playing — an edit to it — carries on from the same beat, even at a
  /// new tempo.
  @Test func anEditedSongKeepsItsPlace() throws {
    let song = try Self.song()
    let host = RackHost(sampleRate: 48000)
    host.load(Patch(modules: [], cables: []))
    host.setSong(song)
    host.setTransport(tempo: song.bpm, running: true, shuffle: song.swing)
    _ = Self.render { host.render(frames: 128, left: $0, right: $1) }
    let before = host.song.songFrame.load(ordering: .relaxed)
    var faster = song
    faster.bpm = song.bpm * 2
    host.setSong(faster)
    let left = UnsafeMutablePointer<Float>.allocate(capacity: 128)
    let right = UnsafeMutablePointer<Float>.allocate(capacity: 128)
    defer {
      left.deallocate()
      right.deallocate()
    }
    host.render(frames: 128, left: left, right: right)
    let after = host.song.songFrame.load(ordering: .relaxed)
    #expect(after == before / 2 + 128, "the same beat at twice the tempo, then one block on")
    let playing = host.song.playing.load(ordering: .relaxed)
    #expect(playing)
  }

  @Test func routingIsTheReferencesRule() {
    let modules = [PatchModule(id: "gb", type: "groovebox"), PatchModule(id: "vca", type: "vca")]
    func mask(_ ports: [String], from module: String = "gb") -> UInt8 {
      GrooveboxModule.routed(
        Patch(
          modules: modules,
          cables: ports.map { PatchCable(from: PortReference(module, $0), to: PortReference("vca", "in")) }))
    }
    #expect(mask([]) == 0)
    #expect(mask(["tr808-out"]) == 0b0001)
    #expect(mask(["tr909-r"]) == 0b0010, "one old side takes the whole machine")
    #expect(mask(["303.a-l", "303-b-out"]) == 0b1100)
    #expect(mask(["tr808-out"], from: "vca") == 0, "only a groovebox's outlets")
  }
}
