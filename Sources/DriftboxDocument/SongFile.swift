/// What a song is called on disk, on every platform.
///
/// A song is the web app's JSON, byte for byte, and `SongCodec` reads it whatever the file is
/// called. What this decides is the name around it: `.driftbox`, which Windows and Android can
/// associate with Driftbox without claiming every `.json` on the machine, and which the Finder
/// is told about the same way. Songs saved before it — `.song.json` by this app, `.json` by the
/// web — still open, and keep the name they came with when saved again: a file is not renamed
/// behind anybody's back.
///
/// Plain strings rather than URLs, so that every platform's file handling and the tests can hold
/// the same rules without a file system in sight.
public enum SongFile {
  /// What a song is saved as.
  public static let fileExtension = "driftbox"

  /// Every ending a song's file may have, longest first so that `.song.json` is taken off whole.
  public static let extensions = ["driftbox", "song.json", "json"]

  /// A file for a song called `name`.
  public static func fileName(for name: String) -> String {
    "\(name).\(fileExtension)"
  }

  /// Whether a file of this name is one to offer as a song: a choice of what to show in a picker,
  /// not a promise that it will decode.
  public static func isSong(fileName: String) -> Bool {
    ending(of: fileName) != nil
  }

  /// A song's name from its file's: whichever ending it has, taken off. A file with none of them
  /// keeps its whole name, since whatever it is called is all there is to go on.
  public static func name(fromFileName fileName: String) -> String {
    guard let ending = ending(of: fileName) else { return fileName }
    let name = String(fileName.dropLast(ending.count + 1))
    return name.isEmpty ? fileName : name
  }

  /// The ending `fileName` has, matched without regard to case, as Windows and the Mac both do.
  private static func ending(of fileName: String) -> String? {
    let lowered = fileName.lowercased()
    return extensions.first { lowered.hasSuffix(".\($0)") }
  }
}
