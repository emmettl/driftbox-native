#if os(Windows)
  import WinSDK

  /// A document type made the program's in Explorer, for the person using the machine and no one
  /// else: the keys under `HKEY_CURRENT_USER\Software\Classes` that an installer writes, so that a
  /// double-click opens the file in the program and the file shows the program's icon.
  ///
  /// Only when asked. A program that quietly claims a type every time it runs takes it back from
  /// whatever the person chose instead.
  public struct Win32FileType: Equatable, Sendable {
    /// The ending, with its dot: `.driftbox`.
    public var fileExtension: String
    /// What Explorer knows the type by, unique to the program: `Driftbox.Song`.
    public var progID: String
    /// What Explorer calls it: "Driftbox Song".
    public var name: String

    public init(fileExtension: String, progID: String, name: String) {
      self.fileExtension = fileExtension
      self.progID = progID
      self.name = name
    }

    /// One value to write: under `Software\Classes\<key>`, named `name` or the key's default.
    public struct Value: Equatable, Sendable {
      public var key: String
      public var name: String?
      public var data: String
    }

    /// What registering the type for `executable` writes, in order. The icon is the program's own,
    /// its first; opening passes the file's path, quoted, as the program's first argument.
    public func values(executable: String) -> [Value] {
      [
        Value(key: fileExtension, name: nil, data: progID),
        Value(key: progID, name: nil, data: name),
        Value(key: "\(progID)\\DefaultIcon", name: nil, data: "\"\(executable)\",0"),
        Value(key: "\(progID)\\shell\\open\\command", name: nil, data: "\"\(executable)\" \"%1\""),
      ]
    }

    /// Make the type `executable`'s, and tell Explorer, which otherwise shows the old icon until
    /// it is restarted.
    public func register(executable: String) throws {
      for value in values(executable: executable) {
        let status = Self.withWide("Software\\Classes\\\(value.key)") { key in
          Self.withWide(value.name) { name in
            Self.withWide(value.data) { data in
              RegSetKeyValueW(
                HKEY_CURRENT_USER, key, name, DWORD(REG_SZ), data,
                DWORD((value.data.utf16.count + 1) * MemoryLayout<WCHAR>.size))
            }
          }
        }
        guard status == ERROR_SUCCESS else {
          throw Win32Error("\(value.key) could not be written (\(status))")
        }
      }
      SHChangeNotify(LONG(SHCNE_ASSOCCHANGED), UINT(SHCNF_IDLIST), nil, nil)
    }

    /// Give the type back: the program's own key gone, and the ending's, if it is still the
    /// program's.
    public func unregister() {
      _ = Self.withWide("Software\\Classes\\\(progID)") { RegDeleteTreeW(HKEY_CURRENT_USER, $0) }
      if Self.defaultValue(of: "Software\\Classes\\\(fileExtension)") == progID {
        _ = Self.withWide("Software\\Classes\\\(fileExtension)") { RegDeleteTreeW(HKEY_CURRENT_USER, $0) }
      }
      SHChangeNotify(LONG(SHCNE_ASSOCCHANGED), UINT(SHCNF_IDLIST), nil, nil)
    }

    /// A key's default value under the current user, if it has one that is a string.
    static func defaultValue(of key: String) -> String? {
      var buffer = [WCHAR](repeating: 0, count: 256)
      var size = DWORD(buffer.count * MemoryLayout<WCHAR>.size)
      let status = withWide(key) { key in
        RegGetValueW(HKEY_CURRENT_USER, key, nil, DWORD(RRF_RT_REG_SZ), nil, &buffer, &size)
      }
      guard status == ERROR_SUCCESS else { return nil }
      return String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
    }

    private static func withWide<T>(_ string: String?, _ body: (UnsafePointer<WCHAR>?) -> T) -> T {
      guard let string else { return body(nil) }
      return string.withCString(encodedAs: UTF16.self) { body($0) }
    }
  }
#endif
