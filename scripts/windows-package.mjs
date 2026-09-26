// Driftbox for Windows as a folder that runs on a machine with no Swift on it: dist/Driftbox, and
// dist/Driftbox-windows-x64.zip of it.
//
//   swift build -c release --product DriftboxWindows    (from a Visual Studio x64 prompt)
//   swift build -c release --product DriftboxVST3Scan
//   node scripts/windows-package.mjs
//
// What goes in:
//   - the program, as Driftbox.exe;
//   - DriftboxVST3Scan.exe, which asks each plug-in the program finds what it holds, in a process of
//     its own, so a plug-in that crashes does not take the program with it;
//   - the resource bundles it names — the catalogue's songs — which Bundle.module looks for beside
//     the program;
//   - the Swift runtime's DLLs it needs, and theirs, found by reading each one's import tables
//     rather than copied wholesale: the runtime carries networking, XML, regex builders and more that
//     a drum machine never loads. The Visual C++ runtime's DLLs among them go too, which leaves
//     nothing to install first.
//
// The Swift runtime is found from SWIFT_RUNTIME, or where the swift.org installer puts it.
import { execFileSync } from 'node:child_process'
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(fileURLToPath(new URL('.', import.meta.url)), '..')
const build = join(root, '.build', 'x86_64-unknown-windows-msvc', 'release')
const program = join(build, 'DriftboxWindows.exe')
const scanner = join(build, 'DriftboxVST3Scan.exe')
const dist = join(root, 'dist')
const out = join(dist, 'Driftbox')

function runtimeDirectory() {
  if (process.env.SWIFT_RUNTIME) return process.env.SWIFT_RUNTIME
  const runtimes = join(process.env.LOCALAPPDATA ?? '', 'Programs', 'Swift', 'Runtimes')
  if (!existsSync(runtimes)) return null
  const newest = readdirSync(runtimes).sort((a, b) => a.localeCompare(b, undefined, { numeric: true })).pop()
  return newest ? join(runtimes, newest, 'usr', 'bin') : null
}

/** The DLLs a PE file imports, loaded at start or delay-loaded, by name as written. */
export function imports(file) {
  const bytes = readFileSync(file)
  const pe = bytes.readUInt32LE(0x3c)
  if (bytes.toString('latin1', pe, pe + 4) !== 'PE\0\0') throw new Error(`${file} is not a PE file`)
  const sectionCount = bytes.readUInt16LE(pe + 6)
  const optionalSize = bytes.readUInt16LE(pe + 20)
  const optional = pe + 24
  const directories = optional + (bytes.readUInt16LE(optional) === 0x20b ? 112 : 96)
  const sections = optional + optionalSize
  const offset = (rva) => {
    for (let index = 0; index < sectionCount; index++) {
      const section = sections + index * 40
      const address = bytes.readUInt32LE(section + 12)
      const size = Math.max(bytes.readUInt32LE(section + 8), bytes.readUInt32LE(section + 16))
      if (rva >= address && rva < address + size) return rva - address + bytes.readUInt32LE(section + 20)
    }
    return null
  }
  const name = (rva) => {
    const at = offset(rva)
    return at === null ? null : bytes.toString('latin1', at, bytes.indexOf(0, at))
  }
  const names = []
  // The import directory's descriptors are 20 bytes, the name's RVA at 12; the delay-load
  // directory's are 32, the name's RVA at 4. Each list ends with one of zeros.
  for (const [index, stride, field] of [[1, 20, 12], [13, 32, 4]]) {
    const rva = bytes.readUInt32LE(directories + index * 8)
    if (rva === 0) continue
    let at = offset(rva)
    while (at !== null && bytes.readUInt32LE(at + field) !== 0) {
      const dll = name(bytes.readUInt32LE(at + field))
      if (dll) names.push(dll)
      at += stride
    }
  }
  return names
}

for (const [file, product] of [[program, 'DriftboxWindows'], [scanner, 'DriftboxVST3Scan']]) {
  if (!existsSync(file)) {
    console.error(`No ${file}. Build it first: swift build -c release --product ${product}`)
    process.exit(1)
  }
}
const runtime = runtimeDirectory()
if (!runtime || !existsSync(runtime)) {
  console.error('No Swift runtime found. Set SWIFT_RUNTIME to its usr\\bin.')
  process.exit(1)
}

rmSync(out, { recursive: true, force: true })
mkdirSync(out, { recursive: true })
cpSync(program, join(out, 'Driftbox.exe'))
cpSync(scanner, join(out, 'DriftboxVST3Scan.exe'))

// Every DLL reachable from the program and the scanner that the runtime has; the rest are Windows'
// own.
const available = new Map(readdirSync(runtime).map((file) => [file.toLowerCase(), join(runtime, file)]))
const needed = new Set()
const pending = [program, scanner]
while (pending.length > 0) {
  for (const dll of imports(pending.pop())) {
    const found = available.get(dll.toLowerCase())
    if (!found || needed.has(found)) continue
    needed.add(found)
    pending.push(found)
  }
}
for (const dll of needed) cpSync(dll, join(out, dll.slice(runtime.length + 1)))

// The resource bundles the program names: Bundle.module finds one by a name built into the code.
const binary = readFileSync(program).toString('latin1')
const bundles = readdirSync(build).filter((name) => name.endsWith('.resources') && binary.includes(name.slice(0, -10)))
for (const bundle of bundles) cpSync(join(build, bundle), join(out, bundle), { recursive: true })

const size = (path) =>
  statSync(path).isDirectory() ? readdirSync(path).reduce((sum, name) => sum + size(join(path, name)), 0) : statSync(path).size
console.log(`dist/Driftbox: Driftbox.exe, DriftboxVST3Scan.exe, ${needed.size} DLLs, ${bundles.join(', ')}  ${(size(out) / 1048576).toFixed(1)}MB`)

// Windows' own tar writes zips; named in full, since a Git shell puts a GNU tar first that does not.
const zip = join(dist, 'Driftbox-windows-x64.zip')
rmSync(zip, { force: true })
const tar = join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'tar.exe')
execFileSync(tar, ['-a', '-c', '-f', 'Driftbox-windows-x64.zip', 'Driftbox'], { cwd: dist })
console.log(`dist/Driftbox-windows-x64.zip  ${(statSync(zip).size / 1048576).toFixed(1)}MB`)
