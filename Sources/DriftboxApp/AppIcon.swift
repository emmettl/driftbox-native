#if canImport(AppKit)
  import AppKit

  /// The app's icon, from the library's resources, for when there is no bundle to carry it —
  /// drawn by `scripts/make-icon.swift`.
  public enum AppIcon {
    public static var image: NSImage? {
      Bundle.module.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
    }
  }
#endif
