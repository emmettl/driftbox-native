import ConformanceSupport
import DriftboxDocument
import DriftboxEngine
import Testing

struct StemTests {
  /// A stem is the voice alone: silent where the mix has only other voices, and not silent.
  @Test func aStemIsOneVoiceAlone() throws {
    let song = try #require(SongCodec.decode(try Fixtures.text("documents/acid.song.json")))
    let used = SongRenderer.voicesUsed(song)
    #expect(used.contains("909.bd") && used.contains("303.a"))
    var options = SongRenderer.Options(sampleRate: 48000, start: 15.238, duration: 2, tail: 0.2)
    options.only = ["303.a"]
    let stem = SongRenderer.render(song, options: options)
    #expect(stem.left.contains { $0 != 0 })
    options.only = []
    let nothing = SongRenderer.render(song, options: options)
    let loudest = nothing.left.map(abs).max() ?? 0
    #expect(loudest == 0, "silence peaks at \(loudest)")
  }
}
