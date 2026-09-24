#if os(macOS)
  import DriftboxHost
  import AVFoundation
  import CoreAudio
  import Foundation

  /// A device sound can go out of, as Core Audio knows it: with the number it goes by this session,
  /// which the port's `AudioDevice` does not need.
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

    /// As every platform describes a device: remembered by its UID.
    public var device: AudioDevice { AudioDevice(id: uid, name: name) }
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
  ///
  /// It is the Mac's `AudioRouting`: sources attached to it are summed by a `Mixer`, as on every
  /// platform, and played by one source node into the engine's mixer, which converts to whatever
  /// the device runs at. Audio Units attached to the engine directly play beside them.
  @MainActor
  public final class AudioRoute: AudioRouting {
    /// The engine it keeps playing, for Audio Units to be attached to.
    public let engine: AVAudioEngine
    /// The device chosen, by its UID; nil for whatever the system is playing through.
    public var chosen: String? {
      didSet { if chosen != oldValue { apply() } }
    }
    /// Every device there is, as of the last change to any of them.
    public private(set) var devices: [AudioDevice] = []
    /// The device the sound is going out of.
    public private(set) var current: AudioDevice?
    /// The device the system is playing through, which is where the sound goes when nothing
    /// else has been chosen, or what has been is not there.
    public private(set) var systemDefault: AudioDevice?
    /// Why there is no sound, if there is none.
    public private(set) var error: String?
    /// Called after every `apply`, for whoever is showing any of the above.
    public var onChange: (() -> Void)?
    /// The rate attached sources render at; the engine's mixer converts to the device's.
    public let sampleRate: Double
    /// How long after a frame is rendered it is heard: what the output says it adds.
    public var latency: Double { engine.outputNode.presentationLatency }

    private let listeners = Listeners()
    private let mixer = Mixer()
    private var node: AVAudioSourceNode?
    /// Each device's number this session, by UID: what the engine's output unit is set by.
    private var numbers: [String: AudioDeviceID] = [:]

    /// A route keeping `engine` playing through `chosen`, or the system's device.
    public init(engine: AVAudioEngine = AVAudioEngine(), chosen: String? = nil, sampleRate: Double = 48000) {
      self.engine = engine
      self.chosen = chosen
      self.sampleRate = sampleRate
      let changed: @Sendable () -> Void = { [weak self] in
        // CoreAudio's blocks are given the main queue, and the engine's notification is posted
        // on whatever thread noticed the change.
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply() } }
      }
      listeners.observe(engine: engine, changed)
      apply()
    }

    isolated deinit {
      mixer.rendering.store(false, ordering: .releasing)
    }

    public func attach(_ source: RenderSource) {
      if node == nil { makeNode() }
      mixer.add(source)
    }

    public func detach(_ context: UnsafeMutableRawPointer) {
      mixer.remove(context)
    }

    /// The one node every attached source plays through: the mixer's sum, two channels at the
    /// route's rate. Its block captures the mixer and scratch it owns, nothing of the route's.
    private func makeNode() {
      guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
      let scratch = Scratch()
      let mixer = mixer
      let node = AVAudioSourceNode(format: format) { _, _, count, list in
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard buffers.count >= 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
          let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
        else { return kAudioUnitErr_InvalidParameter }
        // In pieces no longer than the scratch, for a device that asks for more than it holds.
        var done = 0
        let frames = Int(count)
        while done < frames {
          let piece = min(Scratch.frames, frames - done)
          mixer.render(
            frames: piece, left: left + done, right: right + done, scratchLeft: scratch.left,
            scratchRight: scratch.right)
          done += piece
        }
        mixer.buffers.add(1, ordering: .releasing)
        return noErr
      }
      engine.attach(node)
      engine.connect(node, to: engine.mainMixerNode, format: format)
      self.node = node
      apply()
    }

    /// Two channels of scratch for the mixer to render each source into, kept for the node's life.
    private final class Scratch: @unchecked Sendable {
      static let frames = 4096
      let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
      let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)

      deinit {
        left.deallocate()
        right.deallocate()
      }
    }

    /// Point the engine at the device it should be playing through, and make sure it is.
    public func apply() {
      defer {
        // Whether a buffer will come along to say an old table of sources is done with.
        mixer.rendering.store(engine.isRunning, ordering: .releasing)
        onChange?()
      }
      let outputs = AudioOutputs.all()
      numbers = Dictionary(outputs.map { ($0.uid, $0.id) }, uniquingKeysWith: { a, _ in a })
      devices = outputs.map(\.device)
      systemDefault = AudioOutputs.systemDefault()?.device
      guard
        let target = AudioDevices.pick(chosen: chosen, among: devices, systemDefault: systemDefault),
        let number = numbers[target.id]
      else {
        current = nil
        error = "There is nothing to play through."
        return
      }
      do {
        if device != number {
          engine.stop()
          try setDevice(number)
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
