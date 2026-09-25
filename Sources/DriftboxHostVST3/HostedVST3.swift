#if os(Windows)
  import CVST3
  import DriftboxHost
  import DriftboxRack
  import Foundation
  import Synchronization

  /// A VST 3 plug-in, hosted for a `plugin` module — an effect, stereo in and out — or a
  /// `plugin-instrument` one, played by the MIDI the module makes of the rack's notes: rendered a
  /// block at a time on the rack's render thread through the bridge, and remembered in the patch by
  /// its class ID and its state.
  ///
  /// Everything but `render` happens on the main thread, as VST 3 asks: making it, its params, its
  /// state, and letting it go. What the render thread runs is the bridge's `dbvst3_render`, which
  /// never waits on the main thread.
  public final class HostedVST3: @unchecked Sendable {
    let plugin: OpaquePointer
    public let sampleRate: Double
    public let maximumFrames: Int
    /// Who is told when the plug-in changes itself: held for as long as the plug-in is, since the
    /// bridge keeps its address.
    let listener = Listener()

    final class Listener: Sendable {
      let told = Mutex<(@Sendable (Int64) -> Void)?>(nil)
    }

    /// Why a plug-in will not be made, in its own words or the bridge's.
    public struct Failure: Error, CustomStringConvertible, Equatable {
      public var description: String
    }

    /// The plug-in of class `classID` in the module at `path`, set up to play stereo at
    /// `sampleRate`, and processing.
    public init(path: String, classID: String, sampleRate: Double, maximumFrames: Int = 4096) throws {
      var error = [CChar](repeating: 0, count: 512)
      guard
        let plugin = dbvst3_open(path, classID, sampleRate, Int32(maximumFrames), &error, error.count)
      else {
        let why = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        throw Failure(description: why.prefix(1).uppercased() + why.dropFirst())
      }
      self.plugin = plugin
      self.sampleRate = sampleRate
      self.maximumFrames = maximumFrames
      dbvst3_listen(plugin, Self.tell, Unmanaged.passUnretained(listener).toOpaque())
    }

    deinit {
      dbvst3_listen(plugin, nil, nil)
      dbvst3_close(plugin)
    }

    /// The bridge's word that the plug-in changed, handed to whoever is listening.
    static let tell: DBVST3Listener = { context, id in
      guard let context else { return }
      let listener = Unmanaged<Listener>.fromOpaque(context).takeUnretainedValue()
      listener.told.withLock { $0 }?(id)
    }

    /// Told when the plug-in changes itself — the param it set from its own interface, or -1 for
    /// anything else — on whatever thread it says so on.
    public var onChange: (@Sendable (Int64) -> Void)? {
      get { listener.told.withLock { $0 } }
      set { listener.told.withLock { $0 = newValue } }
    }

    // MARK: - Playing

    /// The plug-in as a `plugin` module's processor, for `RackHost.setExternal`.
    public var external: RackExternal {
      RackExternal(render: Self.render, context: UnsafeMutableRawPointer(plugin), owner: self)
    }

    /// One block through the plug-in, on the render thread: the bridge's, with the rack's pointers
    /// as C has them.
    static let render: ExternalRender = {
      context, inlets, outlets, frames, tempo, beat, running, events, count, macros, macroCount in
      guard let context else { return }
      dbvst3_render(
        OpaquePointer(context),
        UnsafeRawPointer(inlets).assumingMemoryBound(to: UnsafeMutablePointer<Float>?.self),
        UnsafeRawPointer(outlets).assumingMemoryBound(to: UnsafeMutablePointer<Float>?.self),
        Int32(frames), tempo, beat, running, events, Int32(count), macros, Int32(macroCount))
    }

    public var inputChannels: Int { Int(dbvst3_input_channels(plugin)) }
    public var outputChannels: Int { Int(dbvst3_output_channels(plugin)) }
    public var takesNotes: Bool { dbvst3_takes_notes(plugin) }

    /// How late its output is, in seconds, as it reports it.
    public var latency: Double { Double(dbvst3_latency(plugin)) / sampleRate }

    // MARK: - Params

    public struct Parameter: Equatable, Sendable {
      public var id: UInt32
      public var title: String
      public var units: String
      /// 0 for a continuous param; otherwise how many steps past the first it has.
      public var stepCount: Int
      public var defaultValue: Double
      /// Whether a hand, or a macro, can set it.
      public var automatable: Bool
    }

    /// Every param it has, as its controller lists them.
    public var parameters: [Parameter] {
      (0..<dbvst3_parameter_count(plugin)).compactMap { index in
        var parameter = DBVST3Parameter()
        guard dbvst3_parameter(plugin, index, &parameter) else { return nil }
        return Parameter(
          id: parameter.id, title: Self.text(parameter.title), units: Self.text(parameter.units),
          stepCount: Int(parameter.stepCount), defaultValue: parameter.defaultValue,
          automatable: parameter.automatable)
      }
    }

    /// A param's value, 0...1, with whatever the render thread gave it.
    public func value(_ id: UInt32) -> Double { dbvst3_get_parameter(plugin, id) }

    /// Set a param, 0...1: at once on its controller, and in the audio from the next block.
    public func set(_ id: UInt32, _ value: Double) { dbvst3_set_parameter(plugin, id, value) }

    /// What a param at `value` says it is, in its own words.
    public func text(_ id: UInt32, at value: Double) -> String? {
      var text = [CChar](repeating: 0, count: 128)
      guard dbvst3_parameter_text(plugin, id, value, &text, text.count) else { return nil }
      return String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Turn param `id` with macro `slot` (0 to 3) from the next block, or nothing (nil).
    public func map(_ slot: Int, to id: UInt32?) {
      dbvst3_map(plugin, Int32(slot), id.map(Int64.init) ?? -1)
    }

    /// The param macro `slot` turns, or nil.
    public func mapping(_ slot: Int) -> UInt32? {
      let id = dbvst3_mapping(plugin, Int32(slot))
      return id < 0 ? nil : UInt32(id)
    }

    /// What the render thread gave the processor, told to its controller, so that it shows it.
    public func idle() { dbvst3_idle(plugin) }

    // MARK: - What a patch keeps

    /// Its state, processor and controller together, as the bridge writes it.
    public var state: [UInt8]? {
      let size = dbvst3_state(plugin, nil, 0)
      guard size >= 0 else { return nil }
      var bytes = [UInt8](repeating: 0, count: Int(size))
      guard dbvst3_state(plugin, &bytes, size) == size else { return nil }
      return bytes
    }

    /// Its state for the patch, in base64.
    public var savedState: String? { state.map { Data($0).base64EncodedString() } }

    /// Its state as a patch kept it; false when it would not take it.
    @discardableResult
    public func restore(_ saved: String) -> Bool {
      guard let data = Data(base64Encoded: saved) else { return false }
      let bytes = [UInt8](data)
      return dbvst3_set_state(plugin, bytes, Int64(bytes.count))
    }

    /// A C string field as Swift imports one, a tuple of characters, as a string.
    static func text<Field>(_ field: Field) -> String {
      withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
  }
#endif
