import Foundation

#if os(Windows)
  import WinSDK
#endif

/// An export put where the person asked for it, whole or not at all.
enum ExportFile {
  /// How long to wait before each further try at putting a written file in place: 1.55 seconds in
  /// all, before the failure is the person's to hear about.
  static let pauses: [Duration] = [50, 100, 200, 400, 800].map { .milliseconds($0) }

  /// Writes `data` to `url`, replacing what is there.
  ///
  /// On Windows, Foundation's atomic write renames its temporary file the moment it closes it, and
  /// a virus scanner or the search indexer may just have opened it to look: the rename then fails as
  /// if permission were refused, and Foundation does not try again. So there the file is written
  /// beside its destination and moved into place, waiting a little for whoever is looking.
  static func write(_ data: Data, to url: URL) async throws {
    #if os(Windows)
      let partial = url.deletingLastPathComponent()
        .appendingPathComponent("\(url.lastPathComponent).\(UUID().uuidString).partial")
      do {
        try data.write(to: partial)
      } catch let error as CocoaError {
        // Said of the file the person asked for, not the one they never see.
        throw CocoaError(error.code, userInfo: [NSFilePathErrorKey: url.path, NSURLErrorKey: url])
      }
      defer { try? FileManager.default.removeItem(at: partial) }
      try await retrying(pauses, while: isHeld) { try move(partial, over: url) }
    #else
      try data.write(to: url, options: .atomic)
    #endif
  }

  /// `body`'s result, trying again after each pause while it fails in a way that may pass; once the
  /// pauses run out, its last failure.
  nonisolated(nonsending) static func retrying<Result>(
    _ pauses: [Duration], while passing: (any Error) -> Bool, _ body: () throws -> Result
  ) async throws -> Result {
    for pause in pauses {
      do {
        return try body()
      } catch let error where passing(error) {
        try await Task.sleep(for: pause)
      }
    }
    return try body()
  }

  #if os(Windows)
    /// Whether a failure is the refusal Windows gives while something else has the file open.
    private static func isHeld(_ error: any Error) -> Bool {
      (error as? CocoaError)?.code == .fileWriteNoPermission
    }

    /// Replaces `destination` with `source` in one step, as Foundation's failures describe it.
    private static func move(_ source: URL, over destination: URL) throws {
      let from = source.withUnsafeFileSystemRepresentation { String(cString: $0!) }
      let to = destination.withUnsafeFileSystemRepresentation { String(cString: $0!) }
      let moved = from.withCString(encodedAs: UTF16.self) { from in
        to.withCString(encodedAs: UTF16.self) { to in
          MoveFileExW(from, to, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
        }
      }
      guard !moved else { return }
      let code: CocoaError.Code =
        switch GetLastError() {
        case DWORD(ERROR_ACCESS_DENIED), DWORD(ERROR_SHARING_VIOLATION), DWORD(ERROR_LOCK_VIOLATION):
          .fileWriteNoPermission
        case DWORD(ERROR_DISK_FULL), DWORD(ERROR_HANDLE_DISK_FULL): .fileWriteOutOfSpace
        case DWORD(ERROR_FILE_NOT_FOUND), DWORD(ERROR_PATH_NOT_FOUND): .fileNoSuchFile
        default: .fileWriteUnknown
        }
      throw CocoaError(code, userInfo: [NSFilePathErrorKey: destination.path, NSURLErrorKey: destination])
    }
  #endif
}
