# Shared cross-addon CLAUDE.md conventions.
#
# Injects docs/gmod-addon-conventions.md (this module's single source of truth for
# the setup / code-style / tooling / typing-gate guidance every consumer repeats)
# into a consumer's CLAUDE.md between HTML-comment markers, so that guidance has one
# home and reaches each addon as a CI-regenerated, Renovate-gated block. The markers
# must already exist in the target CLAUDE.md (placed once when the addon is
# onboarded); the block between them is rewritten wholesale each run, so it is
# idempotent. Host newline style is preserved (CRLF vs LF).

# HTML comments so the markers are invisible in the rendered markdown.
$script:ConventionsBegin = '<!-- >>> GENERATED shared conventions (gmod-addon-tools) - do not edit; regen: scripts/generate-claude-md.ps1 >>> -->'
$script:ConventionsEnd   = '<!-- <<< END GENERATED shared conventions <<< -->'

function Sync-AddonConventions {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Root)
    $Root = (Resolve-Path $Root).Path

    $moduleRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $srcMd = Join-Path $moduleRoot 'docs/gmod-addon-conventions.md'
    if (-not (Test-Path $srcMd)) { throw "Sync-AddonConventions: shared source not found: $srcMd" }

    $claude = Join-Path $Root 'CLAUDE.md'
    if (-not (Test-Path $claude)) { throw "Sync-AddonConventions: no CLAUDE.md in $Root" }

    $shared = ([System.IO.File]::ReadAllText($srcMd) -replace "`r`n", "`n").Trim()

    $orig = [System.IO.File]::ReadAllText($claude)
    $nl = if ($orig -match "`r`n") { "`r`n" } else { "`n" }
    $lines = [System.Collections.Generic.List[string]]([regex]::Split($orig, "`r`n|`n"))

    $b = -1; $e = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq $script:ConventionsBegin) { $b = $i }
        elseif ($lines[$i].Trim() -eq $script:ConventionsEnd) { $e = $i; break }
    }
    if ($b -lt 0 -or $e -lt $b) {
        throw ("Sync-AddonConventions: markers not found in $claude. Add these two lines where the shared block should live:`n  {0}`n  {1}" -f $script:ConventionsBegin, $script:ConventionsEnd)
    }

    $block = @($script:ConventionsBegin, '') + ($shared -split "`n") + @('', $script:ConventionsEnd)
    $lines.RemoveRange($b, $e - $b + 1)
    for ($k = $block.Count - 1; $k -ge 0; $k--) { $lines.Insert($b, $block[$k]) }

    $new = ($lines -join $nl)
    if ($new -ne $orig) {
        [System.IO.File]::WriteAllText($claude, $new)
        Write-Host "Synced shared conventions into $claude." -ForegroundColor Green
        return @($claude)
    }
    Write-Host "Shared conventions unchanged ($claude)." -ForegroundColor Green
    return @()
}
