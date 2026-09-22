import DriftboxSeq
import Testing

/// The two whole-pattern edits the reference keeps in its store rather than in `pattern.ts`, so
/// they have no fixture: held here to what that code does, read line by line.
struct PatternShapeTests {
  func pattern() -> Pattern {
    var pattern = Pattern(id: "p", name: "P", length: 8)
    pattern.tracks["909.bd"] = [.on, .off, .accent, .off, .on, .off, .off, .on]
    pattern.tracks["909.sd"] = [.off, .on]
    pattern.trackLengths["909.bd"] = 6
    pattern.flams["909.bd"] = [true, false, false, false, false, false, false, false]
    pattern.bass["303.a"] = [BassStep(note: 3), .rest, BassStep(note: 7, accent: true)]
    pattern.pcf = [.on, .off, .off, .off, .accent, .off, .off, .off]
    return pattern
  }

  @Test func shorteningAndLengtheningAgainGivesTheTailBack() {
    let short = pattern().resizing(to: 4)
    #expect(short.length == 4)
    #expect(short.tracks["909.bd"] == [.on, .off, .accent, .off])
    // Written out at the new length, rests where nothing was.
    #expect(short.tracks["909.sd"] == [.off, .on, .off, .off])
    #expect(short.bass["303.a"]?.count == 4)
    #expect(short.flams["909.bd"] == [true, false, false, false])
    #expect(short.pcf == [.on, .off, .off, .off])
    // A loop of six in a pattern of four is the whole pattern, so it is not written.
    #expect(short.trackLengths["909.bd"] == nil)

    let long = pattern().resizing(to: 12)
    #expect(long.tracks["909.bd"]?.prefix(8) == pattern().tracks["909.bd"]?.prefix(8))
    #expect(long.tracks["909.bd"]?.suffix(4) == [.off, .off, .off, .off])
    #expect(long.trackLengths["909.bd"] == 6)
    #expect(long.bass["303.a"]?[2] == BassStep(note: 7, accent: true))
    #expect(long.bass["303.a"]?[11] == .rest)
  }

  @Test func aLengthIsOneToSixtyFourSteps() {
    #expect(pattern().resizing(to: 0).length == 1)
    #expect(pattern().resizing(to: 500).length == 64)
  }

  @Test func clearingTakesTheDrumsAndTheLinesBoth() {
    let cleared = pattern().clearingAll()
    #expect(cleared.tracks.isEmpty)
    #expect(cleared.bass.isEmpty)
    #expect(cleared.flams.isEmpty)
    #expect(cleared.trackLengths.isEmpty)
    #expect(cleared.length == 8)
    #expect(cleared.name == "P")
  }
}
