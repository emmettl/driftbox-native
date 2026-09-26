#if os(Linux)
  import CPipeWireBridge
  import DriftboxHost
  import Foundation

  @MainActor final class PipeWireDevices {
    struct Snapshot {
      var devices: [AudioDevice] = []
      var defaultName: String?
      var systemDefault: AudioDevice? { devices.first { $0.id == defaultName } }
    }
    private var handle: OpaquePointer?
    init() throws {
      var error = [CChar](repeating: 0, count: 512)
      handle = db_pw_discovery_open(&error, error.count)
      guard handle != nil else {
        throw PipeWireError(
          String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
      }
    }
    isolated deinit { db_pw_discovery_close(handle) }
    func snapshot() throws -> Snapshot? {
      let result = DeviceSnapshot()
      var error = [CChar](repeating: 0, count: 512)
      let status = db_pw_discovery_snapshot(
        handle, receiveDevice, Unmanaged.passUnretained(result).toOpaque(), &error, error.count)
      guard status >= 0 else {
        throw PipeWireError(
          String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
      }
      guard status == 1 else { return nil }
      result.value.devices.sort { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
      return result.value
    }
  }
  @MainActor private final class DeviceSnapshot {
    var value = PipeWireDevices.Snapshot()
  }
  private func receiveDevice(
    context: UnsafeMutableRawPointer?, name: UnsafePointer<CChar>?, description: UnsafePointer<CChar>?
  ) {
    guard let context, let description else { return }
    // The C snapshot invokes this synchronously on its caller, never on the PipeWire thread.
    let result = Unmanaged<DeviceSnapshot>.fromOpaque(context).takeUnretainedValue()
    let deviceName = name.map { String(cString: $0) }
    let label = String(cString: description)
    MainActor.assumeIsolated {
      if let deviceName {
        result.value.devices.append(
          AudioDevice(id: deviceName, name: label))
      } else {
        let data = Data(label.utf8)
        let metadata = try? JSONDecoder().decode([String: String].self, from: data)
        result.value.defaultName = metadata?["name"]
      }
    }
  }
#endif
