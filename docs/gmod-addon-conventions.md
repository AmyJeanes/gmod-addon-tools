_Shared conventions for my GMod addons - generated from [`gmod-addon-tools/docs/gmod-addon-conventions.md`](https://github.com/AmyJeanes/gmod-addon-tools/blob/main/docs/gmod-addon-conventions.md). Edit it there, not in this file; the block below is overwritten by CI. Addon-specific guidance lives outside the markers._

## Code style

- **Pure Lua syntax only - no GMod-Lua extensions.** No `//` comments, no `continue`, no `!=`, no `&&`/`||`. Use `--`, `goto skip` (`continue` is a reserved word even as a `goto` label, so `goto continue` fails at load), `~=`, `and`/`or`.
- **Comments: concise, the _why_ not the _what_.** A couple of lines at most; reserve length for genuinely non-obvious rationale and bias toward cutting - match the surrounding density, don't pad to essay length. Don't restate the code, don't explain it by what it replaced, and keep the _why_ self-contained (no pointers to external docs or fragile cross-file references). Keep comments ASCII: `->` not an arrow, a single spaced hyphen for a dash (never a double `--`, which reads as a second comment marker, nor an em-dash).
- **Drop the loop variable you don't use** rather than naming it: `for _, v in pairs(t)`, `for k in pairs(t)`, `for _ = 1, n do`. The `unused` lint is on - keep the noise floor at zero.
- **Every `---@diagnostic disable` needs a paired reason** on the same or preceding line naming _why_ the rule is suppressed. The default is to fix the issue, not suppress it.

## First-time setup (before touching `.lua` files)

The tooling (`glua_check`, `glua_ls`, the GLua API stubs, and the wiki/typing type-model) is provisioned by the shared [`gmod-addon-tools`](https://github.com/AmyJeanes/gmod-addon-tools) module, cloned **beside this addon**. `scripts/install-tools.ps1` is a thin wrapper - `scripts/bootstrap.ps1` resolves the sibling module and it calls `Initialize-GmodTools`, so the version pins live once in the module and every addon runs the exact same engine.

```bash
git clone https://github.com/AmyJeanes/gmod-addon-tools ../gmod-addon-tools
pwsh -File scripts/install-tools.ps1
```

It is idempotent - re-running is a no-op when the pinned versions are already present, so it is also the recovery path when diagnostics look wrong. After a fresh install, run `/reload-plugins` so Claude Code re-launches the LSP against the new binary.

## Claude Code LSP integration (`glua-lsp` plugin)

Diagnostics, hover, and jump-to-definition come from the [`glua-lsp` plugin](https://github.com/AmyJeanes/gmod-claude-plugins) (marketplace `AmyJeanes/gmod-claude-plugins`), which wraps the [`glua_ls`](https://github.com/Pollux12/gmod-glua-ls) server - the same EmmyLua-Analyzer-Rust engine as `glua_check`, running long-lived. Diagnostics arrive automatically after every edit; no hook involvement. `.claude/settings.json` declares the marketplace so contributors get prompted to install on first open, and the plugin auto-resolves `glua_ls` from this project's `.tools/bin/` at launch (no global install, no PATH plumbing). The `glua-lsp:install-glua-ls` skill covers the same recovery flow if symptoms appear later. Treat reported diagnostics as actionable only if your edit caused them - pre-existing noise on unrelated lines is not in scope for the current change.

## Whole-repo scans (`scripts/glua-check.ps1`)

`glua_ls` only analyzes files as they are opened or edited. To audit the whole repo at once, run `pwsh -File scripts/glua-check.ps1` - it provisions tooling on demand (no-op when present) and runs `glua_check --warnings-as-errors` against the workspace root. It takes no path filter, so it always scans everything; CI runs the same script. Useful after a fix ripples across the tree, or when picking the project up to surface latent issues the LSP hasn't opened yet.

**Local (Windows) vs CI (Linux) can diverge - CI is authoritative.** The same tooling and files can flag differently on Linux and no `.luarc.json` change closes that platform gap, so a green local `glua-check` isn't conclusive - watch CI's Linux `GLua Check` job after pushing typing changes. Most often the culprit is a strict `---@class`/`---@type` on a *partial or reused literal* (passes Windows, fails Linux); use `table`/`table[]?` or a `--[[@as Class]]` cast instead of annotating the literal. A second Linux-only firing: an undeclared engine classname used in `ents.Create` / `FindByClass` hints on CI but not locally - declare it in `.luatypes` as `---@class <name> : Entity`.

## Typing enforcement (`scripts/typing-check.ps1`)

`glua_check` catches _wrong_ types but not _missing_ ones - an untyped param is a silent `any` it never flags. `Test-GmodTyping` (CI: `typing-check.yml`) closes that gap, failing the build on any of: an untyped param, annotation rot (a `---@param` for a param that no longer exists), a modeled function whose resolved return type contains `unknown`, a hook fire-site argument that resolves to `unknown`, or a `:CallHook`-style hook whose receiver resolves to `unknown` (so its "Fired on" column would render _Unknown_ - usually fixed with a `---@param self <class>` on the enclosing function). Satisfy it at the **source** - prefer a `---@param` / `---@return` / `---@class` annotation over a per-callsite `---@cast`, since annotations propagate to every caller. The only accepted escapes are explicit and greppable: `---@param x any` (a reviewed, genuine `any`), an `_` discard for a deliberately-unused arg, and a file-level `---@vendored` marker on third-party code.

Where an addon fires its own hooks, callback payload params are typed by a generated `---@overload` catalogue (`scripts/generate-hook-types.ps1`, CI: `generate-hook-types.yml`) - do not hand-edit it; retype a payload at its `CallHook` / `hook.Run` site instead. Custom global-hook overloads are spliced into the provisioned `hook.lua` by `Initialize-GmodTools`, so after pulling a change to a generated fragment mid-session, re-run `scripts/install-tools.ps1` (it re-syncs) then `/reload-plugins` to refresh live types.

## Bumping the shared tooling

Tool versions and this conventions block are pinned to a `gmod-addon-tools` tag. Bump the version constants in `gmod-addon-tools/src/install.ps1` (or edit the shared docs); merging to the module's `main` auto-cuts a new tag, and Renovate then raises a pin-bump PR here that regenerates the affected artifacts and runs GLua Check before it merges. CI pins the module by tag (the `ref:` in each workflow); a local sibling checkout uses whatever branch it is on, so keep it on the pinned tag to mirror CI exactly.
