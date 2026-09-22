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

  /// The song being played, owned by whoever loaded it. Nil plays silence.
  public private(set) var song: UnsafeMutablePointer<CompiledSong>?
  /// The engine's clock, in frames since it was made. Never stops, playing or not.
  public private(set) var frame = 0
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
  }

  deinit {
    scratch.deallocate()
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

  @_noAllocation
  public mutating func stop() {
    isPlaying = false
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
    var done = 0
    while done < frames {
      let count = min(Self.chunk, frames - done)
      renderChunk(count: count, left: left + done, right: right + done)
      done += count
    }
  }

  @_noAllocation
  private mutating func renderChunk(
    count: Int, left out: UnsafeMutablePointer<Float>, right outRight: UnsafeMutablePointer<Float>
  ) {
    let chunk = Self.chunk
    let busLeft = scratch
    let busRight = scratch + chunk
    let toDelayLeft = scratch + chunk * 2
    let toDelayRight = scratch + chunk * 3
    let toReverbLeft = scratch + chunk * 4
    let toReverbRight = scratch + chunk * 5
    for index in 0..<chunk * 6 { scratch[index] = 0 }

    if isPlaying, let song {
      // The song loops: a pass that has run out starts the next one on the frame after.
      if frame - passStart >= song.pointee.passFrames {
        passStart += song.pointee.passFrames
        hitCursor = 0
        bassCursor = 0
        events.send(EngineEvent(kind: .pass, frame: passStart, voice: 0, level: 0, frequency: 0, flag: 0))
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
      delayRight: toDelayRight, reverbLeft: toReverbLeft, reverbRight: toReverbRight)

    for index in 0..<count {
      let at = frame + index
      let time = Double(at) / sampleRate

      // 303 notes land on their exact frame.
      if isPlaying, let song {
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
      busLeft[index] += a + b
      busRight[index] += a + b
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
      out[index] = filtered.left * Self.masterGain
      outRight[index] = filtered.right * Self.masterGain
    }
    frame += count
  }
}
