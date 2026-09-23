import Foundation
import Testing

@testable import DriftboxRack

/// What the rendered cases never feed a module: a pitch that is not a number, a NaN or an infinity
/// on the audio, and a sample rate a millisecond does not divide. The reference fixed each of
/// these; these hold the port to the same fixes.
struct RecoveryTests {
  typealias Bench = ControlTests.Bench

  static func defaults(_ type: String) -> [Double] {
    RackModules.registry[type]!.params.map(\.defaultValue)
  }

  static func finite(_ bench: Bench, outlet: Int = 0) -> Bool {
    (0..<bench.frames).allSatisfy { bench.outlets[outlet][$0].isFinite }
  }

  static func peak(_ bench: Bench, outlet: Int = 0) -> Double {
    (0..<bench.frames).reduce(0) { max($0, abs(Double(bench.outlets[outlet][$1]))) }
  }

  /// The scale walk steps a semitone at a time: from NaN, infinity or a pitch past a double's
  /// integers it never arrived, and the audio thread hung. Such a pitch plays the root.
  @Test(arguments: [Float.nan, .infinity, -.infinity, .greatestFiniteMagnitude])
  func aChordFromAPitchThatIsNotANoteStillComes(pitch: Float) {
    let chord = Bench("chord-player", params: Self.defaults("chord-player"))
    chord.run { _ in pitch }
    #expect(Self.finite(chord))
    if !pitch.isFinite { #expect(chord.outlets[0][0] == 0) }
  }

  @Test func driveRecoversFromANaN() {
    let drive = Bench("drive", params: Self.defaults("drive"))
    drive.run { _ in .nan }
    #expect(Self.finite(drive))
    ControlTests.sine(drive, frequency: 440, amplitude: 0.5, blocks: 1)
    #expect(Self.finite(drive))
    #expect(Self.peak(drive) > 0.1)
  }

  /// NaN in the follower read as silence, so it never compressed again; an infinite peak held the
  /// reduction at infinity, so everything after was silent.
  @Test(arguments: [Float.nan, .infinity])
  func theCompressorRecoversAndStillCompresses(hostile: Float) {
    var params = Self.defaults("compressor")
    params[5] = 0  // a hard knee
    let compressor = Bench("compressor", params: params)
    compressor.run { _ in hostile }
    #expect(Self.finite(compressor))
    #expect(Self.finite(compressor, outlet: 1))

    ControlTests.sine(compressor, frequency: 220, amplitude: 0.9, blocks: 375)
    let settled = Self.peak(compressor)
    #expect(settled < 0.8, "settled at \(settled)")
    #expect(settled > 0.1, "settled at \(settled)")
  }

  /// A millisecond rounded up, as the Clock's: 45 samples at 44.1kHz, not 44.
  @Test func theArrangersTriggerIsTheClocksWidth() {
    let arranger = Bench("arranger", params: Self.defaults("arranger"), sampleRate: 44100)
    for i in 0..<arranger.frames { arranger.inlets[1][i] = 1 }
    arranger.run { _ in 0 }
    let width = (0..<arranger.frames).firstIndex { arranger.outlets[1][$0] < 0.5 }
    #expect(width == 45)
  }
}
