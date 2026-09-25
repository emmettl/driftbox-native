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

  /// Where an app the source plays inside has its transport, from the render thread at the start
  /// of a block, before that block is rendered: `beat` quarter notes from the app's top, and
  /// whether it is moving. Called when it starts or stops or jumps, so the source starts on the
  /// block the app does, and at the beat it is on.
  public typealias Locate =
    @convention(c) (_ context: UnsafeMutableRawPointer, _ beat: Double, _ moving: Bool) -> Void

  public let context: UnsafeMutableRawPointer
  public let render: Render
  /// For a source with a transport of its own to put where the app's is; nil for one without.
  public let locate: Locate?
  /// The rate it renders at, which is the rate it expects to be played at.
  public let sampleRate: Double
  /// What keeps `context` alive for as long as a device might call it. Held by whoever attaches
  /// the source, on the interface's thread; the device's thread never touches it.
  public let owner: AnyObject

  public init(
    context: UnsafeMutableRawPointer, render: Render, locate: Locate? = nil, sampleRate: Double,
    owner: AnyObject
  ) {
    self.context = context
    self.render = render
    self.locate = locate
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
      locate: { context, beat, moving in
        Unmanaged<EngineHost>.fromOpaque(context)._withUnsafeGuaranteedRef {
          $0.locate(beat: beat, moving: moving)
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
      locate: { context, beat, moving in
        Unmanaged<RackHost>.fromOpaque(context)._withUnsafeGuaranteedRef {
          $0.locate(beat: beat, moving: moving)
        }
      },
      sampleRate: sampleRate, owner: self)
  }
}
