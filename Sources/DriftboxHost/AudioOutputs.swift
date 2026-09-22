#if os(macOS)
  import AVFoundation
  import CoreAudio
  import Foundation

  /// A device sound can go out of.
  public struct AudioOutput: Hashable, Sendable {
    /// What CoreAudio calls it this session. Not something to remember: the same interface is a
    /// different number after it has been unplugged and plugged back in.
    public var id: AudioDeviceID
    /// What it is called for good, which is what a choice of it is remembered by.
    public var uid: String
    public var name: String

    public init(id: AudioDeviceID, uid: String, name: String) {
      self.id = id
      self.uid = uid
      self.name = name
    }
  }

  /// The devices CoreAudio knows about, as the Sound settings list them.
  public enum AudioOutputs {
    /// Every device the system would itself play through, in CoreAudio's order. That leaves out
    /// devices with no outputs and the private ones CoreAudio makes for its own purposes.
    public static func all() -> [AudioOutput] {
      let system = AudioObjectID(kAudioObjectSystemObject)
      var address = address(kAudioHardwarePropertyDevices)
      var size: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
      var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
      guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
      return ids.compactMap(output)
    }

    /// The device the system is playing through right now.
    public static func systemDefault() -> AudioOutput? {
      var address = address(kAudioHardwarePropertyDefaultOutputDevice)
      var id = AudioDeviceID(0)
      var size = UInt32(MemoryLayout<AudioDeviceID>.size)
      guard
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
          == noErr, id != kAudioObjectUnknown
      else { return nil }
      return output(id)
    }

    /// Which device to play through: the one chosen, while it is there to be played through,
    /// and the system's otherwise. A chosen interface that has been unplugged is not a reason
    /// to make no sound, and it is not forgotten either — when it comes back, so does the sound.
    public static func pick(chosen: String?, among outputs: [AudioOutput], systemDefault: AudioOutput?)
      -> AudioOutput?
    {
      if let chosen, let found = outputs.first(where: { $0.uid == chosen }) { return found }
      return systemDefault
    }

    static func output(_ id: AudioDeviceID) -> AudioOutput? {
      var canBeDefault = address(
        kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeOutput)
      var yes: UInt32 = 0
      var size = UInt32(MemoryLayout<UInt32>.size)
      guard AudioObjectGetPropertyData(id, &canBeDefault, 0, nil, &size, &yes) == noErr, yes != 0,
        let uid = string(id, kAudioDevicePropertyDeviceUID),
        let name = string(id, kAudioObjectPropertyName)
      else { return nil }
      return AudioOutput(id: id, uid: uid, name: name)
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
      var address = address(selector)
      var value: Unmanaged<CFString>?
      var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
      guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
      return value?.takeRetainedValue() as String?
    }

    static func address(
      _ selector: AudioObjectPropertySelector,
      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
      AudioObjectPropertyAddress(
        mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
  }

  /// Where an `AVAudioEngine`'s sound goes, kept there.
  ///
  /// Three things move it. A person choosing a device. A device coming or going, or the system's
  /// own choice changing, which CoreAudio says on the system object. And the engine itself, which
  /// stops whenever its device changes under it — a new sample rate, a new channel count, the
  /// device unplugged — posts `AVAudioEngineConfigurationChange`, and stays stopped until
  /// somebody starts it again. All three end in `apply`, which works out where the sound should
  /// be going from scratch and puts it there, so it does not matter which of them arrived first
  /// or how many of them one unplugging sets off.
  @MainActor
  public final class AudioRoute {
    private let engine: AVAudioEngine
    /// The device chosen, by its UID; nil for whatever the system is playing through.
    public var chosen: String? {
      didSet { if chosen != oldValue { apply() } }
    }
    /// Every device there is, as of the last change to any of them.
    public private(set) var outputs: [AudioOutput] = []
    /// The device the sound is going out of.
    public private(set) var current: AudioOutput?
    /// The device the system is playing through, which is where the sound goes when nothing
    /// else has been chosen, or what has been is not there.
    public private(set) var systemDefault: AudioOutput?
    /// Why there is no sound, if there is none.
    public private(set) var error: String?
    /// Called after every `apply`, for whoever is showing any of the above.
    public var onChange: (() -> Void)?

    private let listeners = Listeners()

    public init(engine: AVAudioEngine, chosen: String? = nil) {
      self.engine = engine
      self.chosen = chosen
      let changed: @Sendable () -> Void = { [weak self] in
        // CoreAudio's blocks are given the main queue, and the engine's notification is posted
        // on whatever thread noticed the change.
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply() } }
      }
      listeners.observe(engine: engine, changed)
      apply()
    }

    /// Point the engine at the device it should be playing through, and make sure it is.
    public func apply() {
      defer { onChange?() }
      outputs = AudioOutputs.all()
      systemDefault = AudioOutputs.systemDefault()
      guard
        let target = AudioOutputs.pick(chosen: chosen, among: outputs, systemDefault: systemDefault)
      else {
        current = nil
        error = "There is nothing to play through."
        return
      }
      do {
        if device != target.id {
          engine.stop()
          try setDevice(target.id)
        }
        if !engine.isRunning {
          // The mixer's connection to the output keeps the format it was made at, the old
          // device's, until it is made again; Apple's word on the configuration change is that
          // reconnecting is the app's job.
          engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
          engine.prepare()
          try engine.start()
        }
        current = target
        error = nil
      } catch {
        current = nil
        self.error = "\(target.name) could not be played through: \(error.localizedDescription)"
      }
    }

    /// The device the engine's output unit is set to.
    var device: AudioDeviceID? {
      guard let unit = engine.outputNode.audioUnit else { return nil }
      var id = AudioDeviceID(0)
      var size = UInt32(MemoryLayout<AudioDeviceID>.size)
      let status = AudioUnitGetProperty(
        unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
      return status == noErr ? id : nil
    }

    private func setDevice(_ id: AudioDeviceID) throws {
      guard let unit = engine.outputNode.audioUnit else { return }
      var id = id
      let status = AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
        UInt32(MemoryLayout<AudioDeviceID>.size))
      if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    /// What the route listens to, held apart from it so it can be let go of from `deinit`,
    /// which does not run on the main actor.
    private final class Listeners: @unchecked Sendable {
      private var observer: NSObjectProtocol?
      private var block: AudioObjectPropertyListenerBlock?
      private let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice]

      func observe(engine: AVAudioEngine, _ changed: @escaping @Sendable () -> Void) {
        observer = NotificationCenter.default.addObserver(
          forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in changed() }
        let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
        for selector in selectors {
          var address = AudioOutputs.address(selector)
          AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
        }
        self.block = block
      }

      deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let block {
          for selector in selectors {
            var address = AudioOutputs.address(selector)
            AudioObjectRemovePropertyListenerBlock(
              AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
          }
        }
      }
    }
  }
#endif
