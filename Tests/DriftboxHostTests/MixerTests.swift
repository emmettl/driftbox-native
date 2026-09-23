import DriftboxHost
import Synchronization
import Testing

/// Renders a constant and counts what is asked of it, so a test can tell both that it was called
/// and what reached the mix.
final class ConstantSource: @unchecked Sendable {
  let frames = Atomic<Int>(0)
  let level: Float
  init(level: Float = 0) { self.level = level }

  var source: RenderSource {
    RenderSource(
      context: Unmanaged.passUnretained(self).toOpaque(),
      render: { context, frames, left, right in
        Unmanaged<ConstantSource>.fromOpaque(context)._withUnsafeGuaranteedRef { constant in
          constant.frames.add(frames, ordering: .relaxed)
          left.update(repeating: constant.level, count: frames)
          right.update(repeating: -constant.level, count: frames)
        }
      },
      sampleRate: 48000, owner: self)
  }
}

/// The mixer every platform's output renders through.
struct MixerTests {
  /// One call of the mixer, as a render thread makes it, into buffers that start out dirty.
  func mix(_ mixer: Mixer, frames: Int) -> (left: [Float], right: [Float]) {
    let buffers = (0..<4).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
    defer { for buffer in buffers { buffer.deallocate() } }
    for buffer in buffers { buffer.initialize(repeating: 9, count: frames) }
    mixer.render(
      frames: frames, left: buffers[0], right: buffers[1], scratchLeft: buffers[2], scratchRight: buffers[3]
    )
    return (
      Array(UnsafeBufferPointer(start: buffers[0], count: frames)),
      Array(UnsafeBufferPointer(start: buffers[1], count: frames))
    )
  }

  @Test func sourcesAreSummed() {
    let mixer = Mixer()
    let a = ConstantSource(level: 0.25)
    let b = ConstantSource(level: 0.5)
    mixer.add(a.source)
    mixer.add(b.source)
    let mixed = mix(mixer, frames: 64)
    #expect(mixed.left.allSatisfy { $0 == 0.75 })
    #expect(mixed.right.allSatisfy { $0 == -0.75 })
    #expect(a.frames.load(ordering: .relaxed) == 64)
  }

  @Test func aSourceRemovedIsNotCalledAgain() {
    let mixer = Mixer()
    let a = ConstantSource()
    mixer.add(a.source)
    mixer.remove(a.source.context)
    let mixed = mix(mixer, frames: 16)
    #expect(mixed.left.allSatisfy { $0 == 0 })
    #expect(a.frames.load(ordering: .relaxed) == 0)
    #expect(mixer.sources.isEmpty)
  }

  @Test func withNothingAttachedItRendersSilence() {
    let mixed = mix(Mixer(), frames: 8)
    #expect(mixed.left.allSatisfy { $0 == 0 })
    #expect(mixed.right.allSatisfy { $0 == 0 })
  }
}
