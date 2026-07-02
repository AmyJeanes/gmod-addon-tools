# Port plan

The concrete extraction: what moves out of TARDIS into this module, what gets
parameterized, and how it's verified. Nothing here is TARDIS-specific once ported
- the addon-specific bits become `Invoke-WikiGen` / `Install-GmodTools` arguments.

## Source -> destination

| From (TARDIS) | To (this module) | Notes |
| --- | --- | --- |
| `scripts/install-tools.ps1` (whole file) | `src/install.ps1` -> `Install-GmodTools` | Add `-Root <consumerRoot>` (installs into the consumer's `.tools/`, not this repo's). Add `-Wiki` switch gating emmylua_doc_cli + MoonSharp. Version constants move here (pinned once for all addons). |
| `scripts/lua-harness/harness.ps1` | `src/harness/harness.ps1` | `New-AddonHarness` / `ConvertFrom-LuaValue` / `Get-HarnessMeta` exported. Resolve MoonSharp DLL + prelude via `$PSScriptRoot` (module-relative), not the consumer's tree. |
| `scripts/lua-harness/*.lua` (prelude) | `src/harness/prelude/*.lua` | gmod-stubs / gmod-types / stdlib ports / enum load. 100% generic GMod env; verbatim move. |
| `scripts/generate-wiki-api.ps1` (engine body) | `src/wiki/*.ps1` -> `Invoke-WikiGen` | Everything below `Parse-Annotations` down through the render/splice/sidebar logic. Split into `parse.ps1` / `render.ps1` / `emit.ps1` for readability, dot-sourced by the psm1. |

## What gets parameterized (the only addon-specific lines)

| TARDIS today | Becomes a param |
| --- | --- |
| `$Categories = @(...)` (generate-wiki-api.ps1:51) | `-Categories` |
| `Is-Documentable`'s `$name.StartsWith('tardis_')` (:203) | `-OwnedPrefix string[]` -> `foreach ($p in $OwnedPrefix) { if ($name.StartsWith($p)) {...} }` |
| `Get-BaseDefaults` (:129) | `-DefaultsProvider { param($lua, $meta) ... return @{ class = subtree } }` (optional; no provider -> no Default column, the `Test-PageHasDefaults` gate already handles that) |
| `$IdentityFields` (:176) | `-IdentityFields hashtable` (optional) |
| `$WikiPath` default `../TARDIS.wiki` (:39) | `-WikiPath` (required per consumer) |
| `$RepoRoot` / `$LuaRoot` (:33-34) | `-Root` / `-LuaRoot` (default `$Root/lua`) |
| `.tools/glua-api`, `.tools/bin/emmylua_doc_cli` paths | `-GluaApiPath` / `-DocCliPath` (default under `-Root/.tools`) |

## Public API (see GmodAddonTools.psm1 for signatures)

- `Install-GmodTools -Root <path> [-Wiki]`
- `Invoke-WikiGen -Root <path> -WikiPath <path> -Categories <hashtable[]> -OwnedPrefix <string[]> [-DefaultsProvider <scriptblock>] [-IdentityFields <hashtable>] [-Check]`
- `New-AddonHarness -Realm server|client -Root <path>` / `ConvertFrom-LuaValue` / `Get-HarnessMeta` (used inside a consumer's `-DefaultsProvider`)

## Consumer-side after the port (TARDIS)

- `scripts/install-tools.ps1` -> thin wrapper (see `examples/tardis/install-tools.ps1`).
- `scripts/generate-wiki-api.ps1` -> config block (see `examples/tardis/generate-wiki-api.ps1`).
- `scripts/lua-harness/` -> deleted (moved here).
- `scripts/glua-check.ps1` -> unchanged (still calls the local `.tools/bin/glua_check` that `Install-GmodTools` provisions).
- `.github/workflows/*.yml` -> add a checkout of `gmod-addon-tools@<pinned>` before the install/generate steps; the rest is unchanged.
- `.luarc.json` -> unchanged (`.tools/glua-api` still populated locally by `Install-GmodTools`).

## Verification

The port is behaviour-preserving. Regression check: run the ported
`Invoke-WikiGen` against the current TARDIS annotations and diff the output
against the live `../TARDIS.wiki` - must be **byte-identical** (the LF
normalization that keeps Windows/Linux output stable is part of the engine, so
it moves too). Also re-run `glua-check.ps1` to confirm provisioning parity.
