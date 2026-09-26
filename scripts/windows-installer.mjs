// Driftbox for Windows' installer: dist/Driftbox-<version>-setup-x64.exe, made by Inno Setup 6 from
// windows/Driftbox.iss and the folder windows-package.mjs makes, which it makes first.
//
//   swift build -c release --product DriftboxWindows    (from a Visual Studio x64 prompt)
//   swift build -c release --product DriftboxVST3Scan
//   node scripts/windows-installer.mjs [--packaged]
//
// With --packaged, the folder is taken as it is, as the release workflow has it after its programs
// are signed, rather than made again. The version is scripts/version.env's. Inno Setup's compiler
// is found from INNO_SETUP, or where its installer puts it, for one person or for everyone.
import { execFileSync } from 'node:child_process'
import { existsSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { version as versions } from './windows-resources.mjs'

const root = join(fileURLToPath(new URL('.', import.meta.url)), '..')
const version = versions().string

function compiler() {
  const candidates = [
    process.env.INNO_SETUP && join(process.env.INNO_SETUP, 'ISCC.exe'),
    join(process.env.LOCALAPPDATA ?? '', 'Programs', 'Inno Setup 6', 'ISCC.exe'),
    join(process.env['ProgramFiles(x86)'] ?? 'C:\\Program Files (x86)', 'Inno Setup 6', 'ISCC.exe'),
    join(process.env.ProgramFiles ?? 'C:\\Program Files', 'Inno Setup 6', 'ISCC.exe'),
  ]
  return candidates.find((path) => path && existsSync(path))
}

const iscc = compiler()
if (!iscc) {
  console.error('No Inno Setup 6. Install it (winget install JRSoftware.InnoSetup), or set INNO_SETUP to its folder.')
  process.exit(1)
}

if (!process.argv.includes('--packaged')) {
  execFileSync(process.execPath, [join(root, 'scripts', 'windows-package.mjs')], { stdio: 'inherit' })
}
execFileSync(iscc, ['/Q', `/DAppVersion=${version}`, join(root, 'windows', 'Driftbox.iss')], { stdio: 'inherit' })
const setup = join(root, 'dist', `Driftbox-${version}-setup-x64.exe`)
console.log(`dist/Driftbox-${version}-setup-x64.exe  ${(statSync(setup).size / 1048576).toFixed(1)}MB`)
