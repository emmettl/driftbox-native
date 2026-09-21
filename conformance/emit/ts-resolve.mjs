// The reference sources are TypeScript that imports its siblings as `./x.js`, which is what
// tsc wants and what Node cannot find. Node strips the types on its own; this hook only
// points `./x.js` at `./x.ts` when that is the file that exists. No build of the submodule,
// no dependencies, and the code that runs is the code in `driftbox/packages/*/src`.
import { existsSync } from 'node:fs'
import { registerHooks } from 'node:module'
import { fileURLToPath } from 'node:url'

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier.startsWith('.') && specifier.endsWith('.js') && context.parentURL?.startsWith('file:')) {
      const ts = new URL(`${specifier.slice(0, -3)}.ts`, context.parentURL)
      if (existsSync(fileURLToPath(ts))) return nextResolve(ts.href, context)
    }
    return nextResolve(specifier, context)
  },
})
