# CLAUDE.md

Guidance for Claude Code when working in `gmod-addon-tools` — the shared
PowerShell build/dev tooling for my GMod addons. See `README.md` for what it
owns and how consumers (Doors, world-portals, TARDIS, GMod-MCP-Server, …) use it.

## Layout

- `GmodAddonTools.psd1` / `.psm1` — module manifest + loader (dot-sources `src/`).
- `src/install.ps1` — `Initialize-GmodTools` (tooling provisioning; the version pins live here, once, for every consumer).
- `src/wiki/generate.ps1` — `Invoke-WikiGen` (the whole wiki engine).
- `src/harness/` — `New-AddonHarness` + the MoonSharp GMod-stub prelude.
- `src/docs/conventions.ps1` — `Sync-AddonConventions` (injects `docs/gmod-addon-conventions.md` into a consumer's CLAUDE.md between markers).
- `docs/gmod-addon-conventions.md` — the shared cross-addon CLAUDE.md block, single source of truth for the setup / code-style / tooling / typing-gate guidance every consumer shares.
- Consumers are sibling repos that pin this module by tag; **Doors** is the reference consumer to copy when onboarding a new one.

## Commits drive releases — use Conventional Commits

Work here lands **directly on `main`, no PRs**, so the commit message is the only
release signal. `.github/workflows/auto-tag.yml` cuts the next tag from the
Conventional-Commit types since the last tag — the *type* you write picks the
version. So commit with Claude Code (or otherwise follow this) and get the type right:

| Commit | Bump | Example |
| --- | --- | --- |
| `feat:` / `feat(scope):` subject | **minor** | `feat(wiki): cross-addon type links` |
| `type!:` subject, or a `BREAKING CHANGE:` footer | **major** | `feat!: rename Invoke-WikiGen -Root param` |
| anything else — `fix:`, `chore:`, `docs:`, or unclear | **patch** | `fix: strip dot from anchor` |

Rules the tagger follows:

- **Highest level since the last tag wins** — one `feat:` among several `fix:`es makes the release a minor.
- The type is read from the **subject line**; `BREAKING CHANGE:` is read from the **footer**.
- **When in doubt it's a patch** — a non-conventional or ambiguous message never over-bumps.
- Only pushes touching `src/**` or the module manifest cut a release; docs / CI-only changes don't (a lone `docs:` commit ships nothing).

### While the module is 0.x

A breaking marker (`!` / `BREAKING CHANGE:`) at `v0.x` jumps straight to
**`v1.0.0`** — the tagger does plain semver, it doesn't hold you in 0.x. So don't
reach for `!` / `BREAKING CHANGE` until you actually intend 1.0; a rough-edged
change during 0.x should still be `feat:` / `fix:`. To override the derived
version at any time, hand-tag (`git tag vX.Y.Z && git push origin vX.Y.Z`) — the
tagger reads the latest tag and continues from it.
