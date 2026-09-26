#if os(Linux)
  import DriftboxHost
  import Foundation

  /// Sink names persist across PipeWire reconnects; numeric registry IDs are never preferences.
  /// Discovery and stream negotiation run on PipeWire threads, observed from the main actor.
  @MainActor
  public final class PipeWireRoute: AudioRouting {
    public var chosen: String? {
      didSet {
        guard chosen != oldValue else { return }
        retryAt = 0
        check()
        onChange?()
      }
    }
    public private(set) var devices: [AudioDevice] = []
    public private(set) var current: AudioDevice?
    public private(set) var systemDefault: AudioDevice?
    public private(set) var error: String? = "Connecting to PipeWire…"
    public var onChange: (() -> Void)?
    public let sampleRate: Double = 48000
    public let latency: Double = 0
    public var renderedFrames: UInt64 { finalFrames + (output?.renderedFrames ?? 0) }
    private var finalFrames: UInt64 = 0
    private var output: PipeWireOutput?
    private var discovery: PipeWireDevices?
    private var selectedID: String?
    // Kept across stream loss, but removed only after detach's callback barrier has returned.
    private var sources: [RenderSource] = []
    private var monitor: Task<Void, Never>?
    private var stopped = false
    private var retryAt: UInt64 = 0
    private var discoveryAt: UInt64 = 0
    private var openedAt: UInt64 = 0
    private var lastFrames: UInt64 = 0
    private var lastProgress = HostTime.now()

    public init() {
      check()
      monitor = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
          guard let self else { return }
          self.check()
        }
      }
    }
    isolated deinit { stop() }
    public func attach(_ source: RenderSource) {
      guard !stopped else { return }
      guard source.sampleRate == sampleRate else {
        error = "Source rate differs from the output's \(sampleRate) Hz"
        onChange?()
        return
      }
      sources.removeAll { $0.context == source.context }
      sources.append(source)
      do {
        try output?.attach(source)
        lastProgress = HostTime.now()
      } catch {
        fail(error)
        onChange?()
      }
    }
    public func detach(_ context: UnsafeMutableRawPointer) {
      output?.detach(context)
      sources.removeAll { $0.context == context }
    }
    public func stop() {
      stopped = true
      monitor?.cancel()
      monitor = nil
      closeOutput()
      discovery = nil
      sources.removeAll()
      devices = []
      systemDefault = nil
      error = nil
    }
    private func closeOutput() {
      // Stop first, then read the final count: no callback may increment it after this point.
      output?.stop()
      finalFrames += output?.renderedFrames ?? 0
      output = nil
      current = nil
    }
    private func fail(_ failure: Error) {
      closeOutput()
      error = String(describing: failure)
      retryAt = HostTime.time(HostTime.now(), after: 2)
    }
    private func check() {
      guard !stopped else { return }
      let oldDevices = devices
      let oldCurrent = current
      let oldDefault = systemDefault
      let oldError = error
      defer {
        if devices != oldDevices || current != oldCurrent || systemDefault != oldDefault || error != oldError
        {
          onChange?()
        }
      }
      let now = HostTime.now()
      do {
        if discovery == nil {
          guard now >= retryAt else { return }
          discovery = try PipeWireDevices()
          discoveryAt = now
        }
        guard let snapshot = try discovery?.snapshot() else {
          if HostTime.seconds(from: discoveryAt, to: now) > 5 {
            throw PipeWireError("PipeWire device discovery timed out")
          }
          return
        }
        devices = snapshot.devices
        systemDefault = snapshot.systemDefault
      } catch {
        discovery = nil
        devices = []
        systemDefault = nil
        fail(error)
        return
      }
      let wanted = AudioDevices.pick(chosen: chosen, among: devices, systemDefault: systemDefault)
      if selectedID != wanted?.id {
        selectedID = wanted?.id
        closeOutput()
        retryAt = 0
      }
      guard let wanted else {
        error = "No PipeWire output is available"
        return
      }
      do {
        if output == nil {
          guard now >= retryAt else { return }
          let fresh = try PipeWireOutput(target: wanted.id, waitUntilStreaming: false)
          output = fresh
          openedAt = now
          lastProgress = now
          lastFrames = 0
          for source in sources { try fresh.attach(source) }
          error = "Connecting to \(wanted.name)…"
        }
        guard let output else { return }
        if try output.isStreaming() {
          current = wanted
          error = nil
          let frames = output.renderedFrames
          if frames != lastFrames || sources.isEmpty {
            lastFrames = frames
            lastProgress = now
          }
          if HostTime.seconds(from: lastProgress, to: now) > 3 {
            throw PipeWireError("PipeWire output stopped rendering; reconnecting")
          }
        } else {
          current = nil
          error = "Waiting for \(wanted.name)…"
          if HostTime.seconds(from: openedAt, to: now) > 5 {
            throw PipeWireError("PipeWire output is not streaming; reconnecting")
          }
        }
      } catch { fail(error) }
    }
  }
#endif
