#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxRack
  import SwiftUI

  /// A param's value in words, as its knob on a faceplate shows it: for an app showing a macro
  /// mapped onto it.
  public enum RackParamText {
    public static func display(_ def: ParamDef, _ value: Double) -> String {
      def.stepped ? "\(Int(value.rounded()))" : ParamControl.display(def, value)
    }
  }

  /// The rack's macros, as it shows them inside another app: the parameters the app automates, each
  /// mapped onto one of the rack's knobs. A macro is mapped by learning — click it, then turn the
  /// knob — and unmapped from its menu.
  public struct RackMacroStrip: View {
    /// What a macro is mapped onto, in words, and where that is now; nil for one mapped onto nothing.
    public struct Slot: Sendable {
      public let title: String
      public let value: String
      public init(title: String, value: String) {
        self.title = title
        self.value = value
      }
    }

    let slots: [Slot?]
    let learning: Int?
    let learn: (Int) -> Void
    let clear: (Int) -> Void

    public init(
      slots: [Slot?], learning: Int?, learn: @escaping (Int) -> Void, clear: @escaping (Int) -> Void
    ) {
      self.slots = slots
      self.learning = learning
      self.learn = learn
      self.clear = clear
    }

    public var body: some View {
      HStack(spacing: 6) {
        Text("MACROS")
          .font(Theme.mono(9, .semibold)).tracking(0.8).foregroundStyle(Theme.dim)
          .fixedSize()
          .padding(.trailing, 4)
        ForEach(slots.indices, id: \.self) { index in
          macro(index)
        }
      }
      .padding(.horizontal, 14).padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.ground)
      .overlay(alignment: .bottom) { Rectangle().fill(Theme.edge).frame(height: 1) }
    }

    private func macro(_ index: Int) -> some View {
      let slot = slots[index]
      let armed = learning == index
      return Button {
        learn(index)
      } label: {
        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 4) {
            Text("\(index + 1)").font(Theme.mono(9, .semibold))
            if let slot { Text(slot.value).font(Theme.mono(9)).foregroundStyle(Theme.dim) }
          }
          Text(armed ? "turn a knob" : slot?.title ?? "learn")
            .font(Theme.mono(9, armed || slot != nil ? .medium : .regular))
            .lineLimit(1).truncationMode(.tail)
        }
        .frame(minWidth: 64, maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.chip(on: armed || slot != nil, tint: armed ? Theme.three : Theme.nine, size: 9))
      .contextMenu {
        Button("Learn") { learn(index) }
        Button("Clear") { clear(index) }.disabled(slot == nil)
      }
      .help(
        armed
          ? "Turn any knob in the rack to map macro \(index + 1) onto it; click again to stop"
          : slot.map { "Macro \(index + 1) moves \($0.title). Click to learn another knob." }
            ?? "Click, then turn any knob in the rack, to let the app automate it as macro \(index + 1)")
    }
  }
#endif
