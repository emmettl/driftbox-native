#if os(Windows)
  import DriftboxHost
  import Foundation
  import WinSDK

  /// Where the sound goes on Windows, kept there: WASAPI's `AudioRouting`.
  ///
  /// Three things move it, as on the Mac. A person choosing a device. A device coming or going, or
  /// the system's choice changing, which Windows says through `DeviceNotifications`. And the stream
  /// itself, which ends when its device goes away under it. All three end in `apply`, which works
  /// out where the sound should be going from scratch and puts it there, so it does not matter
  /// which arrived first or how many of them one unplugging sets off.
  @MainActor
  public final class WASAPIRoute: AudioRouting {
    public var chosen: String? {
      didSet { if chosen != oldValue { apply() } }
    }
    public private(set) var devices: [AudioDevice] = []
    public private(set) var current: AudioDevice?
    public private(set) var systemDefault: AudioDevice?
    public private(set) var error: String?
    public var onChange: (() -> Void)?
    public let sampleRate: Double
    public var latency: Double { stream?.latency ?? 0 }

    private let enumerator: DeviceEnumerator?
    private var notifications: DeviceNotifications?
    private let mixer = Mixer()
    private var stream: WASAPIStream?

    /// A route playing through `chosen`, or the system's device. `hop` is how word from another
    /// thread reaches the main actor: the main dispatch queue unless the host drains something else.
    public init(
      chosen: String? = nil, sampleRate: Double = 48000,
      hop: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = {
        DispatchQueue.main.async(execute: $0)
      }
    ) {
      self.chosen = chosen
      self.sampleRate = sampleRate
      COM.initialize(multithreaded: false)
      enumerator = DeviceEnumerator()
      let changed: @Sendable () -> Void = { [weak self] in
        hop { MainActor.assumeIsolated { self?.apply() } }
      }
      if let enumerator { notifications = DeviceNotifications(enumerator: enumerator, changed: changed) }
      self.changed = changed
      apply()
    }

    private var changed: (@Sendable () -> Void)?

    isolated deinit {
      notifications = nil
      stream?.stop()
    }

    public func attach(_ source: RenderSource) {
      mixer.add(source)
    }

    public func detach(_ context: UnsafeMutableRawPointer) {
      mixer.remove(context)
    }

    /// Point a stream at the device it should be playing through, and make sure it is.
    public func apply() {
      defer { onChange?() }
      guard let enumerator else {
        current = nil
        error = "Windows would not list its audio devices."
        return
      }
      devices = enumerator.devices()
      systemDefault = enumerator.systemDefault()
      guard let target = AudioDevices.pick(chosen: chosen, among: devices, systemDefault: systemDefault)
      else {
        stream?.stop()
        stream = nil
        current = nil
        error = "There is nothing to play through."
        return
      }
      if let stream, stream.deviceID == target.id, !stream.invalidated.load(ordering: .acquiring) {
        current = target
        error = nil
        return
      }
      stream?.stop()
      stream = nil
      do {
        stream = try WASAPIStream(deviceID: target.id, mixer: mixer, sampleRate: sampleRate) { [changed] in
          changed?()
        }
        current = target
        error = nil
      } catch {
        current = nil
        self.error = "\(target.name) could not be played through: \(error)"
      }
    }
  }
#endif
