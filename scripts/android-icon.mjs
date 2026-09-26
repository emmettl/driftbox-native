// Driftbox's icon for Android: an adaptive icon, drawn as vectors, which a launcher cuts to its own
// shape and draws sharp at any size.
//
//   node scripts/android-icon.mjs                     writes android/res's icon
//   node scripts/android-icon.mjs some/where.svg      and a picture of it, cut as launchers cut it
//
// The outputs are committed, so this is not part of the build: it is what to run again when the
// icon changes. The drawing is the Mac's and the web's (scripts/make-icon.swift, and the web app's
// scripts/icon.svg): the dark, four rows of step pads lit in the machines' colours, and a patch lead
// out of a jack. It is in their coordinates, the 1024 of Apple's template, placed as the web's
// maskable icon places it: centred on the pads and the jack, at (512, 556), whose farthest point,
// the jack's edge, is 459 away, and which has to be inside the circle of 66 of the icon's 108 that
// every launcher's shape keeps. The lead runs on off the edge, as it does everywhere.
//
// Three layers, as Android asks: the background, the dark and its warm glow, filling the whole of
// it, since a launcher moves the foreground over it; the foreground, the pads and the lead; and a
// monochrome one, for the icons Android 13 and later tint to the wallpaper. A vector drawable has
// no blur, so a glow is a radial gradient: under each lit pad, and a wide faint stroke beside the
// lead.
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const res = join(root, 'android', 'res')

const SIZE = 108
const SCALE = 33 / 459
/** A point of the 1024 drawing, in the icon's 108. */
const x = (value) => SIZE / 2 + (value - 512) * SCALE
const y = (value) => SIZE / 2 + (value - 556) * SCALE
const length = (value) => value * SCALE
const n = (value) => String(Math.round(value * 100) / 100)

const ground = '07040f'
const panel = '1e1638'
const pink = 'ff7ad9'
const teal = '5ff0d0'
const amber = 'ffb02e'

/** A colour: six hex digits and an opacity. */
const colour = (rgb, alpha = 1) => ({ rgb, alpha })

// MARK: - Shapes, in the 1024 drawing

function roundedRect(left, top, width, height, radius) {
  const [l, t, w, h, r] = [x(left), y(top), length(width), length(height), length(radius)]
  return (
    `M${n(l + r)},${n(t)} h${n(w - 2 * r)} a${n(r)},${n(r)} 0 0 1 ${n(r)},${n(r)} v${n(h - 2 * r)} ` +
    `a${n(r)},${n(r)} 0 0 1 ${n(-r)},${n(r)} h${n(2 * r - w)} a${n(r)},${n(r)} 0 0 1 ${n(-r)},${n(-r)} ` +
    `v${n(2 * r - h)} a${n(r)},${n(r)} 0 0 1 ${n(r)},${n(-r)} z`
  )
}

function circle(cx, cy, radius) {
  const r = length(radius)
  return (
    `M${n(x(cx) - r)},${n(y(cy))} a${n(r)},${n(r)} 0 1 0 ${n(2 * r)},0 ` +
    `a${n(r)},${n(r)} 0 1 0 ${n(-2 * r)},0 z`
  )
}

/** The whole of the icon, and more. */
const everywhere = `M-1,-1 h${SIZE + 2} v${SIZE + 2} h${-SIZE - 2} z`

/** The lead: out of the jack, hanging as the rack's do, and on out past the right edge. */
const lead =
  `M${n(x(254))},${n(y(236))} C${n(x(420))},${n(y(350))} ${n(x(780))},${n(y(330))} ${n(x(1010))},${n(y(190))} ` +
  `L${n(x(1309))},${n(y(8))}`

const PAD = 112
/** A bar of the thing the app is for: a kick on the one and the three, a snare under an accent on
 * the two and four, hats between. By row, the colour each pad is lit in, or null. */
const LIT = [
  [pink, null, pink, null],
  [null, amber, null, amber],
  [teal, teal, null, teal],
  [null, null, pink, null],
]
const pads = LIT.flatMap((row, r) =>
  row.map((lit, c) => ({ left: 252 + c * 136, top: 356 + r * 136, lit })),
)

// MARK: - Layers

const background = [
  {
    d: everywhere,
    fill: { linear: [x(512), y(100), x(512), y(924)], stops: [[0, colour(panel)], [1, colour(ground)]] },
  },
  {
    d: everywhere,
    fill: {
      radial: [x(512), y(600), length(420)],
      stops: [[0, colour(pink, 0.28)], [1, colour(pink, 0)]],
    },
  },
]

const foreground = [
  ...pads
    .filter((pad) => !pad.lit)
    .map((pad) => ({
      d: roundedRect(pad.left, pad.top, PAD, PAD, 26),
      fill: colour('ffffff', 0.07),
      stroke: colour('ffffff', 0.08),
      width: length(3),
    })),
  // The glow under each lit pad, where the Mac's and the web's blur it.
  ...pads
    .filter((pad) => pad.lit)
    .map((pad) => {
      const [cx, cy] = [pad.left + PAD / 2, pad.top + PAD / 2]
      return {
        d: circle(cx, cy, 124),
        fill: {
          radial: [x(cx), y(cy), length(124)],
          stops: [[0, colour(pad.lit, 0.75)], [0.45, colour(pad.lit, 0.5)], [1, colour(pad.lit, 0)]],
        },
      }
    }),
  ...pads
    .filter((pad) => pad.lit)
    .flatMap((pad) => [
      { d: roundedRect(pad.left, pad.top, PAD, PAD, 26), fill: colour(pad.lit) },
      // Lit from above, as the sequencer's steps are.
      {
        d: roundedRect(pad.left, pad.top, PAD, PAD, 26),
        fill: {
          linear: [x(pad.left), y(pad.top), x(pad.left), y(pad.top + PAD)],
          stops: [[0, colour('ffffff', 0.4)], [0.5, colour('ffffff', 0)]],
        },
      },
    ]),
  { d: lead, stroke: colour('000000', 0.6), width: length(40), round: true },
  { d: lead, stroke: colour(teal, 0.2), width: length(60), round: true },
  { d: lead, stroke: colour(teal), width: length(24), round: true },
  { d: circle(254, 236, 34), fill: colour('1b1430') },
  { d: circle(254, 236, 29), stroke: colour(amber), width: length(10) },
  { d: circle(254, 236, 12), fill: colour(ground) },
]

/** Only the shapes' alpha counts: the lit pads whole, the unlit ones faint, the lead and the jack. */
const monochrome = [
  ...pads.map((pad) => ({
    d: roundedRect(pad.left, pad.top, PAD, PAD, 26),
    fill: colour('ffffff', pad.lit ? 1 : 0.3),
  })),
  { d: lead, stroke: colour('ffffff'), width: length(24), round: true },
  { d: circle(254, 236, 29), stroke: colour('ffffff'), width: length(10) },
]

// MARK: - As a vector drawable

const hex = ({ rgb, alpha }) =>
  `#${Math.round(alpha * 255).toString(16).padStart(2, '0')}${rgb}`.toUpperCase().replace('#', '#')

function gradient(paint, attribute) {
  const items = paint.stops
    .map(([offset, stop]) => `          <item android:offset="${offset}" android:color="${hex(stop)}" />`)
    .join('\n')
  const shape = paint.linear
    ? `android:type="linear" android:startX="${n(paint.linear[0])}" android:startY="${n(paint.linear[1])}"\n` +
      `            android:endX="${n(paint.linear[2])}" android:endY="${n(paint.linear[3])}"`
    : `android:type="radial" android:centerX="${n(paint.radial[0])}" android:centerY="${n(paint.radial[1])}"\n` +
      `            android:gradientRadius="${n(paint.radial[2])}"`
  return (
    `      <aapt:attr name="${attribute}">\n` +
    `        <gradient ${shape}>\n${items}\n        </gradient>\n` +
    `      </aapt:attr>\n`
  )
}

function drawable(what, shapes) {
  const paths = shapes.map((shape) => {
    let attributes = `android:pathData="${shape.d}"`
    let inside = ''
    if (shape.fill?.stops) inside += gradient(shape.fill, 'android:fillColor')
    else if (shape.fill) attributes += `\n      android:fillColor="${hex(shape.fill)}"`
    if (shape.stroke) {
      attributes += `\n      android:strokeColor="${hex(shape.stroke)}" android:strokeWidth="${n(shape.width)}"`
      if (shape.round) attributes += ' android:strokeLineCap="round"'
    }
    return inside ? `  <path ${attributes}>\n${inside}  </path>` : `  <path ${attributes} />`
  })
  return (
    '<?xml version="1.0" encoding="utf-8"?>\n' +
    `<!-- ${what} Written by scripts/android-icon.mjs: change that, and run it again. -->\n` +
    '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n' +
    '    xmlns:aapt="http://schemas.android.com/aapt"\n' +
    `    android:width="${SIZE}dp" android:height="${SIZE}dp"\n` +
    `    android:viewportWidth="${SIZE}" android:viewportHeight="${SIZE}">\n` +
    `${paths.join('\n')}\n</vector>\n`
  )
}

const adaptive = `<?xml version="1.0" encoding="utf-8"?>
<!-- Driftbox's icon, which a launcher cuts to its own shape. Written by scripts/android-icon.mjs. -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
  <background android:drawable="@drawable/ic_launcher_background" />
  <foreground android:drawable="@drawable/ic_launcher_foreground" />
  <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
`

const outputs = {
  'mipmap-anydpi-v26/ic_launcher.xml': adaptive,
  'drawable/ic_launcher_background.xml': drawable("The icon's background: the dark, and its glow.", background),
  'drawable/ic_launcher_foreground.xml': drawable("The icon's pads and lead.", foreground),
  'drawable/ic_launcher_monochrome.xml': drawable('The icon as Android 13 and later tint it.', monochrome),
}
for (const [path, text] of Object.entries(outputs)) {
  mkdirSync(dirname(join(res, path)), { recursive: true })
  writeFileSync(join(res, path), text)
  console.log(`wrote android/res/${path}`)
}

// MARK: - A picture of it

function svg(shapes, prefix) {
  const defs = []
  const body = shapes.map((shape, index) => {
    let fill = 'none'
    if (shape.fill?.stops) {
      const id = `${prefix}${index}`
      const stops = shape.fill.stops
        .map(([offset, stop]) => `<stop offset="${offset}" stop-color="#${stop.rgb}" stop-opacity="${stop.alpha}"/>`)
        .join('')
      defs.push(
        shape.fill.linear
          ? `<linearGradient id="${id}" gradientUnits="userSpaceOnUse" x1="${shape.fill.linear[0]}" ` +
              `y1="${shape.fill.linear[1]}" x2="${shape.fill.linear[2]}" y2="${shape.fill.linear[3]}">${stops}</linearGradient>`
          : `<radialGradient id="${id}" gradientUnits="userSpaceOnUse" cx="${shape.fill.radial[0]}" ` +
              `cy="${shape.fill.radial[1]}" r="${shape.fill.radial[2]}">${stops}</radialGradient>`,
      )
      fill = `url(#${id})`
    } else if (shape.fill) {
      fill = `#${shape.fill.rgb}" fill-opacity="${shape.fill.alpha}`
    }
    const stroke = shape.stroke
      ? ` stroke="#${shape.stroke.rgb}" stroke-opacity="${shape.stroke.alpha}" stroke-width="${shape.width}"` +
        (shape.round ? ' stroke-linecap="round"' : '')
      : ''
    return `<path d="${shape.d}" fill="${fill}"${stroke}/>`
  })
  return { defs: defs.join(''), body: body.join('') }
}

const picture = process.argv[2]
if (picture) {
  // Cut as launchers cut it: a circle, a rounded square, and a squircle's stand-in, each showing the
  // middle 72 of the 108; then the monochrome one, tinted.
  const back = svg(background, 'b')
  const front = svg(foreground, 'f')
  const mono = svg(monochrome, 'm')
  const masks = [
    '<circle cx="54" cy="54" r="36"/>',
    '<rect x="18" y="18" width="72" height="72" rx="16"/>',
    '<rect x="18" y="18" width="72" height="72" rx="28"/>',
  ]
  const cells = masks.map(
    (mask, index) =>
      `<g transform="translate(${index * 80 - 14} -14)"><clipPath id="cut${index}">${mask}</clipPath>` +
      `<g clip-path="url(#cut${index})">${back.body}${front.body}</g></g>`,
  )
  cells.push(
    `<g transform="translate(${3 * 80 - 14} -14)"><clipPath id="cut3">${masks[0]}</clipPath>` +
      `<g clip-path="url(#cut3)"><rect width="108" height="108" fill="#d8e2ff"/>` +
      `<g style="filter: brightness(0) saturate(100%)" opacity="0.8">${mono.body}</g></g></g>`,
  )
  writeFileSync(
    picture,
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 80" width="1280" height="320">` +
      `<rect width="320" height="80" fill="#e8e8ec"/><defs>${back.defs}${front.defs}${mono.defs}</defs>` +
      `${cells.join('')}</svg>\n`,
  )
  console.log(`wrote ${picture}`)
}
