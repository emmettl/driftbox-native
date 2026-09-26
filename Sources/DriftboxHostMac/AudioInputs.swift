#if os(macOS)
  import AVFoundation
  import CoreAudio
  import DriftboxHost
  import Foundation

  /// A device sound can come in from, as Core Audio knows it: described as an output is, by its
  /// number this session, its UID and its name. A device with both, an interface, is the same
  /// device either way.
  public typealias AudioInput = AudioOutput

  /// The devices CoreAudio can listen to, as the Sound settings list them under Input.
  public enum AudioInputs {
    /// Every device the system would itself listen to, in CoreAudio's order. That leaves out
    /// devices with no inputs and the private ones CoreAudio makes for its own purposes.
    public static func all() -> [AudioInput] {
      AudioOutputs.deviceIDs().compactMap(input)
    }

    /// The device the system is listening to right now.
    public static func systemDefault() -> AudioInput? {
      AudioOutputs.systemDevice(kAudioHardwarePropertyDefaultInputDevice).flatMap(input)
    }

    static func input(_ id: AudioDeviceID) -> AudioInput? {
      AudioOutputs.device(id, scope: kAudioObjectPropertyScopeInput)
    }
  }

  /// Where live sound comes in from on the Mac, kept there: Core Audio's `AudioCapturing`.
  ///
  /// `AudioRoute` turned round. A choice, a device coming, going or becoming the system's, and the
  /// device changing under the unit hearing it all end in `apply`, which works out from scratch
  /// what should be heard. So does having somewhere to put it: without a `destination` no device
  /// is open, so the menu bar does not show the microphone in use while nothing is listening, and
  /// the Mac does not ask whether Driftbox may listen until a patch wants to.
  @MainActor
  public final class AudioCapture: AudioCapturing {
    /// The device chosen, by its UID; nil for whatever the system is listening to.
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
    /// The rate what it hears is written at, the rack's; the device may run at another.
    public let sampleRate: Double

    /// What is said while the Mac is not letting Driftbox listen.
    public static let refused =
      "The Mac is not letting Driftbox listen. Turn Driftbox on in System Settings, Privacy & Security, "
      + "Microphone."

    private let listeners = SystemListeners(
      selectors: [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice])
    private var unit: InputUnit?
    /// Each device's number this session, by UID: what the unit is opened on.
    private var numbers: [String: AudioDeviceID] = [:]
    private var changed: (@Sendable () -> Void)?
    /// Whether the Mac is asking the person whether Driftbox may listen.
    private var asking = false

    /// An input listening to `chosen`, or the system's device, once it has somewhere to put what
    /// it hears.
    public init(chosen: String? = nil, sampleRate: Double = 48000) {
      self.chosen = chosen
      self.sampleRate = sampleRate
      let changed: @Sendable () -> Void = { [weak self] in
        // CoreAudio's listeners are called on a thread of its own.
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply() } }
      }
      listeners.observe(changed)
      self.changed = changed
      apply()
    }

    isolated deinit {
      unit?.stop()
    }

    /// List the devices, and hear the one there should be, if anything should be heard.
    public func apply() {
      defer { onChange?() }
      let inputs = AudioInputs.all()
      numbers = Dictionary(inputs.map { ($0.uid, $0.id) }, uniquingKeysWith: { a, _ in a })
      devices = inputs.map(\.device)
      systemDefault = AudioInputs.systemDefault()?.device
      guard let destination else {
        stop()
        error = nil
        return
      }
      switch AVAudioApplication.shared.recordPermission {
      case .granted: break
      case .undetermined:
        // Asked once, and heard from again when the person has answered.
        stop()
        error = nil
        ask()
        return
      default:
        stop()
        error = Self.refused
        return
      }
      guard
        let target = AudioDevices.pick(chosen: chosen, among: devices, systemDefault: systemDefault),
        let number = numbers[target.id]
      else {
        stop()
        error = "There is nothing to listen to."
        return
      }
      if let unit, unit.deviceID == number, unit.input === destination,
        !unit.invalidated.load(ordering: .acquiring)
      {
        current = target
        error = nil
        return
      }
      stop()
      do {
        unit = try InputUnit(device: number, input: destination, sampleRate: sampleRate) { [changed] in
          changed?()
        }
        current = target
        error = nil
      } catch {
        self.error = "\(target.name) could not be heard: \(error)"
      }
    }

    private func ask() {
      guard !asking else { return }
      asking = true
      Task { [weak self] in
        _ = await AVAudioApplication.requestRecordPermission()
        self?.asking = false
        self?.apply()
      }
    }

    private func stop() {
      unit?.stop()
      unit = nil
      current = nil
    }
  }

  /// Listeners on CoreAudio's system object, held apart from what they tell so they can be let go
  /// of from a `deinit`, which does not run on the main actor.
  final class SystemListeners: @unchecked Sendable {
    private let selectors: [AudioObjectPropertySelector]
    private var block: AudioObjectPropertyListenerBlock?

    init(selectors: [AudioObjectPropertySelector]) {
      self.selectors = selectors
    }

    func observe(_ changed: @escaping @Sendable () -> Void) {
      let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
      for selector in selectors {
        var address = AudioOutputs.address(selector)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
      }
      self.block = block
    }

    deinit {
      guard let block else { return }
      for selector in selectors {
        var address = AudioOutputs.address(selector)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
      }
    }
  }
#endif
