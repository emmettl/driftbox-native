#if canImport(AVFoundation)
  import AVFoundation
  import DriftboxDocument
  import DriftboxHost
  import DriftboxHostMac
  import DriftboxRackSession
  import Foundation

  /// The rack inside another app: the `RackSession` every platform shares, behind the rack's Audio
  /// Unit, and what the app loading it says, carried into the session.
  ///
  /// - The rack is made at the rate the app asks for when it readies the unit, and made again if it
  ///   asks for another, keeping the patch; until then there is nothing to play.
  /// - The app's presets are the factory patches, since the extension has no face of its own yet;
  ///   its saved state is the patch, as a document, and restoring one opens it.
  /// - The app's MIDI plays the rack through its MIDI modules, as a controller plugged into the
  ///   Mac would; and the rack follows the app's tempo and runs when its transport does.
  ///
  /// Everything the unit hears arrives on the app's threads, and is carried to the main actor, where
  /// the session lives: the hooks are made below, off the main actor, since a closure made on it
  /// traps when another thread calls it.
  @MainActor
  public final class RackPlugin {
    private weak var unit: RackAudioUnit?
    public private(set) var session: RackSession?
    /// A state restored before there was a rack to open it in.
    private var pending: (document: String, name: String?)?
    private var timer: Timer?

    init(unit: RackAudioUnit) {
      self.unit = unit
      unit.presetNames = PatchEntry.all.map(\.name)
    }

    /// Give `unit` a rack to play, with everything it hears carried to it.
    nonisolated public static func attach(to unit: RackAudioUnit) {
      // Handed to the main actor to be set up, and only set up there; the render thread reads what
      // the unit keeps for it, not the unit.
      let held = Held(unit: unit)
      let plugin = onMain { RackPlugin(unit: held.unit) }
      unit.owner = plugin
      unit.prepare = { [weak plugin] rate in onMain { plugin?.prepare(rate) } }
      unit.choosePreset = { [weak plugin] number in onMain { plugin?.choose(number) } }
      unit.restore = { [weak plugin] document, name in onMain { plugin?.restore(document, name: name) } }
    }

    /// `work` on the main actor, now: in place when already there, and waited for when not.
    nonisolated static func onMain<T: Sendable>(_ work: @escaping @MainActor () -> T) -> T {
      if Thread.isMainThread { return MainActor.assumeIsolated(work) }
      return DispatchQueue.main.sync { MainActor.assumeIsolated(work) }
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
      unit.host = fresh.host
      fresh.listen()
      if timer == nil {
        // Often enough that a note played in the app is heard within a buffer or two of it.
        timer = Timer.scheduledTimer(withTimeInterval: 0.002, repeats: true) { [weak self] _ in
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
    func tick() {
      guard let unit, let session else { return }
      while let bytes = unit.nextMIDI() { session.midi(bytes) }
      if let tempo = unit.appTempo, abs(tempo - session.tempo) > 0.005 { session.setTempo(tempo) }
      if let playing = unit.appPlaying, playing != session.running { session.toggleRunning() }
    }

    isolated deinit {
      timer?.invalidate()
      session?.close()
    }
  }

  /// A unit crossing to the main actor, which `AUAudioUnit`, not being `Sendable`, may not on its own.
  struct Held: @unchecked Sendable {
    let unit: RackAudioUnit
  }
#endif
