// The Windows programs' resources: windows/Driftbox.rc and windows/DriftboxVST3Scan.rc, written from
// scripts/version.env, and compiled to the .res files the programs link.
//
//   node scripts/windows-resources.mjs
//
// Each carries its version and what it is, as Explorer's Details tab shows them, and as a code
// signing service checks them against what it is asked to sign; Driftbox's carries its icon too,
// windows/Driftbox.ico, which scripts/windows-icon.mjs draws. The outputs are committed, so a build
// needs none of this: it is what to run again when the version changes, as the release workflow
// does before it builds. The .res files are compiled by the Windows SDK's rc, found on PATH (a
// Visual Studio prompt) or in the SDK.
import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const out = join(root, 'windows')

/** DRIFTBOX_VERSION and DRIFTBOX_BUILD, as scripts/version.env has them. */
export function version() {
  const values = Object.fromEntries(
    readFileSync(join(root, 'scripts', 'version.env'), 'utf8')
      .split(/\r?\n/)
      .filter((line) => /^\w+=/.test(line))
      .map((line) => line.split('=', 2)),
  )
  const [major, minor, patch] = values.DRIFTBOX_VERSION.split('.').map(Number)
  return { string: values.DRIFTBOX_VERSION, parts: [major, minor, patch, Number(values.DRIFTBOX_BUILD)] }
}

/** The copyright line of the licence, the program's own. */
function copyright() {
  return readFileSync(join(root, 'LICENSE'), 'utf8').split(/\r?\n/).find((line) => line.startsWith('Copyright'))
}

/** A resource script: the icon, where there is one, and the version, as `name` is `description`. */
function script({ name, description, icon }) {
  const { string, parts } = version()
  const quoted = (text) => `"${text.replace(/"/g, '""')}"`
  const strings = [
    ['CompanyName', 'Driftbox'],
    ['FileDescription', description],
    ['FileVersion', string],
    ['InternalName', name],
    ['LegalCopyright', copyright()],
    ['OriginalFilename', `${name}.exe`],
    ['ProductName', 'Driftbox'],
    ['ProductVersion', string],
  ]
  return [
    `// ${name}'s resources, written by scripts/windows-resources.mjs from scripts/version.env and`,
    '// compiled to the .res it links. Written, not edited: change the version there and run it again.',
    ...(icon ? ['// Resource 1 is the icon the window class and Explorer use.', `1 ICON "${icon}"`, ''] : ['']),
    '1 VERSIONINFO',
    `FILEVERSION ${parts.join(',')}`,
    `PRODUCTVERSION ${parts.join(',')}`,
    'FILEFLAGSMASK 0x3F',
    'FILEFLAGS 0x0',
    // Windows NT, an application.
    'FILEOS 0x40004',
    'FILETYPE 0x1',
    'FILESUBTYPE 0x0',
    'BEGIN',
    '  BLOCK "StringFileInfo"',
    '  BEGIN',
    // US English, Unicode.
    '    BLOCK "040904B0"',
    '    BEGIN',
    ...strings.map(([key, value]) => `      VALUE ${quoted(key)}, ${quoted(value)}`),
    '    END',
    '  END',
    '  BLOCK "VarFileInfo"',
    '  BEGIN',
    '    VALUE "Translation", 0x409, 1200',
    '  END',
    'END',
    '',
  ].join('\n')
}

/** rc.exe: on PATH in a Visual Studio prompt, or the newest x64 one in the Windows 10 and 11 SDK. */
export function findRC() {
  try {
    execFileSync('rc', ['/?'], { stdio: 'ignore' })
    return 'rc'
  } catch {}
  const kits = 'C:\\Program Files (x86)\\Windows Kits\\10\\bin'
  if (!existsSync(kits)) return null
  const versions = readdirSync(kits).filter((name) => /^10\./.test(name)).sort().reverse()
  for (const version of versions) {
    const rc = join(kits, version, 'x64', 'rc.exe')
    if (existsSync(rc)) return rc
  }
  return null
}

const programs = [
  { name: 'Driftbox', description: 'Driftbox', icon: 'Driftbox.ico' },
  { name: 'DriftboxVST3Scan', description: 'Driftbox plug-in scanner' },
]

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const rc = findRC()
  if (!rc) {
    console.error('No rc.exe. Run this from a Visual Studio prompt, or install the Windows SDK.')
    process.exit(1)
  }
  for (const program of programs) {
    const source = join(out, `${program.name}.rc`)
    writeFileSync(source, script(program))
    execFileSync(rc, ['/nologo', '/fo', join(out, `${program.name}.res`), source], { stdio: 'inherit' })
  }
  console.log(`${programs.map((program) => `${program.name}.res`).join(', ')}  ${version().string}`)
}
