#!/usr/bin/env pwsh
# Initialize-GmodTools: provisions the pinned GMod tooling into a consumer repo's
# .tools/ and syncs custom-hook type overloads into the glua-api stubs. Idempotent -
# re-running is a no-op when the requested versions are already present and the
# hook overloads are current. The versions are pinned here (once, for every consumer).

# Pinned versions ------------------------------------------------------------
# Renovate (renovate.json customManagers) bumps these on upstream releases.
# Releases: https://github.com/Pollux12/gmod-glua-ls/releases
# renovate: datasource=github-releases depName=Pollux12/gmod-glua-ls
$GluaLsVersion  = '1.1.0'
# Annotations: https://github.com/Pollux12/annotations-gmod-glua-ls - published to
# branches, not releases; gluals-annotations-prerelease is the beta channel paired
# with glua_ls 1.1.0's annotation-driven system. Pinned by commit sha of that branch.
# renovate: datasource=git-refs depName=https://github.com/Pollux12/annotations-gmod-glua-ls branch=gluals-annotations-prerelease
$GluaApiVersion = 'ebc359aa5dea781b9bda9fe4948aa9c7681ab78c'
# glua_doc_cli drives the wiki generator + typing gate - it parses the ---@class /
# ---@field annotations into a JSON type model. It is the GLua fork's doc CLI (same
# analyzer core as glua_ls / glua_check), so it resolves types like the IDE, unlike
# upstream emmylua_doc_cli. Pollux ships it as a crate but not a release asset, so we
# build+host it: the "Build glua_doc_cli" workflow publishes a `glua_doc_cli-<ver>`
# release on THIS repo from Pollux's tagged source. Pinned to $GluaLsVersion so it
# resolves identically; a version bump auto-builds the matching release (that workflow).
$GluaDocCliVersion = $GluaLsVersion
# MoonSharp (pure-C# Lua interpreter) drives the headless harness - it runs the
# addon's content-definition Lua under a GMod stub environment to extract runtime
# defaults for the wiki. Shipped as a NuGet package; the netstandard DLL loads
# straight into PowerShell 7's .NET runtime, so it runs identically on Windows
# and the Linux CI runner.
# Releases: https://www.nuget.org/packages/MoonSharp
# renovate: datasource=nuget depName=MoonSharp
$MoonSharpVersion = '2.0.0'

function Initialize-GmodTools {
    <#
    .SYNOPSIS
        Provisions the pinned GMod tooling into a consumer repo's .tools/ and syncs
        custom-hook type overloads into the glua-api stubs.
    .PARAMETER Root
        Consumer repo root; tools land in <Root>/.tools/ (where .luarc.json and the
        glua-lsp plugin both look). Defaults to the current directory.
    .PARAMETER TypeModel
        Also provision glua_doc_cli - the GLua type-model CLI that both the wiki
        generator and the zero-untyped typing gate consume. Implied by -Wiki.
    .PARAMETER Harness
        Also provision MoonSharp - the pure-C# Lua interpreter the headless
        defaults harness runs on. Implied by -Wiki.
    .PARAMETER Wiki
        Convenience for -TypeModel -Harness (everything the wiki generator needs).
        Omit all three for addons that only need glua_check / glua_ls.
    #>
    [CmdletBinding()]
    param(
        [string] $Root = (Get-Location).Path,
        [switch] $Wiki,
        [switch] $TypeModel,
        [switch] $Harness
    )

    $ErrorActionPreference = 'Stop'

    # glua_doc_cli feeds the wiki generator AND the typing gate; MoonSharp feeds
    # only the headless harness. -Wiki wants both; the narrower switches let a
    # non-wiki consumer (the typing gate) pull just the type model.
    $wantTypeModel = $Wiki -or $TypeModel
    $wantHarness   = $Wiki -or $Harness

    # Paths ------------------------------------------------------------------
    $Root         = (Resolve-Path $Root).Path
    $ToolsRoot    = Join-Path $Root '.tools'
    $BinDir       = Join-Path $ToolsRoot 'bin'
    $GluaCheckDir = Join-Path $ToolsRoot "glua-check/$GluaLsVersion"
    $GluaLsDir    = Join-Path $ToolsRoot "glua-ls/$GluaLsVersion"
    $GluaDocCliDir = Join-Path $ToolsRoot "glua-doc-cli/$GluaDocCliVersion"
    $MoonSharpDir = Join-Path $ToolsRoot "moonsharp/$MoonSharpVersion"
    $GluaApiDir   = Join-Path $ToolsRoot 'glua-api'
    $GluaApiMark  = Join-Path $GluaApiDir '.version'

    # Platform detection -----------------------------------------------------
    if ($IsWindows -or ($null -eq $IsWindows -and $env:OS -eq 'Windows_NT')) {
        $Platform = 'win32-x64'
        $ExeExt   = '.exe'
    } elseif ($IsLinux) {
        $Platform = 'linux-x64'
        $ExeExt   = ''
    } else {
        throw 'Unsupported platform: prebuilt glua_check / glua_ls binaries are only published for Windows and Linux x64.'
    }

    function Install-Archive {
        param(
            [Parameter(Mandatory)] [string] $Url,
            [Parameter(Mandatory)] [string] $Dest
        )
        New-Item -ItemType Directory -Force -Path $Dest | Out-Null
        $tmp = New-TemporaryFile
        try {
            Write-Host "  downloading $Url"
            Invoke-WebRequest -Uri $Url -OutFile $tmp.FullName
            if ($Url.EndsWith('.zip')) {
                Expand-Archive -Path $tmp.FullName -DestinationPath $Dest -Force
            } elseif ($Url.EndsWith('.tar.gz')) {
                tar -xzf $tmp.FullName -C $Dest
                if ($LASTEXITCODE -ne 0) { throw "tar failed extracting $Url" }
            } else {
                throw "Unknown archive type for $Url"
            }
        } finally {
            Remove-Item $tmp.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    function Install-Binary {
        param(
            [Parameter(Mandatory)] [string] $Name,        # 'glua_check' | 'glua_ls' | 'glua_doc_cli'
            [Parameter(Mandatory)] [string] $Dest,        # versioned dir
            [Parameter(Mandatory)] [string] $Repo,        # 'owner/repo'
            [Parameter(Mandatory)] [string] $Version
        )
        $exe = Join-Path $Dest "$Name$ExeExt"
        if (Test-Path $exe) { return $exe }

        Write-Host "Installing $Name $Version -> $Dest"
        $assetExt = if ($Platform -eq 'win32-x64') { 'zip' } else { 'tar.gz' }
        $asset    = "$Name-$Platform.$assetExt"
        $url      = "https://github.com/$Repo/releases/download/$Version/$asset"
        Install-Archive -Url $url -Dest $Dest

        if (-not (Test-Path $exe)) { throw "$Name binary missing after extraction: $exe" }
        if ($ExeExt -eq '') { chmod +x $exe }
        return $exe
    }

    # glua_check + glua_ls (always) -----------------------------------------
    $gluaCheckExe = Install-Binary -Name 'glua_check' -Dest $GluaCheckDir -Repo 'Pollux12/gmod-glua-ls' -Version $GluaLsVersion
    $gluaLsExe    = Install-Binary -Name 'glua_ls'    -Dest $GluaLsDir    -Repo 'Pollux12/gmod-glua-ls' -Version $GluaLsVersion

    # glua_doc_cli - the type-model CLI (wiki generator + typing gate). Self-hosted:
    # built from Pollux's source and published as a `glua_doc_cli-<ver>` release here.
    $gluaDocExe = $null
    if ($wantTypeModel) {
        $gluaDocExe = Install-Binary -Name 'glua_doc_cli' -Dest $GluaDocCliDir -Repo 'AmyJeanes/gmod-addon-tools' -Version "glua_doc_cli-$GluaDocCliVersion"
    }

    # MoonSharp - the headless harness interpreter. A .nupkg (zip) rather than a
    # per-platform binary, so a dedicated fetch: download, extract, lift out the
    # netstandard1.6 assembly. PowerShell 7's runtime loads netstandard1.6, so the
    # one DLL serves Windows and Linux alike.
    $moonSharpDll = $null
    if ($wantHarness) {
        $moonSharpDll = Join-Path $MoonSharpDir 'MoonSharp.Interpreter.dll'
        if (-not (Test-Path $moonSharpDll)) {
            Write-Host "Installing MoonSharp $MoonSharpVersion -> $MoonSharpDir"
            New-Item -ItemType Directory -Force -Path $MoonSharpDir | Out-Null
            $tmp     = New-TemporaryFile
            $extract = Join-Path ([System.IO.Path]::GetTempPath()) ("moonsharp-" + [guid]::NewGuid().ToString('N'))
            try {
                $url = "https://api.nuget.org/v3-flatcontainer/moonsharp/$MoonSharpVersion/moonsharp.$MoonSharpVersion.nupkg"
                Write-Host "  downloading $url"
                Invoke-WebRequest -Uri $url -OutFile $tmp.FullName
                Expand-Archive -Path $tmp.FullName -DestinationPath $extract -Force
                Copy-Item (Join-Path $extract 'lib/netstandard1.6/MoonSharp.Interpreter.dll') $moonSharpDll -Force
            } finally {
                Remove-Item $tmp.FullName -Force -ErrorAction SilentlyContinue
                Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (-not (Test-Path $moonSharpDll)) { throw "MoonSharp DLL missing after extraction: $moonSharpDll" }
        }
    }

    # glua-api annotations (always) ------------------------------------------
    # .luarc.json points at .tools/glua-api directly, so the working dir IS the
    # install target. A .version marker tracks which commit is currently
    # extracted; mismatch triggers a clean re-extract. The GitHub branch archive
    # nests everything under <repo>-<sha>/, so extract to a temp dir and lift
    # the annotation files into place.
    $currentMark = if (Test-Path $GluaApiMark) { (Get-Content $GluaApiMark -Raw).Trim() } else { '' }
    if ($currentMark -ne $GluaApiVersion) {
        Write-Host "Installing glua-api annotations $GluaApiVersion -> $GluaApiDir"
        if (Test-Path $GluaApiDir) { Remove-Item $GluaApiDir -Recurse -Force }
        $extract = Join-Path ([System.IO.Path]::GetTempPath()) ("glua-api-" + [guid]::NewGuid().ToString('N'))
        try {
            # .zip (not .tar.gz): Expand-Archive is drive-letter-safe everywhere,
            # while a PATH'd GNU tar can misread C:\ paths as remote hosts.
            $url = "https://github.com/Pollux12/annotations-gmod-glua-ls/archive/$GluaApiVersion.zip"
            Install-Archive -Url $url -Dest $extract
            $inner = Get-ChildItem $extract -Directory | Select-Object -First 1
            if (-not $inner) { throw "glua-api archive extracted empty: $url" }
            New-Item -ItemType Directory -Force -Path $GluaApiDir | Out-Null
            Copy-Item (Join-Path $inner.FullName '*') $GluaApiDir -Recurse -Force
        } finally {
            Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
        }
        Set-Content -Path $GluaApiMark -Value $GluaApiVersion
    }

    # Splice custom-hook overloads (this repo's + sibling addons', from committed
    # types/*_hook_overloads.lua fragments) into the freshly-provisioned hook.lua, so
    # hook.Add("<custom>", ...) callbacks type their params. Runs every install (a
    # sibling fragment may have changed even when glua-api itself was already current).
    Sync-GmodHookTypes -Root $Root

    # Mirror binaries to .tools/bin/ - scripts/glua-check.ps1 invokes glua_check
    # from here, and the glua-lsp Claude Code plugin's shim resolves glua_ls
    # from each project's .tools/bin/ at LSP launch. Versioned dirs stay around
    # so switching versions is just a path change, not a re-download.
    #
    # A .version marker keeps idempotent re-runs as no-ops - important because
    # Windows holds the glua_ls.exe file lock while the LSP server is running,
    # so an unconditional Copy-Item over the live binary fails.
    #
    # On a genuine version bump: Windows allows *renaming* a running .exe
    # (just not overwriting one). We capture any process using the old path
    # first, rename the live binary aside, copy the new one into place, then
    # kill the captured processes - LSP hosts treat the kill as a crash and
    # respawn against the new binary at the unchanged path.
    $BinMark      = Join-Path $BinDir '.version'
    $gluaCheckBin = Join-Path $BinDir "glua_check$ExeExt"
    $gluaLsBin    = Join-Path $BinDir "glua_ls$ExeExt"
    $currentMark  = if (Test-Path $BinMark) { (Get-Content $BinMark -Raw).Trim() } else { '' }

    # Sweep any .old left over from a prior update - Windows may not release
    # the file handle by the time our Wait-Process returns, so we retry on
    # every invocation (including idempotent no-ops) until the lock is gone.
    foreach ($target in @($gluaCheckBin, $gluaLsBin)) {
        $old = "$target.old"
        if (Test-Path $old) { Remove-Item $old -Force -ErrorAction SilentlyContinue }
    }

    if ($currentMark -ne $GluaLsVersion -or -not (Test-Path $gluaCheckBin) -or -not (Test-Path $gluaLsBin)) {
        New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

        $toKill = @()
        foreach ($target in @($gluaCheckBin, $gluaLsBin)) {
            if (-not (Test-Path $target)) { continue }
            $procName = [System.IO.Path]::GetFileNameWithoutExtension($target)
            $toKill  += @(Get-Process -Name $procName -ErrorAction SilentlyContinue |
                          Where-Object { $_.Path -eq $target })

            $old = "$target.old"
            if (Test-Path $old) { Remove-Item $old -Force -ErrorAction SilentlyContinue }
            Move-Item $target $old -Force
        }

        Copy-Item $gluaCheckExe $gluaCheckBin -Force
        Copy-Item $gluaLsExe    $gluaLsBin    -Force

        foreach ($h in $toKill) {
            Write-Host "  stopping $($h.ProcessName) (PID $($h.Id)) so the LSP host respawns it against the new binary"
            Stop-Process -Id $h.Id -Force -ErrorAction SilentlyContinue
            $h | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue
        }
        foreach ($target in @($gluaCheckBin, $gluaLsBin)) {
            $old = "$target.old"
            if (Test-Path $old) { Remove-Item $old -Force -ErrorAction SilentlyContinue }
        }

        Set-Content -Path $BinMark -Value $GluaLsVersion
    }

    if ($wantTypeModel) {
        # glua_doc_cli mirror - a one-shot CLI (not held open like the LSP server),
        # so a plain copy is safe; its own marker tracks the independent version.
        $gluaDocBin  = Join-Path $BinDir "glua_doc_cli$ExeExt"
        $gluaDocMark = Join-Path $BinDir '.gluadoc-version'
        $curDocMark  = if (Test-Path $gluaDocMark) { (Get-Content $gluaDocMark -Raw).Trim() } else { '' }
        if ($curDocMark -ne $GluaDocCliVersion -or -not (Test-Path $gluaDocBin)) {
            New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
            Copy-Item $gluaDocExe $gluaDocBin -Force
            Set-Content -Path $gluaDocMark -Value $GluaDocCliVersion
        }
    }

    if ($wantHarness) {
        # MoonSharp mirror - the harness loads it from a stable, version-agnostic path.
        $moonSharpBin  = Join-Path $BinDir 'MoonSharp.Interpreter.dll'
        $moonSharpMark = Join-Path $BinDir '.moonsharp-version'
        $curMsMark     = if (Test-Path $moonSharpMark) { (Get-Content $moonSharpMark -Raw).Trim() } else { '' }
        if ($curMsMark -ne $MoonSharpVersion -or -not (Test-Path $moonSharpBin)) {
            New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
            Copy-Item $moonSharpDll $moonSharpBin -Force
            Set-Content -Path $moonSharpMark -Value $MoonSharpVersion
        }
    }

    Write-Host ''
    Write-Host 'Tools ready:'
    Write-Host "  glua_check      $GluaLsVersion  -> $gluaCheckExe"
    Write-Host "  glua_ls         $GluaLsVersion  -> $gluaLsExe"
    if ($gluaDocExe) {
        Write-Host "  glua_doc_cli    $GluaDocCliVersion  -> $gluaDocExe"
    }
    if ($moonSharpDll) {
        Write-Host "  MoonSharp       $MoonSharpVersion       -> $moonSharpDll"
    }
    Write-Host "  glua-api        $GluaApiVersion -> $GluaApiDir"
}
