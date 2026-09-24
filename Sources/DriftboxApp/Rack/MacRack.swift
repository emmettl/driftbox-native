#if canImport(SwiftUI) && canImport(AVFoundation)
  import AVFoundation
  import DriftboxDocument
  import DriftboxHost
  import DriftboxHostMac
  import DriftboxRackSession
  import Foundation
  import Observation

  /// The rack as the Mac holds it: the `RackSession` every platform shares, and what only a Mac
  /// has around it — the rack's Audio Unit in the app's `AVAudioEngine`, Audio Units as its
  /// plug-ins, Core Audio reading its samples, the meters read as the Mac draws, and the groovebox
  /// window its song is edited in.
  @MainActor @Observable
  public final class MacRack {
    /// The rack itself: everything the window shows and edits.
    public let session: RackSession
    /// Why the rack cannot be heard, if its Audio Unit could not be made.
    private(set) var startFailure: String?

    /// The groovebox window: the song in it, and where the rack's song is edited.
    @ObservationIgnored weak var groovebox: Player? {
      didSet {
        session.onUnlinkSong = { [weak self] in self?.groovebox?.unlinkRack() }
      }
    }
    @ObservationIgnored private var node: AVAudioUnit?
    /// The rack's Audio Unit, once it is made, and whether it is being.
    @ObservationIgnored private(set) var unit: RackAudioUnit?
    @ObservationIgnored private var attaching = false
    @ObservationIgnored private var metering: Timer?

    /// A rack whose patch is kept in `memory` between launches, silent until `attach` gives it
    /// somewhere to go. `sampleRate` is the host's, which is the engine's.
    public init(sampleRate: Double = 48000, memory: UserDefaults? = nil) {
      session = RackSession(
        sampleRate: sampleRate, plugins: AudioUnitHosting(), decoder: AudioFileDecoder(), memory: memory)
      session.onSave = { [weak self] document, name in
        self?.unit?.saved.withLock { $0 = (document, name) }
      }
    }

    // MARK: Sound

    /// Play through `engine`: the rack's Audio Unit, made once, playing the session's host.
    /// Asynchronous, as making an Audio Unit is; the rack is heard from when it arrives.
    public func attach(to engine: AVAudioEngine) {
      guard unit == nil, !attaching else { return }
      attaching = true
      _ = Self.registered
      AVAudioUnit.instantiate(with: RackAudioUnit.componentDescription, options: []) {
        [weak self] made, failure in
        Task { @MainActor in self?.attached(made, failure, to: engine) }
      }
    }

    /// The unit registered in this process, once, as the engine's is.
    private static let registered: Void = AUAudioUnit.registerSubclass(
      RackAudioUnit.self, as: RackAudioUnit.componentDescription, name: "Driftbox Rack", version: 1)

    private func attached(_ made: AVAudioUnit?, _ failure: Error?, to engine: AVAudioEngine) {
      attaching = false
      guard let made, let unit = made.auAudioUnit as? RackAudioUnit else {
        startFailure = failure?.localizedDescription ?? "its audio unit could not be made"
        return
      }
      unit.host = session.host
      unit.restore = { [weak self] document, name in
        Task { @MainActor in self?.session.restore(document, name: name) }
      }
      engine.attach(made)
      engine.connect(made, to: engine.mainMixerNode, format: made.outputFormat(forBus: 0))
      node = made
      self.unit = unit
      unit.saved.withLock { $0 = (PatchCodec.encode(session.patch), session.name) }
      session.listen()
      metering = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.session.tick() }
      }
    }

    // MARK: The groovebox window

    /// Open the rack's song in the groovebox window, linked: each edit there plays on here in
    /// place. Whatever is unsaved in the window is asked about first, as this replaces it.
    func editInGroovebox() {
      guard let groovebox, let song = session.song else { return }
      guard SongFiles(player: groovebox).confirmDiscard() else { return }
      groovebox.link(
        song, name: session.name,
        edited: { [weak self] edited in self?.session.songEdited(edited) },
        ended: { [weak self] in self?.session.songLinked = false })
      session.songLinked = true
    }

    // MARK: Plug-ins

    /// A plug-in module's unit's own interface, brought to the front, or opened.
    func showInterface(_ moduleId: String) {
      guard let plugin = session.units[moduleId] as? AudioUnitPlugin,
        let reference = session.patch.modules.first(where: { $0.id == moduleId })?.plugin
      else { return }
      plugin.showInterface(title: "\(reference.name) — \(moduleId)")
    }

    /// Map the next param moved in a unit's own interface onto macro `macro`, opening it.
    func learnMacro(_ moduleId: String, _ macro: Int) {
      session.learnMacro(moduleId, macro)
      showInterface(moduleId)
    }
  }
#endif
