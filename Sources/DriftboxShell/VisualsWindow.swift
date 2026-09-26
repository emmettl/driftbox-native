/// A second window that shows only the visuals, for a projector or a second screen: moved to a
/// display by name, and full screen there. The app draws into it as it draws into its own window,
/// through a surface the platform makes for it.
@MainActor
public protocol ShellVisualsWindow: AnyObject {
  /// The drawing area, in pixels.
  var width: Int { get }
  var height: Int { get }
  /// Pixels to a point, on the display it is on.
  var scale: Float { get }
  var isFullScreen: Bool { get }
  /// The display it is on, as `ShellWindow.displays` names it.
  var display: String? { get }
  /// What happens to it, on the main thread.
  var onEvent: ((VisualsEvent) -> Void)? { get set }

  /// Shown, on the display named if there is one by that name, and full screen there or not.
  func show(on display: String?, fullScreen: Bool)
  /// Closed by the app, as when it quits: `closed` is for a person closing it.
  func close()
}

public enum VisualsEvent: Sendable, Equatable {
  /// Its drawing area is a new size, in pixels, at `scale`.
  case resized(width: Int, height: Int, scale: Float)
  /// A key, while it is the window in front.
  case key(KeyEvent)
  /// Moved to another display, or into or out of full screen: somewhere worth remembering.
  case moved
  /// Closed by the person using it.
  case closed
}
