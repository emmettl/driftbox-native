import DriftboxHelp
import DriftboxInterface
import DriftboxShell

/// The guides, drawn over the window: Help ▸ Groovebox Guide and Rack Guide, F1 the one for what is
/// showing. While one is open it has the pointer, the wheel and the keys, and it is what a screen
/// reader is told; Esc or Close puts it away.
extension Desktop {
  /// A guide opened over the window, from its first topic.
  func showGuide(_ guide: HelpGuide) {
    help = HelpSheet(guide: guide)
    describeNow()
  }

  /// What the window hears, while a guide is open: everything a person does is the guide's. False
  /// for what is not — commands, a resize — which the window takes as ever.
  func handleHelp(_ event: ShellEvent) -> Bool {
    guard let help else { return false }
    switch event {
    case .pointer(let pointer):
      if pointer.button == 0 { help.pointer(pointer) }
    case .scroll(let scroll):
      help.scroll(scroll)
    case .key(let key):
      _ = help.key(key)
    case .accessibility(let action):
      help.perform(action)
    case .dropped:
      break
    default:
      return false
    }
    if !help.isOpen {
      self.help = nil
      describeNow()
    }
    return true
  }
}
