#if canImport(SwiftUI) && canImport(AVFoundation)
  import AVFoundation
  import AppKit
  import CoreAudioKit
  import DriftboxHost
  import DriftboxHostMac
  import DriftboxRack
  import DriftboxRackSession
  import SwiftUI

  /// The Audio Units on this Mac, as the plug-in modules' menus list them: by maker, then name. The
  /// effects for the `plugin` module, between two jacks; the instruments for `plugin-instrument`.
  enum PluginCatalogue {
    struct Entry: Identifiable, Equatable {
      var reference: PluginReference
      var id: String { reference.id }
    }

    /// Asked once: the component manager's search is slow enough to feel in a menu, and a unit
    /// installed while the app is open is found at its next launch.
    static let effects = find([kAudioUnitType_Effect, kAudioUnitType_MusicEffect])
    static let instruments = find([kAudioUnitType_MusicDevice])

    static func find(_ types: [OSType]) -> [(vendor: String, entries: [Entry])] {
      let manager = AVAudioUnitComponentManager.shared()
      var found: [Entry] = []
      for type in types {
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

  /// The Mac's plug-ins for the rack: Audio Units, made from what a patch remembers of them.
  @MainActor
  final class AudioUnitHosting: RackPluginHosting {
    func make(_ reference: PluginReference, sampleRate: Double) async throws -> any RackPluginUnit {
      guard reference.format == "audio-unit", let component = HostedAudioUnit.component(reference.id) else {
        throw RackPluginFailure.missing
      }
      do {
        return AudioUnitPlugin(
          try await HostedAudioUnit.instantiate(component, sampleRate: sampleRate, state: reference.state))
      } catch HostedAudioUnit.Failure.missing {
        throw RackPluginFailure.missing
      } catch HostedAudioUnit.Failure.format {
        throw RackPluginFailure.format
      }
    }
  }

  /// One Audio Unit in the rack, as the session asks for it: rendered by the host, its params by
  /// key for the macros, what it says as it changes, and its interface in a window of its own.
  @MainActor
  final class AudioUnitPlugin: RackPluginUnit {
    let hosted: HostedAudioUnit
    private var token: AUParameterObserverToken?
    private var interface: PluginInterface?
    private var opening = false

    init(_ hosted: HostedAudioUnit) { self.hosted = hosted }

    var external: RackExternal { hosted.external }
    var latency: Double { hosted.latency }
    var savedState: String? { hosted.savedState }

    var parameters: [String: RackPluginParameter] {
      hosted.parameters.mapValues { parameter in
        RackPluginParameter(
          key: parameter.keyPath, name: parameter.displayName, address: parameter.address,
          fraction: HostedAudioUnit.fraction(of: parameter))
      }
    }

    func map(_ slot: Int, to key: String?) { hosted.map(slot, to: key.flatMap { hosted.parameters[$0] }) }

    /// Heard about through the unit's parameter tree, which may call from any thread.
    var onChange: ((UInt64?) -> Void)? {
      didSet {
        if let token { hosted.unit.parameterTree?.removeParameterObserver(token) }
        token =
          onChange.map { changed in
            hosted.unit.parameterTree?.token(byAddingParameterObserver: Self.observer { changed($0) })
          } ?? nil
      }
    }

    /// An observer for a unit to call on whatever thread it likes, which a closure written here, on
    /// the main actor, would trap on: it hands the param moved to the main actor instead.
    nonisolated private static func observer(_ changed: @escaping @MainActor @Sendable (UInt64) -> Void)
      -> AUParameterObserver
    {
      { address, _ in Task { @MainActor in changed(address) } }
    }

    /// The unit's own interface, brought to the front, or opened. Closing it says the unit has
    /// changed, so whatever was done in it is kept, not only a param the tree happened to report.
    func showInterface(title: String) {
      if let interface { return interface.show() }
      guard !opening else { return }
      opening = true
      Task { [weak self, hosted] in
        let opened = await PluginInterface.open(hosted, title: title) { [weak self] in
          self?.interface = nil
          self?.onChange?(nil)
        }
        // Let go of while its window was being made: nothing left to show it for.
        guard let self else { return opened.close() }
        opening = false
        interface = opened
      }
    }

    func close() {
      onChange = nil
      interface?.close()
      interface = nil
    }
  }

  /// The plug-in modules' front: which unit it hosts and by whom, a menu of every effect — or, for
  /// an instrument, every instrument — on this Mac to choose another, its interface, how late it
  /// is, and what is wrong when it cannot play.
  struct PluginFace: View {
    let face: FaceContext

    var body: some View {
      let reference = face.module.plugin
      let status = face.model.plugins[face.module.id]
      let instrument = face.def.type == "plugin-instrument"
      PanelTitle(name: instrument ? "Instrument" : "Plug-in", mark: "AU") {
        HStack(spacing: 5) {
          Circle().fill(Self.lit(status) ? Theme.nine : Theme.dim.opacity(0.4)).frame(width: 5, height: 5)
            .shadow(color: Self.lit(status) ? Theme.nine : .clear, radius: 3)
          Text(Self.state(status, chosen: reference != nil))
        }
        .font(Theme.mono(8)).foregroundStyle(Theme.dim)
      }
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text(reference?.name ?? "No plug-in")
            .font(Theme.mono(12, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
          Text(Self.detail(reference, status, instrument: instrument))
            .font(Theme.mono(8.5)).foregroundStyle(Theme.dim).lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 6)
          buttons(reference: reference, status: status, instrument: instrument)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 0) {
          ForEach(1...4, id: \.self) { macro in self.macro(macro, ready: Self.lit(status)) }
        }
      }
      // An effect's buttons at the foot of its face; an instrument's above its keys.
      .frame(maxHeight: instrument ? RackLayout.cellHeight + 30 : .infinity)
      if instrument {
        let notes = face.reading?.notes ?? []
        NoteStrip(notes: notes)
          .frame(minHeight: 44, maxHeight: 120)
          .padding(.top, 10)
          .accessibilityLabel(
            notes.isEmpty ? "No notes sounding" : notes.map(RackKeyboard.name).joined(separator: ", "))
        Text(notes.isEmpty ? " " : notes.map(RackKeyboard.name).joined(separator: " "))
          .font(Theme.mono(8.5)).foregroundStyle(Theme.nine).lineLimit(1)
      }
      Spacer(minLength: 0)
    }

    /// Choosing a unit, opening it, and mapping its macros.
    private func buttons(reference: PluginReference?, status: RackSession.PluginStatus?, instrument: Bool)
      -> some View
    {
      let kind = instrument ? "instrument" : "effect"
      return HStack(spacing: 6) {
        Menu {
          let units = instrument ? PluginCatalogue.instruments : PluginCatalogue.effects
          if units.isEmpty { Text("No Audio Unit \(kind)s on this Mac") }
          ForEach(units, id: \.vendor) { group in
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
        .help("Choose an Audio Unit \(kind) on this Mac")
        // Only a unit that is running has controls to show, or to map.
        if Self.lit(status) {
          Button("Open") { face.rack.showInterface(face.module.id) }
            .buttonStyle(OptionStyle(on: false, tint: Theme.nine))
            .help("Open the plug-in's own controls in a window")
          Menu {
            ForEach(1...4, id: \.self) { macro in
              Menu(macroTitle(macro)) { macroMenu(macro) }
            }
          } label: {
            Text("Map…").font(Theme.mono(9, .semibold))
          }
          .menuStyle(.button)
          .buttonStyle(OptionStyle(on: false, tint: Theme.nine))
          .menuIndicator(.hidden)
          .fixedSize()
          .help("Choose what each macro turns in the plug-in")
        }
      }
    }

    /// Macro `macro`'s knob, named for what it turns and saying the value in that param's words.
    private func macro(_ macro: Int, ready: Bool) -> some View {
      let mapped = face.model.macroParameter(face.module.id, macro)
      let unit = face.model.units[face.module.id] as? AudioUnitPlugin
      let learning = face.model.learning.map { $0.module == face.module.id && $0.macro == macro } ?? false
      let display: (@Sendable (Double) -> String)? = mapped.flatMap {
        unit?.hosted.parameters[$0.control.key]
      }.map {
        parameter in
        let held = HeldParameter(parameter: parameter)
        return { HostedAudioUnit.display(held.parameter, at: $0) }
      }
      return face.control(
        "macro\(macro)", tint: learning ? Theme.three : Theme.nine,
        named: learning ? "Learn…" : mapped?.control.name ?? "Macro \(macro)", display: display
      )
      .opacity(mapped == nil && !learning ? 0.5 : 1)
      .contextMenu { if ready { macroMenu(macro) } }
      .help(
        learning
          ? "Move a control in the plug-in's window and macro \(macro) turns it"
          : mapped.map { "Macro \(macro) turns \($0.control.name)" } ?? "Macro \(macro): not mapped yet")
    }

    private func macroTitle(_ macro: Int) -> String {
      face.model.macroParameter(face.module.id, macro).map { "Macro \(macro): \($0.control.name)" }
        ?? "Macro \(macro)"
    }

    /// Map macro `macro` from the unit's own tree of params, learn it from its interface, or unmap it.
    @ViewBuilder
    private func macroMenu(_ macro: Int) -> some View {
      let id = face.module.id
      if let tree = (face.model.units[id] as? AudioUnitPlugin)?.hosted.unit.parameterTree {
        Menu("Map To") {
          ParameterMenu(nodes: tree.children) { face.model.mapMacro(id, macro, to: $0.keyPath) }
        }
      }
      Button("Learn from the Plug-in") { face.rack.learnMacro(id, macro) }
      if face.model.macroParameter(id, macro) != nil {
        Button("Unmap") { face.model.mapMacro(id, macro, to: nil) }
      }
    }

    static func lit(_ status: RackSession.PluginStatus?) -> Bool {
      if case .ready = status { true } else { false }
    }

    static func state(_ status: RackSession.PluginStatus?, chosen: Bool) -> String {
      switch status {
      case nil: chosen ? "" : "empty"
      case .loading: "loading"
      case .ready: "running"
      case .missing: "missing"
      case .failed: "failed"
      }
    }

    /// Under the name: who made it and how late it is, or why it is silent.
    static func detail(
      _ reference: PluginReference?, _ status: RackSession.PluginStatus?, instrument: Bool = false
    )
      -> String
    {
      guard let reference else {
        return instrument
          ? "An Audio Unit instrument, played by the rack's notes" : "An Audio Unit effect, in stereo"
      }
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

  /// Two octaves of keys with the sounding notes lit: from the C at or below the lowest, or C3
  /// while nothing sounds, so a chord stays where it is played.
  struct NoteStrip: View {
    let notes: [Int]
    static let blacks: Set<Int> = [1, 3, 6, 8, 10]

    var body: some View {
      let low = notes.first.map { max(0, min(103, $0 - $0 % 12)) } ?? 48
      let sounding = Set(notes)
      GeometryReader { geometry in
        let whites = (low..<low + 24).filter { !Self.blacks.contains($0 % 12) }
        let width = geometry.size.width / CGFloat(whites.count)
        ZStack(alignment: .topLeading) {
          ForEach(Array(whites.enumerated()), id: \.1) { index, note in
            RoundedRectangle(cornerRadius: 2)
              .fill(sounding.contains(note) ? Theme.nine : Theme.ink.opacity(0.82))
              .frame(width: width - 1.5, height: geometry.size.height)
              .offset(x: CGFloat(index) * width)
          }
          ForEach(Array(whites.enumerated()), id: \.1) { index, note in
            // The black key after this white one, if there is one.
            if Self.blacks.contains((note + 1) % 12), note + 1 < low + 24 {
              RoundedRectangle(cornerRadius: 1.5)
                .fill(sounding.contains(note + 1) ? Theme.nine : Theme.ground)
                .frame(width: width * 0.6, height: geometry.size.height * 0.6)
                .offset(x: CGFloat(index + 1) * width - width * 0.3 - 0.75)
            }
          }
        }
      }
      .animation(.easeOut(duration: 0.08), value: notes)
    }
  }

  /// A param for a closure that has to be `Sendable` to be kept: only ever called on the main actor,
  /// by the knob that shows it.
  struct HeldParameter: @unchecked Sendable {
    let parameter: AUParameter
  }

  /// A unit's params as its own tree groups them, a submenu to a group.
  struct ParameterMenu: View {
    let nodes: [AUParameterNode]
    let choose: (AUParameter) -> Void

    var body: some View {
      ForEach(nodes, id: \.keyPath) { node in
        if let group = node as? AUParameterGroup {
          // Behind `AnyView`, as a view whose body holds itself has no type to name.
          Menu(group.displayName) { AnyView(ParameterMenu(nodes: group.children, choose: choose)) }
        } else if let parameter = node as? AUParameter, parameter.flags.contains(.flag_IsWritable) {
          Button(parameter.displayName) { choose(parameter) }
        }
      }
    }
  }
#endif
