import DriftboxDSP
import DriftboxSeq

/// A song, rendered offline to stereo: what `renderMix` does in the reference.
///
/// Every voice and both 303s into a bus; two sends off each of them into the delay and the
/// reverb, whose returns come back to the same bus; then the master inserts, the performance
/// filter — idle, but there — and the master gain.
///
/// This is the offline form, and takes liberties a live engine cannot: each hit is rendered whole
/// and added in, and the reverb is one convolution over the entire send. What it must not take
/// liberties with is the result, which is held to the reference's own renders.
public struct SongRenderer {
  public static let busGain: Float = 0.9
  public static let masterGain: Float = 0.7

  public struct Options: Sendable {
    public var sampleRate = 44100.0
    /// Seconds into the song to start from. Anything struck before it is not rendered, tails and
    /// all, which is the reference's rule and the simplest one to agree on.
    public var start = 0.0
    /// Seconds to render, or nil for the rest of the song.
    public var duration: Double?
    /// Seconds of silence-to-be after the last step, for the tails.
    public var tail = 4.0
    /// See `VoiceRenderer.emulatesBrowserSourceStart`. Off, except when being compared.
    public var emulatesBrowserSourceStart = false
    /// Schedule each 303 note from the start of the render quantum it falls in, as the reference
    /// does, rather than from its own frame, as the real-time engine does. On, except when the
    /// real-time engine is being compared with this.
    public var schedulesBassFromQuantum = true

    public init(sampleRate: Double = 44100, start: Double = 0, duration: Double? = nil, tail: Double = 4) {
      self.sampleRate = sampleRate
      self.start = start
      self.duration = duration
      self.tail = tail
    }
  }

  /// The length of one pass through the arrangement, in seconds.
  public static func seconds(of song: Song) -> Double {
    let plan = song.plan(bars: song.chain.isEmpty ? 1 : song.bars)
    guard let last = plan.last else { return 0 }
    return last.time + last.stepSeconds
  }

  public static func render(_ song: Song, options: Options = Options()) -> VoiceRenderer.Stereo {
    let sampleRate = options.sampleRate
    let plan = song.plan(bars: song.chain.isEmpty ? 1 : song.bars)

    let arrangement = seconds(of: song)
    let start = min(max(0, options.start), arrangement)
    let duration = max(0, min(options.duration ?? (arrangement - start), arrangement - start))
    let frames = max(1, Int(((duration + options.tail) * sampleRate).rounded(.up)))
    let quantum = TargetSmoother.quantum

    var busLeft = [Float](repeating: 0, count: frames)
    var busRight = [Float](repeating: 0, count: frames)
    var delayLeft = [Float](repeating: 0, count: frames)
    var delayRight = [Float](repeating: 0, count: frames)
    var reverbLeft = [Float](repeating: 0, count: frames)
    var reverbRight = [Float](repeating: 0, count: frames)

    // MARK: Drums

    struct Hit {
      var voice: Voice
      var hit: DrumHit
      var time: Double
      var endsAt: Double
      var chokeAt: Double?
    }
    var hits: [Hit] = []
    var ringing: [String: Int] = [:]
    for step in plan {
      for hit in step.drums {
        let time = hit.time - start
        guard time >= 0, time < duration, let voice = voice(id: hit.voiceId) else { continue }
        let spec = voice.build(hit.params, accent: hit.accent)
        if let group = voice.choke {
          if let previous = ringing[group], hits[previous].endsAt > time { hits[previous].chokeAt = time }
          ringing[group] = hits.count
        }
        hits.append(Hit(voice: voice, hit: hit, time: time, endsAt: time + spec.duration))
      }
    }

    var renderer = VoiceRenderer(sampleRate: sampleRate)
    renderer.emulatesBrowserSourceStart = options.emulatesBrowserSourceStart
    for entry in hits {
      let spec = entry.voice.build(entry.hit.params, accent: entry.hit.accent)
      let first = Int((entry.time * sampleRate).rounded(.down))
      // The voice's own length, the waveshaper's delay if it has one, and room for a filter to
      // finish ringing.
      let length = min(frames - first, Int((spec.duration * sampleRate).rounded(.up)) + 512)
      guard length > 0 else { continue }
      let audio = renderer.renderStereo(
        spec, voiceId: entry.voice.id, at: entry.time, firstFrame: first, frames: length,
        chokeAt: entry.chokeAt)
      let toDelay = Float(entry.hit.sends.delay)
      let toReverb = Float(entry.hit.sends.reverb)
      for index in 0..<length {
        let frame = first + index
        busLeft[frame] += audio.left[index]
        busRight[frame] += audio.right[index]
        if toDelay > 0 {
          delayLeft[frame] += audio.left[index] * toDelay
          delayRight[frame] += audio.right[index] * toDelay
        }
        if toReverb > 0 {
          reverbLeft[frame] += audio.left[index] * toReverb
          reverbRight[frame] += audio.right[index] * toReverb
        }
      }
    }

    // MARK: The 303s

    var bassIds: [String] = []
    for step in plan {
      for hit in step.bass where !bassIds.contains(hit.voiceId) { bassIds.append(hit.voiceId) }
    }
    for voiceId in bassIds {
      var line = Bassline(sampleRate: sampleRate)
      var toDelay = ParamTimeline(defaultValue: 0)
      var toReverb = ParamTimeline(defaultValue: 0)
      for step in plan {
        for hit in step.bass where hit.voiceId == voiceId {
          let time = hit.time - start
          guard time >= 0, time < duration else { continue }
          // Scheduled from the start of the render quantum the note falls in, as the reference
          // does — or from the note's own frame, as the real-time engine does.
          let scheduled =
            options.schedulesBassFromQuantum
            ? Double(max(0, Int((time * sampleRate / Double(quantum)).rounded(.down))) * quantum) / sampleRate
            : (time * sampleRate).rounded(.up) / sampleRate
          toDelay.setValue(hit.sends.delay, at: time)
          toReverb.setValue(hit.sends.reverb, at: time)
          line.play(hit.note, at: time, scheduledAt: scheduled)
        }
      }
      let audio = line.render(frames: frames)
      for frame in 0..<frames {
        let sample = audio[frame]
        busLeft[frame] += sample
        busRight[frame] += sample
        let time = Double(frame) / sampleRate
        let delay = Float(toDelay.value(at: time))
        let reverb = Float(toReverb.value(at: time))
        delayLeft[frame] += sample * delay
        delayRight[frame] += sample * delay
        reverbLeft[frame] += sample * reverb
        reverbRight[frame] += sample * reverb
      }
    }

    // MARK: Sends

    // What the song is set to where the window opens. Nothing in the catalogue moves its effects
    // or its tempo, and a render that meets a song which does says so rather than ignoring it.
    var opening = plan.first
    for step in plan where step.time <= start { opening = step }
    let fx = opening?.fx ?? song.fx
    let bpm = opening?.bpm ?? song.bpm
    precondition(
      plan.allSatisfy { $0.fx == fx && $0.bpm == bpm && $0.pcf == .off },
      "automated effects, tempo and filter strikes are not rendered offline yet")

    var left = DelaySend(sampleRate: sampleRate)
    var right = DelaySend(sampleRate: sampleRate)
    left.update(fx, bpm: bpm, atFrame: 0)
    right.update(fx, bpm: bpm, atFrame: 0)
    for frame in 0..<frames {
      busLeft[frame] += left.process(delayLeft[frame], frame: frame)
      busRight[frame] += right.process(delayRight[frame], frame: frame)
    }

    let room = ReverbSend.render(
      left: reverbLeft, right: reverbRight, fx: fx, sampleRate: sampleRate, frames: frames)
    for frame in 0..<frames {
      busLeft[frame] += room.left[frame]
      busRight[frame] += room.right[frame]
    }

    // MARK: Master

    var inserts = MasterInserts(sampleRate: sampleRate)
    inserts.update(fx, atFrame: 0, strike: opening?.pcf ?? .off)
    var pad = Kaoss(sampleRate: sampleRate)
    var outLeft = [Float](repeating: 0, count: frames)
    var outRight = [Float](repeating: 0, count: frames)
    for frame in 0..<frames {
      let inserted = inserts.process(
        left: busLeft[frame] * busGain, right: busRight[frame] * busGain, frame: frame)
      let filtered = pad.process(left: inserted.left, right: inserted.right, frame: frame)
      outLeft[frame] = filtered.left * masterGain
      outRight[frame] = filtered.right * masterGain
    }
    return VoiceRenderer.Stereo(left: outLeft, right: outRight)
  }
}
