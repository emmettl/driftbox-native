#if os(macOS)
  import AudioToolbox
  import CoreAudio
  import DriftboxHost
  import Foundation
  import Synchronization

  /// One device heard into a `LiveInput`, until it is stopped or the device changes under it:
  /// `WASAPICapture`'s counterpart on the Mac.
  ///
  /// An AUHAL unit with its input on and its output off. It hands over what it hears as 32-bit
  /// float in one or two channels — the device's first two, or its only one, which `LiveInput`
  /// hears on both sides as the Audio Input module expects of a microphone — but at the device's
  /// own rate: AUHAL converts formats and channels on the way in, never rates. An `AudioConverter`
  /// takes it the rest of the way, to the rack's rate, where the two differ.
  ///
  /// Everything the device's thread touches is made before the unit starts and let go of after it
  /// has stopped: the unit, two buffers and their lists, the converter, the ring. On that thread
  /// nothing allocates, locks or waits.
  final class InputUnit: @unchecked Sendable {
    /// What stopped it being opened, in words for the person it stops.
    struct Failure: Error, CustomStringConvertible {
      var description: String

      init(_ what: String, _ status: OSStatus? = nil) {
        description = status.map { "\(what) (\($0))" } ?? what
      }
    }

    /// The device heard, by its number this session.
    let deviceID: AudioDeviceID
    /// Where what it hears goes.
    let input: LiveInput
    /// Set when the device goes, or changes its rate or its channels, under the unit: it is heard
    /// no longer, or not rightly, until it is opened again.
    let invalidated = Atomic<Bool>(false)
    private let unit: AudioUnit
    private let io: InputIO
    private let onLost: @Sendable () -> Void
    private var listener: AudioObjectPropertyListenerBlock?
    private var stopped = false

    /// What says the device has changed under the unit: gone, or at another rate, or with other
    /// channels.
    private static let watched: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
      (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
      (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
      (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
    ]

    /// Start hearing `device` into `input` at `sampleRate`. Throws with the reason it could not.
    /// `onLost` is called, from a thread of Core Audio's, when the device changes under it.
    init(
      device: AudioDeviceID, input: LiveInput, sampleRate: Double, onLost: @escaping @Sendable () -> Void
    ) throws {
      deviceID = device
      self.input = input
      self.onLost = onLost
      var description = AudioComponentDescription(
        componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
      guard let component = AudioComponentFindNext(nil, &description) else {
        throw Failure("the Mac has no input unit")
      }
      var made: AudioUnit?
      let status = AudioComponentInstanceNew(component, &made)
      guard status == noErr, let made else { throw Failure("the input unit would not open", status) }
      do {
        io = try Self.configure(made, device: device, input: input, sampleRate: sampleRate)
      } catch {
        AudioComponentInstanceDispose(made)
        throw error
      }
      unit = made
      listen()
      do {
        try Self.check(AudioUnitInitialize(unit), "the device would not open")
        try Self.check(AudioOutputUnitStart(unit), "the device would not start")
      } catch {
        stop()
        throw error
      }
    }

    deinit { stop() }

    /// Stop, and let go of the device. The device's thread is done with the unit once this returns.
    func stop() {
      guard !stopped else { return }
      stopped = true
      if let listener {
        for (selector, scope) in Self.watched {
          var address = AudioOutputs.address(selector, scope: scope)
          AudioObjectRemovePropertyListenerBlock(deviceID, &address, nil, listener)
        }
      }
      listener = nil
      AudioOutputUnitStop(unit)
      AudioUnitUninitialize(unit)
      AudioComponentInstanceDispose(unit)
    }

    private func listen() {
      let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.lose() }
      for (selector, scope) in Self.watched {
        var address = AudioOutputs.address(selector, scope: scope)
        AudioObjectAddPropertyListenerBlock(deviceID, &address, nil, block)
      }
      listener = block
    }

    private func lose() {
      if !invalidated.exchange(true, ordering: .acquiringAndReleasing) { onLost() }
    }

    /// The unit turned into an input on `device`, taking what it hears in the format the IO
    /// thread will write, and calling it with each piece.
    private static func configure(
      _ unit: AudioUnit, device: AudioDeviceID, input: LiveInput, sampleRate: Double
    ) throws -> InputIO {
      var on: UInt32 = 1
      var off: UInt32 = 0
      try set(
        unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, "the device would not listen")
      try set(
        unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off,
        "the device would not listen")
      var device = device
      try set(
        unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
        "the device would not open")
      // The device's side of the input element: its own rate and channels.
      var hardware = AudioStreamBasicDescription()
      try get(
        unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, "the device has no format"
      )
      guard hardware.mChannelsPerFrame > 0, hardware.mSampleRate > 0 else {
        throw Failure("it has no inputs")
      }
      let channels = min(2, Int(hardware.mChannelsPerFrame))
      var client = format(rate: hardware.mSampleRate, channels: channels)
      try set(
        unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client,
        "the device would not give floating point")
      var most: UInt32 = 0
      try get(
        unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &most,
        "the device would not say how much it gives")
      let io = try InputIO(
        unit: unit, input: input, channels: channels, deviceRate: hardware.mSampleRate,
        sampleRate: sampleRate,
        frames: max(8192, Int(most)))
      var callback = AURenderCallbackStruct(
        inputProc: inputHeard, inputProcRefCon: Unmanaged.passUnretained(io).toOpaque())
      try set(
        unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
        "the device would not call back")
      // Two of the device's pieces in hand, at the rack's rate: one arriving while the rack takes
      // the last.
      var piece: UInt32 = 512
      var address = AudioOutputs.address(kAudioDevicePropertyBufferFrameSize)
      var size = UInt32(MemoryLayout<UInt32>.size)
      _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &piece)
      input.prepare(hold: Int((Double(piece) * sampleRate / hardware.mSampleRate).rounded(.up)) * 2)
      return io
    }

    /// Packed, interleaved 32-bit float: what `LiveInput` writes from.
    static func format(rate: Double, channels: Int) -> AudioStreamBasicDescription {
      let bytes = UInt32(channels * MemoryLayout<Float>.size)
      return AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: bytes,
        mFramesPerPacket: 1, mBytesPerFrame: bytes, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32,
        mReserved: 0)
    }

    private static func check(_ status: OSStatus, _ doing: String) throws {
      if status != noErr { throw Failure(doing, status) }
    }

    private static func set<Value>(
      _ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
      _ element: AudioUnitElement,
      _ value: inout Value, _ doing: String
    ) throws {
      try check(
        AudioUnitSetProperty(unit, property, scope, element, &value, UInt32(MemoryLayout<Value>.size)), doing)
    }

    private static func get<Value>(
      _ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
      _ element: AudioUnitElement,
      _ value: inout Value, _ doing: String
    ) throws {
      var size = UInt32(MemoryLayout<Value>.size)
      try check(AudioUnitGetProperty(unit, property, scope, element, &value, &size), doing)
    }
  }

  /// What the device's thread works with: made whole before the unit starts, and never changed
  /// from anywhere else while it runs.
  private final class InputIO: @unchecked Sendable {
    /// What the converter's input callback returns once it has handed over all there is: not an
    /// error, only "nothing more until the device gives more". The converter keeps its place.
    static let drained: OSStatus = 0x6472_6e64  // 'drnd'

    let unit: AudioUnit
    let input: LiveInput
    let channels: Int
    /// Frames the device may give at once, at its own rate.
    let capacity: Int
    let heard: UnsafeMutablePointer<Float>
    let heardList: UnsafeMutableAudioBufferListPointer
    /// To the rack's rate, where the device is at another; nil where it is not.
    let converter: AudioConverterRef?
    let convertedCapacity: Int
    let converted: UnsafeMutablePointer<Float>
    let convertedList: UnsafeMutableAudioBufferListPointer
    /// Frames heard and not yet taken by the converter. The device's thread's alone.
    var pending = 0

    init(
      unit: AudioUnit, input: LiveInput, channels: Int, deviceRate: Double, sampleRate: Double, frames: Int
    ) throws {
      var converter: AudioConverterRef?
      if deviceRate != sampleRate {
        var from = InputUnit.format(rate: deviceRate, channels: channels)
        var to = InputUnit.format(rate: sampleRate, channels: channels)
        let status = AudioConverterNew(&from, &to, &converter)
        guard status == noErr, converter != nil else {
          throw InputUnit.Failure("its rate could not be converted", status)
        }
      }
      self.unit = unit
      self.input = input
      self.channels = channels
      self.converter = converter
      capacity = frames
      heard = .allocate(capacity: frames * channels)
      heard.initialize(repeating: 0, count: frames * channels)
      heardList = AudioBufferList.allocate(maximumBuffers: 1)
      // Enough for all of a piece at the rack's rate, with room for what the converter held back.
      convertedCapacity = Int((Double(frames) * sampleRate / deviceRate).rounded(.up)) + 64
      converted = .allocate(capacity: convertedCapacity * channels)
      converted.initialize(repeating: 0, count: convertedCapacity * channels)
      convertedList = AudioBufferList.allocate(maximumBuffers: 1)
    }

    deinit {
      if let converter { AudioConverterDispose(converter) }
      heard.deallocate()
      converted.deallocate()
      free(heardList.unsafeMutablePointer)
      free(convertedList.unsafeMutablePointer)
    }

    /// A piece the device has: rendered out of the unit, converted if it must be, into the ring.
    func render(
      flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, time: UnsafePointer<AudioTimeStamp>,
      frames: UInt32
    ) -> OSStatus {
      let count = Int(frames)
      guard count <= capacity else { return kAudioUnitErr_TooManyFramesToProcess }
      heardList[0] = AudioBuffer(
        mNumberChannels: UInt32(channels), mDataByteSize: UInt32(count * channels * MemoryLayout<Float>.size),
        mData: UnsafeMutableRawPointer(heard))
      let status = AudioUnitRender(unit, flags, time, 1, frames, heardList.unsafeMutablePointer)
      guard status == noErr else { return status }
      guard let converter else {
        input.write(heard, frames: count, channels: channels)
        return noErr
      }
      pending = count
      var made = UInt32(convertedCapacity)
      convertedList[0] = AudioBuffer(
        mNumberChannels: UInt32(channels),
        mDataByteSize: UInt32(convertedCapacity * channels * MemoryLayout<Float>.size),
        mData: UnsafeMutableRawPointer(converted))
      // Returns `drained` once the piece is all taken, with what it made of it counted in `made`.
      _ = AudioConverterFillComplexBuffer(
        converter, converterSupply, Unmanaged.passUnretained(self).toOpaque(), &made,
        convertedList.unsafeMutablePointer,
        nil)
      if made > 0 { input.write(converted, frames: Int(made), channels: channels) }
      return noErr
    }

    /// The converter asking for more: the piece just heard, once, and then nothing.
    func supply(packets: UnsafeMutablePointer<UInt32>, data: UnsafeMutablePointer<AudioBufferList>)
      -> OSStatus
    {
      guard pending > 0 else {
        packets.pointee = 0
        return Self.drained
      }
      UnsafeMutableAudioBufferListPointer(data)[0] = AudioBuffer(
        mNumberChannels: UInt32(channels),
        mDataByteSize: UInt32(pending * channels * MemoryLayout<Float>.size),
        mData: UnsafeMutableRawPointer(heard))
      packets.pointee = UInt32(pending)
      pending = 0
      return noErr
    }
  }

  /// The unit's input callback, on the device's thread. Out here, at file scope, so that it belongs
  /// to no actor: Swift traps when the audio thread calls something of the main actor's.
  private func inputHeard(
    _ context: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ time: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
    _ data: UnsafeMutablePointer<AudioBufferList>?
  ) -> OSStatus {
    Unmanaged<InputIO>.fromOpaque(context).takeUnretainedValue().render(
      flags: flags, time: time, frames: frames)
  }

  /// The converter's input callback, on the same thread, inside `AudioConverterFillComplexBuffer`.
  private func converterSupply(
    _ converter: AudioConverterRef, _ packets: UnsafeMutablePointer<UInt32>,
    _ data: UnsafeMutablePointer<AudioBufferList>,
    _ descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ context: UnsafeMutableRawPointer?
  ) -> OSStatus {
    guard let context else { return InputIO.drained }
    return Unmanaged<InputIO>.fromOpaque(context).takeUnretainedValue().supply(packets: packets, data: data)
  }
#endif
