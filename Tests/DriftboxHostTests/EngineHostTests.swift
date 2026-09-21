import ConformanceSupport
import DriftboxDocument
import DriftboxEngine
import DriftboxHost
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
