/// Something an audio device's thread renders: a C function and the pointer it is called with.
///
/// That shape rather than a protocol or a closure because of where it is called. A device's thread
/// calls it hundreds of times a second and must not retain, release or dispatch through a witness
/// table while it does — the rule the constrained targets keep, carried out to the one call that
/// crosses from a platform's audio API into Driftbox. A pointer and a function are the same on
/// every platform, so every platform's output can take one without knowing what is behind it.
public struct RenderSource: @unchecked Sendable {
  public typealias Render =
    @convention(c) (
      _ context: UnsafeMutableRawPointer, _ frames: Int, _ left: UnsafeMutablePointer<Float>,
      _ right: UnsafeMutablePointer<Float>
    ) -> Void

  public let context: UnsafeMutableRawPointer
  public let render: Render
  /// The rate it renders at, which is the rate it expects to be played at.
  public let sampleRate: Double
  /// What keeps `context` alive for as long as a device might call it. Held by whoever attaches
  /// the source, on the interface's thread; the device's thread never touches it.
  public let owner: AnyObject

  public init(context: UnsafeMutableRawPointer, render: Render, sampleRate: Double, owner: AnyObject) {
    self.context = context
    self.render = render
    self.sampleRate = sampleRate
    self.owner = owner
  }
}

extension EngineHost {
  /// The engine, for a device to render.
  public var renderSource: RenderSource {
    RenderSource(
      context: Unmanaged.passUnretained(self).toOpaque(),
      render: { context, frames, left, right in
        Unmanaged<EngineHost>.fromOpaque(context)._withUnsafeGuaranteedRef {
          $0.render(frames: frames, left: left, right: right)
        }
      },
      sampleRate: sampleRate, owner: self)
  }
}

extension RackHost {
  /// The rack, for a device to render.
  public var renderSource: RenderSource {
    RenderSource(
      context: Unmanaged.passUnretained(self).toOpaque(),
      render: { context, frames, left, right in
        Unmanaged<RackHost>.fromOpaque(context)._withUnsafeGuaranteedRef {
          $0.render(frames: frames, left: left, right: right)
        }
      },
      sampleRate: sampleRate, owner: self)
  }
}
