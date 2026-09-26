#if os(Windows)
  import CWASAPI
  import WinSDK

  /// Word from Windows that a device came, went, or became the system's — a render device or a
  /// capture one, as its enumerator lists them: an `IMMNotificationClient`, which is a COM object,
  /// built by hand because nothing in Swift builds one. It is a vtable pointer followed by what the
  /// callbacks need; COM only ever sees the first.
  ///
  /// Windows calls it on a thread of its own, and a callback there must not wait on anything that
  /// might be waiting on it — which a device change on the interface's thread could be — so all it
  /// does is call `changed`, whose job is to hop somewhere else.
  final class DeviceNotifications {
    private struct Object {
      var com: IMMNotificationClient
      var changed: Unmanaged<Callback>
      var flow: EDataFlow
    }

    private final class Callback {
      let body: @Sendable () -> Void
      init(_ body: @escaping @Sendable () -> Void) { self.body = body }
    }

    /// Made once and never written again, so shared between threads without harm.
    nonisolated(unsafe) private static let vtable: UnsafeMutablePointer<IMMNotificationClientVtbl> = {
      let table = UnsafeMutablePointer<IMMNotificationClientVtbl>.allocate(capacity: 1)
      table.initialize(
        to: IMMNotificationClientVtbl(
          QueryInterface: { this, iid, out in
            guard let out else { return HRESULT(bitPattern: 0x8000_4003) }  // E_POINTER
            if COM.equal(iid, COM.iidUnknown) || COM.equal(iid, COM.iidNotificationClient) {
              out.pointee = UnsafeMutableRawPointer(this)
              return S_OK
            }
            out.pointee = nil
            return HRESULT(bitPattern: 0x8000_4002)  // E_NOINTERFACE
          },
          // Its lifetime is this class's, not COM's: registered for as long as the class lives,
          // unregistered before it goes.
          AddRef: { _ in 1 },
          Release: { _ in 1 },
          OnDeviceStateChanged: { this, _, _ in DeviceNotifications.fire(this) },
          OnDeviceAdded: { this, _ in DeviceNotifications.fire(this) },
          OnDeviceRemoved: { this, _ in DeviceNotifications.fire(this) },
          OnDefaultDeviceChanged: { this, flow, _, _ in
            guard let this else { return S_OK }
            let listened = UnsafeMutableRawPointer(this).assumingMemoryBound(to: Object.self).pointee.flow
            return flow == listened ? DeviceNotifications.fire(this) : S_OK
          },
          OnPropertyValueChanged: { _, _, _ in S_OK }))
      return table
    }()

    private static func fire(_ this: UnsafeMutablePointer<IMMNotificationClient>?) -> HRESULT {
      guard let this else { return S_OK }
      UnsafeMutableRawPointer(this).assumingMemoryBound(to: Object.self).pointee.changed
        ._withUnsafeGuaranteedRef { $0.body() }
      return S_OK
    }

    private let enumerator: DeviceEnumerator
    private let object: UnsafeMutablePointer<Object>

    init(enumerator: DeviceEnumerator, changed: @escaping @Sendable () -> Void) {
      self.enumerator = enumerator
      object = .allocate(capacity: 1)
      object.initialize(
        to: Object(
          com: IMMNotificationClient(lpVtbl: Self.vtable), changed: Unmanaged.passRetained(Callback(changed)),
          flow: enumerator.flow)
      )
      let client = UnsafeMutableRawPointer(object).assumingMemoryBound(to: IMMNotificationClient.self)
      _ = enumerator.pointer.pointee.lpVtbl.pointee.RegisterEndpointNotificationCallback(
        enumerator.pointer, client)
    }

    deinit {
      let client = UnsafeMutableRawPointer(object).assumingMemoryBound(to: IMMNotificationClient.self)
      // Returns once no callback is running, so nothing below is freed from under one.
      _ = enumerator.pointer.pointee.lpVtbl.pointee.UnregisterEndpointNotificationCallback(
        enumerator.pointer, client)
      object.pointee.changed.release()
      object.deinitialize(count: 1)
      object.deallocate()
    }
  }
#endif
