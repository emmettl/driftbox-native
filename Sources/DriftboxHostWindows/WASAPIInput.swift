#if os(Windows)
  import CWASAPI
  import DriftboxHost
  import Foundation
  import WinSDK

  /// Where live sound comes in from on Windows, kept there: WASAPI's `AudioCapturing`.
  ///
  /// `WASAPIRoute` turned round. The same three things move it — a choice, a device coming, going
  /// or becoming the system's, and the stream ending under it — and all of them end in `apply`,
  /// which works out from scratch what should be heard. One more thing does: having somewhere to
  /// put it. Without a `destination` no device is open, so Windows does not show the microphone in
  /// use while nothing is listening.
  @MainActor
  public final class WASAPIInput: AudioCapturing {
    public var chosen: String? {
      didSet { if chosen != oldValue { apply() } }
    }
    public var destination: LiveInput? {
      didSet { if destination !== oldValue { apply() } }
    }
    public private(set) var devices: [AudioDevice] = []
    public private(set) var current: AudioDevice?
    public private(set) var systemDefault: AudioDevice?
    public private(set) var error: String?
    public var onChange: (() -> Void)?
    public let sampleRate: Double

    private let enumerator: DeviceEnumerator?
    private var notifications: DeviceNotifications?
    private var stream: WASAPICapture?
    private var changed: (@Sendable () -> Void)?

    /// An input listening to `chosen`, or the system's device, once it has somewhere to put what
    /// it hears. `hop` is how word from another thread reaches the main actor, as for the route.
    public init(
      chosen: String? = nil, sampleRate: Double = 48000,
      hop: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = {
        DispatchQueue.main.async(execute: $0)
      }
    ) {
      self.chosen = chosen
      self.sampleRate = sampleRate
      COM.initialize(multithreaded: false)
      enumerator = DeviceEnumerator(flow: eCapture)
      let changed: @Sendable () -> Void = { [weak self] in
        hop { MainActor.assumeIsolated { self?.apply() } }
      }
      if let enumerator { notifications = DeviceNotifications(enumerator: enumerator, changed: changed) }
      self.changed = changed
      apply()
    }

    isolated deinit {
      notifications = nil
      stream?.stop()
    }

    /// List the devices, and hear the one there should be, if anything should be heard.
    public func apply() {
      defer { onChange?() }
      guard let enumerator else {
        stop()
        error = destination == nil ? nil : "Windows would not list its audio inputs."
        return
      }
      devices = enumerator.devices()
      systemDefault = enumerator.systemDefault()
      guard let destination else {
        stop()
        error = nil
        return
      }
      guard let target = AudioDevices.pick(chosen: chosen, among: devices, systemDefault: systemDefault)
      else {
        stop()
        error = "There is nothing to listen to."
        return
      }
      if let stream, stream.deviceID == target.id, !stream.invalidated.load(ordering: .acquiring) {
        current = target
        error = nil
        return
      }
      stop()
      do {
        stream = try WASAPICapture(
          deviceID: target.id, input: destination, sampleRate: sampleRate
        ) { [changed] in changed?() }
        current = target
        error = nil
      } catch {
        self.error = "\(target.name) could not be heard: \(error)"
      }
    }

    private func stop() {
      stream?.stop()
      stream = nil
      current = nil
    }
  }
#endif
