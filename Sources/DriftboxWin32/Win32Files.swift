#if os(Windows)
  import DriftboxShell
  import Foundation
  import WinSDK

  /// Windows' own panels for opening and saving a file: the common dialogs, which Windows shows as
  /// its current Explorer-style one.
  enum Win32Files {
    /// A file to open, of one of `types`; nil when cancelled.
    static func open(owner: HWND?, types: [FileType]) -> URL? {
      run(owner: owner, types: types, name: nil, defaultExtension: nil, saving: false).first
    }

    /// Files to open, of one of `types`, as many as are chosen; empty when cancelled.
    static func openMany(owner: HWND?, types: [FileType]) -> [URL] {
      run(owner: owner, types: types, name: nil, defaultExtension: nil, saving: false, several: true)
    }

    /// Where to save a file of `type`, starting from `name`; nil when cancelled.
    static func save(owner: HWND?, type: FileType, name: String) -> URL? {
      run(owner: owner, types: [type], name: name, defaultExtension: type.extensions.first, saving: true)
        .first
    }

    /// The filter a dialog offers: each type's name and its patterns, every string ended with a
    /// nul and the whole with another — what `lpstrFilter` wants.
    static func filter(for types: [FileType]) -> [WCHAR] {
      var filter: [WCHAR] = []
      for type in types {
        let patterns = type.extensions.map { "*.\($0)" }.joined(separator: ";")
        filter += Array("\(type.name) (\(patterns))".utf16) + [0] + Array(patterns.utf16) + [0]
      }
      return filter + [0]
    }

    private static func run(
      owner: HWND?, types: [FileType], name: String?, defaultExtension: String?, saving: Bool,
      several: Bool = false
    ) -> [URL] {
      var filter = filter(for: types)
      var path = [WCHAR](repeating: 0, count: 32768)
      if let name {
        let units = Array(name.utf16.prefix(path.count - 1))
        path.replaceSubrange(0..<units.count, with: units)
      }
      var extensionUnits = defaultExtension.map { Array($0.utf16) + [0] } ?? []
      let chosen: Bool = filter.withUnsafeMutableBufferPointer { filter in
        path.withUnsafeMutableBufferPointer { path in
          extensionUnits.withUnsafeMutableBufferPointer { defaultExtension in
            var dialog = OPENFILENAMEW()
            dialog.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
            dialog.hwndOwner = owner
            dialog.lpstrFilter = UnsafePointer(filter.baseAddress)
            dialog.lpstrFile = path.baseAddress
            dialog.nMaxFile = DWORD(path.count)
            dialog.lpstrDefExt = defaultExtension.isEmpty ? nil : UnsafePointer(defaultExtension.baseAddress)
            dialog.Flags =
              DWORD(OFN_EXPLORER) | DWORD(OFN_NOCHANGEDIR) | DWORD(OFN_PATHMUSTEXIST)
              | (saving ? DWORD(OFN_OVERWRITEPROMPT) : DWORD(OFN_FILEMUSTEXIST))
              | (several ? DWORD(OFN_ALLOWMULTISELECT) : 0)
            return saving ? GetSaveFileNameW(&dialog) : GetOpenFileNameW(&dialog)
          }
        }
      }
      guard chosen else { return [] }
      // One file is its whole path. Several are the folder, then each name, every one ended with a
      // nul and the list with another.
      let parts = path.split(separator: 0, omittingEmptySubsequences: false).prefix { !$0.isEmpty }
        .map { String(decoding: $0, as: UTF16.self) }
      guard let first = parts.first else { return [] }
      guard parts.count > 1 else { return [URL(fileURLWithPath: first)] }
      let folder = URL(fileURLWithPath: first, isDirectory: true)
      return parts.dropFirst().map { folder.appendingPathComponent($0) }
    }
  }
#endif
