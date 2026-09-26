import DriftboxDocument
import DriftboxInterface
import DriftboxRackSession
import DriftboxShell
import Foundation

/// The rack, in the window in the groovebox's place: what it hears while it shows, and how it is
/// named. The groovebox plays on underneath, as it would with its window out of sight on the Mac.
extension Desktop {
  /// Show the rack, or the groovebox again. The keys held on the one are let go of before the
  /// other hears any.
  func setShowsRack(_ shows: Bool) {
    guard shows != showsRack, rack != nil else { return }
    if shows {
      session.padRelease()
      // The plug-ins installed, found while the rack is looked at, for its Add menu.
      rack?.findPlugins()
    } else {
      rackInterface?.releaseKeys()
    }
    showsRack = shows
    refresh()
  }

  /// What the window hears, while the rack shows: the pointer, the wheel and the keys are the
  /// rack's. False for what is not, which the groovebox's handling takes as ever.
  func handleRack(_ event: ShellEvent) -> Bool {
    guard let rackInterface else { return false }
    switch event {
    case .pointer(let pointer) where pointer.button == 1:
      if pointer.phase == .began, let menu = rackInterface.menu(at: pointer.location) {
        pop(menu, at: pointer.location, for: rackInterface)
      }
      return true
    case .pointer(let pointer):
      rackInterface.pointer(pointer)
      takeRequests(from: rackInterface)
      return true
    case .accessibility(let action):
      // A screen reader's press, as a click: what it asks for asked of the window as a click's is.
      rackInterface.perform(action)
      takeRequests(from: rackInterface)
      return true
    case .dropped(let urls, let at):
      // Onto a module that holds recordings; anything else is the window's, as a song is.
      return rackInterface.drop(urls, at: at)
    case .scroll(let scroll):
      rackInterface.scroll(scroll)
      return true
    case .key(let key):
      return rackInterface.key(key)
    default:
      return false
    }
  }

  /// What a press on the rack asked the window for: a menu, the song edited in the groovebox, or
  /// files to load into a module.
  private func takeRequests(from rackInterface: RackInterface) {
    if let request = rackInterface.takeMenuRequest() {
      pop(request.menu, at: request.at, for: rackInterface)
    }
    if rackInterface.takeSongRequest() { editRackSong() }
    if let module = rackInterface.takeFileRequest() {
      // A set for a Multisampler, several at once; one file for anything else.
      let urls =
        rackInterface.takesSeveral(module)
        ? window.chooseFiles(ofTypes: [Self.audio])
        : window.chooseFile(ofTypes: [Self.audio]).map { [$0] } ?? []
      if !urls.isEmpty { rackInterface.load(urls, into: module) }
    }
  }

  /// The rack's song opened in the groovebox, linked, and the groovebox shown in the rack's place:
  /// each edit there plays on in the rack. Whatever is unsaved in the groovebox is asked about
  /// first, as this replaces it.
  func editRackSong() {
    guard let rack, let song = rack.song, mayLoseChanges() else { return }
    session.link(
      song, name: rack.name, edited: { [weak rack] edited in rack?.songEdited(edited) },
      ended: { [weak rack] in rack?.songLinked = false })
    rack.songLinked = true
    setShowsRack(false)
  }

  /// What a face loads: WAV, which the rack reads on every platform.
  static let audio = FileType(name: "WAV Audio", extensions: ["wav", "wave"])

  /// Files dropped where nothing else took them: the first song among them opened, as Open would.
  func openDropped(_ urls: [URL]) {
    guard let song = urls.first(where: { SongFile.isSong(fileName: $0.lastPathComponent) }),
      mayLoseChanges()
    else { return }
    session.open(file: song)
    setShowsRack(false)
  }

  private func pop(_ menu: Menu, at point: SIMD2<Float>, for rack: RackInterface) {
    let chosen = window.popUp(
      menu, at: point, isEnabled: { rack.menuIsEnabled($0) }, isChecked: { rack.menuIsChecked($0) })
    if let chosen { rack.choose(chosen) }
  }

  /// The rack's title: its patch, and the program's name after it.
  static func title(for rack: RackSession) -> String { "\(rack.name) - Driftbox Rack" }
}
