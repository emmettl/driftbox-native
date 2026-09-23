#if canImport(AVFoundation)
  import Foundation
  import Testing

  @testable import DriftboxApp

  /// The hand-built faces' arithmetic, held to the reference's own tests of it.
  struct RackDisplayTests {
    @Test func theTunerNamesNotesAndCents() {
      let a = RackDisplay.tuning(frequency: 440, reference: 440, clarity: 0.99)
      #expect(a.detected && a.note == "A" && a.octave == 4 && a.cents == 0)
      let e = RackDisplay.tuning(frequency: 82.4069, reference: 440, clarity: 0.9)
      #expect(e.note == "E" && e.octave == 2)
      let sharp = RackDisplay.tuning(frequency: 277.1826, reference: 440, clarity: 0.9)
      #expect(sharp.note == "C♯" && sharp.octave == 4)
      #expect(abs(RackDisplay.tuning(frequency: 445, reference: 440, clarity: 0.9).cents - 19.56) < 0.05)
      #expect(abs(RackDisplay.tuning(frequency: 445, reference: 445, clarity: 0.9).cents) < 1e-5)
      #expect(!RackDisplay.tuning(frequency: 0, reference: 440, clarity: 1).detected)
      let unsure = RackDisplay.tuning(frequency: 440, reference: 440, clarity: 0.2)
      #expect(!unsure.detected && unsure.note == "—")
    }

    @Test func theMeterMapsMinusFortyEightToPlusThree() {
      #expect(RackDisplay.meterPosition(0) == 0)
      #expect(abs(RackDisplay.meterPosition(pow(10, -48 / 20))) < 1e-9)
      #expect(abs(RackDisplay.meterPosition(1) - 48 / 51) < 1e-9)
      #expect(abs(RackDisplay.meterPosition(pow(10, 3 / 20)) - 1) < 1e-9)
      #expect(RackDisplay.meterPosition(100) == 1)
      #expect(RackDisplay.meterLabel(0) == "−∞ dB")
      #expect(RackDisplay.meterLabel(1) == "+0.0 dB")
      #expect(RackDisplay.meterLabel(0.5) == "-6.0 dB")
    }

    @Test func aWaveformStaysInItsBox() {
      let points = RackDisplay.waveformPoints([-2, 0, 2], width: 100, height: 50)
      #expect(points == [CGPoint(x: 0, y: 46), CGPoint(x: 50, y: 25), CGPoint(x: 100, y: 4)])
      #expect(
        RackDisplay.waveformPoints([], width: 100, height: 50) == [
          CGPoint(x: 0, y: 25), CGPoint(x: 100, y: 25),
        ])
    }

    @Test func theLoopTimeKeepsItsTenths() {
      #expect(RackDisplay.loopTime(0) == "EMPTY")
      #expect(RackDisplay.loopTime(0.125) == "0:00.1")
      #expect(RackDisplay.loopTime(9.96) == "0:10.0")
      #expect(RackDisplay.loopTime(30) == "0:30.0")
      #expect(RackDisplay.loopTime(61.25) == "1:01.3")
    }
  }
#endif
