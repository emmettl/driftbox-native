import DriftboxEngine
import DriftboxSeq
import Testing

/// The real-time voices against the offline ones. No browser here: `VoiceRenderer` was held to
/// Chromium, and this is held to `VoiceRenderer` — to the bit, so that nothing has to be shown twice.
struct VoicePoolTests {
  static let sampleRate = 48000.0

  /// Render `frames` frames from frame zero, in blocks of a size no voice would choose.
  static func render(_ pool: inout VoicePool, frames: Int, block: Int = 97, starting hits: [FixedVoiceSpec])
    -> (
      left: [Float], right: [Float], delay: [Float], reverb: [Float]
    )
  {
    var left = [Float](repeating: 0, count: frames)
    var right = [Float](repeating: 0, count: frames)
    var delayLeft = [Float](repeating: 0, count: frames)
    var delayRight = [Float](repeating: 0, count: frames)
    var reverbLeft = [Float](repeating: 0, count: frames)
    var reverbRight = [Float](repeating: 0, count: frames)
    var pending = hits.sorted { $0.firstFrame < $1.firstFrame }[...]
    var frame = 0
    while frame < frames {
      let count = min(block, frames - frame)
      // A hit is started in the block its first frame falls in, as a sequencer would start it.
      while let next = pending.first, next.firstFrame < frame + count {
        pool.start(next)
        pending = pending.dropFirst()
      }
      left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
          delayLeft.withUnsafeMutableBufferPointer { dl in
            delayRight.withUnsafeMutableBufferPointer { dr in
              reverbLeft.withUnsafeMutableBufferPointer { rl in
                reverbRight.withUnsafeMutableBufferPointer { rr in
                  pool.render(
                    firstFrame: frame, frames: count, left: l.baseAddress! + frame,
                    right: r.baseAddress! + frame,
                    delayLeft: dl.baseAddress! + frame, delayRight: dr.baseAddress! + frame,
                    reverbLeft: rl.baseAddress! + frame, reverbRight: rr.baseAddress! + frame)
                }
              }
            }
          }
        }
      }
      frame += count
    }
    return (left, right, delayLeft, reverbLeft)
  }

  @Test func everyVoiceIsTheOfflineVoiceToTheBit() {
    var pool = VoicePool(sampleRate: Self.sampleRate)
    var offline = VoiceRenderer(sampleRate: Self.sampleRate)
    var panel = VoiceParams()
    panel.pan = 0.3
    panel.tune = 0.62
    panel.colour = 0.81

    for voice in allVoices {
      for (params, accent, time) in [
        (VoiceParams(), 1.0, 0.0), (panel, 0.55, 0.0123456789), (panel, 1.0, 0.23809523809523808),
      ] {
        let spec = voice.build(params, accent: accent)
        let hit = pool.prepare(spec, voiceId: voice.id, at: time)
        let frames = hit.endFrame + 100
        let mine = Self.render(&pool, frames: frames, starting: [hit])
        let expected = offline.renderStereo(
          spec, voiceId: voice.id, at: time, firstFrame: hit.firstFrame, frames: hit.endFrame - hit.firstFrame
        )

        var differences = 0
        for frame in hit.firstFrame..<hit.endFrame {
          if mine.left[frame] != expected.left[frame - hit.firstFrame] { differences += 1 }
          if mine.right[frame] != expected.right[frame - hit.firstFrame] { differences += 1 }
        }
        #expect(differences == 0, "\(voice.id) at \(time): \(differences) samples differ")
        #expect(mine.left[..<hit.firstFrame].allSatisfy { $0 == 0 }, "\(voice.id) sounds before it starts")
        #expect(mine.left[hit.endFrame...].allSatisfy { $0 == 0 }, "\(voice.id) sounds after it ends")
      }
    }
  }

  /// A closed hat cuts off the open hat still ringing in its group, exactly as offline.
  @Test func aChokeIsTheOfflineChokeToTheBit() throws {
    var pool = VoicePool(sampleRate: Self.sampleRate)
    var offline = VoiceRenderer(sampleRate: Self.sampleRate)
    let open = try #require(voice(id: "909.oh"))
    let closed = try #require(voice(id: "909.ch"))
    let openSpec = open.build(accent: 1)
    let closedSpec = closed.build(accent: 0.55)
    let chokeAt = 0.11904761904761904

    let first = pool.prepare(openSpec, voiceId: open.id, at: 0, chokeGroup: 2)
    let second = pool.prepare(closedSpec, voiceId: closed.id, at: chokeAt, chokeGroup: 2)
    let frames = max(first.endFrame, second.endFrame)
    let mine = Self.render(&pool, frames: frames, starting: [first, second])

    let expectedOpen = offline.renderStereo(
      openSpec, voiceId: open.id, at: 0, frames: frames, chokeAt: chokeAt)
    let expectedClosed = offline.renderStereo(
      closedSpec, voiceId: closed.id, at: chokeAt, firstFrame: second.firstFrame,
      frames: frames - second.firstFrame)
    var differences = 0
    for frame in 0..<frames {
      var expected = frame < first.endFrame ? expectedOpen.left[frame] : 0
      if frame >= second.firstFrame, frame < second.endFrame {
        expected += expectedClosed.left[frame - second.firstFrame]
      }
      if mine.left[frame] != expected { differences += 1 }
    }
    #expect(differences == 0)
    // And it really was cut off: four milliseconds after the choke the open hat is silent.
    let after = Int((chokeAt + 0.005) * Self.sampleRate)
    #expect(expectedOpen.left[after...].allSatisfy { $0 == 0 })
  }

  @Test func sendsCarryTheVoiceAtTheirLevels() throws {
    var pool = VoicePool(sampleRate: Self.sampleRate)
    let clap = try #require(voice(id: "808.cp"))
    var sends = SendLevels()
    sends.delay = 0.25
    sends.reverb = 0.5
    let hit = pool.prepare(clap.build(accent: 1), voiceId: clap.id, at: 0, sends: sends)
    let mine = Self.render(&pool, frames: hit.endFrame, starting: [hit])
    for frame in 0..<hit.endFrame {
      #expect(mine.delay[frame] == mine.left[frame] * 0.25)
      #expect(mine.reverb[frame] == mine.left[frame] * 0.5)
    }
  }

  /// More hits than slots: the one that would have finished soonest gives way, and nothing breaks.
  @Test func aFullPoolGivesUpTheVoiceNearestItsEnd() throws {
    var pool = VoicePool(sampleRate: Self.sampleRate, capacity: 4)
    let hat = try #require(voice(id: "808.ch"))
    let hits = (0..<12).map { pool.prepare(hat.build(accent: 1), voiceId: hat.id, at: Double($0) * 0.001) }
    let mine = Self.render(&pool, frames: 12000, starting: hits)
    #expect(mine.left.allSatisfy { $0.isFinite })
    #expect(mine.left.contains { $0 != 0 })
  }
}
