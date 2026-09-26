#if os(Windows)
  import DriftboxHost
  import DriftboxRack
  import DriftboxRackSession
  import Foundation

  /// Windows' plug-ins for the rack: VST 3, made from what a patch remembers of them, found among
  /// those installed by their class ID. A patch's Audio Units, from a Mac, are missing here.
  @MainActor
  public final class VST3Hosting: RackPluginHosting {
    let folders: [URL]
    /// The window the plug-ins' editors belong to, so they stay in front of it; and whether they
    /// are shown, which a test's are not.
    let owner: (@MainActor () -> UnsafeMutableRawPointer?)?
    let showsEditors: Bool
    /// The scanner, and where what it was told is kept from one launch to the next.
    let scanner: VST3Scanner
    let memory: UserDefaults?
    static let memoryKey = "vst3.scanned"
    private var catalogue: VST3Catalogue?
    private var scanning: Task<VST3Catalogue, Never>?

    /// Plug-ins from `folders`: where Windows installs them, unless a test says otherwise, asked by
    /// `scanner` what they hold, which is kept in `memory`. Their editors belong to the window
    /// `owner` gives.
    public init(
      folders: [URL] = VST3Catalogue.standardFolders, scanner: VST3Scanner = VST3Scanner(),
      memory: UserDefaults? = nil, owner: (@MainActor () -> UnsafeMutableRawPointer?)? = nil,
      showsEditors: Bool = true
    ) {
      self.folders = folders
      self.owner = owner
      self.showsEditors = showsEditors
      self.memory = memory
      var scanner = scanner
      if let data = memory?.data(forKey: Self.memoryKey),
        let known = try? JSONDecoder().decode([String: VST3Scanner.Scanned].self, from: data)
      {
        scanner.known.merge(known) { given, _ in given }
      }
      self.scanner = scanner
    }

    /// The plug-ins installed, found the first time they are asked for and remembered: one
    /// installed while the app is open is found at its next launch.
    public func installed() async -> VST3Catalogue {
      if let catalogue { return catalogue }
      if let scanning { return await scanning.value }
      let folders = folders
      let scanner = scanner
      let task = Task.detached {
        var scanner = scanner
        let found = VST3Catalogue.scan(folders, with: &scanner)
        return (found, scanner.known)
      }
      scanning = Task { await task.value.0 }
      let (found, known) = await task.value
      catalogue = found
      scanning = nil
      if let memory, let data = try? JSONEncoder().encode(known) { memory.set(data, forKey: Self.memoryKey) }
      return found
    }

    public func available() async -> [RackPluginChoice] {
      await installed().entries.map { RackPluginChoice(reference: $0.reference, instrument: $0.isInstrument) }
    }

    public func make(_ reference: PluginReference, sampleRate: Double) async throws -> any RackPluginUnit {
      guard reference.format == VST3Catalogue.format, let entry = await installed().entry(reference.id) else {
        throw RackPluginFailure.missing
      }
      let hosted = try HostedVST3(path: entry.path, classID: entry.reference.id, sampleRate: sampleRate)
      guard hosted.outputChannels > 0 else { throw RackPluginFailure.format }
      if let state = reference.state { hosted.restore(state) }
      return VST3Plugin(hosted, owner: owner, showsEditor: showsEditors)
    }
  }

  /// One VST 3 plug-in in the rack, as the session asks for it: rendered by the host, its params by
  /// ID for the macros, what it says as it changes, and its own editor in a window of its own.
  @MainActor
  public final class VST3Plugin: RackPluginUnit {
    public let hosted: HostedVST3
    /// The params a macro can turn, as the plug-in lists them, found once.
    let automatable: [HostedVST3.Parameter]

    let owner: (@MainActor () -> UnsafeMutableRawPointer?)?
    let showsEditor: Bool

    public init(
      _ hosted: HostedVST3, owner: (@MainActor () -> UnsafeMutableRawPointer?)? = nil,
      showsEditor: Bool = true
    ) {
      self.hosted = hosted
      self.owner = owner
      self.showsEditor = showsEditor
      automatable = hosted.parameters.filter(\.automatable)
    }

    public var external: RackExternal { hosted.external }
    public var latency: Double { hosted.latency }
    public var savedState: String? { hosted.savedState }

    /// Each by its ID, which a plug-in keeps from one version of itself to the next, and where it is
    /// now, which is already 0...1 across its range.
    public var parameters: [String: RackPluginParameter] {
      hosted.idle()
      var out: [String: RackPluginParameter] = [:]
      for parameter in automatable {
        let key = String(parameter.id)
        out[key] = RackPluginParameter(
          key: key, name: parameter.title, address: UInt64(parameter.id), fraction: hosted.value(parameter.id)
        )
      }
      return out
    }

    public func map(_ slot: Int, to key: String?) { hosted.map(slot, to: key.flatMap { UInt32($0) }) }

    /// Heard from the plug-in on whatever thread it calls from, and handed to the main actor.
    public var onChange: ((UInt64?) -> Void)? {
      didSet {
        guard onChange != nil else {
          hosted.onChange = nil
          return
        }
        hosted.onChange = { [weak self] id in
          Task { @MainActor in self?.onChange?(id < 0 ? nil : UInt64(id)) }
        }
      }
    }

    /// Its editor, in front of the app's window. Closing it says the plug-in has changed, so
    /// whatever was done in it is kept, not only a param it happened to report.
    public func showInterface(title: String) {
      hosted.openEditor(title: title, owner: owner?(), show: showsEditor) { [weak self] in
        Task { @MainActor in self?.onChange?(nil) }
      }
    }

    public func close() {
      onChange = nil
      hosted.closeEditor()
    }

    /// In the plug-in's own words, with its units after them where it gives any and its words do
    /// not already end in them.
    public func display(_ key: String, at fraction: Double) -> String? {
      guard let id = UInt32(key), let text = hosted.text(id, at: fraction), !text.isEmpty else { return nil }
      let units = automatable.first { $0.id == id }?.units ?? ""
      return units.isEmpty || text.hasSuffix(units) ? text : text + " " + units
    }
  }
#endif
