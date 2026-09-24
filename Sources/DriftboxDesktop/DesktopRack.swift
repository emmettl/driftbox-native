import DriftboxInterface
import DriftboxRackSession
import DriftboxShell

/// The rack, in the window in the groovebox's place: what it hears while it shows, and how it is
/// named. The groovebox plays on underneath, as it would with its window out of sight on the Mac.
extension Desktop {
  /// Show the rack, or the groovebox again. The keys held on the one are let go of before the
  /// other hears any.
  func setShowsRack(_ shows: Bool) {
    guard shows != showsRack, rack != nil else { return }
    if shows {
      session.padRelease()
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
      if let request = rackInterface.takeMenuRequest() {
        pop(request.menu, at: request.at, for: rackInterface)
      }
      return true
    case .scroll(let scroll):
      rackInterface.scroll(scroll)
      return true
    case .key(let key):
      return rackInterface.key(key)
    default:
      return false
    }
  }

  private func pop(_ menu: Menu, at point: SIMD2<Float>, for rack: RackInterface) {
    let chosen = window.popUp(
      menu, at: point, isEnabled: { rack.menuIsEnabled($0) }, isChecked: { _ in false })
    if let chosen { rack.choose(chosen) }
  }

  /// The rack's title: its patch, and the program's name after it.
  static func title(for rack: RackSession) -> String { "\(rack.name) - Driftbox Rack" }
}
