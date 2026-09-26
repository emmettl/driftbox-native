// A screen reader, as far as the tests need one: a process of its own, as Narrator and NVDA are,
// reading a window's controls through Windows' UI Automation and acting on them.
//
//   DriftboxAXProbe <window> describe
//   DriftboxAXProbe <window> invoke|toggle <automation id>
//   DriftboxAXProbe <window> set <automation id> <value>
//
// The window is its handle, in decimal. What it read is written to standard output; it exits 0
// when it did what it was asked, and 1 when it could not.
#if os(Windows)
  import DriftboxAXClient
  import WinSDK

  let arguments = CommandLine.arguments
  guard arguments.count >= 3, let handle = UInt(arguments[1]),
    let window = UnsafeMutableRawPointer(bitPattern: handle)
  else {
    print("usage: DriftboxAXProbe <window> describe|invoke|toggle|set …")
    ExitProcess(64)
  }
  var done = false
  switch (arguments[2], arguments.count) {
  case ("describe", _):
    var text = [CChar](repeating: 0, count: 1 << 20)
    done = axclient_describe(window, &text, text.count)
    print(
      String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), terminator: "")
  case ("invoke", 4): done = axclient_invoke(window, arguments[3])
  case ("toggle", 4): done = axclient_toggle(window, arguments[3])
  case ("set", 5): done = axclient_set(window, arguments[3], Double(arguments[4]) ?? .nan)
  default: print("usage: DriftboxAXProbe <window> describe|invoke|toggle|set …")
  }
  ExitProcess(done ? 0 : 1)
#endif
