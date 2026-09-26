#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxEngine
  import DriftboxHost
  import DriftboxHostMac
  import DriftboxRackSession
  import DriftboxSession
  import Foundation
  import Observation

  /// The app's hardware, and what plays through it: one route to the device the sound goes out of,
  /// MIDI in and out, the groovebox's `Session` and the rack, and the loop that ticks them. The one
  /// place that chooses the Mac's adapters, as every platform's app has one; everything else is the
  /// sessions every platform shares.
  @MainActor @Observable
  public final class Studio {
    /// The groovebox: the song, its transport and its editing.
    public let session: Session
    /// The rack, silent until its window is first opened.
    public let rack: MacRack
    /// Where both play: the device chosen, kept there as devices come and go.
    @ObservationIgnored let route: AudioRoute
    @ObservationIgnored private var clock: Timer?

    /// A studio on the Mac's own devices, remembering what it is left with in `memory`.
    public init(memory: UserDefaults = .standard) {
      let route = AudioRoute()
      let midiIn = MIDIInput()
      let midiOut = MIDIOutput()
      // The input never hears the app's own output: it would only ever be the app's own clock
      // coming back round.
      midiIn.hiding = midiOut.sourceID.map { [$0] } ?? []
      session = Session(
        host: EngineHost(sampleRate: route.sampleRate), audio: route, midiIn: midiIn, midiOut: midiOut,
        memory: memory,
        // Core MIDI calls from a thread of its own; everything the session holds is the main actor's.
        hop: { work in DispatchQueue.main.async(execute: work) })
      rack = MacRack(sampleRate: route.sampleRate, memory: memory)
      rack.groovebox = session
      session.midiListener = rack.session
      self.route = route
      clock = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.tick() }
      }
    }

    /// As often as the app draws: where the song is, what struck, the clock out, and the rack's
    /// meters.
    func tick() {
      session.tick()
      rack.session.tick()
    }

    /// The rack heard from now on, through the same device as the groovebox.
    public func openRack() {
      rack.attach(to: route)
    }
  }
#endif
