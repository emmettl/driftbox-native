// Driftbox's icon for Windows: windows/Driftbox.ico, compiled into windows/Driftbox.res, which the
// Windows app links so that Explorer, the taskbar and its own title bar show it.
//
//   node scripts/windows-icon.mjs
//
// The outputs are committed, so this is not part of the build: it is what to run again when the
// web app's icon changes. It draws the same two pictures the web app's icons.mjs does, from the
// submodule, and in the same way, in a Chromium, because the full icon glows through
// feGaussianBlur and nothing short of a browser draws that right:
//
//   - the small sizes, 16 to 32, from public/favicon.svg, the icon cut down to four pads, since at
//     sixteen pixels the full one's sixteen pads and lead are a smudge;
//   - the rest, 48 to 256, from scripts/icon.svg, the rounded tile on transparent, as icon-512 is.
//
// Each size is a PNG inside the .ico, which Windows has read since Vista. scripts/windows-resources.mjs
// then compiles it into the .res, with the version.
import { execFileSync } from 'node:child_process'
import { writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { openReference } from '../conformance/emit/browser.mjs'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const out = join(root, 'windows')

/** The full drawing's view box: the 824 body of Apple's 1024 icon template, as icons.mjs has it. */
const TILE = '100 100 824 824'
const SIZES = [
  { size: 16, source: '/app/public/favicon.svg' },
  { size: 24, source: '/app/public/favicon.svg' },
  { size: 32, source: '/app/public/favicon.svg' },
  { size: 48, source: '/app/scripts/icon.svg', viewBox: TILE },
  { size: 64, source: '/app/scripts/icon.svg', viewBox: TILE },
  { size: 128, source: '/app/scripts/icon.svg', viewBox: TILE },
  { size: 256, source: '/app/scripts/icon.svg', viewBox: TILE },
]

const page = await openReference(join(root, 'driftbox', 'packages'))
const images = []
try {
  for (const { size, source, viewBox } of SIZES) {
    const base64 = await page.evaluate(`(async () => {
      const text = await (await fetch(${JSON.stringify(source)})).text()
      const svg = new DOMParser().parseFromString(text, 'image/svg+xml').documentElement
      ${viewBox ? `svg.setAttribute('viewBox', ${JSON.stringify(viewBox)})` : ''}
      svg.setAttribute('width', '${size}')
      svg.setAttribute('height', '${size}')
      const url = URL.createObjectURL(new Blob([new XMLSerializer().serializeToString(svg)], { type: 'image/svg+xml' }))
      const image = new Image()
      image.src = url
      await image.decode()
      const canvas = document.createElement('canvas')
      canvas.width = canvas.height = ${size}
      canvas.getContext('2d').drawImage(image, 0, 0, ${size}, ${size})
      const blob = await new Promise((resolve) => canvas.toBlob(resolve, 'image/png'))
      const bytes = new Uint8Array(await blob.arrayBuffer())
      let binary = ''
      for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
      return btoa(binary)
    })()`)
    images.push({ size, png: Buffer.from(base64, 'base64') })
  }
} finally {
  await page.close()
}

// ICONDIR, then an ICONDIRENTRY for each image, then the images. A width or height of 256 is
// written as 0.
const header = Buffer.alloc(6 + 16 * images.length)
header.writeUInt16LE(0, 0)
header.writeUInt16LE(1, 2)
header.writeUInt16LE(images.length, 4)
let offset = header.length
images.forEach(({ size, png }, index) => {
  const entry = 6 + 16 * index
  header.writeUInt8(size >= 256 ? 0 : size, entry)
  header.writeUInt8(size >= 256 ? 0 : size, entry + 1)
  header.writeUInt8(0, entry + 2)
  header.writeUInt8(0, entry + 3)
  header.writeUInt16LE(1, entry + 4)
  header.writeUInt16LE(32, entry + 6)
  header.writeUInt32LE(png.length, entry + 8)
  header.writeUInt32LE(offset, entry + 12)
  offset += png.length
})
const ico = join(out, 'Driftbox.ico')
writeFileSync(ico, Buffer.concat([header, ...images.map((image) => image.png)]))
console.log(`Driftbox.ico  ${images.map((image) => image.size).join(', ')}  ${(offset / 1024).toFixed(1)}kB`)

// The resources that carry it, compiled with the version.
execFileSync(process.execPath, [join(root, 'scripts', 'windows-resources.mjs')], { stdio: 'inherit' })
