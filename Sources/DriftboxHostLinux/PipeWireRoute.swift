#if os(Linux)
  import DriftboxHost
  import Foundation

  /// Initial desktop route: the session manager's default output only. Device discovery,
  /// measured latency and reconnect are deliberately not represented as implemented.
  @MainActor
  public final class PipeWireRoute: AudioRouting {
    public var chosen: String?
    public var devices: [AudioDevice] { [] }
    private let endpoint = AudioDevice(id: "pipewire.default", name: "System default (PipeWire)")
    public var current: AudioDevice? { error == nil && output != nil ? endpoint : nil }
    public var systemDefault: AudioDevice? { current }
    public private(set) var error: String?
    public var onChange: (() -> Void)?
    public let sampleRate: Double = 48000
    public let latency: Double = 0
    public var renderedFrames: UInt64 { output?.renderedFrames ?? finalFrames }
    private var finalFrames: UInt64 = 0
    private var output: PipeWireOutput?
    private var monitor: Task<Void, Never>?
    private var lastFrames: UInt64 = 0
    private var lastProgress = HostTime.now()

    public init() {
      do { output = try PipeWireOutput() } catch { self.error = String(describing: error) }
      monitor = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
          self?.check()
        }
      }
    }
    isolated deinit { stop() }
    public func attach(_ source: RenderSource) {
      guard let output else { return }
      do { try output.attach(source) } catch { fail(error) }
    }
    public func detach(_ context: UnsafeMutableRawPointer) { output?.detach(context) }
    public func stop() {
      monitor?.cancel()
      monitor = nil
      finalFrames = output?.renderedFrames ?? finalFrames
      output?.stop()
      output = nil
    }
    private func fail(_ failure: Error) {
      stop()
      error = String(describing: failure)
      onChange?()
    }
    private func check() {
      guard let output else { return }
      do {
        let streaming = try output.isStreaming()
        let frames = output.renderedFrames
        if frames != lastFrames {
          lastFrames = frames
          lastProgress = HostTime.now()
        }
        if !streaming || HostTime.seconds(from: lastProgress, to: HostTime.now()) > 3 {
          throw PipeWireError("PipeWire output stopped; restart the app after restoring the output")
        }
      } catch { fail(error) }
    }
  }
#endif
