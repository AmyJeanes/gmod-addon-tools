# gmod-addon-tools

Shared build/dev tooling for my Garry's Mod addons. One home for the parts that
are identical across TARDIS, Doors, world-portals, Sonic-Screwdriver, and the
rest - so they stop being copy-pasted per repo.

It owns three things, all **generic** (nothing addon-specific lives here):

1. **Tooling provisioning** (`Install-GmodTools`) - fetches pinned `glua_check`,
   `glua_ls`, the glua-api stubs, and (for wiki consumers) `emmylua_doc_cli` +
   MoonSharp into a consumer repo's `.tools/`. The versions are pinned **here**,
   so every addon runs the exact same engine and Renovate bumps them in one place.
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
| How to extract base defaults (optional) | `-DefaultsProvider` scriptblock |
| Identity fields excluded from defaults (optional) | `-IdentityFields` |
| Where the wiki clone / lua root live | `-WikiPath` / `-Root` |

Everything else is in this repo.

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

The guard + import is one shared `bootstrap.ps1` per consumer (see
`examples/tardis/bootstrap.ps1`), so the real entry scripts stay tiny:

```powershell
# scripts/install-tools.ps1
. "$PSScriptRoot/_bootstrap.ps1"
Install-GmodTools -Root (Split-Path -Parent $PSScriptRoot) -Wiki
```

`scripts/generate-wiki-api.ps1` is the config block in
`examples/tardis/generate-wiki-api.ps1` - see there for the full shape.

Each consuming addon documents one setup step: clone `gmod-addon-tools` beside it
before running the tooling.

## Status

Live. Ported from TARDIS's `scripts/generate-wiki-api.ps1`, `scripts/lua-harness/*`,
and `scripts/install-tools.ps1`; verified by the generated wiki output staying
byte-identical. TARDIS is consumer #1. [docs/PORT-PLAN.md](docs/PORT-PLAN.md)
records the extraction map, and `examples/tardis/` is the consumer template other
addons follow to onboard.
