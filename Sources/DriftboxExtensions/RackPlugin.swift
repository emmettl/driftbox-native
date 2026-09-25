#if canImport(AVFoundation)
  import AVFoundation
  import DriftboxApp
  import DriftboxDocument
  import DriftboxHost
  import DriftboxHostMac
  import DriftboxRackSession
  import Foundation
  import Observation

  /// The rack inside another app: the `RackSession` every platform shares, behind the rack's Audio
  /// Unit, and what the app loading it says, carried into the session.
  ///
  /// - The rack is made at the rate the app asks for when it readies the unit, and made again if it
  ///   asks for another, keeping the patch; until then there is nothing to play.
  /// - Its face is the Mac app's rack window, on the same session, shown in the app's window.
  /// - The app's presets are the factory patches, from the app's own menu; its saved state is the
  ///   patch, as a document, and restoring one opens it.
  /// - The app's MIDI plays the rack through its MIDI modules, as a controller plugged into the
  ///   Mac would; and the rack follows the app's tempo, and starts and stops as its transport does,
  ///   at the app's beat, on the block it does.
  ///
  /// Everything the unit hears arrives on the app's threads, and is carried to the main actor, where
  /// the session lives: the hooks are made below, off the main actor, since a closure made on it
  /// traps when another thread calls it.
  @MainActor @Observable
  public final class RackPlugin {
    @ObservationIgnored private weak var unit: RackAudioUnit?
    public private(set) var session: RackSession?
    /// The rack's own face on that session, for the app's window: the one the Mac app's rack
    /// window shows.
    public private(set) var face: MacRack?
    /// A state restored before there was a rack to open it in.
    @ObservationIgnored private var pending: (document: String, name: String?)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var transport = TransportEdge()
    @ObservationIgnored private var ticks = 0

    init(unit: RackAudioUnit) {
      self.unit = unit
      unit.presetNames = PatchEntry.all.map(\.name)
    }

    /// Give `unit` a rack to play, with everything it hears carried to it.
    nonisolated public static func attach(to unit: RackAudioUnit) {
      // Handed to the main actor to be set up, and only set up there; the render thread reads what
      // the unit keeps for it, not the unit.
      let held = Held(unit: unit)
      let plugin = Plugins.onMain { RackPlugin(unit: held.unit) }
      unit.owner = plugin
      unit.prepare = { [weak plugin] rate in Plugins.onMain { plugin?.prepare(rate) } }
      unit.choosePreset = { [weak plugin] number in Plugins.onMain { plugin?.choose(number) } }
      unit.restore = { [weak plugin] document, name in
        Plugins.onMain { plugin?.restore(document, name: name) }
      }
    }

    /// A rack at `rate`: the one there is if it is already at it, a new one keeping its patch if not.
    func prepare(_ rate: Double) {
      guard let unit else { return }
      if let session, session.host.sampleRate == rate { return }
      let carried = session.map { (PatchCodec.encode($0.patch), $0.name as String?) } ?? pending
      session?.close()
      let fresh = RackSession(sampleRate: rate)
      if let carried { fresh.restore(carried.0, name: carried.1) }
      pending = nil
      fresh.onSave = { [weak unit] document, name in unit?.saved.withLock { $0 = (document, name) } }
      unit.saved.withLock { $0 = (PatchCodec.encode(fresh.patch), fresh.name) }
      session = fresh
      face = MacRack(session: fresh)
      unit.host = fresh.host
      fresh.listen()
      if timer == nil {
        timer = Timer.scheduledTimer(withTimeInterval: Plugins.interval, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated { self?.tick() }
        }
      }
    }

    func choose(_ number: Int) {
      guard number >= 0, number < PatchEntry.all.count, let patch = PatchEntry.all[number].load() else {
        return
      }
      let name = PatchEntry.all[number].name
      if let session {
        session.open(patch, name: name)
      } else {
        pending = (PatchCodec.encode(patch), name)
      }
    }

    func restore(_ document: String, name: String?) {
      if let session {
        session.restore(document, name: name)
      } else {
        pending = (document, name)
      }
    }

    /// What the app has said since last time: its MIDI played, its tempo and transport followed.
    /// And, as often as the face draws, the session's own tick, which its meters are read by.
    func tick() {
      guard let unit, let session else { return }
      while let bytes = unit.nextMIDI() { session.midi(bytes) }
      if let tempo = unit.appTempo, abs(tempo - session.tempo) > 0.005 { session.setTempo(tempo) }
      if let playing = transport.change(unit.appPlaying) {
        // Put where the app is on the render thread, the rack need only be told it is running; an
        // app that does not say where it is has the rack start as it would itself.
        if unit.appLocates {
          session.follow(running: playing)
        } else if playing != session.running {
          session.toggleRunning()
        }
      }
      ticks += 1
      if ticks % Plugins.sessionEvery == 0 { session.tick() }
    }

    isolated deinit {
      timer?.invalidate()
      session?.close()
    }
  }
#endif
