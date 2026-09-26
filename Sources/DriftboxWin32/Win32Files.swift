#if os(Windows)
  import CShellDialogs
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

    /// A folder, from the Explorer-style panel Windows' own programs choose folders with, titled
    /// `title`, its button saying `button`; nil when cancelled. The common dialogs above cannot choose
    /// a folder, so this is the shell's file dialog, in COM, in the calling thread's apartment.
    static func folder(owner: HWND?, title: String, button: String) -> URL? {
      let initialized = CoInitializeEx(nil, DWORD(COINIT_APARTMENTTHREADED.rawValue))
      defer { if initialized >= 0 { CoUninitialize() } }
      var clsid = fileOpenDialog
      var iid = iidFileOpenDialog
      var raw: UnsafeMutableRawPointer?
      let made = CoCreateInstance(&clsid, nil, DWORD(CLSCTX_INPROC_SERVER.rawValue), &iid, &raw)
      guard made >= 0, let raw else { return nil }
      let dialog = raw.assumingMemoryBound(to: IFileOpenDialog.self)
      defer { _ = dialog.pointee.lpVtbl.pointee.Release(dialog) }
      let calls = dialog.pointee.lpVtbl.pointee
      var options: FILEOPENDIALOGOPTIONS = 0
      _ = calls.GetOptions(dialog, &options)
      let wanted = FOS_PICKFOLDERS.rawValue | FOS_FORCEFILESYSTEM.rawValue | FOS_PATHMUSTEXIST.rawValue
      _ = calls.SetOptions(dialog, options | FILEOPENDIALOGOPTIONS(wanted))
      _ = title.withCString(encodedAs: UTF16.self) { calls.SetTitle(dialog, $0) }
      _ = button.withCString(encodedAs: UTF16.self) { calls.SetOkButtonLabel(dialog, $0) }
      // Cancelled, it says ERROR_CANCELLED; either way there is nothing to take.
      guard calls.Show(dialog, owner) >= 0 else { return nil }
      var item: UnsafeMutablePointer<IShellItem>?
      guard calls.GetResult(dialog, &item) >= 0, let item else { return nil }
      defer { _ = item.pointee.lpVtbl.pointee.Release(item) }
      var path: PWSTR?
      guard item.pointee.lpVtbl.pointee.GetDisplayName(item, SIGDN_FILESYSPATH, &path) >= 0, let path else {
        return nil
      }
      defer { CoTaskMemFree(path) }
      let chosen = String(decoding: UnsafeBufferPointer(start: path, count: wcslen(path)), as: UTF16.self)
      return URL(fileURLWithPath: chosen, isDirectory: true)
    }

    /// CLSID_FileOpenDialog and IID_IFileOpenDialog, named here rather than linked from uuid.lib.
    static let fileOpenDialog = GUID(
      Data1: 0xDC1C_5A9C, Data2: 0xE88A, Data3: 0x4DDE,
      Data4: (0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7))
    static let iidFileOpenDialog = GUID(
      Data1: 0xD57C_7288, Data2: 0xD4AD, Data3: 0x4768,
      Data4: (0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60))

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
