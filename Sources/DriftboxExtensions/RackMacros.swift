#if canImport(AVFoundation)
  import AVFoundation
  import DriftboxApp
  import DriftboxHostMac
  import DriftboxRack
  import DriftboxRackSession
  import Foundation
  import Synchronization

  /// One of the rack's macros, mapped onto a knob: a module's param, by the module's id.
  public struct RackMacro: Codable, Equatable, Sendable {
    public var module: String
    public var param: String

    public init(module: String, param: String) {
      self.module = module
      self.param = param
    }

    /// As many as an app has to automate; the same for every patch.
    public static let count = 8
    /// The key the unit's state keeps them under.
    static let stateKey = "macros"
  }

  /// The macros' params by address, for the app's words for a value, which it asks for on whatever
  /// thread it likes.
  final class MacroMap: Sendable {
    private let defs = Mutex([ParamDef?](repeating: nil, count: RackMacro.count))

    func set(_ defs: [ParamDef?]) { self.defs.withLock { $0 = defs } }

    func text(_ address: Int, _ fraction: Float) -> String {
      guard let def = defs.withLock({ address < $0.count ? $0[address] : nil }) else { return "—" }
      return RackParamText.display(def, RackPlugin.value(of: Double(fraction), on: def))
    }
  }

  extension RackPlugin {
    /// The macros as the unit's parameters, "Macro 1" to "Macro 8", each from 0 to 1 across the
    /// travel of the knob it is mapped onto.
    nonisolated static func publishMacros(on unit: RackAudioUnit, map: MacroMap) {
      let parameters = (0..<RackMacro.count).map { index in
        AUParameterTree.createParameter(
          withIdentifier: "macro\(index + 1)", name: "Macro \(index + 1)", address: AUParameterAddress(index),
          min: 0, max: 1, unit: .generic, unitName: nil,
          flags: [.flag_IsReadable, .flag_IsWritable, .flag_CanRamp], valueStrings: nil,
          dependentParameters: nil)
      }
      unit.publish(
        [AUParameterTree.createGroup(withIdentifier: "macros", name: "Macros", children: parameters)],
        count: RackMacro.count
      ) { address, value in map.text(address, value) }
    }

    /// A macro's travel, 0 to 1, as a value of `def`: a knob's across its range, a selector's the
    /// choice nearest.
    nonisolated static func value(of fraction: Double, on def: ParamDef) -> Double {
      let value = def.min + min(1, max(0, fraction)) * (def.max - def.min)
      return def.stepped ? value.rounded() : value
    }

    nonisolated static func fraction(of value: Double, on def: ParamDef) -> Double {
      def.max > def.min ? min(1, max(0, (value - def.min) / (def.max - def.min))) : 0
    }

    /// The param a macro is mapped onto, in the patch the rack has now; nil where the patch has no
    /// such module, or its type no such param.
    func target(_ macro: RackMacro?) -> (module: PatchModule, def: ParamDef)? {
      guard let macro, let session,
        let module = session.patch.modules.first(where: { $0.id == macro.module }),
        let def = RackModules.registry[module.type]?.params.first(where: { $0.id == macro.param })
      else { return nil }
      return (module, def)
    }

    /// The face's words for each macro: what it moves and where that is.
    public var macroSlots: [RackMacroStrip.Slot?] {
      macros.map { macro in
        guard let macro else { return nil }
        guard let (module, def) = target(macro), let session else {
          return RackMacroStrip.Slot(title: "\(macro.module) \(macro.param)", value: "—")
        }
        let owner = RackModules.registry[module.type]?.name ?? module.id
        return RackMacroStrip.Slot(
          title: "\(owner) \(def.name)", value: RackParamText.display(def, session.value(module, def)))
      }
    }

    /// Map macro `index` onto the next knob turned; the same again stops.
    public func learn(_ index: Int) {
      guard index >= 0, index < RackMacro.count else { return }
      if learning == index {
        learning = nil
        learnFrom = nil
      } else {
        learning = index
        learnFrom = session?.patch
      }
    }

    public func clearMacro(_ index: Int) {
      guard index >= 0, index < RackMacro.count else { return }
      if learning == index {
        learning = nil
        learnFrom = nil
      }
      macros[index] = nil
      macrosChanged()
    }

    /// What a state restored said the macros were mapped onto.
    func restoreMacros(_ extras: [String: String]) {
      guard let text = extras[RackMacro.stateKey],
        let restored = try? JSONDecoder().decode([RackMacro?].self, from: Data(text.utf8))
      else { return }
      macros = (0..<RackMacro.count).map { $0 < restored.count ? restored[$0] : nil }
      macrosChanged()
    }

    /// The first knob turned between two patches: a param of a module both have, that a knob turns.
    static func turned(from before: Patch, to after: Patch) -> RackMacro? {
      for module in after.modules {
        guard let was = before.modules.first(where: { $0.id == module.id }),
          let defs = RackModules.registry[module.type]?.params
        else { continue }
        for def in defs where !def.hidden && module.params[def.id] != was.params[def.id] {
          return RackMacro(module: module.id, param: def.id)
        }
      }
      return nil
    }

    /// As often as the face draws: a knob learnt, the app's moves into the rack, and the rack's
    /// knobs out to the app.
    func macroTick(_ unit: RackAudioUnit, _ session: RackSession) {
      if let index = learning, let from = learnFrom, session.patch != from {
        if let turned = Self.turned(from: from, to: session.patch) {
          macros[index] = turned
          learning = nil
          learnFrom = nil
          macrosChanged()
        } else {
          // Something else changed — a cable, a module — and the next knob turned is still the one.
          learnFrom = session.patch
        }
      }
      for move in unit.movedParameters() {
        guard move.address < macros.count, let (module, def) = target(macros[move.address]) else { continue }
        let fraction = Double("\(move.value)") ?? Double(move.value)
        session.automate(module.id, def.id, to: Self.value(of: fraction, on: def))
      }
      guard session.patch != macrosShown else { return }
      macrosShown = session.patch
      // Another patch may not have what a macro was mapped onto, or have it again.
      macroMap.set(macros.map { target($0)?.def })
      for (index, macro) in macros.enumerated() {
        guard let (module, def) = target(macro) else { continue }
        unit.show(Float(Self.fraction(of: session.value(module, def), on: def)), at: index)
      }
    }

    /// The macros mapped differently: kept in the unit's state, their params for the app's words, and
    /// shown to the app afresh.
    func macrosChanged() {
      macroMap.set(macros.map { target($0)?.def })
      if let data = try? JSONEncoder().encode(macros) {
        unit?.extras.withLock { $0[RackMacro.stateKey] = String(decoding: data, as: UTF8.self) }
      }
      macrosShown = nil
    }
  }
#endif
