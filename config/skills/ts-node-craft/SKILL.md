---
name: ts-node-craft
description: TypeScript/Node discipline sourced from official docs (researched 2026-10: Node 26 LTS, TS 7, Google TS guide, typescript-eslint). Load when writing, reviewing or testing JS/TS/Node code.
---

# TS/Node on this station (official rules, verified 2026-10-29)

## Facts
- Node LTS: **26 "Lithium"** (v26.13.0, LTS since 2026-10-28; EOL 2029-04) (https://nodejs.org/dist/index.json)
- Native TS runtime: **Stability 2 (stable), ON by default** - Node executes `.ts` directly with erasable syntax; no strip-types flag (disable: `--no-strip-types`) (https://nodejs.org/api/typescript.html)
- TypeScript npm latest: **7.0.2** (7.1 Beta Sep 2026) (https://registry.npmjs.org/typescript/latest)
- Stripping does NOT type-check nor read tsconfig - ALWAYS run `tsc --noEmit` as a separate gate (`module: nodenext`, `target: esnext`, `verbatimModuleSyntax`, `erasableSyntaxOnly`) (https://nodejs.org/api/typescript.html)

## Check ladder
1. `node --check file.mjs` instant (ESM); node runs `.ts` natively now
2. `tsc --noEmit -p .` (or narrow `--files` when tsconfig is fat)
3. Targeted tests: `node --test` (native runner) / `npx vitest run path/to/test`
4. typescript-eslint: base `recommended` + `stylistic`, type-checked adds `recommended-type-checked` (+ `parserOptions.projectService: true`); presets never include formatting (https://typescript-eslint.io/users/configs/)

## Style (official distillation, each with source)
- Packages: explicit file extensions in relative imports and `require()`; `.mts` = ESM, `.cts` = CJS; node modules MUST NOT contain .ts (https://nodejs.org/api/typescript.html)
- Untype-strippable syntax is FORBIDDEN for native Node TS: `enum`, runtime namespaces, parameter properties (ctor `private x`), decorators, tsconfig `paths` (use `#/` subpath imports) (https://nodejs.org/api/typescript.html)
- Type-only imports with explicit `type` keyword: `import type {T}` / `{fn, type T}` - without `type` it breaks at strip time (https://nodejs.org/api/typescript.html)
- `satisfies` for literal shape checks while keeping literal inference (https://www.typescriptlang.org/docs/handbook/release-notes/typescript-4-9.html)
- Google naming: `UpperCamelCase` types/classes/enums, `lowerCamelCase` everything else, `CONSTANT_CASE` module constants, file names snake_case, acronyms as words (`loadHttpUrl`), no leading/trailing underscores (https://google.github.io/styleguide/tsguide.html)
- `any` - the guide says "consider not to use": pick `unknown` + narrowing, or an explicit suppression with justification; keep `noImplicitAny` (https://google.github.io/styleguide/tsguide.html)
- No `export default`, no `export let`, no "container classes" with statics - named exports or bare functions (https://google.github.io/styleguide/tsguide.html)
- Modules, not namespaces: no `namespace {}`, no `import x = require()`, no `/// <reference>` (except ambient APIs/legacy) (https://google.github.io/styleguide/tsguide.html)
- Errors: throw `new Error(...)` only (never bare strings); custom errors subclass Error with `cause`; catch as `unknown` + guard (`catch (e: unknown)`); empty catch needs a comment-or-refactor (https://google.github.io/styleguide/tsguide.html)
- Assertions (`as`, `!`) only with obvious explicit reason; prefer `: Foo` over `Foo = {};
 as Foo` on literals; unavoidable casts via `unknown` (double assertion) (https://google.github.io/styleguide/tsguide.html)
- `readonly` for post-ctor fields; `public` modifier is redundant; `private` NOT `#field`; no `obj[foo]` escape hatches (https://google.github.io/styleguide/tsguide.html)
- Never `var`; arrow function expressions; `[]`/`{}` over `Array()`/`Object()`; no unguarded `for...in` - `Object.keys/entries`; `const enum` BANNED - plain `enum` only (https://google.github.io/styleguide/tsguide.html)
- Agents: every Promise-materialized expression must be `await`/`.catch`/`return`/`void` (`no-floating-promises` lives in type-checked config) (https://typescript-eslint.io/rules/no-floating-promises/)

## Gotchas of this machine (NixOS)
- node 26 natively handles fetch/WebSocket/node:test/TS strip-types - no `ts-node`/`tsx` baggage.
- npm with native modules when no prebuilt binary -> `nix-shell -p gcc gnumake python3`.
- Persistent global tools: `nix profile install nixpkgs#<pkg>` over npm -g; project-local node_modules live fine in $HOME.
