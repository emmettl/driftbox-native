#if os(Windows)
  import CVST3
  import DriftboxRack
  import Foundation

  /// The VST 3 plug-ins installed on this machine, as the rack finds them: each audio processor class
  /// of each module in the folders plug-ins are installed in, by the class ID a patch keeps it by.
  public struct VST3Catalogue: Sendable {
    /// What a patch calls the format, in a `PluginReference`.
    public static let format = "vst3"

    public struct Entry: Equatable, Sendable {
      /// Its class ID as `id`, and who made it.
      public var reference: PluginReference
      /// The module it is in: a `.vst3` bundle folder, or a file.
      public var path: String
      /// The VST 3 subcategories it gives, as `Fx` and `Delay`, or `Instrument` and `Synth`.
      public var subCategories: [String]

      /// An instrument, for the `plugin-instrument` module, rather than an effect for `plugin`.
      public var isInstrument: Bool { subCategories.contains("Instrument") }
    }

    public var entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    /// The plug-in a patch names by `classID`, whatever case its digits are in.
    public func entry(_ classID: String) -> Entry? {
      let wanted = classID.uppercased()
      return entries.first { $0.reference.id.uppercased() == wanted }
    }

    /// Where Windows keeps VST 3 plug-ins: for everyone, `Common Files\VST3` under Program Files;
    /// for one person alone, `Programs\Common\VST3` under their local application data.
    public static var standardFolders: [URL] {
      let environment = ProcessInfo.processInfo.environment
      var folders: [URL] = []
      if let common = environment["CommonProgramFiles"] {
        folders.append(URL(fileURLWithPath: common).appendingPathComponent("VST3"))
      }
      if let local = environment["LOCALAPPDATA"] {
        folders.append(URL(fileURLWithPath: local).appendingPathComponent("Programs/Common/VST3"))
      }
      return folders
    }

    /// Every plug-in in `folders`, in the order found. A module that describes itself in a
    /// `moduleinfo.json`, as modules made with SDK 3.7.5 and later do, is read, not loaded; any other
    /// is asked by `scanner`, which remembers what it was told. Slow for a folder of many, so not on
    /// the main thread.
    public static func scan(_ folders: [URL], with scanner: inout VST3Scanner) -> VST3Catalogue {
      var entries: [Entry] = []
      let found = folders.flatMap(modules)
      for module in found {
        if let described = described(module) {
          entries += described
        } else {
          entries += scanner.classes(of: module).map {
            entry(module, id: $0.id, name: $0.name, vendor: $0.vendor, subCategories: $0.subCategories)
          }
        }
      }
      // What was held by a module that has gone is forgotten.
      let paths = Set(found.map(\.path))
      scanner.known = scanner.known.filter { paths.contains($0.key) }
      return VST3Catalogue(entries: entries)
    }

    /// Every plug-in in `folders`, asked by the scanner beside this program, remembering nothing.
    public static func scan(_ folders: [URL]) -> VST3Catalogue {
      var scanner = VST3Scanner()
      return scan(folders, with: &scanner)
    }

    /// The modules in `folder` and in the folders within it: whatever is named `.vst3`.
    static func modules(in folder: URL) -> [URL] {
      let files = FileManager.default
      guard let names = try? files.contentsOfDirectory(atPath: folder.path) else { return [] }
      var found: [URL] = []
      for name in names.sorted() {
        let url = folder.appendingPathComponent(name)
        if name.lowercased().hasSuffix(".vst3") {
          found.append(url)
        } else {
          var isFolder: ObjCBool = false
          if files.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            found += modules(in: url)
          }
        }
      }
      return found
    }

    /// The classes a bundle's `Contents/Resources/moduleinfo.json` lists, or nil for a module with
    /// none, or one this cannot read.
    static func described(_ module: URL) -> [Entry]? {
      let info = module.appendingPathComponent("Contents/Resources/moduleinfo.json")
      guard let data = FileManager.default.contents(atPath: info.path),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let classes = json["Classes"] as? [[String: Any]]
      else { return nil }
      let factoryVendor = (json["Factory Info"] as? [String: Any])?["Vendor"] as? String ?? ""
      return classes.compactMap { item in
        guard item["Category"] as? String == "Audio Module Class", let id = item["CID"] as? String,
          let name = item["Name"] as? String
        else { return nil }
        let vendor = item["Vendor"] as? String ?? ""
        return entry(
          module, id: id, name: name, vendor: vendor.isEmpty ? factoryVendor : vendor,
          subCategories: item["Sub Categories"] as? [String] ?? [])
      }
    }

    static func entry(_ module: URL, id: String, name: String, vendor: String, subCategories: [String])
      -> Entry
    {
      Entry(
        reference: PluginReference(format: format, id: id.uppercased(), name: name, vendor: vendor),
        path: module.path, subCategories: subCategories)
    }

    /// A C string field as Swift imports one, a tuple of characters, as a string.
    static func text<Field>(_ field: Field) -> String {
      withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
  }

  /// What asks a module that does not describe itself what it holds: `DriftboxVST3Scan`, in a
  /// process of its own, so a plug-in that crashes as it loads, or never finishes, is counted as
  /// holding nothing rather than taking the app with it. What each module held is remembered by
  /// its path, with its binary's size and time, and it is asked again only once they change.
  public struct VST3Scanner: Sendable {
    /// One class as the scanner tells of it.
    public struct Class: Codable, Equatable, Sendable {
      public var id: String
      public var name: String
      public var vendor: String
      public var subCategories: [String]
    }

    /// What a module held when it was last asked, and which binary it was.
    public struct Scanned: Codable, Equatable, Sendable {
      public var stamp: String
      /// None for one that would not load, crashed, or was not done in time.
      public var classes: [Class]
    }

    /// The scanner; nil to load each module here instead.
    public var program: URL?
    /// How long a module has to answer, in seconds.
    public var timeout: Double
    /// What each module held, by its path, as of this scan and the ones before it.
    public var known: [String: Scanned]

    public init(program: URL? = beside, timeout: Double = 30, known: [String: Scanned] = [:]) {
      self.program = program
      self.timeout = timeout
      self.known = known
    }

    /// The scanner beside this program, as the package puts it and the build makes it.
    public static var beside: URL? {
      let url = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent("DriftboxVST3Scan.exe")
      return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The classes `module` holds: remembered, where its binary is as it was; otherwise asked.
    public mutating func classes(of module: URL) -> [Class] {
      let stamp = Self.stamp(module)
      if let stamp, let scanned = known[module.path], scanned.stamp == stamp { return scanned.classes }
      let classes = program.map { run($0, module) } ?? Self.load(module)
      if let stamp { known[module.path] = Scanned(stamp: stamp, classes: classes) }
      return classes
    }

    /// The module's binary's size and time: its own, for a module that is one file, or the
    /// Windows binary inside a bundle.
    static func stamp(_ module: URL) -> String? {
      var binary = module
      var isFolder: ObjCBool = false
      if FileManager.default.fileExists(atPath: module.path, isDirectory: &isFolder), isFolder.boolValue {
        let windows = module.appendingPathComponent("Contents/x86_64-win")
        binary = windows.appendingPathComponent(module.lastPathComponent)
      }
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: binary.path),
        let size = attributes[.size] as? NSNumber, let date = attributes[.modificationDate] as? Date
      else { return nil }
      return "\(size.int64Value) \(Int64(date.timeIntervalSince1970 * 1000))"
    }

    /// Asked by the scanner: its lines, once it has exited in time and well.
    func run(_ program: URL, _ module: URL) -> [Class] {
      let output = FileManager.default.temporaryDirectory.appendingPathComponent(
        "driftbox-scan-\(UUID().uuidString)")
      guard FileManager.default.createFile(atPath: output.path, contents: nil),
        let handle = try? FileHandle(forWritingTo: output)
      else { return [] }
      defer {
        try? handle.close()
        try? FileManager.default.removeItem(at: output)
      }
      let process = Process()
      process.executableURL = program
      process.arguments = [module.path]
      // To a file rather than a pipe, which a module of many classes could fill before it exits.
      process.standardOutput = handle
      process.standardError = FileHandle.nullDevice
      // A plug-in that crashes it is only counted, so Swift need not spend a second writing it up.
      var environment = ProcessInfo.processInfo.environment
      environment["SWIFT_BACKTRACE"] = "enable=no"
      process.environment = environment
      do { try process.run() } catch { return [] }
      let deadline = Date().addingTimeInterval(timeout)
      while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
      if process.isRunning {
        process.terminate()
        return []
      }
      guard process.terminationStatus == 0, let data = FileManager.default.contents(atPath: output.path)
      else {
        return []
      }
      return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4, !fields[0].isEmpty else { return nil }
        return Class(
          id: fields[0], name: fields[1], vendor: fields[2],
          subCategories: fields[3].split(separator: "|").map(String.init))
      }
    }

    /// Asked here, where there is no scanner: a module that crashes takes this program with it.
    static func load(_ module: URL) -> [Class] {
      var error = [CChar](repeating: 0, count: 512)
      let count = dbvst3_classes(module.path, nil, 0, &error, error.count)
      guard count > 0 else { return [] }
      var classes = [DBVST3Class](repeating: DBVST3Class(), count: Int(count))
      let written = min(Int(dbvst3_classes(module.path, &classes, count, &error, error.count)), classes.count)
      return classes.prefix(max(0, written)).map {
        Class(
          id: VST3Catalogue.text($0.classID), name: VST3Catalogue.text($0.name),
          vendor: VST3Catalogue.text($0.vendor),
          subCategories: VST3Catalogue.text($0.subCategories).split(separator: "|").map(String.init))
      }
    }
  }
#endif
