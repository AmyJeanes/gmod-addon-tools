# Runs glua_check over a consumer repo and reports what it found.
#
# Why this is a module function rather than a few lines in each addon's driver: the drivers
# were byte-identical copies carrying a bug that made five of six repos skip the check
# entirely while exiting 0. Owning it once means fixing it once.
#
# TWO THINGS THIS DELIBERATELY DOES NOT DO:
#
#   It does not trust the exit code. `hint` sits below --warnings-as-errors, so a workspace
#   with hint-level diagnostics still prints "Check successful" and exits 0. Callers that
#   care about a zero-hint standard need the count, so the count is what gets reported.
#
#   It does not silently pass when the binary is absent. That is the failure mode that hid
#   here for months - a check that cannot run should be loud, not green.

# glua_check emits one of these per overlapping workspace.library entry. On a machine where
# sibling addons sit on the library path that is a dozen lines of environmental noise ahead
# of the real output, so it is collapsed to a count unless -Verbose is on. 1.2.0 reworded it
# from "... overlaps definitions" to "... has duplicate definitions that conflict with ..."; match both.
function Test-GluaCheckNoise([string]$line) {
    return $line -match '^\s*(\x1b\[\d+m)?WARN: Library .*(overlaps definitions|has duplicate definitions)'
}

<#
.SYNOPSIS
Run glua_check against a repo and summarise the result.

.DESCRIPTION
Provisioning is the caller's job (scripts/install-tools.ps1). This runs the pinned binary from
the repo's own .tools/bin, prints the diagnostics, and returns the process exit code.

Library-overlap warnings are collapsed to a count; pass -Verbose to see them in full.

.PARAMETER RepoRoot
The addon repo to check.

.PARAMETER Sarif
Optional path to also write a SARIF report to, for CI code-scanning upload.

.OUTPUTS
The glua_check exit code. Diagnostic counts are printed, and returned via -Statistics.

.EXAMPLE
Invoke-GluaCheck -RepoRoot . -Sarif results.sarif
#>
function Invoke-GluaCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [string] $Sarif,
        [switch] $Statistics
    )

    $RepoRoot = (Resolve-Path $RepoRoot).Path
    $exeName  = if ($IsWindows -or ($null -eq $IsWindows -and $env:OS -eq 'Windows_NT')) { 'glua_check.exe' } else { 'glua_check' }
    $exe      = Join-Path $RepoRoot ".tools/bin/$exeName"

    if (-not (Test-Path $exe)) {
        throw "glua_check is not provisioned at '$exe'. Run scripts/install-tools.ps1 first."
    }

    $annotations = Get-GmodAnnotationsArgs (Join-Path $RepoRoot '.luarc.json')

    Push-Location $RepoRoot
    try {
        $output   = & $exe --warnings-as-errors @annotations . 2>&1 | ForEach-Object { $_.ToString() }
        $exitCode = $LASTEXITCODE

        if ($Sarif) {
            & $exe --warnings-as-errors @annotations -f sarif --output $Sarif . 2>$null | Out-Null
        }
    }
    finally {
        Pop-Location
    }

    $noise = @($output | Where-Object { Test-GluaCheckNoise $_ })
    foreach ($line in $output) {
        if ((Test-GluaCheckNoise $line) -and -not $VerbosePreference.Equals('Continue')) { continue }
        Write-Host $line
    }
    if ($noise.Count -and -not $VerbosePreference.Equals('Continue')) {
        Write-Host "($($noise.Count) library-overlap warning(s) hidden - re-run with -Verbose to see them)" -ForegroundColor DarkGray
    }

    # Severity prefixes, counted off the real diagnostic lines only. Deliberately -cmatch:
    # glua_check ends a failing run with its own `Error: "exit code: 1"` summary line, and a
    # case-insensitive match counts that as a second error, inflating the total.
    $counts = [ordered]@{ error = 0; warning = 0; hint = 0 }
    foreach ($line in $output) {
        if (Test-GluaCheckNoise $line) { continue }
        if ($line -cmatch '^\s*(\x1b\[\d+m)?(error|warning|hint):') { $counts[$Matches[2]]++ }
    }
    $total = ($counts.Values | Measure-Object -Sum).Sum

    Write-Host ""
    if ($total -eq 0) {
        Write-Host "glua_check: clean (0 diagnostics), exit $exitCode" -ForegroundColor Green
    }
    else {
        $breakdown = (($counts.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { "$($_.Value) $($_.Key)" }) -join ', ')
        $colour    = if ($counts.error -or $counts.warning) { 'Red' } else { 'Yellow' }
        Write-Host "glua_check: $total diagnostic(s) - $breakdown - exit $exitCode" -ForegroundColor $colour
        if ($exitCode -eq 0) {
            Write-Host "note: exit 0 with diagnostics present - hint severity sits below --warnings-as-errors." -ForegroundColor DarkGray
        }
    }

    if ($Statistics) {
        return [pscustomobject]@{ ExitCode = $exitCode; Total = $total; Errors = $counts.error; Warnings = $counts.warning; Hints = $counts.hint }
    }
    return $exitCode
}
