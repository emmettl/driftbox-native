#if os(Linux)
  import DriftboxHost
  import DriftboxHostLinux
  import Foundation
  import Glibc
  import Synchronization
  import Testing

  private final class Tone: @unchecked Sendable {
    let calls = Atomic<Int>(0)
    let entered = Atomic<Bool>(false)
    let completed = Atomic<Bool>(false)
    let slow: Bool
    init(slow: Bool = false) { self.slow = slow }
    var source: RenderSource {
      RenderSource(
        context: Unmanaged.passUnretained(self).toOpaque(),
        render: { context, frames, left, right in
          Unmanaged<Tone>.fromOpaque(context)._withUnsafeGuaranteedRef {
            $0.calls.add(1, ordering: .relaxed)
            if $0.slow {
              $0.entered.store(true, ordering: .releasing)
              usleep(100_000)  // Deliberately hold a test callback across detach.
              $0.completed.store(true, ordering: .releasing)
            }
            left.update(repeating: 0.125, count: frames)
            right.update(repeating: -0.25, count: frames)
          }
        }, sampleRate: 48000, owner: self)
    }
  }

  @Suite(.serialized)
  @MainActor
  struct PipeWireTests {
    @Test func invalidRatesAreRejectedWithoutOpeningADevice() {
      for rate in [Double.nan, .infinity, 0, 47999.5, 384000] {
        #expect(throws: PipeWireError.self) { _ = try PipeWireOutput(sampleRate: rate) }
      }
    }

    // Opt in only when a real or isolated test PipeWire session is available.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DRIFTBOX_TEST_PIPEWIRE"] == "1"))
    func detachStopsCallsAndReattachAndCloseAreSafe() throws {
      let output = try PipeWireOutput()
      defer { output.stop() }
      let tone = Tone()
      try output.attach(tone.source)
      usleep(300_000)
      #expect(tone.calls.load(ordering: .relaxed) > 0)
      #expect(output.renderedFrames > 0)
      output.detach(tone.source.context)
      let calls = tone.calls.load(ordering: .relaxed)
      usleep(100_000)
      #expect(tone.calls.load(ordering: .relaxed) == calls)
      try output.attach(tone.source)
      usleep(100_000)
      #expect(tone.calls.load(ordering: .relaxed) > calls)
      let source = tone.source
      let wrongRate = RenderSource(
        context: source.context, render: source.render, sampleRate: 44100, owner: tone)
      #expect(throws: PipeWireError.self) { try output.attach(wrongRate) }
      output.stop()
      let stoppedCalls = tone.calls.load(ordering: .relaxed)
      let stoppedFrames = output.renderedFrames
      usleep(100_000)
      #expect(tone.calls.load(ordering: .relaxed) == stoppedCalls)
      #expect(output.renderedFrames == stoppedFrames)
      output.stop()
      #expect(throws: PipeWireError.self) { try output.attach(source) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DRIFTBOX_TEST_PIPEWIRE"] == "1"))
    func detachedOwnersAreReleasedAndStreamsCanBeReopened() throws {
      for _ in 0..<3 {
        let output = try PipeWireOutput()
        var tone: Tone? = Tone()
        weak let owner = tone
        let context = tone!.source.context
        try output.attach(tone!.source)
        tone = nil
        #expect(owner != nil)
        usleep(50_000)
        output.detach(context)
        #expect(owner == nil)
        output.stop()
      }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DRIFTBOX_TEST_PIPEWIRE"] == "1"))
    func detachWaitsForAnInFlightCallback() throws {
      let output = try PipeWireOutput()
      defer { output.stop() }
      let tone = Tone(slow: true)
      try output.attach(tone.source)
      let began = HostTime.now()
      while !tone.entered.load(ordering: .acquiring),
        HostTime.seconds(from: began, to: HostTime.now()) < 2
      { usleep(1000) }
      try #require(tone.entered.load(ordering: .acquiring) == true)
      #expect(tone.completed.load(ordering: .acquiring) == false)
      output.detach(tone.source.context)
      #expect(tone.completed.load(ordering: .acquiring) == true)
      let count = tone.calls.load(ordering: .relaxed)
      usleep(150_000)
      #expect(tone.calls.load(ordering: .relaxed) == count)
    }
  }
#endif
