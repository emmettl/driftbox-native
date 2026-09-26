import DriftboxRack
import Foundation
import Testing

@testable import DriftboxHost

/// Live input on its way from a device's thread to the rack's: what comes in, in order, a little
/// behind, and silence rather than anything stale when there is none.
struct LiveInputTests {
  /// `frames` stereo frames counting up from `from`, the left channel positive and the right
  /// negative, so a test can see which frame went where and on which side.
  static func ramp(from: Int, frames: Int) -> [Float] {
    (0..<frames).flatMap { [Float(from + $0), -Float(from + $0)] }
  }

  static func read(_ input: LiveInput, frames: Int) -> (left: [Float], right: [Float]) {
    var left = [Float](repeating: 99, count: frames)
    var right = [Float](repeating: 99, count: frames)
    left.withUnsafeMutableBufferPointer { l in
      right.withUnsafeMutableBufferPointer { r in
        input.read(frames: frames, left: l.baseAddress!, right: r.baseAddress!)
      }
    }
    return (left, right)
  }

  static func write(_ input: LiveInput, _ samples: [Float], channels: Int = 2) {
    samples.withUnsafeBufferPointer {
      input.write($0.baseAddress!, frames: samples.count / channels, channels: channels)
    }
  }

  /// Nothing is read until what is held has come in; then it is read in order, left and right.
  @Test func itWaitsForWhatItHoldsThenReadsInOrder() {
    let input = LiveInput()
    input.prepare(hold: 256)
    Self.write(input, Self.ramp(from: 1, frames: 200))
    #expect(Self.read(input, frames: 128).left.allSatisfy { $0 == 0 }, "not yet enough in hand")
    Self.write(input, Self.ramp(from: 201, frames: 100))
    let first = Self.read(input, frames: 128)
    #expect(first.left == (1...128).map(Float.init))
    #expect(first.right == (1...128).map { -Float($0) })
    #expect(Self.read(input, frames: 128).left == (129...256).map(Float.init))
    #expect(input.received == 300)
  }

  /// Run dry, it plays what it has and silence after, then waits to have enough in hand again.
  @Test func runDryItIsSilentUntilItHasEnoughAgain() {
    let input = LiveInput()
    input.prepare(hold: 256)
    Self.write(input, Self.ramp(from: 1, frames: 300))
    _ = Self.read(input, frames: 256)
    let dry = Self.read(input, frames: 128)
    #expect(dry.left[..<44] == ArraySlice((257...300).map(Float.init)))
    #expect(dry.left[44...].allSatisfy { $0 == 0 })
    Self.write(input, Self.ramp(from: 301, frames: 128))
    #expect(Self.read(input, frames: 128).left.allSatisfy { $0 == 0 }, "128 is less than it holds")
    Self.write(input, Self.ramp(from: 429, frames: 128))
    #expect(Self.read(input, frames: 128).left == (301...428).map(Float.init))
  }

  /// Fallen far behind, it skips to the newest of what came in rather than stay late.
  @Test func fallenBehindItSkipsToTheNewest() {
    let input = LiveInput()
    input.prepare(hold: 256)
    Self.write(input, Self.ramp(from: 1, frames: 2000))
    #expect(Self.read(input, frames: 128).left == (1745...1872).map(Float.init))
  }

  /// A single channel is heard on both sides; silence is silence; and what does not fit is
  /// dropped, not written over what the reader has yet to take.
  @Test func monoSilenceAndOverflow() {
    let input = LiveInput()
    input.prepare(hold: 256)
    Self.write(input, (1...256).map(Float.init), channels: 1)
    let mono = Self.read(input, frames: 256)
    #expect(mono.left == (1...256).map(Float.init))
    #expect(mono.right == mono.left)

    input.writeSilence(frames: 300)
    #expect(Self.read(input, frames: 256).left.allSatisfy { $0 == 0 })
    #expect(input.received == 556)

    // Its newest, read after the overflow, are the last that fitted.
    let full = LiveInput()
    full.prepare(hold: 256)
    Self.write(full, Self.ramp(from: 0, frames: LiveInput.capacity + 100))
    #expect(full.received == LiveInput.capacity + 100)
    let capacity = LiveInput.capacity
    #expect(Self.read(full, frames: 128).left == (capacity - 256..<capacity - 128).map(Float.init))
  }
}

/// The rack hears live input on bus 4, where the Audio Input module listens, with or without a
/// song beside it.
struct RackHostInputTests {
  static let patch = Patch(
    modules: [
      PatchModule(id: "mic", type: "audio-input", params: ["level": 0.5]),
      PatchModule(id: "out", type: "out", params: ["level": 1]),
    ],
    cables: [PatchCable(from: PortReference("mic", "out"), to: PortReference("out", "in"))])

  @Test func theAudioInputModuleHearsTheHostsInput() {
    let host = RackHost(sampleRate: 48000)
    host.load(Self.patch)
    host.input.prepare(hold: 256)
    let quiet = RackHostTests().render(host, frames: 512, callback: 128)
    #expect(quiet.allSatisfy { $0 == 0 }, "nothing has come in")

    let tone = (0..<4800).flatMap { frame -> [Float] in
      let value = Float(sin(Double(frame) * 2 * .pi * 440 / 48000)) * 0.8
      return [value, -value]
    }
    LiveInputTests.write(host.input, tone)
    let heard = RackHostTests().render(host, frames: 2048, callback: 480)
    let loudest = heard.map(abs).max() ?? 0
    #expect(loudest > 0.2 && loudest < 0.8, "heard at the module's level, then the Out's: \(loudest)")
  }
}
