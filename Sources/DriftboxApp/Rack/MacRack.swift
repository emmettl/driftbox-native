#if canImport(SwiftUI) && canImport(AVFoundation)
  import AVFoundation
  import DriftboxDocument
  import DriftboxHost
  import DriftboxHostMac
  import DriftboxRackSession
  import DriftboxSession
  import Foundation
  import Observation

  /// The rack as the Mac holds it: the `RackSession` every platform shares, and what only a Mac
  /// has around it — Audio Units as its plug-ins, Core Audio reading its samples, and the groovebox
  /// window its song is edited in. It plays through the `Studio`'s route once its window opens.
  @MainActor @Observable
  public final class MacRack {
    /// The rack itself: everything the window shows and edits.
    public let session: RackSession
    /// Why the rack cannot be heard: why nothing can, since it plays through the groovebox's device.
    var startFailure: String? { groovebox?.outputError }

    /// The groovebox window: the song in it, and where the rack's song is edited.
    @ObservationIgnored weak var groovebox: Session? {
      didSet {
        session.onUnlinkSong = { [weak self] in self?.groovebox?.unlinkRack() }
      }
    }
    /// Whether the rack is playing through a device yet.
    @ObservationIgnored private(set) var attached = false

    /// A rack whose patch is kept in `memory` between launches, silent until `attach` gives it
    /// somewhere to go. `sampleRate` is the host's, which is the engine's; `input` is what its
    /// Audio Input modules hear.
    public init(sampleRate: Double = 48000, input: (any AudioCapturing)? = nil, memory: UserDefaults? = nil) {
      session = RackSession(
        sampleRate: sampleRate, input: input, plugins: AudioUnitHosting(), decoder: AudioFileDecoder(),
        memory: memory)
    }

    /// A face for a rack that is already playing somewhere else: in another app, behind the rack's
    /// Audio Unit, where the app renders it and nothing here attaches it to a device.
    public init(session: RackSession) {
      self.session = session
      attached = true
    }

    // MARK: Sound

    /// Play through `route` from now on, beside whatever else it plays. Once: the rack is not taken
    /// off the device again when its window closes, as a synth keeps sounding with its lid down.
    func attach(to route: any AudioRouting) {
      guard !attached else { return }
      attached = true
      route.attach(session.host.renderSource)
      session.listen()
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
