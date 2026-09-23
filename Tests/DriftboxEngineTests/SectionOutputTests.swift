import ConformanceSupport
import DriftboxDocument
import DriftboxEngine
import DriftboxSeq
import Testing

/// A song's four machines, each on outputs of its own: the web engine's `sectionOutputs`, which
/// is what lets the rack take the 909 through an effect without the song losing its place.
struct SectionOutputTests {
  static let sampleRate = 48000.0

  struct Rendered {
    var left: [Float]
    var right: [Float]
    /// Left then right for the 808, the 909, 303 A and 303 B.
    var sections: [[Float]]
  }

  /// `seconds` of `song` from its start, in blocks of a size no host would choose, with its
  /// machines' outputs or without, and the machines in `diverted` taken out of the mix.
  static func render(_ song: Song, seconds: Double, machines: Bool, diverted: UInt8 = 0) -> Rendered {
    var engine = SongEngine(sampleRate: sampleRate)
    let compiled = UnsafeMutablePointer<CompiledSong>.allocate(capacity: 1)
    compiled.initialize(to: CompiledSong(song, preparer: engine.voices.preparer))
    defer {
      compiled.deinitialize(count: 1)
      compiled.deallocate()
    }
    engine.load(compiled)
    engine.play()
    let frames = Int(seconds * sampleRate)
    let block = 441
    var out = Rendered(
      left: [], right: [], sections: Array(repeating: [], count: 2 * SectionOutputs.count))
    let left = UnsafeMutablePointer<Float>.allocate(capacity: block)
    let right = UnsafeMutablePointer<Float>.allocate(capacity: block)
    let buffers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 8)
    for index in 0..<8 {
      buffers[index] = .allocate(capacity: block)
      buffers[index].initialize(repeating: .nan, count: block)
    }
    defer {
      left.deallocate()
      right.deallocate()
      for index in 0..<8 { buffers[index].deallocate() }
      buffers.deallocate()
    }
    var done = 0
    while done < frames {
      let count = min(block, frames - done)
      if machines {
        engine.render(
          frames: count, left: left, right: right,
          sections: SectionOutputs(buffers: buffers, diverted: diverted))
        for index in 0..<8 { out.sections[index] += UnsafeBufferPointer(start: buffers[index], count: count) }
      } else {
        engine.render(frames: count, left: left, right: right)
      }
      out.left += UnsafeBufferPointer(start: left, count: count)
      out.right += UnsafeBufferPointer(start: right, count: count)
      done += count
    }
    engine.load(nil)
    return out
  }

  static func song(_ name: String) throws -> Song {
    try #require(SongCodec.decode(try Fixtures.text("documents/\(name).song.json")))
  }

  static func loudest(_ samples: [Float]) -> Float { samples.reduce(0) { max($0, abs($1)) } }

  /// Asking for the machines' outputs changes nothing about the mix, to the bit: a host that only
  /// meters them hears the song it would have heard.
  @Test(arguments: ["acid", "garage", "pump"])
  func theMixIsTheSameWhenItsMachinesAreAskedFor(_ name: String) throws {
    let song = try Self.song(name)
    let plain = Self.render(song, seconds: 6, machines: false)
    let asked = Self.render(song, seconds: 6, machines: true)
    #expect(plain.left == asked.left && plain.right == asked.right)
  }

  /// Each machine's outputs carry sound exactly when the song plays that machine, and every sample
  /// of them is written.
  @Test(arguments: ["acid", "garage", "pump", "hothouse"])
  func eachMachineCarriesWhatItPlays(_ name: String) throws {
    let song = try Self.song(name)
    let seconds = 6.0
    let rendered = Self.render(song, seconds: seconds, machines: true)
    let plan = song.plan(bars: song.bars)
    let voices = Set(
      plan.flatMap(\.drums).filter { $0.time < seconds - 0.5 }.map(\.voiceId)
        + plan.flatMap(\.bass).filter { $0.time < seconds - 0.5 }.map(\.voiceId))
    let plays = [
      voices.contains { $0.hasPrefix("808.") }, voices.contains { $0.hasPrefix("909.") },
      voices.contains("303.a"), voices.contains("303.b"),
    ]
    for (machine, playing) in plays.enumerated() {
      let left = rendered.sections[machine * 2]
      let right = rendered.sections[machine * 2 + 1]
      #expect(!left.contains { $0.isNaN } && !right.contains { $0.isNaN }, "machine \(machine) is written")
      #expect(
        (Self.loudest(left) > 0.001) == playing && (Self.loudest(right) > 0.001) == playing,
        "\(name): machine \(machine) plays \(playing), loudest \(Self.loudest(left))")
    }
    #expect(plays.contains(true))
  }

  /// A diverted machine leaves the mix and keeps its outputs; diverting all of them leaves only
  /// what the sends bring back.
  @Test func aDivertedMachineLeavesTheMix() throws {
    let song = try Self.song("garage")
    let whole = Self.render(song, seconds: 6, machines: true)
    let none = Self.render(song, seconds: 6, machines: true, diverted: 0b1111)
    #expect(none.sections == whole.sections, "what the machines play does not change")
    #expect(Self.loudest(none.left) < Self.loudest(whole.left) * 0.6, "the mix loses them")
  }

  /// The split itself, where it is made: a voice's sound goes to its machine, and to the mix
  /// unless its machine is diverted, so the mix and the diverted machine add up to the mix alone.
  @Test func thePoolSplitsItsVoicesByMachine() throws {
    let rate = Self.sampleRate
    let voices = ["808.bd", "909.sd", "808.ch", "909.oh"].compactMap { id in allVoices.first { $0.id == id } }
    #expect(voices.count == 4)
    func hits(_ pool: borrowing VoicePool) -> [FixedVoiceSpec] {
      voices.enumerated().map { index, voice in
        pool.prepare(voice.build(accent: 1), voiceId: voice.id, at: Double(index) * 0.01)
      }
    }
    #expect(hits(VoicePool(sampleRate: rate)).map(\.section) == [0, 1, 0, 1])

    let frames = 9600
    func run(sections: Bool, diverted: UInt8) -> (mix: [Float], machines: [Float]) {
      var pool = VoicePool(sampleRate: rate)
      for hit in hits(pool) { pool.start(hit) }
      var mix = [Float](repeating: 0, count: frames)
      var right = mix
      var sends = [Float](repeating: 0, count: frames * 4)
      var machines = [Float](repeating: 0, count: frames * 4)
      mix.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
          sends.withUnsafeMutableBufferPointer { s in
            machines.withUnsafeMutableBufferPointer { m in
              pool.render(
                firstFrame: 0, frames: frames, left: l.baseAddress!, right: r.baseAddress!,
                delayLeft: s.baseAddress!, delayRight: s.baseAddress! + frames,
                reverbLeft: s.baseAddress! + frames * 2, reverbRight: s.baseAddress! + frames * 3,
                sections: sections ? m.baseAddress! : nil, stride: frames, diverted: diverted)
            }
          }
        }
      }
      return (mix, machines)
    }
    let plain = run(sections: false, diverted: 0)
    let split = run(sections: true, diverted: 0b10)
    let tr808 = Array(split.machines[0..<frames])
    let tr909 = Array(split.machines[frames * 2..<frames * 3])
    #expect(Self.loudest(tr808) > 0.01 && Self.loudest(tr909) > 0.01)
    var worst: Float = 0
    for frame in 0..<frames { worst = max(worst, abs(split.mix[frame] + tr909[frame] - plain.mix[frame])) }
    #expect(worst < 1e-6, "the mix and the diverted 909 add up to the mix alone, within \(worst)")
    var withoutDivert: Float = 0
    let kept = run(sections: true, diverted: 0)
    for frame in 0..<frames { withoutDivert = max(withoutDivert, abs(kept.mix[frame] - plain.mix[frame])) }
    #expect(withoutDivert == 0, "an undiverted machine's voices reach the mix unchanged")
  }

  @Test func voicesBelongToTheMachinesTheReferenceSays() {
    #expect(SectionOutputs.section(ofVoice: "808.bd") == 0)
    #expect(SectionOutputs.section(ofVoice: "909.ch") == 1)
    #expect(SectionOutputs.section(ofVoice: "303.a") == 2)
    #expect(SectionOutputs.section(ofVoice: "303.b") == 3)
    #expect(SectionOutputs.section(ofVoice: "click") == -1)
    #expect(SectionOutputs.section(ofVoice: "") == -1)
  }
}
