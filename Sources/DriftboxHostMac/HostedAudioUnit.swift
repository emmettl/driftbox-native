#if canImport(AVFoundation)
  import DriftboxHost
  import AVFoundation
  import DriftboxRack
  import Synchronization

  /// An Audio Unit, hosted for a `plugin` module — an effect, stereo in and out — or a
  /// `plugin-instrument` one, played by MIDI the module makes of the rack's notes: rendered a block at
  /// a time on the rack's render thread by its own render block, and remembered in the patch by its
  /// component and its state.
  ///
  /// Everything that allocates happens here on the interface's thread — instantiating, the formats,
  /// the render resources, the buffer list and the pull block. What the render thread runs is
  /// `render`: pointers set, the unit's render block called, nothing made and nothing freed.
  public final class HostedAudioUnit: @unchecked Sendable {
    public let unit: AUAudioUnit
    public let component: AudioComponentDescription
    public let sampleRate: Double
    public let maximumFrames: Int
    /// What the render function reads, at an address the context points to.
    let state: UnsafeMutablePointer<RenderState>

    struct RenderState {
      var renderBlock: AURenderBlock
      var pull: AURenderPullInputBlock
      /// How MIDI reaches the unit ahead of a render, for one that takes it.
      var midi: AUScheduleMIDIEventBlock?
      /// Two buffers, pointed at the module's outlets for each block.
      var output: UnsafeMutableAudioBufferListPointer
      /// The module's inlets for the block being rendered, copied into `input` for the unit to read.
      var inlets: UnsafePointer<UnsafeMutablePointer<Float>>?
      var input: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>)
      var maximumFrames: Int
      var sampleTime: Double
      var tempo: Double
      var beat: Double
      var running: Bool
      var wasRunning: Bool
      /// How a param change reaches the unit from the render thread.
      var parameters: AUScheduleParameterBlock
      /// The four macros' mappings, and what the render thread last sent for each, and for which
      /// mapping: a new mapping is sent at once, whatever the macro was.
      var macros: UnsafeMutablePointer<MacroMapping>
      var sent: UnsafeMutablePointer<Float>
      var sentFor: UnsafeMutablePointer<Int>
    }

    /// One macro's mapping, written on the interface's thread and read on the render thread: the
    /// param's address, its range as float bits, and how the range is crossed. `generation` is
    /// written last and read first, so a mapping is read whole; `shape` 0 is unmapped.
    struct MacroMapping: ~Copyable {
      let generation = Atomic<Int>(0)
      let shape = Atomic<UInt32>(0)
      let address = Atomic<UInt64>(0)
      let low = Atomic<UInt32>(0)
      let high = Atomic<UInt32>(0)

      static let linear: UInt32 = 1
      static let logarithmic: UInt32 = 2
    }

    public enum Failure: Error, Equatable {
      /// No component on this machine answers to that description.
      case missing
      /// It will not take the rack's stereo at this rate.
      case format
    }

    /// Make and ready the unit `component` describes, at `sampleRate`, with the `state` a patch kept
    /// for it, if any.
    public static func instantiate(
      _ component: AudioComponentDescription, sampleRate: Double, maximumFrames: Int = 4096,
      state: String? = nil
    ) async throws -> HostedAudioUnit {
      guard AudioComponentFindNext(nil, [component]) != nil else { throw Failure.missing }
      let unit = try await AUAudioUnit.instantiate(with: component, options: [])
      return try HostedAudioUnit(
        unit: unit, sampleRate: sampleRate, maximumFrames: maximumFrames, state: state)
    }

    init(unit: AUAudioUnit, sampleRate: Double, maximumFrames: Int, state saved: String?) throws {
      self.unit = unit
      component = unit.componentDescription
      self.sampleRate = sampleRate
      self.maximumFrames = maximumFrames
      guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
        unit.outputBusses.count > 0
      else { throw Failure.format }
      do {
        if unit.inputBusses.count > 0 {
          try unit.inputBusses[0].setFormat(format)
          unit.inputBusses[0].isEnabled = true
        }
        try unit.outputBusses[0].setFormat(format)
      } catch {
        throw Failure.format
      }
      unit.maximumFramesToRender = AUAudioFrameCount(maximumFrames)
      if let saved { Self.restore(saved, into: unit) }

      let output = AudioBufferList.allocate(maximumBuffers: 2)
      let left = UnsafeMutablePointer<Float>.allocate(capacity: maximumFrames)
      left.initialize(repeating: 0, count: maximumFrames)
      let right = UnsafeMutablePointer<Float>.allocate(capacity: maximumFrames)
      right.initialize(repeating: 0, count: maximumFrames)
      state = .allocate(capacity: 1)
      let state = state
      // What the unit asks for as its input: the module's inlets, copied into buffers of the host's
      // own, since a unit may render in place and an inlet may be the rack's shared zero buffer.
      let pull: AURenderPullInputBlock = { _, _, frames, _, list in
        guard let inlets = state.pointee.inlets else { return kAudioUnitErr_NoConnection }
        let count = min(Int(frames), maximumFrames)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        for channel in 0..<min(2, buffers.count) {
          let into = channel == 0 ? state.pointee.input.0 : state.pointee.input.1
          into.update(from: inlets[channel], count: count)
          if let data = buffers[channel].mData, data != UnsafeMutableRawPointer(into) {
            data.assumingMemoryBound(to: Float.self).update(from: into, count: count)
          } else {
            buffers[channel].mData = UnsafeMutableRawPointer(into)
          }
          buffers[channel].mDataByteSize = UInt32(count * MemoryLayout<Float>.size)
        }
        return noErr
      }
      unit.musicalContextBlock = { tempo, numerator, denominator, beat, _, downbeat in
        tempo?.pointee = state.pointee.tempo
        numerator?.pointee = 4
        denominator?.pointee = 4
        beat?.pointee = state.pointee.beat
        downbeat?.pointee = (state.pointee.beat / 4).rounded(.down) * 4
        return true
      }
      unit.transportStateBlock = { flags, sample, _, _ in
        var now: AUHostTransportStateFlags = []
        if state.pointee.running { now.insert(.moving) }
        if state.pointee.running != state.pointee.wasRunning { now.insert(.changed) }
        flags?.pointee = now
        sample?.pointee = state.pointee.sampleTime
        return true
      }
      do {
        try unit.allocateRenderResources()
      } catch {
        free(output.unsafeMutablePointer)
        left.deallocate()
        right.deallocate()
        state.deallocate()
        throw Failure.format
      }
      let macros = UnsafeMutablePointer<MacroMapping>.allocate(capacity: 4)
      for index in 0..<4 { (macros + index).initialize(to: MacroMapping()) }
      let sent = UnsafeMutablePointer<Float>.allocate(capacity: 4)
      sent.initialize(repeating: -1, count: 4)
      let sentFor = UnsafeMutablePointer<Int>.allocate(capacity: 4)
      sentFor.initialize(repeating: -1, count: 4)
      state.initialize(
        to: RenderState(
          renderBlock: unit.renderBlock, pull: pull, midi: unit.scheduleMIDIEventBlock, output: output,
          inlets: nil, input: (left, right),
          maximumFrames: maximumFrames, sampleTime: 0, tempo: 120, beat: 0, running: false, wasRunning: false,
          parameters: unit.scheduleParameterBlock, macros: macros, sent: sent, sentFor: sentFor)
      )
    }

    deinit {
      unit.deallocateRenderResources()
      free(state.pointee.output.unsafeMutablePointer)
      state.pointee.input.0.deallocate()
      state.pointee.input.1.deallocate()
      state.pointee.macros.deinitialize(count: 4)
      state.pointee.macros.deallocate()
      state.pointee.sent.deallocate()
      state.pointee.sentFor.deallocate()
      state.deinitialize(count: 1)
      state.deallocate()
    }

    /// The unit as a `plugin` module's processor, for `RackHost.setExternal`.
    public var external: RackExternal {
      RackExternal(render: Self.render, context: UnsafeMutableRawPointer(state), owner: self)
    }

    /// One block through the unit, on the render thread. A failed render, or one longer than the
    /// unit was readied for, is silence.
    static let render: ExternalRender = {
      context, inlets, outlets, frames, tempo, beat, running, events, count, macros, macroCount in
      guard let context else { return }
      let state = context.assumingMemoryBound(to: RenderState.self)
      let left = outlets[0]
      let right = outlets[1]
      guard frames <= state.pointee.maximumFrames else {
        left.update(repeating: 0, count: frames)
        right.update(repeating: 0, count: frames)
        return
      }
      state.pointee.inlets = inlets
      state.pointee.tempo = tempo
      state.pointee.beat = beat
      state.pointee.running = running
      var output = state.pointee.output
      output.count = 2
      let bytes = UInt32(frames * MemoryLayout<Float>.size)
      output[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(left))
      output[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(right))
      // The macros that moved, or were mapped anew, onto their params, once a block. Not ramped: a
      // version 2 unit, as Apple's own are, drops a ramped event rather than following it.
      for macro in 0..<min(4, macroCount) {
        let mapping = state.pointee.macros + macro
        let generation = mapping.pointee.generation.load(ordering: .acquiring)
        let shape = mapping.pointee.shape.load(ordering: .relaxed)
        let value = macros[macro]
        guard shape != 0,
          value != state.pointee.sent[macro] || generation != state.pointee.sentFor[macro]
        else { continue }
        let low = Float(bitPattern: mapping.pointee.low.load(ordering: .relaxed))
        let high = Float(bitPattern: mapping.pointee.high.load(ordering: .relaxed))
        state.pointee.parameters(
          AUEventSampleTimeImmediate, 0,
          mapping.pointee.address.load(ordering: .relaxed),
          HostedAudioUnit.scaled(value, low: low, high: high, shape: shape))
        state.pointee.sent[macro] = value
        state.pointee.sentFor[macro] = generation
      }
      // The block's notes, each at its frame of the block, before the block is rendered.
      if let midi = state.pointee.midi, let events {
        for index in 0..<count {
          let event = events[index]
          var message = MIDIEvent.bytes(event)
          withUnsafeBytes(of: &message) { raw in
            midi(
              AUEventSampleTimeImmediate + AUEventSampleTime(MIDIEvent.frame(event)), 0, 3,
              raw.baseAddress!.assumingMemoryBound(to: UInt8.self))
          }
        }
      }
      var flags = AudioUnitRenderActionFlags()
      var time = AudioTimeStamp()
      time.mSampleTime = state.pointee.sampleTime
      time.mFlags = .sampleTimeValid
      let status = state.pointee.renderBlock(
        &flags, &time, AUAudioFrameCount(frames), 0, output.unsafeMutablePointer, state.pointee.pull)
      if status != noErr {
        left.update(repeating: 0, count: frames)
        right.update(repeating: 0, count: frames)
      } else {
        // A unit may answer with buffers of its own rather than filling the ones it was given.
        if let data = output[0].mData, data != UnsafeMutableRawPointer(left) {
          left.update(from: data.assumingMemoryBound(to: Float.self), count: frames)
        }
        if let data = output[1].mData, data != UnsafeMutableRawPointer(right) {
          right.update(from: data.assumingMemoryBound(to: Float.self), count: frames)
        }
      }
      state.pointee.sampleTime += Double(frames)
      state.pointee.wasRunning = running
    }

    // MARK: - Macros

    /// Turn `parameter` with macro `macro` (0 to 3) from the next block, or nothing (nil).
    public func map(_ macro: Int, to parameter: AUParameter?) {
      guard (0..<4).contains(macro) else { return }
      let mapping = state.pointee.macros + macro
      if let parameter {
        mapping.pointee.address.store(parameter.address, ordering: .relaxed)
        mapping.pointee.low.store(parameter.minValue.bitPattern, ordering: .relaxed)
        mapping.pointee.high.store(parameter.maxValue.bitPattern, ordering: .relaxed)
        mapping.pointee.shape.store(
          Self.logarithmic(parameter) ? MacroMapping.logarithmic : MacroMapping.linear, ordering: .relaxed)
      } else {
        mapping.pointee.shape.store(0, ordering: .relaxed)
      }
      mapping.pointee.generation.wrappingAdd(1, ordering: .releasing)
    }

    /// The address of the param macro `macro` (0 to 3) turns, or nil.
    public func mapping(_ macro: Int) -> AUParameterAddress? {
      guard (0..<4).contains(macro) else { return nil }
      let mapping = state.pointee.macros + macro
      _ = mapping.pointee.generation.load(ordering: .acquiring)
      guard mapping.pointee.shape.load(ordering: .relaxed) != 0 else { return nil }
      return mapping.pointee.address.load(ordering: .relaxed)
    }

    /// Whether a param is shown on a logarithmic scale, and so crossed as one: a frequency, say.
    static func logarithmic(_ parameter: AUParameter) -> Bool {
      parameter.flags.contains(.flag_DisplayLogarithmic) && parameter.minValue > 0
        && parameter.maxValue > parameter.minValue
    }

    /// A macro's 0 to 1 as a param's value, across its range as the param would be shown.
    static func scaled(_ value: Float, low: Float, high: Float, shape: UInt32) -> Float {
      let fraction = max(0, min(1, value))
      if shape == MacroMapping.logarithmic { return low * powf(high / low, fraction) }
      return low + (high - low) * fraction
    }

    /// Where a param's value is as a macro's 0 to 1: the inverse, for a macro to start where the
    /// param already is.
    public static func fraction(of parameter: AUParameter) -> Double {
      let low = Double(parameter.minValue)
      let high = Double(parameter.maxValue)
      guard high > low else { return 0 }
      let value = max(low, min(high, Double(parameter.value)))
      if logarithmic(parameter) { return log(value / low) / log(high / low) }
      return (value - low) / (high - low)
    }

    /// The param a macro turns, as it would say its value at `fraction`: in its own words and units.
    public static func display(_ parameter: AUParameter, at fraction: Double) -> String {
      let shape = logarithmic(parameter) ? MacroMapping.logarithmic : MacroMapping.linear
      let value = scaled(Float(fraction), low: parameter.minValue, high: parameter.maxValue, shape: shape)
      var text = parameter.string(fromValue: [value])
      // A unit that has no words of its own for a value gives none: then the number, to a sensible
      // number of places for its size.
      if text.isEmpty {
        let magnitude = abs(value)
        text = String(format: magnitude >= 100 ? "%.0f" : magnitude >= 10 ? "%.1f" : "%.2f", value)
      }
      if let unit = parameter.unitName, !unit.isEmpty { text += " " + unit }
      return text
    }

    /// Every param a macro can turn, by key: found once, and again only when the unit's tree is
    /// replaced, as a unit may do on changing preset.
    public var parameters: [String: AUParameter] {
      let tree = unit.parameterTree
      if let cached = parameterCache, cached.tree === tree { return cached.parameters }
      var out: [String: AUParameter] = [:]
      for parameter in tree?.allParameters ?? [] where parameter.flags.contains(.flag_IsWritable) {
        out[parameter.keyPath] = parameter
      }
      parameterCache = (tree, out)
      return out
    }
    private var parameterCache: (tree: AUParameterTree?, parameters: [String: AUParameter])?

    // MARK: - What a patch keeps

    /// The unit's state, for the patch: its document state as a binary property list, in base64.
    public var savedState: String? {
      guard let state = unit.fullStateForDocument ?? unit.fullState,
        let data = try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
      else { return nil }
      return data.base64EncodedString()
    }

    static func restore(_ saved: String, into unit: AUAudioUnit) {
      guard let data = Data(base64Encoded: saved),
        let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
      else { return }
      unit.fullStateForDocument = state
    }

    /// How late the unit's output is, in seconds, as it reports it.
    public var latency: Double { unit.latency }

    /// The patch's record of this unit, with its state as of now.
    public var reference: PluginReference {
      PluginReference(
        format: "audio-unit", id: Self.identifier(component), name: unit.audioUnitName ?? "Audio Unit",
        vendor: unit.manufacturerName ?? "", state: savedState)
    }

    // MARK: - Identifiers

    /// `aufx dely appl`: the component's type, subtype and manufacturer as four characters each.
    public static func identifier(_ component: AudioComponentDescription) -> String {
      [component.componentType, component.componentSubType, component.componentManufacturer]
        .map(fourCharacters).joined(separator: " ")
    }

    /// The component a patch's identifier names, or nil for one that is not three codes of four.
    /// Read by position, not by splitting on spaces: a code may end in one, as DLS's `dls ` does.
    public static func component(_ identifier: String) -> AudioComponentDescription? {
      let bytes = Array(identifier.utf8)
      guard bytes.count == 14, bytes[4] == 0x20, bytes[9] == 0x20 else { return nil }
      let codes = [bytes[0..<4], bytes[5..<9], bytes[10..<14]].map {
        $0.reduce(OSType(0)) { $0 << 8 | OSType($1) }
      }
      return AudioComponentDescription(
        componentType: codes[0], componentSubType: codes[1], componentManufacturer: codes[2],
        componentFlags: 0, componentFlagsMask: 0)
    }

    static func fourCharacters(_ code: OSType) -> String {
      let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
      return String(decoding: bytes, as: UTF8.self)
    }

  }
#endif
