import DriftboxRack
import DriftboxRackSession
import DriftboxShell

/// The menus of the platform's plug-ins: the Add menu's, a plug-in module's own to choose another,
/// and its macros', each onto one of its plug-in's params.
extension RackInterface {
  /// The platform's plug-ins, effects and instruments apart, each by who made them: one chosen is
  /// added with its module, in one step. While they are being found, or where there are none, the
  /// menu says so.
  func pluginMenus() -> [MenuItem] {
    let kinds = [
      (title: "Effect Plug-ins", instrument: false), (title: "Instrument Plug-ins", instrument: true),
    ]
    return kinds.map { kind in
      .submenu(
        Menu(
          kind.title,
          pluginItems(instrument: kind.instrument) { choice in
            self.rack.add(choice.moduleType, plugin: choice.reference)
          }))
    }
  }

  /// The plug-in a module hosts, chosen from those of its kind: the one it has ticked.
  func pluginMenu(_ moduleId: String) -> Menu {
    resetMenu()
    rack.findPlugins()
    let module = rack.patch.modules.first { $0.id == moduleId }
    let instrument = module?.type == "plugin-instrument"
    let items = pluginItems(instrument: instrument, current: module?.plugin) { choice in
      self.rack.choosePlugin(moduleId, choice.reference)
    }
    return Menu("Plug-in", items)
  }

  /// A kind's plug-ins by who made them, in order, `current` ticked; or, while they are being found
  /// or where there are none, a line that says so.
  func pluginItems(
    instrument: Bool, current: PluginReference? = nil, choose: @escaping (RackPluginChoice) -> Void
  ) -> [MenuItem] {
    guard case .found(let choices) = rack.pluginChoices else {
      return [item("Finding Plug-ins…", "plugins.finding", enabled: false) {}]
    }
    let wanted = choices.filter { $0.instrument == instrument }
    guard !wanted.isEmpty else {
      let none = instrument ? "No Instruments Installed" : "No Effects Installed"
      return [item(none, "plugins.none.\(instrument)", enabled: false) {}]
    }
    let byVendor = Dictionary(grouping: wanted) {
      $0.reference.vendor.isEmpty ? "Other" : $0.reference.vendor
    }
    // Case aside, and without the old Foundation's localized comparison, which Android does not link.
    let vendors = byVendor.keys.sorted { $0.lowercased() < $1.lowercased() }
    return vendors.map { vendor in
      let sorted = (byVendor[vendor] ?? []).sorted {
        $0.reference.name.lowercased() < $1.reference.name.lowercased()
      }
      return .submenu(
        Menu(
          vendor,
          sorted.map { choice in
            let chosen = current?.format == choice.reference.format && current?.id == choice.reference.id
            return item(
              choice.reference.name, "plugin.\(choice.reference.format).\(choice.reference.id)",
              checked: chosen
            ) { choose(choice) }
          }))
    }
  }

  /// Each macro of a plug-in module, onto one of its plug-in's params, the one it turns ticked; or
  /// unmapped. A plug-in with more params than a menu holds comfortably has them in runs.
  func macroMenu(_ moduleId: String) -> Menu {
    resetMenu()
    guard let unit = rack.units[moduleId] else {
      return Menu("Macros", [item("The Plug-in Is Not Running", "macro.none", enabled: false) {}])
    }
    let parameters = unit.parameters.values.sorted {
      $0.name.lowercased() < $1.name.lowercased()
    }
    return Menu(
      "Macros",
      (1...4).map { macro in
        let mapped = rack.macroParameter(moduleId, macro)?.control
        let choices = parameters.map { parameter in
          item(parameter.name, "macro.\(macro).\(parameter.key)", checked: mapped?.key == parameter.key) {
            self.rack.mapMacro(moduleId, macro, to: parameter.key)
          }
        }
        var items = Self.runs(choices, names: parameters.map(\.name))
        if items.isEmpty { items = [item("No Params to Map", "macro.\(macro).none", enabled: false) {}] }
        if mapped != nil {
          items += [
            .separator,
            item("Unmap", "macro.\(macro).unmap") { self.rack.mapMacro(moduleId, macro, to: nil) },
          ]
        }
        return .submenu(Menu(mapped.map { "Macro \(macro): \($0.name)" } ?? "Macro \(macro)", items))
      })
  }

  /// `items` as they are, or, past forty, in runs of thirty, each named from its first to its last.
  static func runs(_ items: [MenuItem], names: [String]) -> [MenuItem] {
    guard items.count > 40 else { return items }
    return stride(from: 0, to: items.count, by: 30).map { start in
      let end = min(items.count, start + 30)
      return .submenu(Menu("\(names[start]) – \(names[end - 1])", Array(items[start..<end])))
    }
  }

  /// A menu about to be built: nothing from the last one can be chosen from it.
  func resetMenu() {
    menuActions = [:]
    menuDisabled = []
    menuChecked = []
  }
}
