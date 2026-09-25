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
    private var catalogue: VST3Catalogue?
    private var scanning: Task<VST3Catalogue, Never>?

    /// Plug-ins from `folders`: where Windows installs them, unless a test says otherwise.
    public init(folders: [URL] = VST3Catalogue.standardFolders) { self.folders = folders }

    /// The plug-ins installed, found the first time they are asked for and remembered: one
    /// installed while the app is open is found at its next launch.
    public func installed() async -> VST3Catalogue {
      if let catalogue { return catalogue }
      if let scanning { return await scanning.value }
      let folders = folders
      let task = Task.detached { VST3Catalogue.scan(folders) }
      scanning = task
      let found = await task.value
      catalogue = found
      scanning = nil
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
      return VST3Plugin(hosted)
    }
  }

  /// One VST 3 plug-in in the rack, as the session asks for it: rendered by the host, its params by
  /// ID for the macros, and what it says as it changes.
  @MainActor
  public final class VST3Plugin: RackPluginUnit {
    public let hosted: HostedVST3
    /// The params a macro can turn, as the plug-in lists them, found once.
    let automatable: [HostedVST3.Parameter]

    public init(_ hosted: HostedVST3) {
      self.hosted = hosted
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

    public func close() { onChange = nil }
  }
#endif
