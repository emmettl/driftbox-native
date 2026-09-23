#if os(Android)
  import CAMidi
  import Synchronization

  /// The MIDI devices Driftbox may use on Android, as they are handed over.
  ///
  /// Android's native MIDI plays through a device but cannot find or open one: that is Java's
  /// `MidiManager`, which opens a device asynchronously and says when one comes or goes. So the app
  /// does the finding and opening, turns each device into a native one with `AMidiDevice_fromJava`,
  /// and hands it here; `AMidiInput` and `AMidiOutput` watch this and open the device's ports.
  /// Everything below the handing over is Swift.
  public final class AMidiDevices: Sendable {
    /// One device, as the ports see it.
    struct Device: @unchecked Sendable {
      let id: Int32
      let name: String
      let handle: OpaquePointer
      /// Whether it is on USB, whose driver holds a message to its stamp; other devices do not.
      let usb: Bool
    }

    private struct Watcher {
      let owner: ObjectIdentifier
      let changed: @Sendable ([Device]) -> Void
    }

    private struct State {
      var devices: [Device] = []
      var watchers: [Watcher] = []
    }

    private let state = Mutex(State())

    public init() {}

    deinit {
      for device in state.withLock({ $0.devices }) { AMidiDevice_release(device.handle) }
    }

    /// `device`, made with `AMidiDevice_fromJava`, known to Java as `id` and to people as `name`.
    /// Driftbox owns it from here, and releases it when it is removed.
    public func add(_ device: OpaquePointer, id: Int32, name: String) {
      let (devices, watchers) = state.withLock { state in
        let taken = Set(state.devices.map(\.name))
        state.devices.append(
          Device(
            id: id, name: MIDIPortNaming.unique(name, among: taken), handle: device,
            usb: AMidiDevice_getType(device) == AMIDI_DEVICE_TYPE_USB))
        return (state.devices, state.watchers)
      }
      for watcher in watchers { watcher.changed(devices) }
    }

    /// A Java `MidiDevice`, open, made native and added. False if Android would not make it native.
    /// On a thread Java is attached to, which a native method called from Java always is.
    @discardableResult
    public func add(
      java device: jobject, env: UnsafeMutablePointer<JNIEnv?>, id: Int32, name: String
    ) -> Bool {
      var native: OpaquePointer?
      guard AMidiDevice_fromJava(env, device, &native) == AMEDIA_OK, let native else { return false }
      add(native, id: id, name: name)
      return true
    }

    /// The device Java knows as `id` has gone. Its ports are closed before it is released.
    public func remove(id: Int32) {
      let (gone, devices, watchers) = state.withLock { state in
        let gone = state.devices.filter { $0.id == id }
        state.devices.removeAll { $0.id == id }
        return (gone, state.devices, state.watchers)
      }
      guard !gone.isEmpty else { return }
      for watcher in watchers { watcher.changed(devices) }
      for device in gone { AMidiDevice_release(device.handle) }
    }

    /// Call `changed` with every device now, and again whenever that changes, until `unwatch`.
    func watch(_ owner: AnyObject, _ changed: @escaping @Sendable ([Device]) -> Void) {
      let devices = state.withLock { state in
        state.watchers.append(Watcher(owner: ObjectIdentifier(owner), changed: changed))
        return state.devices
      }
      changed(devices)
    }

    func unwatch(_ owner: AnyObject) {
      state.withLock { $0.watchers.removeAll { $0.owner == ObjectIdentifier(owner) } }
    }
  }
#endif
