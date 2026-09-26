import DriftboxShell
import Foundation

/// The songs opened and saved lately, as the Mac's Open Recent lists them: the ten last, the latest
/// first, whichever way each came — the Open panel, a drop, Explorer handing one over, a Save As.
/// Each is told to the platform's own list too, which on Windows is the taskbar's jump list.
extension Desktop {
  static let recentKey = "files.recent"
  static let recentLimit = 10

  /// The songs, the latest first.
  public var recentFiles: [URL] {
    (memory?.stringArray(forKey: Self.recentKey) ?? []).map { URL(fileURLWithPath: $0) }
  }

  /// A song opened or saved, first in the list, and nowhere else in it.
  func noteRecent(_ url: URL) {
    guard let memory else { return }
    let path = url.standardizedFileURL.path
    memory.set(Array(([path] + others(than: path)).prefix(Self.recentLimit)), forKey: Self.recentKey)
    window.addToRecents(url)
  }

  /// Caught up with the song the session has open: a new file is one opened or saved as. Not until
  /// there is somewhere to keep it, so a song handed over at launch, opened before, is kept too.
  func noteOpenFile() {
    guard memory != nil, session.fileURL != lastFile else { return }
    lastFile = session.fileURL
    if let url = session.fileURL { noteRecent(url) }
  }

  /// Open the `index`th, over whatever is open if its changes may be lost. One that is not there any
  /// more is taken off the list, and the person told.
  func openRecent(_ index: Int) {
    let files = recentFiles
    guard files.indices.contains(index), mayLoseChanges() else { return }
    let url = files[index]
    guard FileManager.default.fileExists(atPath: url.path) else {
      memory?.set(others(than: url.standardizedFileURL.path), forKey: Self.recentKey)
      window.tell("\(url.lastPathComponent) is not there any more, so it has been taken off the list.")
      return
    }
    session.open(file: url)
  }

  func clearRecent() { memory?.removeObject(forKey: Self.recentKey) }

  /// The list's paths but `path`.
  private func others(than path: String) -> [String] {
    (memory?.stringArray(forKey: Self.recentKey) ?? []).filter { !Self.samePath($0, path) }
  }

  /// The menu's names for the songs: each file's name, and its folder's after it where two share a
  /// name.
  var recentTitles: [String] {
    let files = recentFiles
    let names = files.map(\.lastPathComponent)
    return files.map { url in
      let name = url.lastPathComponent
      guard names.filter({ $0.lowercased() == name.lowercased() }).count > 1 else { return name }
      return "\(name) — \(url.deletingLastPathComponent().lastPathComponent)"
    }
  }

  /// Whether two paths are one file: case aside, as Windows' file system has it, and the Mac's
  /// usually does.
  static func samePath(_ a: String, _ b: String) -> Bool { a.lowercased() == b.lowercased() }
}
