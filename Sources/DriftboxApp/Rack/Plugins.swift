#if canImport(SwiftUI) && canImport(AVFoundation)
  import AVFoundation
  import AppKit
  import CoreAudioKit
  import DriftboxHost
  import DriftboxRack
  import SwiftUI

  /// The Audio Unit effects on this Mac, as the plug-in module's menu lists them: by maker, then
  /// name. Instruments are left out, since the module is an effect between two jacks.
  enum PluginCatalogue {
    struct Entry: Identifiable, Equatable {
      var reference: PluginReference
      var id: String { reference.id }
    }

    /// Asked once: the component manager's search is slow enough to feel in a menu, and a unit
    /// installed while the app is open is found at its next launch.
    static let effects = find()

    static func find() -> [(vendor: String, entries: [Entry])] {
      let manager = AVAudioUnitComponentManager.shared()
      var found: [Entry] = []
      for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
        let wanted = AudioComponentDescription(
          componentType: type, componentSubType: 0, componentManufacturer: 0, componentFlags: 0,
          componentFlagsMask: 0)
        for component in manager.components(matching: wanted) {
          found.append(
            Entry(
              reference: PluginReference(
                format: "audio-unit", id: HostedAudioUnit.identifier(component.audioComponentDescription),
                name: component.name, vendor: component.manufacturerName)))
        }
      }
      let byVendor = Dictionary(grouping: found) { $0.reference.vendor }
      return byVendor.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { vendor in
        (
          vendor,
          byVendor[vendor]!.sorted {
            $0.reference.name.localizedStandardCompare($1.reference.name) == .orderedAscending
          }
        )
      }
    }
  }

  /// A unit's own interface, in a window of its own: the view it draws, or the system's generic
  /// one of its parameters when it draws none.
  @MainActor
  final class PluginInterface: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let closed: () -> Void

    private init(_ controller: NSViewController, title: String, closed: @escaping () -> Void) {
      let size = controller.preferredContentSize
      let fitting = controller.view.fittingSize
      let width = size.width > 0 ? size.width : max(fitting.width, 360)
      let height = size.height > 0 ? size.height : max(fitting.height, 240)
      window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
      self.closed = closed
      super.init()
      window.contentViewController = controller
      window.setContentSize(NSSize(width: width, height: height))
      window.title = title
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.center()
    }

    /// Ask `unit` for its interface and show it.
    static func open(_ unit: HostedAudioUnit, title: String, closed: @escaping () -> Void) async
      -> PluginInterface
    {
      let own = await viewController(of: unit.unit)
      let controller: NSViewController
      if let own {
        controller = own
      } else {
        let generic = AUGenericViewController()
        generic.auAudioUnit = unit.unit
        controller = generic
      }
      let interface = PluginInterface(controller, title: title, closed: closed)
      interface.window.makeKeyAndOrderFront(nil)
      return interface
    }

    /// The unit's own view, if it has one. Not on the main actor: a unit may answer on any thread,
    /// and a completion written on the main actor would trap there.
    nonisolated private static func viewController(of unit: AUAudioUnit) async -> NSViewController? {
      await withCheckedContinuation { continuation in
        unit.requestViewController { continuation.resume(returning: $0) }
      }
    }

    func show() { window.makeKeyAndOrderFront(nil) }

    /// Closed from the rack, for a unit that has gone.
    func close() {
      window.delegate = nil
      window.close()
    }

    func windowWillClose(_ notification: Notification) { closed() }
  }

  extension RackModel {
    /// A `plugin` module's unit's own interface, brought to the front, or opened.
    func showInterface(_ moduleId: String) {
      if let open = interfaces[moduleId] {
        open.show()
        return
      }
      guard let unit = units[moduleId],
        let reference = patch.modules.first(where: { $0.id == moduleId })?.plugin
      else { return }
      Task { [weak self] in
        let interface = await PluginInterface.open(unit, title: "\(reference.name) — \(moduleId)") {
          [weak self] in
          guard let self else { return }
          interfaces[moduleId] = nil
          // Whatever was done in it is kept now, not only once a param happens to be observed.
          unitChanged(moduleId)
        }
        // The unit may have gone, or been given an interface already, while this one was made.
        guard let self, units[moduleId] === unit, interfaces[moduleId] == nil else {
          interface.close()
          return
        }
        interfaces[moduleId] = interface
      }
    }
  }

  /// The plug-in module's front: which unit it hosts and by whom, a menu of every effect on this
  /// Mac to choose another, its interface, how late it is, and what is wrong when it cannot play.
  struct PluginFace: View {
    let face: FaceContext

    var body: some View {
      let reference = face.module.plugin
      let status = face.model.plugins[face.module.id]
      PanelTitle(name: "Plug-in", mark: "AU") {
        HStack(spacing: 5) {
          Circle().fill(Self.lit(status) ? Theme.nine : Theme.dim.opacity(0.4)).frame(width: 5, height: 5)
            .shadow(color: Self.lit(status) ? Theme.nine : .clear, radius: 3)
          Text(Self.state(status, chosen: reference != nil))
        }
        .font(Theme.mono(8)).foregroundStyle(Theme.dim)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(reference?.name ?? "No plug-in")
          .font(Theme.mono(12, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
        Text(Self.detail(reference, status))
          .font(Theme.mono(8.5)).foregroundStyle(Theme.dim).lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
      HStack(spacing: 6) {
        Menu {
          let effects = PluginCatalogue.effects
          if effects.isEmpty { Text("No Audio Unit effects on this Mac") }
          ForEach(effects, id: \.vendor) { group in
            Section(group.vendor) {
              ForEach(group.entries) { entry in
                Button(entry.reference.name) { face.model.choosePlugin(face.module.id, entry.reference) }
              }
            }
          }
        } label: {
          Text(reference == nil ? "Choose…" : "Change…").font(Theme.mono(9, .semibold))
        }
        .menuStyle(.button)
        .buttonStyle(OptionStyle(on: reference == nil, tint: Theme.nine))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose an Audio Unit effect on this Mac")
        // Only a unit that is running has controls to show.
        if Self.lit(status) {
          Button("Open") { face.model.showInterface(face.module.id) }
            .buttonStyle(OptionStyle(on: false, tint: Theme.nine))
            .help("Open the plug-in's own controls in a window")
        }
      }
    }

    static func lit(_ status: RackModel.PluginStatus?) -> Bool {
      if case .ready = status { true } else { false }
    }

    static func state(_ status: RackModel.PluginStatus?, chosen: Bool) -> String {
      switch status {
      case nil: chosen ? "" : "empty"
      case .loading: "loading"
      case .ready: "running"
      case .missing: "missing"
      case .failed: "failed"
      }
    }

    /// Under the name: who made it and how late it is, or why it is silent.
    static func detail(_ reference: PluginReference?, _ status: RackModel.PluginStatus?) -> String {
      guard let reference else { return "An Audio Unit effect, in stereo" }
      switch status {
      case .ready(let latency) where latency > 0:
        return "\(reference.vendor) · \(RackDisplay.fixed(latency * 1000, 1)) ms late"
      case .missing:
        return "Not on this Mac. Kept in the patch, silent here."
      case .failed(let reason):
        return reason
      default:
        return reference.vendor
      }
    }
  }
#endif
