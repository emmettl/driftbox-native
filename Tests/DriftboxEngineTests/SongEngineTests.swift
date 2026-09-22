import ConformanceSupport
import DriftboxDocument
import DriftboxEngine
import DriftboxSeq
import Foundation
import Testing

/// The real-time engine against the offline renderer, on catalogue songs. Not to the bit — the
/// reverb is a partitioned single-precision convolution here and one double-precision transform
/// there, and what it returns goes through the compressor — but close.
struct SongEngineTests {
  static let sampleRate = 48000.0

  static func song(_ id: String) throws -> Song {
    try #require(SongCodec.decode(try Fixtures.text("documents/\(id).song.json")))
  }

  /// Render `seconds` from the top through the engine, in blocks of `block` frames.
  static func render(_ song: Song, seconds: Double, block: Int) -> (left: [Float], right: [Float]) {
    var engine = SongEngine(sampleRate: sampleRate, voiceCapacity: 32)
    let compiled = UnsafeMutablePointer<CompiledSong>.allocate(capacity: 1)
    compiled.initialize(to: CompiledSong(song, preparer: engine.voices.preparer))
    defer {
      compiled.deinitialize(count: 1)
      compiled.deallocate()
    }
    engine.load(compiled)
    engine.play()
    let frames = Int(seconds * sampleRate)
    var left = [Float](repeating: 0, count: frames)
    var right = [Float](repeating: 0, count: frames)
    var done = 0
    while done < frames {
      let count = min(block, frames - done)
      left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
          engine.render(frames: count, left: l.baseAddress! + done, right: r.baseAddress! + done)
        }
      }
      done += count
    }
    engine.load(nil)
    return (left, right)
  }

  @Test(arguments: ["acid", "smallhours", "garage", "orrery"])
  func playsWhatTheOfflineRendererRenders(id: String) throws {
    let song = try Self.song(id)
    let seconds = 6.0
    var options = SongRenderer.Options(sampleRate: Self.sampleRate, start: 0, duration: seconds, tail: 0)
    options.schedulesBassFromQuantum = false
    let expected = SongRenderer.render(song, options: options)
    let mine = Self.render(song, seconds: seconds, block: 512)

    var worst = 0.0
    var peak = 0.0
    for frame in 0..<mine.left.count {
      worst = max(
        worst, abs(Double(mine.left[frame]) - Double(expected.left[frame])),
        abs(Double(mine.right[frame]) - Double(expected.right[frame])))
      peak = max(peak, abs(Double(expected.left[frame])))
    }
    let decibels = worst > 0 ? 20 * log10(worst / peak) : -Double.infinity
    #expect(peak > 0.1)
    #expect(decibels <= -90, "\(id) is \(decibels)dB from the offline render")
  }

  /// The block size the host chooses must not change the sound.
  @Test func theBlockSizeDoesNotMatter() throws {
    let song = try Self.song("acid")
    let a = Self.render(song, seconds: 2, block: 128)
    let b = Self.render(song, seconds: 2, block: 333)
    #expect(a.left == b.left && a.right == b.right)
  }

  /// A pass ends and the next begins on the very next frame, with the tails of the first ringing
  /// on into it, and every pass after the first sounds the same.
  @Test func loopsSeamlessly() throws {
    var song = try Self.song("acid")
    song.chain = Array(song.chain.prefix(1))
    let passSeconds = SongRenderer.seconds(of: song)
    let passFrames = Int((passSeconds * Self.sampleRate).rounded())
    let rendered = Self.render(song, seconds: passSeconds * 3 + 0.5, block: 256)

    // The song opens with a kick. The compressor, starting from nothing, ducks the very first
    // one — as the reference's does — so it is the second and third passes that are compared,
    // 288 frames later in the output than in the song because of the compressor's look-ahead.
    let lookahead = 288
    func opening(_ pass: Int) -> Float {
      rendered.left[pass * passFrames + lookahead..<pass * passFrames + lookahead + 2400].map(abs).max()!
    }
    #expect(opening(1) > 0.1)
    #expect(abs(opening(1) - opening(2)) < 0.05 * opening(1), "second \(opening(1)), third \(opening(2))")

    // And nothing is dropped at the join: the pass before is still ringing into it, and the kick
    // that opens the next pass lands on the frame it should.
    let join = passFrames + lookahead
    #expect(rendered.left[join - 480..<join].contains { $0 != 0 })
    #expect(rendered.left[join..<join + 240].map(abs).max()! > 0.05)
  }

  /// A stopped song stays where it stopped, however long the engine's own clock runs on — and
  /// takes up from there, not from wherever the clock has got to.
  @Test func aStoppedSongHoldsItsPlace() throws {
    let song = try Self.song("acid")
    var engine = SongEngine(sampleRate: Self.sampleRate, voiceCapacity: 32)
    let compiled = UnsafeMutablePointer<CompiledSong>.allocate(capacity: 1)
    compiled.initialize(to: CompiledSong(song, preparer: engine.voices.preparer))
    defer {
      compiled.deinitialize(count: 1)
      compiled.deallocate()
    }
    var left = [Float](repeating: 0, count: 128)
    var right = [Float](repeating: 0, count: 128)
    func render(blocks: Int) {
      for _ in 0..<blocks {
        left.withUnsafeMutableBufferPointer { l in
          right.withUnsafeMutableBufferPointer { r in
            engine.render(frames: 128, left: l.baseAddress!, right: r.baseAddress!)
          }
        }
      }
    }
    engine.load(compiled)
    engine.play()
    render(blocks: 100)
    #expect(engine.songFrame() == 12800)
    engine.stop()
    render(blocks: 1000)
    #expect(engine.songFrame() == 12800)
    engine.seek(toSongFrame: 4800)
    render(blocks: 10)
    #expect(engine.songFrame() == 4800)
    engine.play()
    render(blocks: 10)
    #expect(engine.songFrame() == 4800 + 1280)
    engine.load(nil)
  }
}
