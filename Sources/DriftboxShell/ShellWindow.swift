import Foundation

/// What the app asks of a platform's window: its size, what it hears, a menu bar, a loop to draw
/// in, and the panels for choosing a file. The Windows shell answers it with Win32; Android's
/// will with a GameActivity. The Mac has AppKit and SwiftUI for all of this, and needs none of it.
@MainActor
public protocol ShellWindow: AnyObject {
  /// The drawing area, in pixels.
  var width: Int { get }
  var height: Int { get }
  /// Pixels to a point: 1 on a standard display, 2 on one at twice the density.
  var scale: Float { get }
  var title: String { get set }
  var menuBar: MenuBar? { get set }
  /// Everything the window hears, on the main thread, as it hears it.
  var onEvent: ((ShellEvent) -> Void)? { get set }
  /// Whether a command can be chosen now, asked as its menu opens. Nil, or no answer, is yes.
  var isEnabled: ((String) -> Bool)? { get set }
  /// Whether a command shows as on — a setting, or the one chosen of several — asked as its menu
  /// opens. Nil, or no answer, is off.
  var isChecked: ((String) -> Bool)? { get set }
  /// Whether the app is taking typed text, as a field being typed in does: while it is, a key held
  /// with nothing or Shift is the text's, and not a shortcut's, whatever a menu says it is.
  var takesText: Bool { get set }
  /// Whether the window may close when the person using it closes it — its close box, Alt+F4 —
  /// asked first. Nil is yes. `close` is not asked: it is the app deciding.
  var shouldClose: (() -> Bool)? { get set }

  /// Until the window closes: take what has arrived, then `frame`, and again. `frame` is also
  /// called while the window is being moved or resized, when the platform would otherwise hold the
  /// loop and leave the picture frozen, so a frame is whatever makes the window's content current.
  /// An error from a frame ends the loop and is thrown from here — one from a frame drawn inside the
  /// platform's own loop too, once that has handed back, which is why this throws and cannot rethrow.
  func run(frame: () throws -> Void) throws
  func close()

  /// `work`, on the window's thread, in its own loop, from any thread: how word from an audio
  /// device or a MIDI port reaches the interface. Through the window's loop rather than another,
  /// because the window's loop is the only one that turns while it runs — and on some platforms
  /// another would take the window's messages from under it.
  nonisolated func post(_ work: @escaping @Sendable () -> Void)

  /// A file to open, from the platform's own panel, of one of `types`. Nil when cancelled.
  func chooseFile(ofTypes types: [FileType]) -> URL?
  /// Files to open, several at once where the platform's panel allows, of `types`. Empty when
  /// cancelled.
  func chooseFiles(ofTypes types: [FileType]) -> [URL]
  /// Where to save a file of `type`, starting from `name`. Nil when cancelled.
  func chooseSaveLocation(for type: FileType, name: String) -> URL?
  /// The platform's own question before work is lost: save the changes to `name`, throw them
  /// away, or think again.
  func askToSave(_ name: String) -> SaveAnswer
  /// `menu` at `point`, in points from the window's top left, as the platform shows a context
  /// menu, until something is chosen from it or it is dismissed: the chosen command's id, or nil.
  /// Its items are greyed and ticked as `isEnabled` and `isChecked` say, asked as it is made.
  func popUp(
    _ menu: Menu, at point: SIMD2<Float>, isEnabled: (String) -> Bool, isChecked: (String) -> Bool
  ) -> String?
}

/// What someone said when asked whether to save their changes.
public enum SaveAnswer: Sendable, Equatable {
  case save
  case discard
  case cancel
}

/// A kind of file, as a panel offers it: a name, and the endings files of it have, the first being
/// what one is saved as.
public struct FileType: Sendable, Equatable {
  public var name: String
  public var extensions: [String]

  public init(name: String, extensions: [String]) {
    self.name = name
    self.extensions = extensions
  }
}

extension ShellWindow {
  /// One file, where a window has no panel for several.
  public func chooseFiles(ofTypes types: [FileType]) -> [URL] {
    chooseFile(ofTypes: types).map { [$0] } ?? []
  }
}
