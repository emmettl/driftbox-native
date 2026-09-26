// Asks a VST 3 module what plug-ins it holds, in a process of its own: a module that crashes as it
// loads takes this with it, not Driftbox, which only sees it fail.
//
//   DriftboxVST3Scan <module>
//
// Prints each audio processor class, one to a line, as its class ID, name, vendor and
// subcategories, separated by tabs; and exits 0. A module that will not load exits 2, with why on
// standard error.
#if os(Windows)
  import CVST3
  import WinSDK

  func fail(_ message: String, _ code: Int32) -> Never {
    var line = message + "\n"
    line.withUTF8 { bytes in
      var written: DWORD = 0
      _ = WriteFile(GetStdHandle(STD_ERROR_HANDLE), bytes.baseAddress, DWORD(bytes.count), &written, nil)
    }
    ExitProcess(UINT(code))
  }

  // A plug-in that crashes ends this at once, with no dialog for anyone to dismiss.
  _ = SetErrorMode(UINT(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX))

  let arguments = CommandLine.arguments
  guard arguments.count == 2 else { fail("usage: DriftboxVST3Scan <module>", 64) }

  /// A C string field as Swift imports one, a tuple of characters, as a string without tabs or
  /// line breaks, which would split it.
  func text<Field>(_ field: Field) -> String {
    let string = withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    return String(string.map { $0 == "\t" || $0.isNewline ? " " : $0 })
  }

  var error = [CChar](repeating: 0, count: 512)
  let count = dbvst3_classes(arguments[1], nil, 0, &error, error.count)
  guard count >= 0 else {
    fail(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), 2)
  }
  var classes = [DBVST3Class](repeating: DBVST3Class(), count: Int(count))
  var written = 0
  if count > 0 {
    written = min(Int(dbvst3_classes(arguments[1], &classes, count, &error, error.count)), classes.count)
  }
  for found in classes.prefix(max(0, written)) {
    let fields = [text(found.classID), text(found.name), text(found.vendor), text(found.subCategories)]
    print(fields.joined(separator: "\t"))
  }
#else
  print("VST 3 plug-ins are scanned on Windows alone for now.")
#endif
