#if os(Windows)
  import DriftboxShell
  import Foundation
  import WinSDK

  /// Windows' own panels for opening and saving a file: the common dialogs, which Windows shows as
  /// its current Explorer-style one.
  enum Win32Files {
    /// A file to open, of one of `types`; nil when cancelled.
    static func open(owner: HWND?, types: [FileType]) -> URL? {
      run(owner: owner, types: types, name: nil, defaultExtension: nil, saving: false)
    }

    /// Where to save a file of `type`, starting from `name`; nil when cancelled.
    static func save(owner: HWND?, type: FileType, name: String) -> URL? {
      run(owner: owner, types: [type], name: name, defaultExtension: type.extensions.first, saving: true)
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
      owner: HWND?, types: [FileType], name: String?, defaultExtension: String?, saving: Bool
    ) -> URL? {
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
            return saving ? GetSaveFileNameW(&dialog) : GetOpenFileNameW(&dialog)
          }
        }
      }
      guard chosen else { return nil }
      let end = path.firstIndex(of: 0) ?? path.count
      return URL(fileURLWithPath: String(decoding: path[..<end], as: UTF16.self))
    }
  }
#endif
