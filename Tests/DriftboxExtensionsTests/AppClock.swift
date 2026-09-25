#if canImport(AVFoundation)
  import AVFoundation
  import DriftboxHostMac
  import Synchronization

  /// A stand-in for the clock an app gives a unit: its tempo, whether its transport moves, and the
  /// beat it is on, which moves on by a block each time the unit reads it while the transport does
  /// — as a DAW's does. The tests here render in blocks of 512.
  final class AppClock: Sendable {
    private let state: Mutex<(tempo: Double, moving: Bool, beat: Double)>
    let rate: Double

    init(tempo: Double = 120, beat: Double = 0, rate: Double = 44100) {
      state = Mutex((tempo, false, beat))
      self.rate = rate
    }

    var moving: Bool {
      get { state.withLock { $0.moving } }
      set { state.withLock { $0.moving = newValue } }
    }

    /// Where the app's playhead is: set, as moving it by hand or a cycle going round is.
    var beat: Double {
      get { state.withLock { $0.beat } }
      set { state.withLock { $0.beat = newValue } }
    }

    func attach(to unit: InstrumentAudioUnit) {
      let rate = rate
      unit.musicalContextBlock = { [self] tempo, _, _, beat, _, _ in
        state.withLock { clock in
          tempo?.pointee = clock.tempo
          beat?.pointee = clock.beat
          if clock.moving { clock.beat += 512 * clock.tempo / (60 * rate) }
        }
        return true
      }
      unit.transportStateBlock = { [self] flags, _, _, _ in
        flags?.pointee = moving ? .moving : []
        return true
      }
    }
  }
#endif
