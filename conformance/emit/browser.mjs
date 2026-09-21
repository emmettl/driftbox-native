// A real Chromium, for the fixtures only a real OfflineAudioContext can produce.
//
// No dependencies, on the same terms as the rest of the emitter. Two small pieces:
//
//   - An HTTP server that serves the reference sources straight out of the submodule. A browser
//     can import ES modules but not TypeScript, and the sources import each other as `./x.js`;
//     so a request for `x.js` that finds an `x.ts` gets that file with its types stripped, by
//     Node's own `stripTypeScriptTypes`. Nothing is bundled and nothing is built.
//   - The DevTools protocol over Node's built-in WebSocket: open a page, evaluate an expression,
//     wait for its promise, take the value.
import { spawn } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs'
import { createServer } from 'node:http'
import { stripTypeScriptTypes } from 'node:module'
import { homedir, tmpdir } from 'node:os'
import { extname, join, normalize } from 'node:path'

/** DRIFTBOX_CHROMIUM, then whatever Playwright has cached, then an installed Chrome. */
export function findChromium() {
  const candidates = []
  if (process.env.DRIFTBOX_CHROMIUM) candidates.push(process.env.DRIFTBOX_CHROMIUM)

  for (const cache of [join(homedir(), 'Library/Caches/ms-playwright'), join(homedir(), '.cache/ms-playwright')]) {
    if (!existsSync(cache)) continue
    const shells = readdirSync(cache).filter((name) => name.startsWith('chromium_headless_shell-')).sort().reverse()
    for (const shell of shells) {
      for (const platform of readdirSync(join(cache, shell))) {
        candidates.push(join(cache, shell, platform, 'headless_shell'), join(cache, shell, platform, 'chrome-headless-shell'))
      }
    }
  }

  candidates.push(
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    '/usr/bin/google-chrome',
    '/usr/bin/google-chrome-stable',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
  )
  const found = candidates.find((path) => existsSync(path))
  if (!found) throw new Error('No Chromium found. Set DRIFTBOX_CHROMIUM to a Chrome or Chromium binary.')
  return found
}

function serve(root) {
  const server = createServer((request, response) => {
    const path = normalize(decodeURIComponent(new URL(request.url, 'http://x').pathname))
    if (path === '/') {
      response.writeHead(200, { 'content-type': 'text/html' }).end('<!doctype html><title>driftbox reference</title>')
      return
    }
    const file = join(root, path)
    if (!file.startsWith(root)) return response.writeHead(403).end()

    const typescript = extname(file) === '.js' ? `${file.slice(0, -3)}.ts` : file
    // Read first and answer second: a full Chrome asks for a favicon, and a file that is not there
    // must become a 404 rather than an exception halfway through a 200.
    let body
    try {
      body = extname(typescript) === '.ts' && existsSync(typescript)
        ? stripTypeScriptTypes(readFileSync(typescript, 'utf8'))
        : readFileSync(file)
    } catch (error) {
      response.writeHead(404).end(String(error))
      return
    }
    response.writeHead(200, { 'content-type': 'text/javascript' }).end(body)
  })
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)))
}

async function launch(binary) {
  const profile = mkdtempSync(join(tmpdir(), 'driftbox-chromium-'))
  const chromium = spawn(binary, [
    '--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`, '--no-first-run',
    '--no-default-browser-check', '--disable-gpu', '--mute-audio',
    // A hosted runner's kernel refuses Chromium the namespaces its sandbox wants. The page only
    // ever loads this repository's own files from localhost.
    ...(process.env.CI ? ['--no-sandbox'] : []),
    'about:blank',
  ], { stdio: ['ignore', 'ignore', 'pipe'] })

  const endpoint = await new Promise((resolve, reject) => {
    let log = ''
    // Cleared the moment it listens: left running, it would kill a browser in the middle of its work.
    const patience = setTimeout(() => {
      chromium.kill()
      reject(new Error(`${binary} did not start listening within a minute:\n${log}`))
    }, 60000)
    chromium.stderr.on('data', (chunk) => {
      log += chunk
      const match = log.match(/DevTools listening on (ws:\/\/\S+)/)
      if (match) {
        clearTimeout(patience)
        resolve(match[1])
      }
    })
    chromium.on('exit', (code) => {
      clearTimeout(patience)
      reject(new Error(`${binary} exited (${code}) before listening:\n${log}`))
    })
  })
  return { chromium, endpoint, profile }
}


/**
 * Open a page with the submodule's packages served beside it, and hand back `evaluate`.
 *
 * `evaluate(expression)` runs in the page, awaits a promise if the expression is one, and returns
 * the value — which has to survive JSON, so audio comes back as base64 (see `floats`).
 */
export async function openReference(packagesRoot) {
  const server = await serve(packagesRoot)
  const origin = `http://127.0.0.1:${server.address().port}`
  const binary = findChromium()
  // A hosted runner's Chrome sometimes sits for a long while before it listens, and once in a
  // while never does. Give it a minute, and a second and a third go.
  let chromium, endpoint, profile
  for (let attempt = 1; ; attempt++) {
    try {
      ;({ chromium, endpoint, profile } = await launch(binary))
      break
    } catch (error) {
      if (attempt >= 3) throw error
      console.error(`${error.message.split('\n')[0]} — trying again`)
    }
  }

  const socket = new WebSocket(endpoint)
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true })
    socket.addEventListener('error', reject, { once: true })
  })

  let nextId = 0
  const pending = new Map()
  socket.addEventListener('message', (event) => {
    const message = JSON.parse(event.data)
    const waiting = pending.get(message.id)
    if (!waiting) return
    pending.delete(message.id)
    if (message.error) waiting.reject(new Error(message.error.message))
    else waiting.resolve(message.result)
  })
  const send = (method, params = {}, sessionId) =>
    new Promise((resolve, reject) => {
      const id = ++nextId
      pending.set(id, { resolve, reject })
      socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }))
    })

  const { targetId } = await send('Target.createTarget', { url: `${origin}/` })
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true })
  const { product } = await send('Browser.getVersion')

  // The page is still arriving when the target is attached, and an evaluation that lands mid-
  // navigation dies with its execution context. Wait until it is really there.
  for (let attempt = 0; ; attempt++) {
    const ready = await send('Runtime.evaluate', { expression: `document.readyState === 'complete' && location.origin === ${JSON.stringify(origin)}`, returnByValue: true }, sessionId)
      .then((result) => result.result?.value === true, () => false)
    if (ready) break
    if (attempt > 200) throw new Error('the reference page never finished loading')
    await new Promise((resolve) => setTimeout(resolve, 50))
  }

  return {
    origin,
    product,
    async evaluate(expression) {
      const result = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sessionId)
      if (result.exceptionDetails) {
        const details = result.exceptionDetails
        throw new Error(`in the page: ${details.exception?.description ?? details.text}`)
      }
      return result.result.value
    },
    async close() {
      socket.close()
      chromium.kill()
      server.close()
      await new Promise((resolve) => chromium.on('exit', resolve))
      // Chrome's helper processes can outlive it by a moment and are still writing here. It is a
      // temporary directory: try properly, and do not let a leftover fail a run whose work is done.
      try {
        rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 })
      } catch {}
    },
  }
}

/** Page-side source for turning a Float32Array into something `evaluate` can return. */
export const FLOATS_TO_BASE64 = `(floats) => {
  const bytes = new Uint8Array(floats.buffer, floats.byteOffset, floats.byteLength)
  let binary = ''
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(binary)
}`

export function floats(base64) {
  const bytes = Buffer.from(base64, 'base64')
  return new Float32Array(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength))
}
