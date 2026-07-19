# gmod-addon-tools

Shared build/dev tooling for my Garry's Mod addons. One home for the parts that
are identical across TARDIS, Doors, world-portals, Sonic-Screwdriver, and the
rest - so they stop being copy-pasted per repo.

It owns three things, all **generic** (nothing addon-specific lives here):

1. **Tooling provisioning** (`Install-GmodTools`) - always fetches pinned
   `glua_check`, `glua_ls`, and the glua-api stubs into a consumer repo's `.tools/`,
   plus two opt-in tools: `emmylua_doc_cli` (the EmmyLua type-model CLI the wiki
   generator **and** the zero-untyped typing gate consume - `-TypeModel`) and
   MoonSharp (the headless harness interpreter - `-Harness`). `-Wiki` implies both.
   The versions are pinned **here**, so every addon runs the exact same engine and
   Renovate bumps them in one place.
2. **Wiki generator engine** (`Invoke-WikiGen`) - the emmylua_doc_cli -> markdown
   type-reference renderer: annotation parsing, ownership resolution, GMod-wiki
   linking, marker splicing, sidebar management, the Default/Required/Used-in
   columns, shared-class handling, linkify/expansion.
3. **Headless Lua harness** (`New-AddonHarness` / `ConvertFrom-LuaValue`) - loads
   an addon's content-definition Lua under a MoonSharp GMod-stub environment, so a
   consumer can extract real runtime defaults for its wiki.

## The contract: generic here, specifics in each addon

Each addon keeps a thin driver that imports this module and passes its config.
The addon-specific surface is small (for TARDIS it was ~5 things):

| Per-addon config | Passed as |
| --- | --- |
| Which pages exist + their root classes | `-Categories` |
| Which type names are "ours" to document | `-OwnedPrefix` (e.g. `tardis_`, `Door`, `wp.`) |
| Links to types owned by another addon's wiki | Auto-discovered from `.luarc.json` libraries that have `scripts/wiki-api.config.ps1`; `-ExternalTypeLinks` for overrides |
| How to extract base defaults (optional) | `-DefaultsProvider` scriptblock |
| Identity fields excluded from defaults (optional) | `-IdentityFields` |
| Where the wiki clone / lua root live | `-WikiPath` / `-Root` |

Everything else is in this repo.

### Build-time codegen: `scripts/pre-pack.ps1`

The reusable publish workflow (`.github/workflows/publish-workshop.yml`) runs an
addon's `scripts/pre-pack.ps1`, if it has one, in the addon checkout just before
packing. There is nothing to wire up - an addon opts in by having the file.

Use it for content that must be **generated into the `.gma` but never committed**.
TARDIS derives its version from the git tag this way: committing a file that
records the commit sha would change the very sha it records. The checkout has full
history and tags (`fetch-depth: 0`) and the standard `GITHUB_*` environment, so the
script can tell a tagged release from a branch build.

## Consuming it

Addons sit as siblings under `garrysmod/addons/`, and their CI already checks
each other out, so this module rides the same rails - no PowerShell Gallery
publish, no submodule, no vendored copy. It is consumed **as a sibling clone**:

- **Locally:** clone it next to the addon (it's then always present, so zero
  day-to-day friction). A consumer resolves `../gmod-addon-tools` and imports it.
- **CI:** the workflow checks it out at a **pinned ref** (tag/SHA) into the same
  sibling location - identical to how the other sibling repos are already pinned;
  Renovate can bump the ref.
- **Missing:** a small guard fails with an actionable message ("clone it beside
  this addon") instead of an opaque `Import-Module` error. It never auto-clones -
  setup stays an explicit, documented step.

The guard + import is one shared `bootstrap.ps1` per consumer (see Doors'
`scripts/bootstrap.ps1`), so the real entry scripts stay tiny:

```powershell
# scripts/install-tools.ps1
. "$PSScriptRoot/bootstrap.ps1"
Install-GmodTools -Root (Split-Path -Parent $PSScriptRoot) -Wiki
```

`scripts/generate-wiki-api.ps1` is a thin config block - see a real consumer
like Doors (`scripts/generate-wiki-api.ps1` + `scripts/wiki-api.config.ps1`) for
the full shape. Addons that generate a wiki should also expose the
category/prefix portion as
`scripts/wiki-api.config.ps1`; other addons can then discover and link those
types automatically through their existing `.luarc.json` `workspace.library`
entries.

Each consuming addon documents one setup step: clone `gmod-addon-tools` beside it
before running the tooling.

## Releases

Consumers pin a **tag** (not `main`), so tooling changes reach them as a Renovate
bump PR that runs their CI first - never silently on an unrelated build.

`.github/workflows/auto-tag.yml` cuts the next patch tag automatically when the
tooling itself changes (a push to `main` touching `src/**` or the module
manifest). Docs / CI-only changes don't release. A consumer's Renovate
then opens a PR bumping its pinned `ref:` to the new tag; a bump that breaks the
consumer shows up as a red PR that never merges.

So the release loop is: edit `src/` -> merge to `main` -> auto-tag -> per-consumer
Renovate PR -> consumer CI gates it.

## Status

Live. Ported from TARDIS's `scripts/generate-wiki-api.ps1`, `scripts/lua-harness/*`,
and `scripts/install-tools.ps1`; verified by the generated wiki output staying
byte-identical. **Doors** is the reference consumer - copy its `scripts/`
(`bootstrap.ps1`, `install-tools.ps1`, `generate-wiki-api.ps1`,
`wiki-api.config.ps1`) and `.github/workflows/generate-wiki.yml` to onboard a
new addon.
