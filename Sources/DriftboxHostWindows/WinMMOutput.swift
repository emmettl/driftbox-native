#if os(Windows)
  import DriftboxHost
  import Foundation
  import Synchronization
  import WinSDK

  /// Bytes out to WinMM's devices, each at the moment it is stamped with: Windows'
  /// `MIDIOutputPort`.
  ///
  /// WinMM cannot publish a source of an application's own, so there is no virtual destination
  /// here. Something on the same machine is driven through a loopback port instead — one made in
  /// Windows MIDI Services, which WinMM lists like any other device.
  ///
  /// Unchecked because of `scheduler` and `watch`, which are written in `init` and nowhere else;
  /// the rest is behind its locks.
  public final class WinMMOutput: MIDIOutputPort, @unchecked Sendable {
    private let names = Mutex<[String]>([])
    /// Devices opened so far, by name. Only the scheduler's thread opens, uses or closes them —
    /// and `deinit`, once that thread has ended — so they need no lock.
    private var handles: [String: HMIDIOUT] = [:]
    /// Set when the device list changes: the handles are closed by the thread that uses them.
    private let stale = Atomic<Bool>(false)
    private var scheduler: MIDIScheduler?
    private var watch: WinMM.Watch?

    public var destinations: [String] { names.withLock { $0 } }
    public var offersVirtualSource: Bool { false }

    public init() {
      names.withLock { $0 = WinMM.outputNames() }
      scheduler = MIDIScheduler { [weak self] name, message in self?.deliver(message, to: name) }
      watch = WinMM.Watch(list: WinMM.outputNames) { [weak self] now in self?.devicesChanged(now) }
    }

    deinit {
      watch = nil
      scheduler = nil
      for handle in handles.values { midiOutClose(handle) }
    }

    @discardableResult
    public func send(_ bytes: [UInt8], to destination: MIDIDestination, at hostTime: UInt64) -> Bool {
      guard case .port(let name) = destination, destinations.contains(name),
        let message = Self.packed(bytes)
      else { return false }
      scheduler?.schedule(message, to: name, at: hostTime)
      return true
    }

    public func flush(_ destination: MIDIDestination) {
      guard case .port(let name) = destination else { return }
      scheduler?.drop(name)
    }

    /// One MIDI 1.0 message as WinMM's short message: status in the low byte, then the data.
    /// Nil for what does not fit in one, system exclusive above all.
    static func packed(_ bytes: [UInt8]) -> UInt32? {
      guard let status = bytes.first, status >= 0x80, status != 0xF0, status != 0xF7 else { return nil }
      let data1 = UInt32(bytes.count > 1 ? bytes[1] & 0x7F : 0)
      let data2 = UInt32(bytes.count > 2 ? bytes[2] & 0x7F : 0)
      return UInt32(status) | data1 << 8 | data2 << 16
    }

    private func devicesChanged(_ now: [String]) {
      names.withLock { $0 = now }
      // Numbers move when the list does, so every handle is suspect: they are closed and opened
      // again by name when next used.
      stale.store(true, ordering: .releasing)
    }

    /// From the scheduler's thread: the device called `name`, opened if it is not already.
    private func deliver(_ message: UInt32, to name: String) {
      if stale.exchange(false, ordering: .acquiringAndReleasing) {
        for handle in handles.values { midiOutClose(handle) }
        handles = [:]
      }
      if let handle = handles[name] {
        midiOutShortMsg(handle, DWORD(message))
        return
      }
      guard let index = WinMM.outputNames().firstIndex(of: name) else { return }
      var handle: HMIDIOUT?
      guard midiOutOpen(&handle, UINT(index), 0, 0, DWORD(CALLBACK_NULL)) == MMSYSERR_NOERROR, let handle
      else {
        return
      }
      handles[name] = handle
      midiOutShortMsg(handle, DWORD(message))
    }
  }
#endif
