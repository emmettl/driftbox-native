import ConformanceSupport
import DriftboxDocument
import DriftboxEngine
import DriftboxHost
import DriftboxSeq
import Foundation
import Testing

struct EngineHostTests {
  /// Commands through the ring, songs through the host: the same samples as the engine gives
  /// when driven directly.
  @Test func theHostRendersWhatTheEngineRenders() throws {
    let song = try #require(SongCodec.decode(try Fixtures.text("documents/acid.song.json")))
    let frames = 48000
    var left = [Float](repeating: 0, count: frames)
    var right = [Float](repeating: 0, count: frames)

    let host = EngineHost(sampleRate: 48000)
    host.load(song)
    host.send(.play)
    var done = 0
    while done < frames {
      let count = min(1024, frames - done)
      left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
          host.render(frames: count, left: l.baseAddress! + done, right: r.baseAddress! + done)
        }
      }
      done += count
    }
    let playing = host.playing.load(ordering: .relaxed)
    let position = host.songFrame.load(ordering: .relaxed)
    #expect(playing)
    #expect(position == frames)

    var engine = SongEngine(sampleRate: 48000)
    let compiled = UnsafeMutablePointer<CompiledSong>.allocate(capacity: 1)
    compiled.initialize(to: CompiledSong(song, preparer: engine.voices.preparer))
    engine.load(compiled)
    engine.play()
    var expected = [Float](repeating: 0, count: frames)
    var expectedRight = [Float](repeating: 0, count: frames)
    expected.withUnsafeMutableBufferPointer { l in
      expectedRight.withUnsafeMutableBufferPointer { r in
        engine.render(frames: frames, left: l.baseAddress!, right: r.baseAddress!)
      }
    }
    engine.load(nil)
    compiled.deinitialize(count: 1)
    compiled.deallocate()

    #expect(left == expected && right == expectedRight)
    #expect(left.contains { $0 != 0 })
  }

  /// An app's transport, put on the song from the render thread: at the same beat, round again past
  /// the song's end, playing or stopped as the app is — from the block it is said on.
  @Test func anAppsTransportLocatesTheSong() {
    var pattern = DriftboxSeq.Pattern(id: "p", name: "P", length: 16)
    pattern.tracks["909.bd"] = [StepValue](repeating: .on, count: 16)
    var song = Song(bpm: 120, patterns: [pattern])
    song.chain = [ChainStep(pattern: "p")]
    let host = EngineHost(sampleRate: 48000)
    host.load(song)
    var left = [Float](repeating: 0, count: 480)
    var right = [Float](repeating: 0, count: 480)
    func render() {
      left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
          host.render(frames: 480, left: l.baseAddress!, right: r.baseAddress!)
        }
      }
    }
    render()

    // Half a second a beat at 120: the third beat is a second and a half in.
    host.locate(beat: 3, moving: true)
    render()
    let playing = host.playing.load(ordering: .relaxed)
    #expect(playing)
    #expect(host.songFrame.load(ordering: .relaxed) == 3 * 24000 + 480)

    // The song is a bar, four beats, so the app's fifth is the song's second, a pass on.
    host.locate(beat: 5, moving: false)
    render()
    let stopped = !host.playing.load(ordering: .relaxed)
    #expect(stopped)
    #expect(host.songFrame.load(ordering: .relaxed) == 24000)
  }

  /// Loading a second song hands the first back, and the host frees it.
  @Test func songsComeBackToBeFreed() throws {
    let song = try #require(SongCodec.decode(try Fixtures.text("documents/pump.song.json")))
    let host = EngineHost(sampleRate: 48000)
    var left = [Float](repeating: 0, count: 256)
    var right = [Float](repeating: 0, count: 256)
    func render() {
      left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
          host.render(frames: 256, left: l.baseAddress!, right: r.baseAddress!)
        }
      }
    }
    host.load(song)
    render()
    host.load(song)
    render()
    host.collect()
    host.send(.stop)
    render()
    let playing = host.playing.load(ordering: .relaxed)
    #expect(!playing)
  }

  /// A strike from the keys sounds on the next frame rendered, and the engine reports it.
  @Test func aStrikeSoundsAtOnce() throws {
    let host = EngineHost(sampleRate: 48000)
    let kick = try #require(voice(id: "909.bd"))
    let hit = host.preparer.prepare(kick.build(accent: 1), voiceId: kick.id, at: 0)
    var left = [Float](repeating: 0, count: 512)
    var right = [Float](repeating: 0, count: 512)
    func render() {
      left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
          host.render(frames: 512, left: l.baseAddress!, right: r.baseAddress!)
        }
      }
    }
    render()
    #expect(left.allSatisfy { $0 == 0 })
    host.send(.strike(hit))
    render()
    // The compressor looks ahead 288 frames, so the kick shows from there.
    #expect(left[0..<288].allSatisfy { $0 == 0 })
    #expect(left[288...].contains { $0 != 0 })
    let event = host.nextEvent()
    #expect(event?.kind == .hit && event?.frame == 512)
  }

  @Test func aFullRingDropsTheNewest() {
    let ring = CommandRing()
    for _ in 0..<CommandRing.capacity {
      let sent = ring.send(.play)
      #expect(sent)
    }
    let sent = ring.send(.stop)
    #expect(!sent)
    var received = 0
    while ring.receive() != nil { received += 1 }
    #expect(received == CommandRing.capacity)
  }
}
