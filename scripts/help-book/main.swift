import Foundation

// Compiled alongside DriftboxHelp by build-help-book.sh; no second copy of the guide text.
guard CommandLine.arguments.count == 4 else {
  fatalError("Usage: generate-help-book OUTPUT VERSION BUILD")
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let contents = root.appendingPathComponent("Contents", isDirectory: true)
let language = contents.appendingPathComponent("Resources/en.lproj", isDirectory: true)
try FileManager.default.createDirectory(at: language, withIntermediateDirectories: true)
let info: [String: String] = [
  "CFBundleDevelopmentRegion": "en",
  "CFBundleIdentifier": HelpBook.identifier,
  "CFBundleInfoDictionaryVersion": "6.0",
  "CFBundleName": HelpBook.title,
  "CFBundlePackageType": "BNDL",
  "CFBundleSignature": "hbwr",
  "CFBundleShortVersionString": CommandLine.arguments[2],
  "CFBundleVersion": CommandLine.arguments[3],
  "HPDBookAccessPath": "index.html",
  "HPDBookIndexPath": "search.cshelpindex",
  "HPDBookTitle": HelpBook.title,
  "HPDBookType": "3",
]
try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
  .write(to: contents.appendingPathComponent("Info.plist"))
for page in HelpBook.pages {
  try page.html.write(to: language.appendingPathComponent(page.filename), atomically: true, encoding: .utf8)
}
try HelpBook.stylesheet.write(
  to: language.appendingPathComponent("help.css"), atomically: true, encoding: .utf8)
try "\"HPDBookTitle\" = \"Driftbox Help\";\n".write(
  to: language.appendingPathComponent("InfoPlist.strings"), atomically: true, encoding: .utf8)
