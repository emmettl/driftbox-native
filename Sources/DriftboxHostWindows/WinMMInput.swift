#if os(Windows)
  import DriftboxHost
  import DriftboxSeq
  import Foundation
  import Synchronization
  import WinSDK

  /// Every MIDI input WinMM has, as it arrives, less any it has been told to ignore: Windows'
  /// `MIDIInputPort`. Callbacks are called on WinMM's own thread, as CoreMIDI's are on the Mac.
  ///
  /// Unchecked because of `watch`, which is written in `init` and nowhere else; the rest is behind
  /// its locks.
  public final class WinMMInput: MIDIInputPort, @unchecked Sendable {
    private struct State {
      var ordered: [String] = []
      var ignoring: Set<String> = []
      var onNote: (@Sendable (Int, Double) -> Void)?
      var onMessage: (@Sendable ([UInt8]) -> Void)?
      var onClock: (@Sendable (ClockMessage, Double) -> Void)?
      var onSourcesChange: (@Sendable ([String]) -> Void)?
    }

    /// One open device: what its callback is given to find its way back here. Written only before it
    /// is published, so shared between threads without harm.
    private final class Port: @unchecked Sendable {
      let name: String
      weak var input: WinMMInput?
      var handle: HMIDIIN?
      init(name: String, input: WinMMInput) {
        self.name = name
        self.input = input
      }
    }

    private let state = Mutex(State())
    /// The open ports. Opened and closed on the watch's queue or while being made, never both.
    private let ports = Mutex<[Port]>([])
    private var watch: WinMM.Watch?

    public var onNote: (@Sendable (Int, Double) -> Void)? {
      get { state.withLock { $0.onNote } }
      set { state.withLock { $0.onNote = newValue } }
    }

    public var onMessage: (@Sendable ([UInt8]) -> Void)? {
      get { state.withLock { $0.onMessage } }
      set { state.withLock { $0.onMessage = newValue } }
    }

    public var onClock: (@Sendable (ClockMessage, Double) -> Void)? {
      get { state.withLock { $0.onClock } }
      set { state.withLock { $0.onClock = newValue } }
    }

    public var onSourcesChange: (@Sendable ([String]) -> Void)? {
      get { state.withLock { $0.onSourcesChange } }
      set { state.withLock { $0.onSourcesChange = newValue } }
    }

    public var sources: [String] { state.withLock { $0.ordered } }

    public var ignoring: Set<String> {
      get { state.withLock { $0.ignoring } }
      set { state.withLock { $0.ignoring = newValue } }
    }

    public init() {
      open(WinMM.inputNames())
      watch = WinMM.Watch(list: WinMM.inputNames) { [weak self] names in self?.open(names) }
    }

    deinit { closeAll() }

    /// Every device there is, opened afresh: WinMM's numbering has moved if the list has.
    private func open(_ names: [String]) {
      closeAll()
      var opened: [Port] = []
      for (index, name) in names.enumerated() {
        let port = Port(name: name, input: self)
        var handle: HMIDIIN?
        let context = DWORD_PTR(UInt(bitPattern: Unmanaged.passUnretained(port).toOpaque()))
        let callback = DWORD_PTR(unsafeBitCast(Self.callback, to: UInt.self))
        guard
          midiInOpen(&handle, UINT(index), callback, context, DWORD(CALLBACK_FUNCTION)) == MMSYSERR_NOERROR
        else { continue }
        port.handle = handle
        midiInStart(handle)
        opened.append(port)
      }
      ports.withLock { $0 = opened }
      let announce = state.withLock { state in
        state.ordered = names
        return state.onSourcesChange
      }
      announce?(names)
    }

    private func closeAll() {
      let closing = ports.withLock { ports in
        defer { ports = [] }
        return ports
      }
      for port in closing {
        midiInStop(port.handle)
        midiInReset(port.handle)
        // Returns once the callback is done with the port, which is kept alive until then by
        // `closing` itself.
        midiInClose(port.handle)
      }
    }

    private static let callback: @convention(c) (HMIDIIN?, UINT, DWORD_PTR, DWORD_PTR, DWORD_PTR) -> Void = {
      _, message, instance, packed, _ in
      guard message == UINT(MIM_DATA), let pointer = UnsafeRawPointer(bitPattern: UInt(instance)) else {
        return
      }
      let port = Unmanaged<Port>.fromOpaque(pointer).takeUnretainedValue()
      port.input?.receive(UInt32(truncatingIfNeeded: packed), from: port.name)
    }

    /// A WinMM short message as its three bytes: status in the low byte, then the data.
    static func bytes(_ packed: UInt32) -> [UInt8] {
      [UInt8(packed & 0xFF), UInt8((packed >> 8) & 0x7F), UInt8((packed >> 16) & 0x7F)]
    }

    private func receive(_ packed: UInt32, from source: String) {
      let (onNote, onMessage, onClock) = state.withLock { state in
        state.ignoring.contains(source) ? (nil, nil, nil) : (state.onNote, state.onMessage, state.onClock)
      }
      guard onNote != nil || onMessage != nil || onClock != nil else { return }
      let bytes = Self.bytes(packed)
      // A channel message whole, as the Mac passes it on, before what Driftbox makes of it.
      if (0x80..<0xF0).contains(bytes[0]) { onMessage?(bytes) }
      switch MIDIMessage(status: bytes[0], bytes[1], bytes[2]) {
      case .note(let note, let velocity): onNote?(note, velocity)
      case .clock(let clock): onClock?(clock, HostTime.milliseconds())
      case nil: break
      }
    }
  }
#endif
