import DriftboxDSP

// Combinator routings: one knob driving others across a range, applied to a patch's params when it
// is compiled, so what a patch sounds like is a property of the patch. A port of
// `driftbox/packages/rack/src/modulation.ts`, which has the reasoning: routes apply in order, in
// one pass over a working copy, so a route reads what an earlier route wrote, and when two routes
// write one target the later one wins.

/// What a param reads, falling back to its default: the rule `compile` uses too.
func modulatedParamValue(_ module: PatchModule, _ def: ModuleDef, _ paramId: String) -> Double? {
  guard let param = def.params.first(where: { $0.id == paramId }) else { return nil }
  if let saved = module.params[paramId], saved.isFinite { return saved }
  return param.defaultValue
}

/// Where a route's source sits, 0..1 across its own range. Normalised rather than assumed, so a
/// route can be driven by a rotary, a button, or any other module's param.
public func sourcePosition(
  _ modules: [PatchModule], registry: [String: ModuleDef], from: PortReference
) -> Double? {
  guard let module = modules.first(where: { $0.id == from.module }),
    let def = registry[module.type],
    let param = def.params.first(where: { $0.id == from.port }),
    let value = modulatedParamValue(module, def, from.port)
  else { return nil }
  let span = param.max - param.min
  if span == 0 { return 0 }
  let position = (value - param.min) / span
  return position < 0 ? 0 : position > 1 ? 1 : position
}

/// What one route puts on its target: linear between the route's `min` and `max` (inverted when
/// `min > max`), clamped to the target's range, and rounded as `Math.round` does when the target
/// is stepped.
public func routeValue(_ route: ModRoute, position: Double, param: ParamDef) -> Double {
  let low = route.min.flatMap { $0.isFinite ? $0 : nil } ?? param.min
  let high = route.max.flatMap { $0.isFinite ? $0 : nil } ?? param.max
  var value = low + (high - low) * position
  if value < param.min { value = param.min } else if value > param.max { value = param.max }
  return param.stepped ? jsRound(value) : value
}

/// The patch with its routings applied. A route naming a module or param this build does not
/// have, or a hidden one, is skipped and kept, never deleted.
public func applyModulation(_ patch: Patch, registry: [String: ModuleDef]) -> Patch {
  let routes = patch.modulation
  if routes.isEmpty { return patch }

  // The reference's working copy is a `Map` keyed by id: an id keeps the place it first took, and
  // holds the last module that had it.
  var order: [String] = []
  var working: [String: PatchModule] = [:]
  for module in patch.modules {
    if working[module.id] == nil { order.append(module.id) }
    working[module.id] = module
  }
  var changed = false

  for route in routes {
    // Rebuilt for every route, so a route's source reads what an earlier route wrote.
    let live = order.compactMap { working[$0] }

    guard let target = live.first(where: { $0.id == route.to.module }),
      let def = registry[target.type],
      let param = def.params.first(where: { $0.id == route.to.port }),
      !param.hidden,
      let position = sourcePosition(live, registry: registry, from: route.from)
    else { continue }

    let value = routeValue(route, position: position, param: param)
    if modulatedParamValue(target, def, param.id) == value { continue }

    var updated = target
    updated.params[param.id] = value
    working[target.id] = updated
    changed = true
  }

  if !changed { return patch }
  var result = patch
  result.modules = patch.modules.map { working[$0.id] ?? $0 }
  return result
}
