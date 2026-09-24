import DriftboxDSP
import DriftboxSeq

/// The whole instrument, for a render thread: `SongRenderer`'s graph, a block at a time, with a
/// transport. Everything it will ever need is allocated when it is made; `render` and the
/// transport calls allocate nothing, lock nothing and touch no class.
///
/// Held to `SongRenderer`, the offline form, on catalogue songs.
public struct SongEngine: ~Copyable {
  public static var busGain: Float { 0.9 }
  public static var masterGain: Float { 0.7 }
  /// Frames rendered at a time inside `render`, whatever the host asks for.
  static var chunk: Int { 128 }

  public let sampleRate: Double
  public var voices: VoicePool
  var bassA: RealtimeBassline
  var bassB: RealtimeBassline
  var delayLeft: DelaySend
  var delayRight: DelaySend
  var inserts: MasterInserts
  public var pad: Kaoss
  /// What was played, for the interface. Read it with `events.receive()` from one thread only.
  public var events = EventRing()

  /// Bus and sends for one chunk, stereo each.
  let scratch: UnsafeMutablePointer<Float>
  /// Each machine's dry sound for one chunk, left and right in turn, when a host asks for them.
  let sectionScratch: UnsafeMutablePointer<Float>

  /// The metronome and the count-in: clicks, from a pool of their own, added after the master so
  /// nothing in the mix — the pad least of all — can take them away.
  var clicks: VoicePool
  let strongClick: FixedVoiceSpec
  let weakClick: FixedVoiceSpec
  /// A click's output for one chunk, and the sends it has but never uses.
  let clickScratch: UnsafeMutablePointer<Float>
  /// Click on every beat of the song while it plays.
  public var metronome = false
  var beatCursor = 0

  /// Bars of clicks before the song moves, when it is started from a stop.
  public var countInBars = 0
  /// Frames of count-in left: while there are any, the song waits where it is and only the
  /// clicks sound.
  public private(set) var countInLeft = 0
  var countInNext = 0
  var countInBeat = 0
  var countInBeats = 0
  var countInBeatsPerBar = 4

  /// The bars being looped, or a count of zero for none. In bars rather than frames so an edit,
  /// which recompiles the song and so moves every frame, keeps the loop where it was.
  public private(set) var loopStartBar = 0
  public private(set) var loopBarCount = 0

  /// The song being played, owned by whoever loaded it. Nil plays silence.
  public private(set) var song: UnsafeMutablePointer<CompiledSong>?
  /// The engine's clock, in frames since it was made, or since where it was set to start. Never
  /// stops, playing or not.
  public private(set) var frame = 0

  /// Start the clock at `frame` rather than zero, before anything is rendered: an engine playing a
  /// performance again runs on the clock it was played on, since the master's inserts and the
  /// delay's quanta keep time by it, as Web Audio's render quanta do.
  public mutating func startClock(at frame: Int) {
    self.frame = max(0, frame)
  }
  public private(set) var isPlaying = false
  /// Where on the engine's clock the current pass through the song began.
  var passStart = 0
  var hitCursor = 0
  var bassCursor = 0

  public init(sampleRate: Double, voiceCapacity: Int = 32) {
    self.sampleRate = sampleRate
    voices = VoicePool(sampleRate: sampleRate, capacity: voiceCapacity)
    bassA = RealtimeBassline(sampleRate: sampleRate)
    bassB = RealtimeBassline(sampleRate: sampleRate)
    delayLeft = DelaySend(sampleRate: sampleRate)
    delayRight = DelaySend(sampleRate: sampleRate)
    inserts = MasterInserts(sampleRate: sampleRate)
    pad = Kaoss(sampleRate: sampleRate)
    scratch = .allocate(capacity: Self.chunk * 6)
    scratch.initialize(repeating: 0, count: Self.chunk * 6)
    sectionScratch = .allocate(capacity: Self.chunk * 8)
    sectionScratch.initialize(repeating: 0, count: Self.chunk * 8)
    clicks = VoicePool(sampleRate: sampleRate, capacity: 4)
    strongClick = clicks.prepare(metronomeClick(strong: true), voiceId: "", at: 0)
    weakClick = clicks.prepare(metronomeClick(strong: false), voiceId: "", at: 0)
    clickScratch = .allocate(capacity: Self.chunk * 6)
    clickScratch.initialize(repeating: 0, count: Self.chunk * 6)
  }

  deinit {
    scratch.deallocate()
    sectionScratch.deallocate()
    clickScratch.deallocate()
  }

  // MARK: - Transport

  /// Play `song` from its start. The previous song, if any, is the caller's to free once this
  /// call has returned on the render thread.
  @_noAllocation
  public mutating func load(_ song: UnsafeMutablePointer<CompiledSong>?) {
    self.song = song
    passStart = frame
    hitCursor = 0
    bassCursor = 0
    beatCursor = 0
    if let song {
      delayLeft.update(song.pointee.fx, bpm: song.pointee.bpm, atFrame: frame)
      delayRight.update(song.pointee.fx, bpm: song.pointee.bpm, atFrame: frame)
      inserts.update(song.pointee.fx, atFrame: frame)
    }
  }

  @_noAllocation
  public mutating func play() {
    isPlaying = true
  }

  /// Play, and if this is a start from a stop, count in first: `countInBars` bars of clicks, at
  /// the song's tempo and as many beats as the bar it starts in has, before the song moves.
  @_noAllocation
  public mutating func start() {
    if !isPlaying, countInBars > 0, let song {
      let bar = song.pointee.bar(at: max(0, songFrame()))
      let steps = max(1, song.pointee.barSteps[bar])
      let barFrames = song.pointee.barStarts[bar + 1] - song.pointee.barStarts[bar]
      countInBeatsPerBar = (steps + 3) / 4
      countInBeat = max(1, barFrames * 4 / steps)
      countInLeft = countInBeat * countInBeatsPerBar * countInBars
      countInNext = 0
      countInBeats = 0
    }
    isPlaying = true
  }

  @_noAllocation
  public mutating func stop() {
    isPlaying = false
    countInLeft = 0
  }

  /// Loop `bars` bars from `startBar`; zero bars loops nothing. Heard at the next boundary: a
  /// transport inside the loop goes round at its end, one past it goes back at the next bar.
  @_noAllocation
  public mutating func setLoop(startBar: Int, bars: Int) {
    loopStartBar = max(0, startBar)
    loopBarCount = max(0, bars)
  }

  /// Where the loop is in the song playing, in frames, or nil if there is none that fits it.
  @_noAllocation
  func loopFrames() -> (start: Int, end: Int)? {
    guard loopBarCount > 0, let song, loopStartBar < song.pointee.barCount else { return nil }
    let end = min(song.pointee.barCount, loopStartBar + loopBarCount)
    return (song.pointee.barStarts[loopStartBar], song.pointee.barStarts[end])
  }

  /// Where the transport next has to turn round, in song frames: the loop's end, the next bar
  /// when it is already past the loop, or the end of the pass.
  @_noAllocation
  func nextBoundary() -> Int? {
    guard let song else { return nil }
    let at = songFrame()
    if let loop = loopFrames() {
      if at < loop.end { return loop.end }
      let bar = song.pointee.bar(at: at)
      return song.pointee.barStarts[bar + 1]
    }
    return song.pointee.passFrames
  }

  /// Jump to `songFrame` within the pass. Voices already sounding ring on.
  @_noAllocation
  public mutating func seek(toSongFrame songFrame: Int) {
    guard let song else { return }
    let target = max(0, min(song.pointee.passFrames - 1, songFrame))
    passStart = frame - target
    hitCursor = 0
    while hitCursor < song.pointee.hitCount, song.pointee.hits[hitCursor].firstFrame < target {
      hitCursor += 1
    }
    bassCursor = 0
    while bassCursor < song.pointee.bassCount, song.pointee.bass[bassCursor].frame < target {
      bassCursor += 1
    }
    beatCursor = 0
    while beatCursor < song.pointee.beatCount, song.pointee.beats[beatCursor].frame < target {
      beatCursor += 1
    }
  }

  /// Strike a voice on the next frame rendered, outside the song: `hit` was prepared against time
  /// zero and is placed on the engine's clock here.
  @_noAllocation
  public mutating func strike(_ hit: FixedVoiceSpec) {
    var placed = hit
    placed.shift(byFrames: frame, sampleRate: sampleRate)
    voices.start(placed)
    events.send(
      EngineEvent(
        kind: .hit, frame: placed.firstFrame, voice: placed.voiceIndex, level: placed.accent, frequency: 0,
        flag: placed.chokeGroup))
  }

  /// Play a 303 note on the next frame rendered, outside the song.
  @_noAllocation
  public mutating func play(_ note: BassNote, line: Int) {
    let when = Double(frame) / sampleRate
    if line == 0 { bassA.play(note, at: when) } else { bassB.play(note, at: when) }
    events.send(
      EngineEvent(
        kind: .note, frame: frame, voice: line, level: Float(note.gain), frequency: Float(note.frequency),
        flag: note.glide > 0 ? 1 : 0))
  }

  /// Where the song is, in frames from its start, or -1 when nothing is loaded.
  @_noAllocation
  public func songFrame() -> Int { song == nil ? -1 : frame - passStart }

  // MARK: - Rendering

  /// `frames` frames of stereo output, added to nothing: the buffers are overwritten.
  @_noAllocation
  public mutating func render(
    frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
  ) {
    render(frames: frames, left: left, right: right, sections: nil)
  }

  /// The same, and each machine's dry sound into `sections`, overwritten too; a machine
  /// `sections` diverts is left out of the mix in `left` and `right`.
  @_noAllocation
  public mutating func render(
    frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
    sections: SectionOutputs?
  ) {
    var done = 0
    while done < frames {
      var count = min(Self.chunk, frames - done)
      // A chunk ends where the count-in does, so the song starts on its first frame, and where
      // the transport turns round, so a loop's first hit lands on its exact frame.
      var turning: Int?
      if countInLeft > 0 {
        count = min(count, countInLeft)
      } else if isPlaying, let boundary = nextBoundary() {
        let until = boundary - songFrame()
        if until > 0, until <= count {
          count = until
          turning = boundary
        }
      }
      renderChunk(count: count, left: left + done, right: right + done, sections: sections, at: done)
      if let turning, songFrame() == turning { turn(at: turning) }
      done += count
    }
  }

  /// Go round: to the loop's start, or at the end of a pass, to the top.
  @_noAllocation
  mutating func turn(at boundary: Int) {
    guard let song else { return }
    if let loop = loopFrames(), boundary >= loop.end || boundary < loop.start {
      seek(toSongFrame: loop.start)
    } else if boundary >= song.pointee.passFrames {
      passStart += song.pointee.passFrames
      hitCursor = 0
      bassCursor = 0
      beatCursor = 0
      events.send(EngineEvent(kind: .pass, frame: passStart, voice: 0, level: 0, frequency: 0, flag: 0))
    }
  }

  @_noAllocation
  private mutating func renderChunk(
    count: Int, left out: UnsafeMutablePointer<Float>, right outRight: UnsafeMutablePointer<Float>,
    sections: SectionOutputs?, at offset: Int
  ) {
    let chunk = Self.chunk
    let busLeft = scratch
    let busRight = scratch + chunk
    let toDelayLeft = scratch + chunk * 2
    let toDelayRight = scratch + chunk * 3
    let toReverbLeft = scratch + chunk * 4
    let toReverbRight = scratch + chunk * 5
    for index in 0..<chunk * 6 {
      scratch[index] = 0
      clickScratch[index] = 0
    }
    let diverted = sections?.diverted ?? 0
    if sections != nil { for index in 0..<chunk * 8 { sectionScratch[index] = 0 } }
    let counting = countInLeft > 0
    let moving = isPlaying && !counting

    // The count-in's clicks, on a clock of their own: the song is not moving yet.
    if counting {
      while countInNext < count {
        var click = countInBeats % countInBeatsPerBar == 0 ? strongClick : weakClick
        click.shift(byFrames: frame + countInNext, sampleRate: sampleRate)
        clicks.start(click)
        countInBeats += 1
        countInNext += countInBeat
      }
      countInNext -= count
      countInLeft -= count
    }

    if moving, let song {
      // A pass that has run out — because a seek put the transport past its end — starts the
      // next one here. The usual way round is `turn`, on the boundary's exact frame.
      if frame - passStart >= song.pointee.passFrames {
        passStart += song.pointee.passFrames
        hitCursor = 0
        bassCursor = 0
        beatCursor = 0
        events.send(EngineEvent(kind: .pass, frame: passStart, voice: 0, level: 0, frequency: 0, flag: 0))
      }
      // The metronome: a click on each beat that falls in this chunk, straight whatever the
      // song's swing, because a click that shuffled would be measuring against itself.
      let songStart = frame - passStart
      while beatCursor < song.pointee.beatCount, song.pointee.beats[beatCursor].frame < songStart + count {
        let beat = song.pointee.beats[beatCursor]
        if metronome, beat.frame >= songStart {
          var click = beat.strong ? strongClick : weakClick
          click.shift(byFrames: passStart + beat.frame, sampleRate: sampleRate)
          clicks.start(click)
        }
        beatCursor += 1
      }
      // Hits due in this chunk are started now; the pool renders each from its own first frame.
      let songEnd = frame - passStart + count
      while hitCursor < song.pointee.hitCount, song.pointee.hits[hitCursor].firstFrame < songEnd {
        var hit = song.pointee.hits[hitCursor]
        hit.shift(byFrames: passStart, sampleRate: sampleRate)
        voices.start(hit)
        events.send(
          EngineEvent(
            kind: .hit, frame: hit.firstFrame, voice: hit.voiceIndex, level: hit.accent, frequency: 0,
            flag: hit.chokeGroup))
        hitCursor += 1
      }
    }
    voices.render(
      firstFrame: frame, frames: count, left: busLeft, right: busRight, delayLeft: toDelayLeft,
      delayRight: toDelayRight, reverbLeft: toReverbLeft, reverbRight: toReverbRight,
      sections: sections == nil ? nil : sectionScratch, stride: chunk, diverted: diverted)
    let clickLeft = clickScratch
    let clickRight = clickScratch + chunk
    clicks.render(
      firstFrame: frame, frames: count, left: clickLeft, right: clickRight,
      delayLeft: clickScratch + chunk * 2,
      delayRight: clickScratch + chunk * 3, reverbLeft: clickScratch + chunk * 4,
      reverbRight: clickScratch + chunk * 5)

    for index in 0..<count {
      let at = frame + index
      let time = Double(at) / sampleRate

      // 303 notes land on their exact frame.
      if moving, let song {
        let songAt = at - passStart
        while bassCursor < song.pointee.bassCount, song.pointee.bass[bassCursor].frame <= songAt {
          let event = song.pointee.bass[bassCursor]
          let when = event.time + Double(passStart) / sampleRate
          events.send(
            EngineEvent(
              kind: .note, frame: at, voice: event.line, level: Float(event.note.gain),
              frequency: Float(event.note.frequency), flag: event.note.glide > 0 ? 1 : 0))
          if event.line == 0 {
            bassA.play(event.note, at: when)
            bassA.sendDelay = event.sendDelay
            bassA.sendReverb = event.sendReverb
          } else {
            bassB.play(event.note, at: when)
            bassB.sendDelay = event.sendDelay
            bassB.sendReverb = event.sendReverb
          }
          bassCursor += 1
        }
      }
      let a = bassA.next(time: time)
      let b = bassB.next(time: time)
      // The 303s are machines 2 and 3, mono into both sides, as they reach the mix.
      if sections != nil {
        sectionScratch[4 * chunk + index] += a
        sectionScratch[5 * chunk + index] += a
        sectionScratch[6 * chunk + index] += b
        sectionScratch[7 * chunk + index] += b
      }
      let heardA = diverted & 4 == 0 ? a : 0
      let heardB = diverted & 8 == 0 ? b : 0
      busLeft[index] += heardA + heardB
      busRight[index] += heardA + heardB
      toDelayLeft[index] += a * bassA.sendDelay + b * bassB.sendDelay
      toDelayRight[index] += a * bassA.sendDelay + b * bassB.sendDelay
      toReverbLeft[index] += a * bassA.sendReverb + b * bassB.sendReverb
      toReverbRight[index] += a * bassA.sendReverb + b * bassB.sendReverb

      // Sends return to the bus.
      busLeft[index] += delayLeft.process(toDelayLeft[index], frame: at)
      busRight[index] += delayRight.process(toDelayRight[index], frame: at)
      if let song {
        busLeft[index] += song.pointee.reverbLeft.process(toReverbLeft[index])
        busRight[index] += song.pointee.reverbRight.process(toReverbRight[index])
      }

      // Master.
      let inserted = inserts.process(
        left: busLeft[index] * Self.busGain, right: busRight[index] * Self.busGain, frame: at)
      let filtered = pad.process(left: inserted.left, right: inserted.right, frame: at)
      out[index] = filtered.left * Self.masterGain + clickLeft[index]
      outRight[index] = filtered.right * Self.masterGain + clickRight[index]
    }
    if let sections {
      for buffer in 0..<8 {
        let from = sectionScratch + buffer * chunk
        let to = sections.buffers[buffer] + offset
        for index in 0..<count { to[index] = from[index] }
      }
    }
    frame += count
    // The engine's clock always runs — tails, the pad and struck voices need it — but a stopped
    // song stays where it stopped, and a counting-in one where it will start.
    if !moving { passStart += count }
  }
}
