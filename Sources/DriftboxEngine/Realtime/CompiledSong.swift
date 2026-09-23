import DriftboxDSP
import DriftboxSeq

/// A song, worked out ahead of time into what a render thread can play: every hit as a
/// `FixedVoiceSpec`, every 303 note with its frame, the pass length, the room, all in storage
/// that stays put. Made on a thread that may allocate, handed to `SongEngine`, and freed by
/// whoever made it once the engine has let go of it.
///
/// Times are the song's own, from zero. The engine places each pass on its clock with `shift`,
/// so a song that loops sounds the same every time round — including where each hit reads its
/// noise from, which the reference hashes on absolute time and so varies between plays.
public struct CompiledSong: ~Copyable {
  public struct BassEvent {
    /// Which line: 0 for 303 A, 1 for 303 B.
    public var line: Int
    /// The first frame at or after the note's time: when a sequencer inside the render call
    /// reaches it.
    public var frame: Int
    public var time: Double
    public var note: BassNote
    public var sendDelay: Float
    public var sendReverb: Float
  }

  /// A beat of the song, where the metronome clicks: every fourth step of a bar, straight, and
  /// the bar's first strong.
  public struct Beat {
    public var frame: Int
    public var strong: Bool
  }

  public let sampleRate: Double
  public let hits: UnsafeMutablePointer<FixedVoiceSpec>
  public let hitCount: Int
  public let bass: UnsafeMutablePointer<BassEvent>
  public let bassCount: Int
  /// Frames in one pass through the arrangement.
  public let passFrames: Int
  /// Where each bar starts, in frames, and after the last, `passFrames`: `barCount + 1` of them.
  public let barStarts: UnsafeMutablePointer<Int>
  public let barCount: Int
  /// Steps in each bar, for a count-in to know how many beats a bar has.
  public let barSteps: UnsafeMutablePointer<Int>
  public let beats: UnsafeMutablePointer<Beat>
  public let beatCount: Int
  public let fx: FxParams
  public let bpm: Double
  /// The room, as the reverb send's convolvers, one per side.
  public var reverbLeft: Reverb
  public var reverbRight: Reverb

  /// Choke groups by name, so a hat can be told which other hats to silence.
  static let chokeGroups = ["808.hats", "909.hats"]

  public init(_ song: Song, preparer: HitPreparer) {
    let sampleRate = preparer.sampleRate
    self.sampleRate = sampleRate
    let bars = song.chain.isEmpty ? 1 : song.bars
    let plan = song.plan(bars: bars)
    let seconds = plan.last.map { $0.time + $0.stepSeconds } ?? 0
    passFrames = max(1, Int((seconds * sampleRate).rounded()))

    // The plan is every step of every bar in order, so walking the bars' lengths alongside it
    // says which bar and which step of it each planned step is.
    var starts: [Int] = []
    var steps: [Int] = []
    var clicks: [Beat] = []
    var at = 0
    for bar in 0..<bars where at < plan.count {
      let length = song.barLength(forBar: bar)
      starts.append(Int((plan[at].time * sampleRate).rounded()))
      steps.append(length)
      for index in 0..<length where at + index < plan.count && index % 4 == 0 {
        clicks.append(Beat(frame: Int((plan[at + index].time * sampleRate).rounded()), strong: index == 0))
      }
      at += length
    }
    starts.append(passFrames)
    barCount = steps.count
    barStarts = .allocate(capacity: starts.count)
    barStarts.initialize(from: starts, count: starts.count)
    barSteps = .allocate(capacity: max(1, steps.count))
    barSteps.initialize(from: steps, count: steps.count)
    beatCount = clicks.count
    beats = .allocate(capacity: max(1, clicks.count))
    beats.initialize(from: clicks, count: clicks.count)

    // Nothing in the catalogue moves its effects or its tempo mid-song; a song that does is
    // played at its opening settings, and the render says nothing about it. The offline form
    // refuses such a song; here there is no one to refuse to.
    fx = plan.first?.fx ?? song.fx
    bpm = plan.first?.bpm ?? song.bpm

    var prepared: [FixedVoiceSpec] = []
    for step in plan {
      for hit in step.drums {
        guard let voice = voice(id: hit.voiceId) else { continue }
        let group = voice.choke.flatMap { Self.chokeGroups.firstIndex(of: $0) }.map { UInt8($0 + 1) } ?? 0
        var fixed = preparer.prepare(
          voice.build(hit.params, accent: hit.accent), voiceId: voice.id, at: hit.time, sends: hit.sends,
          chokeGroup: group)
        fixed.accent = Float(hit.accent)
        prepared.append(fixed)
      }
    }
    // By frame, and in plan order within a frame: two hats on one step choke each other in the
    // order the plan lists them, and a sort on its own would not promise to keep that.
    // (Written out rather than as a key path, which Embedded Swift has no room for.)
    prepared = prepared.enumerated().sorted {
      ($0.element.firstFrame, $0.offset) < ($1.element.firstFrame, $1.offset)
    }.map { pair in pair.element }
    hitCount = prepared.count
    hits = .allocate(capacity: max(1, prepared.count))
    hits.initialize(from: prepared, count: prepared.count)

    var notes: [BassEvent] = []
    for step in plan {
      for hit in step.bass {
        let line = hit.voiceId == "303.b" ? 1 : 0
        notes.append(
          BassEvent(
            line: line, frame: Int((hit.time * sampleRate).rounded(.up)), time: hit.time, note: hit.note,
            sendDelay: Float(hit.sends.delay), sendReverb: Float(hit.sends.reverb)))
      }
    }
    notes = notes.enumerated().sorted { ($0.element.frame, $0.offset) < ($1.element.frame, $1.offset) }
      .map { pair in pair.element }
    bassCount = notes.count
    bass = .allocate(capacity: max(1, notes.count))
    bass.initialize(from: notes, count: notes.count)

    let room = ReverbSend.impulseResponse(for: fx, sampleRate: sampleRate)
    let scale = Float(ReverbSend.normalisation(room, sampleRate: sampleRate))
    reverbLeft = Reverb(response: room[0], gain: scale)
    reverbRight = Reverb(response: room[1], gain: scale)
  }

  deinit {
    hits.deallocate()
    bass.deallocate()
    barStarts.deallocate()
    barSteps.deallocate()
    beats.deallocate()
  }

  /// The bar playing at `songFrame`.
  @_noAllocation
  public func bar(at songFrame: Int) -> Int {
    var low = 0
    var high = barCount
    while low + 1 < high {
      let middle = (low + high) / 2
      if barStarts[middle] <= songFrame { low = middle } else { high = middle }
    }
    return low
  }
}
