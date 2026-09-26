#if os(Windows)
  import CWASAPI
  import DriftboxHost
  import WinSDK

  /// The few pieces of COM the audio adapter needs, named once.
  enum COM {
    static let clsidDeviceEnumerator = GUID(
      Data1: 0xBCDE_0395, Data2: 0xE52F, Data3: 0x467C,
      Data4: (0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E))
    static let iidDeviceEnumerator = GUID(
      Data1: 0xA956_64D2, Data2: 0x9614, Data3: 0x4F35,
      Data4: (0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6))
    static let iidAudioClient = GUID(
      Data1: 0x1CB9_AD4C, Data2: 0xDBFA, Data3: 0x4C32,
      Data4: (0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2))
    static let iidAudioRenderClient = GUID(
      Data1: 0xF294_ACFC, Data2: 0x3146, Data3: 0x4483,
      Data4: (0xA7, 0xBF, 0xAD, 0xDC, 0xA7, 0xC2, 0x60, 0xE2))
    static let iidAudioCaptureClient = GUID(
      Data1: 0xC8AD_BD64, Data2: 0xE71E, Data3: 0x48A0,
      Data4: (0xA4, 0xDE, 0x18, 0x5C, 0x39, 0x5C, 0xD3, 0x17))
    static let iidNotificationClient = GUID(
      Data1: 0x7991_EEC9, Data2: 0x7E89, Data3: 0x4D85,
      Data4: (0x83, 0x90, 0x6C, 0x70, 0x3C, 0xEC, 0x60, 0xC0))
    static let iidUnknown = GUID(
      Data1: 0, Data2: 0, Data3: 0, Data4: (0xC0, 0, 0, 0, 0, 0, 0, 0x46))
    static let friendlyName = PROPERTYKEY(
      fmtid: GUID(
        Data1: 0xA45C_254E, Data2: 0xDF1C, Data3: 0x4EFD,
        Data4: (0x80, 0x20, 0x67, 0xD1, 0x46, 0xA8, 0x50, 0xE0)),
      pid: 14)

    /// `AUDCLNT_E_DEVICE_INVALIDATED`: the device went away under the stream.
    static let deviceInvalidated = HRESULT(bitPattern: 0x8889_0004)
    /// `AUDCLNT_E_DEVICE_IN_USE`: another program has the device to itself.
    static let deviceInUse = HRESULT(bitPattern: 0x8889_000A)
    /// `E_ACCESSDENIED`, which is what a microphone Windows's privacy settings keep from desktop
    /// apps says.
    static let accessDenied = HRESULT(bitPattern: 0x8007_0005)

    /// COM for the calling thread, in whatever apartment it already has if it has one: a thread
    /// that has chosen before is left as it chose.
    static func initialize(multithreaded: Bool) {
      let mode = multithreaded ? COINIT_MULTITHREADED.rawValue : COINIT_APARTMENTTHREADED.rawValue
      _ = CoInitializeEx(nil, DWORD(mode))
    }

    static func equal(_ a: UnsafePointer<GUID>?, _ b: GUID) -> Bool {
      guard var a = a?.pointee else { return false }
      var b = b
      return memcmp(&a, &b, MemoryLayout<GUID>.size) == 0
    }

    /// A wide C string, as Swift.
    static func string(_ wide: UnsafePointer<WCHAR>?) -> String? {
      wide.map { String(decodingCString: $0, as: UTF16.self) }
    }
  }

  extension HRESULT {
    var succeeded: Bool { self >= 0 }
  }

  /// Every device there is one way — render, or capture — and the system's own: the part of the
  /// device API the main thread uses. Made on the thread that asks, in that thread's apartment.
  final class DeviceEnumerator {
    let pointer: UnsafeMutablePointer<IMMDeviceEnumerator>
    let flow: EDataFlow

    init?(flow: EDataFlow = eRender) {
      self.flow = flow
      var raw: UnsafeMutableRawPointer?
      var clsid = COM.clsidDeviceEnumerator
      var iid = COM.iidDeviceEnumerator
      guard CoCreateInstance(&clsid, nil, DWORD(CLSCTX_INPROC_SERVER.rawValue), &iid, &raw).succeeded,
        let raw
      else { return nil }
      pointer = raw.assumingMemoryBound(to: IMMDeviceEnumerator.self)
    }

    deinit { _ = pointer.pointee.lpVtbl.pointee.Release(pointer) }

    /// Every active device its way, in the system's order.
    func devices() -> [AudioDevice] {
      var collection: UnsafeMutablePointer<IMMDeviceCollection>?
      guard
        pointer.pointee.lpVtbl.pointee.EnumAudioEndpoints(
          pointer, flow, DWORD(DEVICE_STATE_ACTIVE), &collection
        )
        .succeeded, let collection
      else { return [] }
      defer { _ = collection.pointee.lpVtbl.pointee.Release(collection) }
      var count: UINT = 0
      _ = collection.pointee.lpVtbl.pointee.GetCount(collection, &count)
      return (0..<count).compactMap { index in
        var device: UnsafeMutablePointer<IMMDevice>?
        guard collection.pointee.lpVtbl.pointee.Item(collection, index, &device).succeeded, let device else {
          return nil
        }
        defer { _ = device.pointee.lpVtbl.pointee.Release(device) }
        return Self.record(device)
      }
    }

    /// The device the system plays music through, or listens to.
    func systemDefault() -> AudioDevice? {
      var device: UnsafeMutablePointer<IMMDevice>?
      guard
        pointer.pointee.lpVtbl.pointee.GetDefaultAudioEndpoint(pointer, flow, eMultimedia, &device)
          .succeeded,
        let device
      else { return nil }
      defer { _ = device.pointee.lpVtbl.pointee.Release(device) }
      return Self.record(device)
    }

    /// The device with endpoint ID `id`, retained; nil if it is not there.
    func device(id: String) -> UnsafeMutablePointer<IMMDevice>? {
      var device: UnsafeMutablePointer<IMMDevice>?
      let found = id.withCString(encodedAs: UTF16.self) { id in
        pointer.pointee.lpVtbl.pointee.GetDevice(pointer, id, &device)
      }
      return found.succeeded ? device : nil
    }

    static func record(_ device: UnsafeMutablePointer<IMMDevice>) -> AudioDevice? {
      var wide: LPWSTR?
      guard device.pointee.lpVtbl.pointee.GetId(device, &wide).succeeded, let id = COM.string(wide) else {
        return nil
      }
      CoTaskMemFree(wide)
      return AudioDevice(id: id, name: name(device) ?? id)
    }

    static func name(_ device: UnsafeMutablePointer<IMMDevice>) -> String? {
      var store: UnsafeMutablePointer<IPropertyStore>?
      guard device.pointee.lpVtbl.pointee.OpenPropertyStore(device, DWORD(STGM_READ), &store).succeeded,
        let store
      else { return nil }
      defer { _ = store.pointee.lpVtbl.pointee.Release(store) }
      var key = COM.friendlyName
      var value = PROPVARIANT()
      guard store.pointee.lpVtbl.pointee.GetValue(store, &key, &value).succeeded else { return nil }
      defer { PropVariantClear(&value) }
      return COM.string(cwasapi_string(&value))
    }
  }

#endif
