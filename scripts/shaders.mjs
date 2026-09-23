// The scenes' shaders are written once, in GLSL, and every platform's language is made from that
// here, offline, and checked in: Metal for the Mac and iOS, HLSL for Direct3D on Windows, GLSL ES
// for Android.
//
//   node scripts/shaders.mjs           rewrite every generated file
//   node scripts/shaders.mjs --check   write nothing; fail if a generated file is stale
//
// --check makes everything again and compares it whole when the tools are here. Where they are not
// — CI, which would otherwise download a 330MB SDK to check a few files — it checks each file's
// hashes of its GLSL and of itself instead, which is enough to catch GLSL edited without the file
// being made again, and the file edited by hand.
//
// shaders/<Target>/<program>.frag is a program, with <program>.vert, or the target's fullscreen.vert
// where it has none of its own — which is what the surface scenes, one fragment shader each, share.
// glslang compiles each stage to SPIR-V, SPIRV-Cross writes it out in the three languages, and its
// reflection gives every uniform block's layout — from which the Swift structs the blocks are filled
// from are written too, so that Swift and the shaders cannot disagree about where a member lives. A
// layout Swift cannot lay out the same way is refused here, with the reason, rather than drawn wrong.
//
// The output goes to Sources/<Target>/Generated/ShaderPrograms.swift, or Tests/<Target>/... for a
// test target. The tools come from the Vulkan SDK (VULKAN_SDK, or PATH). Their version is written into
// every generated file, and --check refuses to compare against another version, since a different
// SPIRV-Cross writes different text that means the same thing.
import { execFileSync, spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync, mkdirSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const check = process.argv.includes('--check')

// ── The tools ───────────────────────────────────────────────────────────────────────────────────

function tool(name) {
  const sdk = process.env.VULKAN_SDK
  const exe = process.platform === 'win32' ? `${name}.exe` : name
  if (sdk) {
    for (const bin of ['Bin', 'bin', 'x86_64/bin']) {
      const path = join(sdk, bin, exe)
      if (existsSync(path)) return path
    }
  }
  return exe
}
const glslang = tool('glslangValidator')
const spirvCross = tool('spirv-cross')
// Line endings are \n whatever the platform writes, so a file made on Windows hashes as on Linux.
const lf = (text) => text.replace(/\r\n/g, '\n')
const run = (command, args) => lf(execFileSync(command, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }))

// SPIRV-Cross says its revision on stderr, and exits as though it had been given nothing to do.
function toolVersion() {
  const result = spawnSync(spirvCross, ['--revision'], { encoding: 'utf8' })
  if (result.error) throw result.error
  const line = `${result.stdout}${result.stderr}`.split(/\r?\n/).find((l) => l.startsWith('Git commit'))
  return (line ?? 'unknown').replace(/^Git commit: /, '').replace(/ Timestamp:.*$/, '').trim()
}

// ── Reading reflection ──────────────────────────────────────────────────────────────────────────

/** Swift's own type for a GLSL uniform member: its name, size, alignment and zero value. */
const SWIFT = {
  float: { type: 'Float', size: 4, align: 4, zero: '0' },
  int: { type: 'Int32', size: 4, align: 4, zero: '0' },
  uint: { type: 'UInt32', size: 4, align: 4, zero: '0' },
  vec2: { type: 'SIMD2<Float>', size: 8, align: 8, zero: '.zero' },
  vec3: { type: 'SIMD3<Float>', size: 16, align: 16, zero: '.zero' },
  vec4: { type: 'SIMD4<Float>', size: 16, align: 16, zero: '.zero' },
  mat4: { type: 'Matrix4', size: 64, align: 16, zero: '.identity' },
}
const ATTRIBUTE = { float: '.float', vec2: '.float2', vec3: '.float3', vec4: '.float4' }

/** A uniform block as a Swift struct, member by member at the offsets the shader reads them. */
function swiftBlock(program, block, types) {
  const fields = []
  const layout = []
  let at = 0
  let padding = 0
  for (const member of types[block.type].members) {
    const base = SWIFT[member.type]
    if (!base) fail(program, `${block.name}.${member.name} is a ${member.type}, which has no Swift form here`)
    let type = base.type
    let size = base.size
    let zero = base.zero
    if (member.array) {
      const count = member.array[0]
      if (member.array_stride !== base.size) {
        fail(
          program,
          `${block.name}.${member.name}: std140 puts its elements ${member.array_stride} bytes apart, and Swift ` +
            `puts a ${base.type} ${base.size} apart. Make it an array of vec4.`,
        )
      }
      type = `InlineArray<${count}, ${base.type}>`
      size = base.size * count
      zero = `InlineArray(repeating: ${base.zero})`
    }
    at = Math.ceil(at / base.align) * base.align
    if (at > member.offset) {
      fail(
        program,
        `${block.name}.${member.name}: std140 puts it at ${member.offset}, and Swift cannot before ${at} — ` +
          `a scalar after a vec3 is the usual cause. Move it, or make the vec3 a vec4.`,
      )
    }
    if (at < member.offset) {
      const floats = (member.offset - at) / 4
      fields.push(`  private var _padding${padding++}: (${Array(floats).fill('Float').join(', ')}) = (${Array(floats).fill('0').join(', ')})`)
      at = member.offset
    }
    fields.push(`  public var ${member.name}: ${type} = ${zero}`)
    layout.push(`("${member.name}", MemoryLayout<Self>.offset(of: \\Self.${member.name}), ${member.offset})`)
    at += size
  }
  return (
    `/// \`${block.name}\` in the shaders, laid out as they read it.\n` +
    `public struct ${block.name}: UniformBlock {\n` +
    fields.join('\n') +
    '\n\n  public init() {}\n\n' +
    `  public static let blockSize = ${block.block_size}\n` +
    `  public static var layout: [(member: String, swift: Int?, shader: Int)] {\n    [\n` +
    layout.map((line) => `      ${line},`).join('\n') +
    '\n    ]\n  }\n}\n'
  )
}

function fail(program, message) {
  console.error(`${program}: ${message}`)
  process.exit(1)
}

// ── One program ─────────────────────────────────────────────────────────────────────────────────

function compile(dir, name, scratch) {
  const out = {}
  for (const stage of ['vert', 'frag']) {
    // A program with no vertex shader of its own covers the screen with the target's.
    const own = join(dir, `${name}.${stage}`)
    const source = stage === 'vert' && !existsSync(own) ? join(dir, 'fullscreen.vert') : own
    const spv = join(scratch, `${name}.${stage}.spv`)
    try {
      run(glslang, ['-V', '--quiet', source, '-o', spv])
    } catch (error) {
      fail(`${name}.${stage}`, `${error.stdout ?? ''}${error.stderr ?? ''}`.trim())
    }
    const entry = `${name}${stage === 'vert' ? 'Vertex' : 'Fragment'}`
    out[stage] = {
      metal: run(spirvCross, [
        spv, '--msl', '--msl-version', '20100', '--msl-decoration-binding',
        '--rename-entry-point', 'main', entry, stage, '--stage', stage,
      ]),
      hlsl: run(spirvCross, [spv, '--hlsl', '--shader-model', '50', '--stage', stage]),
      essl: run(spirvCross, [spv, '--es', '--version', '300', ...(stage === 'vert' ? ['--fixup-clipspace'] : []), '--stage', stage]),
      reflection: JSON.parse(run(spirvCross, [spv, '--reflect', '--stage', stage])),
    }
  }
  return out
}

const raw = (text) => `#"""\n${text.replace(/\s+$/, '')}\n"""#`

function generate(target, dir, scratch) {
  const names = readdirSync(dir).filter((f) => f.endsWith('.frag')).map((f) => f.slice(0, -5)).sort()
  const programs = []
  const blocks = new Map()
  for (const name of names) {
    if (!existsSync(join(dir, `${name}.vert`)) && !existsSync(join(dir, 'fullscreen.vert'))) {
      fail(name, 'has no .vert, and there is no fullscreen.vert beside it')
    }
    const { vert, frag } = compile(dir, name, scratch)
    // Both stages see the same uniform blocks at the same bindings, as a pass sets them once.
    const ubos = new Map()
    for (const reflection of [vert.reflection, frag.reflection]) {
      for (const ubo of reflection.ubos ?? []) {
        const members = JSON.stringify(reflection.types[ubo.type].members)
        const known = ubos.get(ubo.name)
        if (known && (known.binding !== ubo.binding || known.members !== members)) {
          fail(name, `${ubo.name} differs between the stages`)
        }
        ubos.set(ubo.name, { ...ubo, members, types: reflection.types })
        const shared = blocks.get(ubo.name)
        if (shared && shared.members !== members) fail(name, `${ubo.name} is declared differently in another program`)
        if (!shared) blocks.set(ubo.name, { name, ubo, members, types: reflection.types })
      }
    }
    const textures = [...(vert.reflection.textures ?? []), ...(frag.reflection.textures ?? [])]
    const attributes = (vert.reflection.inputs ?? []).sort((a, b) => a.location - b.location)
    for (const attribute of attributes) {
      if (!ATTRIBUTE[attribute.type]) fail(name, `attribute ${attribute.name} is a ${attribute.type}`)
    }
    programs.push(
      `  public static let ${name} = ShaderProgram(\n` +
        `    name: "${name}",\n` +
        `    metal: .init(\n      vertex: ${raw(vert.metal)},\n      fragment: ${raw(frag.metal)}),\n` +
        `    hlsl: .init(\n      vertex: ${raw(vert.hlsl)},\n      fragment: ${raw(frag.hlsl)}),\n` +
        `    essl: .init(\n      vertex: ${raw(vert.essl)},\n      fragment: ${raw(frag.essl)}),\n` +
        `    blocks: [${[...ubos.values()].map((u) => `.init(name: "${u.name}", binding: ${u.binding}, size: ${u.block_size})`).join(', ')}],\n` +
        `    textures: [${textures.map((t) => `.init(name: "${t.name}", binding: ${t.binding})`).join(', ')}],\n` +
        `    attributes: [${attributes.map((a) => `.init(name: "${a.name}", location: ${a.location}, format: ${ATTRIBUTE[a.type]})`).join(', ')}])\n`,
    )
  }
  const structs = [...blocks.values()].map(({ name, ubo, types }) => swiftBlock(name, ubo, types))
  const imports = target === 'DriftboxGPU' ? '' : 'import DriftboxGPU\n\n'
  const body =
    `// swift-format-ignore-file\n\n${imports}` +
    `extension ShaderProgram {\n${programs.join('\n')}}\n\n${structs.join('\n')}`
  return (
    `// Generated by scripts/shaders.mjs from shaders/${target}. Edit the GLSL and run it again.\n` +
    `// glslang and SPIRV-Cross: ${toolVersion()}\n` +
    `// GLSL ${sourceHash(dir)}, this file ${hash(body)}\n` +
    body
  )
}

// ── Checking without the tools ──────────────────────────────────────────────────────────────────
//
// A generated file says what it was made from, as a hash of the GLSL, and what it is, as a hash of
// everything below its header. Without the tools, that is still enough to say whether anybody has
// edited the GLSL without making the file again, or edited the file itself: the two ways it goes
// stale. With them, --check makes everything again and compares it whole.

const hash = (text) => createHash('sha256').update(text).digest('hex').slice(0, 16)

function sourceHash(dir) {
  const files = readdirSync(dir).filter((f) => f.endsWith('.vert') || f.endsWith('.frag')).sort()
  return hash(files.map((f) => `${f}\n${lf(readFileSync(join(dir, f), 'utf8'))}`).join('\n'))
}

/** Why a generated file does not match its GLSL, or nil. */
function hashesDisagree(current, dir) {
  const lines = current.split('\n')
  const recorded = lines[2]?.match(/^\/\/ GLSL ([0-9a-f]+), this file ([0-9a-f]+)$/)
  if (!recorded) return 'it has no hashes'
  if (recorded[1] !== sourceHash(dir)) return 'the GLSL has changed since it was made'
  if (recorded[2] !== hash(lines.slice(3).join('\n'))) return 'it has been edited since it was made'
  return null
}

function toolsHere() {
  return [glslang, spirvCross].every((command) => !spawnSync(command, ['--version'], { encoding: 'utf8' }).error)
}

// ── Every target ────────────────────────────────────────────────────────────────────────────────

const shaders = join(root, 'shaders')
const tools = toolsHere()
if (!check && !tools) fail('shaders', 'glslang and SPIRV-Cross are not here: install the Vulkan SDK, or set VULKAN_SDK')
const scratch = mkdtempSync(join(tmpdir(), 'driftbox-shaders-'))
const stale = []
try {
  for (const target of readdirSync(shaders, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name)) {
    const home = existsSync(join(root, 'Tests', target)) ? 'Tests' : 'Sources'
    const out = join(root, home, target, 'Generated', 'ShaderPrograms.swift')
    if (check && !tools) {
      const why = existsSync(out) ? hashesDisagree(lf(readFileSync(out, 'utf8')), join(shaders, target)) : 'it is missing'
      if (why) stale.push(`${home}/${target}/Generated/ShaderPrograms.swift: ${why}`)
      continue
    }
    const text = generate(target, join(shaders, target), scratch)
    if (check) {
      const current = existsSync(out) ? lf(readFileSync(out, 'utf8')) : ''
      const made = current.match(/glslang and SPIRV-Cross: (\S+)/)?.[1]
      if (made && made !== toolVersion()) {
        console.error(`${out} was made with SPIRV-Cross ${made} and this is ${toolVersion()}: compare with that version`)
        process.exit(1)
      }
      if (current !== text) stale.push(`${home}/${target}/Generated/ShaderPrograms.swift`)
    } else {
      mkdirSync(dirname(out), { recursive: true })
      writeFileSync(out, text)
    }
  }
} finally {
  rmSync(scratch, { recursive: true, force: true })
}
if (stale.length) {
  console.error(`generated shaders are stale — run node scripts/shaders.mjs:\n  ${stale.join('\n  ')}`)
  process.exit(1)
}
console.log(check ? `generated shaders are current${tools ? '' : ' (by their hashes: glslang and SPIRV-Cross are not here)'}` : 'shaders generated')
