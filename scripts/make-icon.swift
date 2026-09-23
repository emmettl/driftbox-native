// Draws the app icon: the instrument's own dark, four rows of step pads with a rhythm lit on them
// in the machines' colours — the 808's pink, the accent's amber, the 909's teal — and a patch lead
// from the rack hanging across the top. Drawn rather than stored, so a change to it is a change to
// this file, and every size is drawn at its own size rather than scaled from one.
//
//   swift scripts/make-icon.swift                  writes Sources/DriftboxApp/Resources/AppIcon.icns
//   swift scripts/make-icon.swift some/where.png   also writes the 1024 drawing there, to look at
import AppKit

let ground = NSColor(srgbRed: 7 / 255, green: 4 / 255, blue: 15 / 255, alpha: 1)
let panel = NSColor(srgbRed: 30 / 255, green: 22 / 255, blue: 56 / 255, alpha: 1)
let pink = NSColor(srgbRed: 1, green: 122 / 255, blue: 217 / 255, alpha: 1)
let teal = NSColor(srgbRed: 95 / 255, green: 240 / 255, blue: 208 / 255, alpha: 1)
let amber = NSColor(srgbRed: 1, green: 176 / 255, blue: 46 / 255, alpha: 1)

/// The pads lit, by row and column, and in what: a kick on the one and the three, a snare on
/// the two and four under an accent, hats between — a bar of the thing the app is for.
let lit: [[NSColor?]] = [
  [pink, nil, pink, nil],
  [nil, amber, nil, amber],
  [teal, teal, nil, teal],
  [nil, nil, pink, nil],
]

func draw(size: CGFloat) -> NSBitmapImageRep {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
    bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let context = NSGraphicsContext.current!.cgContext
  // Everything below is in the 1024 design of Apple's template, flipped so y runs down.
  let unit = size / 1024
  context.scaleBy(x: unit, y: unit)
  context.translateBy(x: 0, y: 1024)
  context.scaleBy(x: 1, y: -1)
  // A shadow is set in the bitmap's own pixels, which run upward, and ignores the scale above: so
  // it is given in design units, downward, and scaled here.
  func shadow(down: CGFloat, blur: CGFloat, _ colour: NSColor) {
    context.setShadow(
      offset: CGSize(width: 0, height: -down * unit), blur: blur * unit, color: colour.cgColor)
  }

  // The body: the template's 824 square with its corner, a shadow under it, lit from above.
  let body = CGRect(x: 100, y: 100, width: 824, height: 824)
  let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
  context.saveGState()
  shadow(down: 12, blur: 28, NSColor.black.withAlphaComponent(0.45))
  context.addPath(shape)
  context.setFillColor(ground.cgColor)
  context.fillPath()
  context.restoreGState()

  context.saveGState()
  context.addPath(shape)
  context.clip()
  let space = CGColorSpaceCreateDeviceRGB()
  let wash = CGGradient(
    colorsSpace: space, colors: [panel.cgColor, ground.cgColor] as CFArray, locations: [0, 1])!
  context.drawLinearGradient(wash, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
  // A glow behind the lit pads, as the web's backdrop has one.
  let glow = CGGradient(
    colorsSpace: space,
    colors: [pink.withAlphaComponent(0.28).cgColor, pink.withAlphaComponent(0).cgColor] as CFArray,
    locations: [0, 1])!
  context.drawRadialGradient(
    glow, startCenter: CGPoint(x: 512, y: 600), startRadius: 0, endCenter: CGPoint(x: 512, y: 600),
    endRadius: 420,
    options: [])
  // Everything from here is inside the body.

  // The pads.
  let pad = 112.0
  let gap = 24.0
  let left = 512 - (4 * pad + 3 * gap) / 2
  let top = 356.0
  for row in 0..<4 {
    for column in 0..<4 {
      let rect = CGRect(
        x: left + Double(column) * (pad + gap), y: top + Double(row) * (pad + gap), width: pad, height: pad)
      let path = CGPath(roundedRect: rect, cornerWidth: 26, cornerHeight: 26, transform: nil)
      if let colour = lit[row][column] {
        context.saveGState()
        shadow(down: 0, blur: 46, colour.withAlphaComponent(0.75))
        context.addPath(path)
        context.setFillColor(colour.cgColor)
        context.fillPath()
        context.restoreGState()
        // Lit from above, as the web's steps are.
        context.saveGState()
        context.addPath(path)
        context.clip()
        let sheen = CGGradient(
          colorsSpace: space,
          colors: [
            NSColor.white.withAlphaComponent(0.4).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
          ]
            as CFArray, locations: [0, 1])!
        context.drawLinearGradient(
          sheen, start: rect.origin, end: CGPoint(x: rect.minX, y: rect.midY), options: [])
        context.restoreGState()
      } else {
        context.addPath(path)
        context.setFillColor(NSColor.white.withAlphaComponent(0.07).cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        context.setLineWidth(3)
        context.strokePath()
      }
    }
  }

  // The lead: out of a jack at the top left, hanging as the rack's do, and on out of the right
  // edge to wherever it is patched.
  let from = CGPoint(x: 254, y: 236)
  let to = CGPoint(x: 1010, y: 190)
  let lead = CGMutablePath()
  lead.move(to: from)
  lead.addCurve(to: to, control1: CGPoint(x: 420, y: 350), control2: CGPoint(x: 780, y: 330))
  context.saveGState()
  context.setLineCap(.round)
  context.addPath(lead)
  context.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
  context.setLineWidth(40)
  context.strokePath()
  context.addPath(lead)
  context.setStrokeColor(teal.cgColor)
  shadow(down: 0, blur: 24, teal.withAlphaComponent(0.6))
  context.setLineWidth(24)
  context.strokePath()
  context.restoreGState()
  for jack in [from] {
    let ring = CGRect(x: jack.x - 34, y: jack.y - 34, width: 68, height: 68)
    context.setFillColor(NSColor(srgbRed: 27 / 255, green: 20 / 255, blue: 48 / 255, alpha: 1).cgColor)
    context.fillEllipse(in: ring)
    context.setStrokeColor(amber.cgColor)
    context.setLineWidth(10)
    context.strokeEllipse(in: ring.insetBy(dx: 5, dy: 5))
    context.setFillColor(ground.cgColor)
    context.fillEllipse(in: ring.insetBy(dx: 22, dy: 22))
  }

  context.restoreGState()

  // The edge, catching the light.
  context.addPath(shape)
  context.setStrokeColor(NSColor.white.withAlphaComponent(0.1).cgColor)
  context.setLineWidth(3)
  context.strokePath()

  NSGraphicsContext.restoreGraphicsState()
  return rep
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Sources/DriftboxApp/Resources")
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    let data = draw(size: CGFloat(points * scale)).representation(using: .png, properties: [:])!
    try data.write(to: set.appendingPathComponent(name))
  }
}
let make = Process()
make.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
make.arguments = ["-c", "icns", set.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try make.run()
make.waitUntilExit()
if CommandLine.arguments.count > 1 {
  try draw(size: 1024).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
print("wrote Sources/DriftboxApp/Resources/AppIcon.icns")
