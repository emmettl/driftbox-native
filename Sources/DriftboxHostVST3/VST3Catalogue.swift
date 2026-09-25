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
    /// is loaded to be asked, then let go of. Slow for a folder of many, so not on the main thread.
    public static func scan(_ folders: [URL]) -> VST3Catalogue {
      VST3Catalogue(entries: folders.flatMap(modules).flatMap(classes))
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

    /// The audio processor classes of `module`.
    static func classes(of module: URL) -> [Entry] {
      if let described = described(module) { return described }
      var error = [CChar](repeating: 0, count: 512)
      let count = dbvst3_classes(module.path, nil, 0, &error, error.count)
      guard count > 0 else { return [] }
      var classes = [DBVST3Class](repeating: DBVST3Class(), count: Int(count))
      let written = min(Int(dbvst3_classes(module.path, &classes, count, &error, error.count)), classes.count)
      return classes.prefix(max(0, written)).map {
        entry(
          module, id: text($0.classID), name: text($0.name), vendor: text($0.vendor),
          subCategories: text($0.subCategories).split(separator: "|").map(String.init))
      }
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
#endif
