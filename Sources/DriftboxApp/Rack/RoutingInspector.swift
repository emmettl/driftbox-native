#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxRack
  import SwiftUI

  /// A Combinator's routing, to edit: which control moves which knob, and between what — the
  /// reference's `Modulation` panel. Beside the rack rather than on its back, as the reference
  /// keeps it in a panel of its own: a routing is read and typed rather than dragged, and it
  /// stays open while a rotary turns, so the value each routing is putting on its target can be
  /// watched moving. Source, target, min and max, and no more: anything else is a cable and an
  /// Offset, and the Combinator's value is that it is the simple one.
  struct RoutingInspector: View {
    let model: RackModel
    let combi: PatchModule

    var body: some View {
      let rows = model.patch.modulation.enumerated().filter { $0.element.from.module == combi.id }
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .firstTextBaseline) {
            Text("ROUTING").font(.system(size: 11, weight: .semibold)).tracking(0.8)
              .foregroundStyle(Theme.ink)
            Text(combi.id).font(Theme.mono(9)).foregroundStyle(Theme.dim)
            Spacer()
            Button {
              model.editRoutes(nil)
            } label: {
              Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Close the routing")
          }
          if rows.isEmpty {
            Text(
              "Nothing routed yet. A routing points one rotary or button at one knob anywhere in the rack; "
                + "the knob then moves when the rotary does, between the two ends set here."
            )
            .font(.system(size: 11)).foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
          }
          ForEach(rows, id: \.offset) { index, route in
            RouteRow(model: model, combi: combi, index: index, number: rowNumber(index, rows), route: route)
          }
          HStack {
            Button("Add Routing") { model.addRoute(combi.id) }
              .buttonStyle(.chip(on: true, tint: Theme.nine))
              .disabled(model.defaultTarget(combi.id) == nil)
              .help(
                model.defaultTarget(combi.id) == nil
                  ? "Nothing else in the rack has a knob to drive: add a module first" : "")
            Spacer()
          }
          Text("4 rotaries and 4 buttons · a later routing wins a shared target")
            .font(Theme.mono(8.5)).foregroundStyle(Theme.dim)
        }
        .padding(14)
      }
      .scrollIndicators(.automatic)
      .background(Theme.ground)
    }

    private func rowNumber(_ index: Int, _ rows: [EnumeratedSequence<[ModRoute]>.Element]) -> Int {
      (rows.firstIndex { $0.offset == index } ?? 0) + 1
    }
  }

  /// One routing: its source, its target module and knob, its two ends — blank meaning the
  /// target's own limit — and what it is putting on the target now.
  struct RouteRow: View {
    let model: RackModel
    let combi: PatchModule
    /// Where it is in the patch's routings, which is what the model edits it by.
    let index: Int
    /// Where it is among this Combinator's.
    let number: Int
    let route: ModRoute

    var body: some View {
      let target = model.patch.modules.first { $0.id == route.to.module }
      let param = target.flatMap { RackModel.routable($0.type).first { $0.id == route.to.port } }
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 6) {
          Text("\(number)").font(Theme.mono(9, .semibold)).foregroundStyle(Theme.three)
            .frame(width: 14, alignment: .leading)
          Picker("Source", selection: source) {
            ForEach(RackModel.routable(combi.type), id: \.id) { Text($0.name).tag($0.id) }
          }
          .labelsHidden()
          .fixedSize()
          Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Theme.dim)
          Picker("Target module", selection: module) {
            ForEach(targets, id: \.id) { Text($0.id).tag($0.id) }
            // A target this build cannot find is kept and shown, never quietly re-aimed.
            if target == nil { Text("\(route.to.module) (not here)").tag(route.to.module) }
          }
          .labelsHidden()
          Spacer(minLength: 0)
          Button {
            model.removeRoute(index)
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
          .help("Remove this routing")
          .accessibilityLabel("Remove routing \(number)")
        }
        HStack(spacing: 6) {
          Color.clear.frame(width: 14, height: 1)
          Picker("Target knob", selection: knob) {
            if let target {
              ForEach(RackModel.routable(target.type), id: \.id) { Text($0.name).tag($0.id) }
            }
            if param == nil { Text("\(route.to.port) (unknown)").tag(route.to.port) }
          }
          .labelsHidden()
        }
        HStack(spacing: 8) {
          Color.clear.frame(width: 14, height: 1)
          End(label: "Min", value: route.min, limit: param?.min) { value in
            model.setRoute(index) { $0.min = value }
          }
          End(label: "Max", value: route.max, limit: param?.max) { value in
            model.setRoute(index) { $0.max = value }
          }
          Spacer(minLength: 4)
          VStack(alignment: .trailing, spacing: 1) {
            Text("NOW").font(Theme.mono(7.5)).tracking(0.6).foregroundStyle(Theme.dim)
            Text(now(param).map(Self.round) ?? "—")
              .font(Theme.mono(11, .semibold)).foregroundStyle(Theme.nine)
              .contentTransition(.numericText())
              .help("What this routing is putting on its target now")
          }
        }
      }
      .padding(10)
      .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.panel))
      .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.edge))
    }

    /// Modules with a knob to drive.
    private var targets: [PatchModule] {
      model.patch.modules.filter { !RackModel.routable($0.type).isEmpty }
    }

    private var source: Binding<String> {
      Binding(
        get: { route.from.port },
        set: { port in model.setRoute(index) { $0.from = PortReference(combi.id, port) } })
    }

    private var module: Binding<String> {
      Binding(
        get: { route.to.module },
        set: { id in model.setRoute(index) { $0.to = PortReference(id, $0.to.port) } })
    }

    private var knob: Binding<String> {
      Binding(
        get: { route.to.port },
        set: { port in model.setRoute(index) { $0.to = PortReference($0.to.module, port) } })
    }

    /// What the routing is putting on its target, by the arithmetic the sound gets.
    private func now(_ param: ParamDef?) -> Double? {
      guard let param,
        let position = sourcePosition(model.patch.modules, registry: RackModules.registry, from: route.from)
      else { return nil }
      return routeValue(route, position: position, param: param)
    }

    /// Enough digits to be useful and few enough to fit: a cutoff in whole numbers, a resonance
    /// not, as the reference rounds it.
    static func round(_ value: Double) -> String {
      let rounded = abs(value) >= 100 ? RackDisplay.jsRound(value) : RackDisplay.jsRound(value * 100) / 100
      return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    /// One end of the range. Blank is the target's own limit, shown as the prompt rather than
    /// written in, so a module that later widens its range is swept to its new end.
    struct End: View {
      let label: String
      let value: Double?
      let limit: Double?
      let set: (Double?) -> Void

      var body: some View {
        VStack(alignment: .leading, spacing: 1) {
          Text(label.uppercased()).font(Theme.mono(7.5)).tracking(0.6).foregroundStyle(Theme.dim)
          TextField(
            label, value: Binding(get: { value }, set: { set($0) }),
            format: .number.grouping(.never).precision(.fractionLength(0...6)),
            prompt: Text(limit.map(RouteRow.round) ?? "")
          )
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .font(Theme.mono(10))
          .frame(width: 76)
        }
      }
    }
  }
#endif
