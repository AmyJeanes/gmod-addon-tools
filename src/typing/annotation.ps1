# Removal test for a type assertion.
#
# `glua_check` alone does not tell you whether an annotation is doing anything.
# Four separate things read our annotations, and three of them are invisible to a
# local check:
#
#   glua_check   - the obvious one, but it exits 0 with hint-level diagnostics, so
#                  the count matters and the exit code does not.
#   typing gate  - reads hook fire-site arguments that glua_check never complains about.
#   hook model   - feeds the generated ---@overload catalogue and the custom global-hook
#                  fragment, both of which only regenerate in CI. Deleting a cast that
#                  fed a CallHook argument has turned a main branch red with no local
#                  signal at all.
#   wiki         - on an addon with a generated reference, a ---@field can decide a
#                  PUBLISHED type. That one has no gate behind it whatsoever: the wiki
#                  workflow regenerates and commits, so a downgrade just ships.
#
# So: snapshot, delete the lines, re-measure all four, restore, report what moved.
# Nothing here writes to the repo except the annotation under test, and the restore
# is in a finally so a crash cannot leave the tree dirty.
#
# The hook model is compared rather than the generated catalogue itself because the
# catalogue's text is platform-dependent and must never be regenerated locally. A
# before/after comparison on one machine is unaffected by that - the platform is the
# same on both sides - and the model covers the global fragment too, which
# Build-HookTypeCatalogue does not.

# 'lua/foo.lua:270' or 'lua/foo.lua:270-273' -> a path plus an inclusive line range.
function ConvertFrom-AnnotationSite([string]$spec, [string]$RepoRoot) {
    $m = [regex]::Match($spec, '^(?<p>.+):(?<a>\d+)(?:-(?<b>\d+))?$')
    if (-not $m.Success) { throw "Site '$spec' is not <path>:<line> or <path>:<start>-<end>." }
    $rel = $m.Groups['p'].Value -replace '\\', '/'
    $abs = if ([System.IO.Path]::IsPathRooted($rel)) { $rel } else { Join-Path $RepoRoot $rel }
    if (-not (Test-Path $abs)) { throw "Site '$spec': no such file '$abs'." }
    $from = [int]$m.Groups['a'].Value
    $to = if ($m.Groups['b'].Success) { [int]$m.Groups['b'].Value } else { $from }
    if ($to -lt $from) { throw "Site '$spec': end line precedes start line." }
    return @{ Spec = $spec; Path = (Resolve-Path $abs).Path; Rel = $rel; From = $from; To = $to }
}

# Diagnostics at EVERY severity. glua_check prints "Check successful" and exits 0 with
# hints present, so neither the exit code nor the summary line can be trusted.
function Measure-GluaCheck([string]$RepoRoot, [string]$Exe) {
    # Pass the GMod annotations the same way the real gate does (Invoke-GluaCheck), else this
    # measures glua_check without the stubs loaded and reports diagnostics the gate never sees.
    $ann = Get-GmodAnnotationsArgs (Join-Path $RepoRoot '.luarc.json')
    $out = & $Exe $RepoRoot @ann 2>&1
    $diag = @($out | Select-String -Pattern '^\s*(hint|warning|error):' | ForEach-Object { $_.Line.Trim() })
    return @{ Count = $diag.Count; Detail = $diag }
}

# Hook names, receivers and resolved argument types - the input both catalogue
# generators consume. Order-normalised so an incidental reordering is not a diff.
function Measure-HookModel([string]$RepoRoot) {
    $model = Get-HookModel -RepoRoot $RepoRoot
    $rows = foreach ($h in $model) {
        '{0}|{1}|{2}|{3}' -f $h.Name, $h.System, (@($h.FiredOn) -join ','),
            ((@($h.Args) | ForEach-Object { "$($_.Display):$($_.Type)" }) -join ',')
    }
    return (@($rows) | Sort-Object) -join "`n"
}

# Render to a scratch path and normalise the #L<n> source anchors out: deleting lines
# shifts every anchor below them, which is not a content change.
function Measure-WikiRender([string]$RepoRoot, [string]$Scratch) {
    $driver = Join-Path $RepoRoot 'scripts/generate-wiki-api.ps1'
    if (-not (Test-Path $driver)) { return $null }
    if (Test-Path $Scratch) { Remove-Item $Scratch -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Scratch | Out-Null
    & pwsh -NoProfile -File $driver -WikiPath $Scratch *>&1 | Out-Null
    $parts = foreach ($f in (Get-ChildItem $Scratch -Filter *.md -File | Sort-Object Name)) {
        $f.Name + "`n" + ((Get-Content $f.FullName) -replace '#L\d+', '#L' -join "`n")
    }
    return ($parts -join "`n----`n")
}

<#
.SYNOPSIS
Removal-test one or more annotations against every consumer that reads them.

.DESCRIPTION
For each site, deletes the given line(s), re-measures glua_check, the typing gate, the
hook model and the generated wiki, then restores the file. Reports which consumers
moved, so "inert" means inert everywhere rather than just clean on the obvious check.

An annotation that moves nothing is a candidate for deletion. One that moves anything
is load-bearing, and the consumer that moved tells you why.

.PARAMETER Site
'<path>:<line>' or '<path>:<start>-<end>', repo-relative. Pass several to amortise the
baseline, which is measured once.

.EXAMPLE
Test-GmodAnnotation -RepoRoot . -Site 'lua/entities/gmod_door_exterior/modules/sh_players.lua:272'
#>
function Test-GmodAnnotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $RepoRoot,
        [Parameter(Mandatory)] [string[]] $Site,
        [switch] $SkipWiki,
        [switch] $SkipHooks,
        [switch] $Quiet
    )

    $RepoRoot = (Resolve-Path $RepoRoot).Path
    $exe = Join-Path $RepoRoot ".tools/bin/glua_check$(if ($IsWindows -or $env:OS -match 'Windows') { '.exe' } else { '' })"
    # Provision on demand like the other entry points, so a cold checkout is not a dead end.
    if (-not (Test-Path $exe)) {
        $installer = Join-Path $RepoRoot 'scripts/install-tools.ps1'
        if (Test-Path $installer) { & pwsh -NoProfile -File $installer *>&1 | Out-Null }
    }
    if (-not (Test-Path $exe)) { throw "glua_check not provisioned at '$exe'. Run scripts/install-tools.ps1 first." }

    $sites = @($Site | ForEach-Object { ConvertFrom-AnnotationSite $_ $RepoRoot })

    # A dirty tree makes every measurement suspect - the caller cannot tell our edit's
    # effect from their own, and a failed restore is unrecoverable.
    Push-Location $RepoRoot
    $dirty = @(git status --porcelain 2>$null | Where-Object { $_ })
    Pop-Location
    if ($dirty.Count) {
        Write-Warning "$RepoRoot has $($dirty.Count) uncommitted change(s). Results include them, and a failed restore cannot be recovered with git. Commit or stash first."
    }

    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("gmod-annotation-" + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))

    if (-not $Quiet) { Write-Host "Baseline..." -ForegroundColor DarkGray }
    $base = @{
        Check  = Measure-GluaCheck $RepoRoot $exe
        Typing = (Test-GmodTyping -RepoRoot $RepoRoot -Quiet)
        Hooks  = if ($SkipHooks) { $null } else { Measure-HookModel $RepoRoot }
        Wiki   = if ($SkipWiki) { $null } else { Measure-WikiRender $RepoRoot (Join-Path $scratch 'base') }
    }
    if (-not $Quiet) {
        Write-Host ("  glua_check {0} diagnostic(s); typing {1}{2}{3}" -f $base.Check.Count,
            $(if ($base.Typing.Ok) { 'clean' } else { 'FAILING' }),
            $(if ($null -eq $base.Wiki) { '; wiki n/a' } else { '; wiki rendered' }),
            $(if ($null -eq $base.Hooks) { '; hooks skipped' } else { '' })) -ForegroundColor DarkGray
    }

    $results = foreach ($s in $sites) {
        $original = [System.IO.File]::ReadAllText($s.Path)
        try {
            $lines = [System.Collections.Generic.List[string]]([regex]::Split($original, "`r`n|`n"))
            if ($s.To -gt $lines.Count) { throw "Site '$($s.Spec)': file has only $($lines.Count) lines." }
            $nl = if ($original -match "`r`n") { "`r`n" } else { "`n" }

            # An inline `--[[@as T]]` shares its line with real code, so deleting the line
            # would test removing the statement, not the annotation. Strip just the token.
            $single = $lines[$s.From - 1]
            $inline = ($s.From -eq $s.To) -and ($single -match '--\[\[@as\b.*?\]\]') -and
                      (($single -replace '--\[\[@as\b.*?\]\]', '').Trim().Length -gt 0)
            if ($inline) {
                $removed = @([regex]::Matches($single, '--\[\[@as\b.*?\]\]') | ForEach-Object { $_.Value })
                $lines[$s.From - 1] = ($single -replace '\s*--\[\[@as\b.*?\]\]', '')
            }
            else {
                $removed = $lines[($s.From - 1)..($s.To - 1)]
                $lines.RemoveRange($s.From - 1, $s.To - $s.From + 1)
            }
            [System.IO.File]::WriteAllText($s.Path, ($lines -join $nl))

            if (-not $Quiet) { Write-Host "Testing $($s.Spec) ..." -ForegroundColor Cyan }

            $check = Measure-GluaCheck $RepoRoot $exe
            $typing = Test-GmodTyping -RepoRoot $RepoRoot -Quiet
            $hooks = if ($SkipHooks) { $null } else { Measure-HookModel $RepoRoot }
            $wiki = if ($SkipWiki) { $null } else { Measure-WikiRender $RepoRoot (Join-Path $scratch 'mod') }

            $moved = [System.Collections.Generic.List[string]]::new()
            $delta = $check.Count - $base.Check.Count
            if ($delta -ne 0) { $moved.Add("glua_check $(if ($delta -gt 0) { '+' })$delta") }
            if ($typing.Ok -ne $base.Typing.Ok) { $moved.Add('typing gate') }
            if ($null -ne $hooks -and $hooks -ne $base.Hooks) { $moved.Add('hook model') }
            if ($null -ne $wiki -and $wiki -ne $base.Wiki) { $moved.Add('wiki') }

            [pscustomobject]@{
                Site         = $s.Spec
                Removed      = ($removed -join ' / ').Trim()
                LoadBearing  = [bool]$moved.Count
                Consumers    = @($moved)
                NewDiagnostics = @($check.Detail | Where-Object { $_ -notin $base.Check.Detail })
            }
        }
        finally {
            [System.IO.File]::WriteAllText($s.Path, $original)
        }
    }

    if (Test-Path $scratch) { Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue }

    if (-not $Quiet) {
        Write-Host ""
        foreach ($r in $results) {
            if ($r.LoadBearing) {
                Write-Host ("LOAD-BEARING  {0}  -> {1}" -f $r.Site, ($r.Consumers -join ', ')) -ForegroundColor Yellow
                foreach ($d in $r.NewDiagnostics) { Write-Host "                  $d" -ForegroundColor DarkYellow }
            }
            else {
                Write-Host ("inert         {0}" -f $r.Site) -ForegroundColor Green
            }
        }
        Write-Host ""
        Write-Host "'inert' means no consumer moved - a candidate for deletion, not a guarantee." -ForegroundColor DarkGray
    }

    return $results
}
