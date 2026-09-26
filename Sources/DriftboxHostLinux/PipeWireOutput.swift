#if os(Linux)
  import CPipeWireBridge
  import DriftboxHost
  import Glibc

  public struct PipeWireError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
  }

  /// A default-output stream. Control operations belong to the main actor; PipeWire renders on
  /// its realtime thread. A future AudioRouting adapter will add device discovery and recovery.
  @MainActor
  public final class PipeWireOutput {
    public let sampleRate: Double
    private var stream: OpaquePointer?
    private let callback = Callback()
    private var finalFrames: UInt64 = 0

    public var renderedFrames: UInt64 { stream.map(db_pw_frames) ?? finalFrames }

    public init(sampleRate: Double = 48000) throws {
      guard sampleRate.isFinite, (8000...192000).contains(sampleRate),
        sampleRate.rounded() == sampleRate
      else { throw PipeWireError("unsupported source sample rate") }
      self.sampleRate = sampleRate
      var error = [CChar](repeating: 0, count: 512)
      let context = Unmanaged.passUnretained(callback).toOpaque()
      guard
        let opened = db_pw_open(
          renderPipeWire, context, UInt32(sampleRate), &error, error.count)
      else {
        throw PipeWireError(
          String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
      }
      stream = opened
      do {
        // A connected but unlinked stream is not a working audio output.
        let began = HostTime.now()
        while try !isStreaming() {
          guard HostTime.seconds(from: began, to: HostTime.now()) < 5 else {
            throw PipeWireError("no running PipeWire output after 5 seconds")
          }
          usleep(10_000)
        }
      } catch {
        stop()
        throw error
      }
    }

    isolated deinit { stop() }

    /// PipeWire handles conversion from this fixed source rate to the graph/device rate.
    public func attach(_ source: RenderSource) throws {
      guard let stream else { throw PipeWireError("the output has stopped") }
      guard source.sampleRate == sampleRate else {
        throw PipeWireError("source rate differs from the output's \(sampleRate) Hz")
      }
      db_pw_pause(stream)
      callback.mixer.rendering.store(false, ordering: .releasing)
      callback.mixer.add(source)
      callback.mixer.rendering.store(true, ordering: .releasing)
      db_pw_enable(stream)
    }

    /// The gate waits for the source callback before releasing its owner or old mixer table.
    public func detach(_ context: UnsafeMutableRawPointer) {
      guard let stream else { return }
      db_pw_pause(stream)
      callback.mixer.rendering.store(false, ordering: .releasing)
      callback.mixer.remove(context)
      if !callback.mixer.sources.isEmpty {
        callback.mixer.rendering.store(true, ordering: .releasing)
        db_pw_enable(stream)
      }
    }

    public func isStreaming() throws -> Bool {
      guard let stream else { throw PipeWireError("the output has stopped") }
      var error = [CChar](repeating: 0, count: 512)
      let state = db_pw_status(stream, &error, error.count)
      guard state >= 0 else {
        throw PipeWireError(
          String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
      }
      return state == 2
    }

    public func stop() {
      guard let stream else { return }
      db_pw_pause(stream)
      finalFrames = db_pw_frames(stream)
      db_pw_close(stream)
      self.stream = nil
      callback.mixer.rendering.store(false, ordering: .releasing)
      for source in callback.mixer.sources { callback.mixer.remove(source.context) }
    }
  }

  // Declared outside the main-actor output so Swift does not attach actor isolation to the
  // C callback. PipeWire invokes this on its own realtime thread.
  private func renderPipeWire(
    context: UnsafeMutableRawPointer?, frames: Int,
    left: UnsafeMutablePointer<Float>?, right: UnsafeMutablePointer<Float>?
  ) {
    guard let context, let left, let right else { return }
    Unmanaged<Callback>.fromOpaque(context)._withUnsafeGuaranteedRef {
      $0.render(frames: frames, left: left, right: right)
    }
  }

  private final class Callback {
    let mixer = Mixer()
    // The C bridge splits arbitrarily large PipeWire buffers into chunks of at most 4096.
    let left = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    let right = UnsafeMutablePointer<Float>.allocate(capacity: 4096)

    deinit {
      left.deallocate()
      right.deallocate()
    }

    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
      mixer.render(frames: frames, left: left, right: right, scratchLeft: self.left, scratchRight: self.right)
      mixer.buffers.add(1, ordering: .releasing)
    }
  }
#endif
