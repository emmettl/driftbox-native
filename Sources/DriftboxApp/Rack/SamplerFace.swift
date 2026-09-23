#if canImport(SwiftUI) && canImport(AVFoundation)
  import SwiftUI
  import UniformTypeIdentifiers

  /// The Slice Lab: the sample's shape with its slices over it — click one to play from it — a
  /// file dropped anywhere on the display or chosen from the button, the length it is taken to be
  /// in bars, and the sampler's controls.
  struct SamplerFace: View {
    let face: FaceContext
    static let bars = [1, 2, 4, 8]

    @State private var choosing = false
    @State private var dropping = false

    var body: some View {
      let info = face.model.samples[face.module.id]
      let busy = face.model.loading.contains(face.module.id)
      let slices = max(1, min(32, Int(face.value("slices").rounded())))
      let selected = max(0, min(slices - 1, Int(face.value("slice").rounded())))
      PanelTitle(name: "Slice Lab", mark: "S—32") {
        HStack(spacing: 5) {
          Circle().fill(info == nil ? Theme.dim.opacity(0.4) : Theme.nine).frame(width: 5, height: 5)
            .shadow(color: info == nil ? .clear : Theme.nine, radius: 3)
          Text(busy ? "decoding" : info == nil ? "empty" : "sample ready")
        }
        .font(Theme.mono(8)).foregroundStyle(Theme.dim)
      }
      ZStack {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Color(red: 4 / 255, green: 9 / 255, blue: 12 / 255))
          .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .strokeBorder(dropping ? Theme.nine : Theme.nine.opacity(0.2), lineWidth: dropping ? 1.5 : 1))
        if let info {
          VStack(spacing: 4) {
            Wave(peaks: info.peaks).padding(.horizontal, 8).padding(.top, 6)
            HStack(spacing: 2) {
              ForEach(0..<slices, id: \.self) { index in
                Button {
                  face.set("slice", Double(index))
                } label: {
                  Text(slices <= 16 ? "\(index + 1)" : "")
                    .font(Theme.mono(7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(index == selected ? Theme.ground : Theme.dim)
                    .background(
                      RoundedRectangle(cornerRadius: 2).fill(
                        index == selected ? Theme.nine : Color.white.opacity(0.04))
                    )
                    .overlay(
                      RoundedRectangle(cornerRadius: 2).strokeBorder(
                        index % 4 == 0 ? Color.white.opacity(0.18) : Theme.edge))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Slice \(index + 1)")
              }
            }
            .frame(height: 16)
            .padding(.horizontal, 8).padding(.bottom, 6)
          }
        } else {
          Button {
            choosing = true
          } label: {
            VStack(spacing: 3) {
              Text(busy ? "Reading sample…" : "Drop audio here").font(Theme.mono(11, .semibold))
                .foregroundStyle(Theme.ink)
              Text("or choose a WAV, AIFF, MP3 or FLAC").font(Theme.mono(8)).foregroundStyle(Theme.dim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(busy)
        }
        if dropping {
          Text("DROP TO LOAD").font(Theme.mono(9, .semibold)).tracking(1).foregroundStyle(Theme.nine)
            .padding(6).background(Capsule().fill(Theme.ground.opacity(0.9)))
        }
      }
      .frame(height: 84)
      .dropDestination(for: URL.self) { urls, _ in
        guard let url = urls.first else { return false }
        Task { await face.model.load(url, into: face.module.id) }
        return true
      } isTargeted: {
        dropping = $0
      }
      HStack(spacing: 8) {
        Button(busy ? "Loading…" : info == nil ? "Load sample" : "Replace") { choosing = true }
          .buttonStyle(OptionStyle(on: false, tint: Theme.nine))
          .disabled(busy)
        VStack(alignment: .leading, spacing: 0) {
          Text(info?.name ?? "No sample loaded").font(Theme.mono(9, .semibold)).foregroundStyle(Theme.ink)
            .lineLimit(1)
          if let info {
            Text(
              "\(info.source == .break ? "factory break" : "local file") · \(RackDisplay.fixed(info.seconds, 2))s"
            )
            .font(Theme.mono(7.5)).foregroundStyle(Theme.dim)
          } else if let failure = face.model.loadFailure, failure.module == face.module.id {
            Text(failure.reason).font(Theme.mono(7.5)).foregroundStyle(Theme.eight).lineLimit(1)
          }
        }
        Spacer(minLength: 4)
        if let info {
          Text("BARS").font(Theme.mono(7.5)).tracking(0.6).foregroundStyle(Theme.dim)
          ForEach(Self.bars, id: \.self) { bars in
            Button("\(bars)") { face.model.setSampleBars(face.module.id, bars) }
              .buttonStyle(OptionStyle(on: info.bars == bars, tint: Theme.three))
          }
        }
      }
      .frame(height: 22)
      HStack(alignment: .top, spacing: 0) {
        face.control("slices")
        VStack(spacing: 3) {
          Text("\(selected + 1)").font(Theme.mono(9.5, .semibold)).foregroundStyle(Theme.ink)
          HStack(spacing: 3) {
            Button("‹") { face.set("slice", Double((selected - 1 + slices) % slices)) }
            Button("›") { face.set("slice", Double((selected + 1) % slices)) }
          }
          .buttonStyle(OptionStyle(on: false, tint: Theme.nine))
          Text("SLICE").font(Theme.mono(8.5, .medium)).tracking(0.6).foregroundStyle(Theme.dim)
        }
        .frame(width: RackLayout.cellWidth, height: RackLayout.cellHeight)
        face.control("start", tint: Theme.three)
        face.control("loop")
        face.control("reverse")
        Spacer()
      }
      .fileImporter(isPresented: $choosing, allowedContentTypes: [.audio]) { result in
        guard case .success(let url) = result else { return }
        Task { await face.model.load(url, into: face.module.id) }
      }
    }

    /// The sample's peaks as bars about a centre line.
    struct Wave: View {
      let peaks: [Double]

      var body: some View {
        Canvas { context, size in
          var middle = Path()
          middle.move(to: CGPoint(x: 0, y: size.height / 2))
          middle.addLine(to: CGPoint(x: size.width, y: size.height / 2))
          context.stroke(middle, with: .color(Theme.nine.opacity(0.2)), lineWidth: 0.7)
          guard !peaks.isEmpty else { return }
          let step = size.width / Double(peaks.count)
          let width = max(1, step * 0.78)
          for (index, peak) in peaks.enumerated() {
            let height = max(1, peak * size.height * 0.81)
            context.fill(
              Path(
                CGRect(x: Double(index) * step, y: (size.height - height) / 2, width: width, height: height)),
              with: .color(Theme.nine.opacity(0.85)))
          }
        }
      }
    }
  }
#endif
