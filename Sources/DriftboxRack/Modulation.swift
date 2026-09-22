// Combinator routings: one knob driving others across a range, applied to a patch's params when it
// is compiled, so what a patch sounds like is a property of the patch. A port of
// `driftbox/packages/rack/src/modulation.ts`.

/// The patch with its routings applied. Until the Combinator is ported, the patch as it is.
func applyModulation(_ patch: Patch, registry: [String: ModuleDef]) -> Patch {
  patch
}
