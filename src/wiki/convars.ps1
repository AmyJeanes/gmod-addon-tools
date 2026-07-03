# Convar/concommand model provider for the wiki generator.
#
# Two capture backends, merged as a union - neither is a superset of the other:
#  - Static scan: literal CreateConVar / CreateClientConVar / concommand.Add calls,
#    giving exact source file:line, flag names and help straight from the source -
#    including registrations in entity-module files, which only load on entity
#    spawn and so never run during a headless load.
#  - Execution: New-AddonHarness run twice (server + client). The prelude's recording
#    stubs capture every registration that runs at load - including the dynamic ones
#    static can't see (settings-system convars, factory loops) with their real
#    runtime defaults/help - and the two runs diff to the exact realm (a convar in
#    both is shared, one run only is that realm; a client convar is always client).
#    Skipped for an addon whose headless load fails (falls back to static + file
#    prefix realm).
#
# Merge: exact realm from execution where captured, else the file-prefix realm;
# source line from static where captured; each backend fills the other's gaps.

function Get-CvRealmFromFile([string]$relPath, [string]$fn) {
    if ($fn -eq 'CreateClientConVar') { return 'client' }
    $base = [System.IO.Path]::GetFileName($relPath).ToLower()
    if ($base -eq 'cl_init.lua') { return 'client' }
    if ($base -eq 'init.lua') { return 'server' }
    if ($base -eq 'shared.lua') { return 'shared' }
    if ($base -like 'cl_*') { return 'client' }
    if ($base -like 'sv_*') { return 'server' }
    if ($base -like 'sh_*') { return 'shared' }
    return 'shared'
}

# From the '(' at $open, walk to the matching ')', splitting top-level args on
# commas. String- and comment-aware; handles nested brackets and multi-line calls.
function Get-CvCallArgs([string]$text, [int]$open) {
    $len = $text.Length
    $depth = 0
    $inStr = $false; $strCh = ''
    $args = [System.Collections.Generic.List[string]]::new()
    $cur = [System.Text.StringBuilder]::new()
    for ($i = $open; $i -lt $len; $i++) {
        $c = $text[$i]
        if ($inStr) {
            [void]$cur.Append($c)
            if ($c -eq '\') { if ($i + 1 -lt $len) { $i++; [void]$cur.Append($text[$i]) }; continue }
            if ($c -eq $strCh) { $inStr = $false }
            continue
        }
        if ($c -eq '-' -and $i + 1 -lt $len -and $text[$i + 1] -eq '-') {
            while ($i -lt $len -and $text[$i] -ne "`n") { $i++ }
            continue
        }
        if ($c -eq '"' -or $c -eq "'") { $inStr = $true; $strCh = $c; [void]$cur.Append($c); continue }
        if ($c -eq '(' -or $c -eq '{' -or $c -eq '[') { $depth++; if ($depth -gt 1) { [void]$cur.Append($c) }; continue }
        if ($c -eq ')' -or $c -eq '}' -or $c -eq ']') {
            $depth--
            if ($depth -eq 0) { $args.Add($cur.ToString().Trim()); return $args }
            [void]$cur.Append($c); continue
        }
        if ($c -eq ',' -and $depth -eq 1) { $args.Add($cur.ToString().Trim()); [void]$cur.Clear(); continue }
        [void]$cur.Append($c)
    }
    $args.Add($cur.ToString().Trim())
    return $args
}

function Test-CvStringLiteral([string]$s) { return $s -match '^"([^"]*)"$' -or $s -match "^'([^']*)'$" }
function Get-CvStringValue([string]$s) {
    if ($s -match '^"(.*)"$') { return $Matches[1] }
    if ($s -match "^'(.*)'$") { return $Matches[1] }
    return $s
}

# Static scan: literal-named registrations only. Returns
#   @{ Convars = @{ name -> @{Realm;Default;Flags;Help;Min;Max;IsDebug;File;Line} };
#      Commands = @{ name -> @{Realm;Help;IsDebug;File;Line} };
#      Dynamic  = @(@{Fn;Expr;File;Line}) }   # name not a literal - left to execution
function Get-ConVarStaticScan([string]$repoRoot) {
    $luaRoot = Join-Path $repoRoot 'lua'
    $rx = [regex]'\b(CreateConVar|CreateClientConVar|concommand\.Add)\s*\('
    $convars = @{}; $commands = @{}; $dynamic = [System.Collections.Generic.List[object]]::new()

    $files = Get-ChildItem -LiteralPath $luaRoot -Recurse -Filter *.lua -File |
        Where-Object { $_.FullName -notmatch '[\\/](\.tools|\.luatypes)[\\/]' -and $_.FullName -notmatch 'gmod_wire_expression2' }

    foreach ($file in $files) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        $rel  = $file.FullName.Substring($repoRoot.Length + 1) -replace '\\', '/'
        foreach ($m in $rx.Matches($text)) {
            $fn = $m.Groups[1].Value
            $a = Get-CvCallArgs $text ($m.Index + $m.Length - 1)
            $line = ($text.Substring(0, $m.Index) -split "`n").Count
            if ($a.Count -lt 1 -or -not (Test-CvStringLiteral $a[0])) {
                $dynamic.Add([pscustomobject]@{ Fn = $fn; Expr = ($a | Select-Object -First 1); File = $rel; Line = $line })
                continue
            }
            $name = Get-CvStringValue $a[0]
            $isDebug = ($name -match 'debug') -or ($rel -match 'debug')
            $realm = Get-CvRealmFromFile $rel $fn

            if ($fn -eq 'concommand.Add') {
                $help = if ($a.Count -ge 4 -and (Test-CvStringLiteral $a[3])) { Get-CvStringValue $a[3] } else { '' }
                if (-not $commands.ContainsKey($name)) {
                    $commands[$name] = @{ Realm = $realm; Help = $help; IsDebug = $isDebug; File = $rel; Line = $line }
                }
                continue
            }

            $default = if ($a.Count -ge 2) { Get-CvStringValue $a[1] } else { '' }
            $flags = @(); $min = $null; $max = $null; $help = ''
            if ($fn -eq 'CreateConVar') {
                if ($a.Count -ge 3) { $flags = @([regex]::Matches($a[2], 'FCVAR_\w+') | ForEach-Object { $_.Value }) }
                if ($a.Count -ge 4 -and (Test-CvStringLiteral $a[3])) { $help = Get-CvStringValue $a[3] }
                if ($a.Count -ge 5 -and $a[4] -match '^-?[\d.]+$') { $min = $a[4] }
                if ($a.Count -ge 6 -and $a[5] -match '^-?[\d.]+$') { $max = $a[5] }
            } else {
                if ($a.Count -ge 3 -and $a[2] -eq 'true') { $flags += 'FCVAR_ARCHIVE' }
                if ($a.Count -ge 4 -and $a[3] -eq 'true') { $flags += 'FCVAR_USERINFO' }
                if ($a.Count -ge 5 -and (Test-CvStringLiteral $a[4])) { $help = Get-CvStringValue $a[4] }
                if ($a.Count -ge 6 -and $a[5] -match '^-?[\d.]+$') { $min = $a[5] }
                if ($a.Count -ge 7 -and $a[6] -match '^-?[\d.]+$') { $max = $a[6] }
            }
            if (-not $convars.ContainsKey($name)) {
                $convars[$name] = @{ Realm = $realm; Default = $default; Flags = $flags; Help = $help; Min = $min; Max = $max; IsDebug = $isDebug; File = $rel; Line = $line }
            }
        }
    }
    return @{ Convars = $convars; Commands = $commands; Dynamic = @($dynamic) }
}

# Read the recording-stub registries from one harness run. An empty Lua registry
# ({}) converts to an empty object rather than an array, so filter to real entries
# (those with a name) - a nothing-registered run then yields an empty list, not a
# phantom null-named row.
function Read-HarnessRegistrations($harness) {
    $meta = Get-HarnessMeta $harness
    $cv = ConvertFrom-LuaValue $harness.Globals.Get('__HARNESS').Table.Get('convars') $meta
    $cc = ConvertFrom-LuaValue $harness.Globals.Get('__HARNESS').Table.Get('concommands') $meta
    $hasName = { $_ -is [pscustomobject] -and $_.PSObject.Properties['name'] -and $_.name }
    return @{ Convars = @(@($cv) | Where-Object $hasName); Commands = @(@($cc) | Where-Object $hasName) }
}

# Execution capture: run the harness in both realms and diff to a realm per
# registration. Returns @{ Available; Convars=@{name->@{...}}; Commands=@{name->@{...}} }.
# Available is $false (and the maps empty) if either realm fails to load headless.
function Get-ConVarExecCapture([string]$repoRoot) {
    $runs = @{}
    foreach ($realm in @('server', 'client')) {
        try {
            $h = New-AddonHarness -Realm $realm -AddonPath $repoRoot
            $runs[$realm] = Read-HarnessRegistrations $h
        } catch {
            Write-Warning "Convar execution capture unavailable ($realm realm failed to load): $(($_.ToString() -split "`n")[0]). Falling back to static scan + file-prefix realm."
            return @{ Available = $false; Convars = @{}; Commands = @{} }
        }
    }

    $convars = @{}
    foreach ($realm in @('server', 'client')) {
        foreach ($e in $runs[$realm].Convars) {
            if (-not $convars.ContainsKey($e.name)) {
                $convars[$e.name] = @{ Server = $false; Client = $false; IsClientConvar = [bool]$e.client
                    Default = [string]$e.default; Flags = @($e.flags | Where-Object { $_ -is [string] }); Help = [string]$e.help; Min = $e.min; Max = $e.max }
            }
            $convars[$e.name][$(if ($realm -eq 'server') { 'Server' } else { 'Client' })] = $true
        }
    }
    $commands = @{}
    foreach ($realm in @('server', 'client')) {
        foreach ($e in $runs[$realm].Commands) {
            if (-not $commands.ContainsKey($e.name)) { $commands[$e.name] = @{ Server = $false; Client = $false; Help = [string]$e.help } }
            $commands[$e.name][$(if ($realm -eq 'server') { 'Server' } else { 'Client' })] = $true
        }
    }

    $diffRealm = {
        param($r)
        if ($r.IsClientConvar) { return 'client' }
        if ($r.Server -and $r.Client) { return 'shared' }
        if ($r.Server) { return 'server' }
        return 'client'
    }
    $outC = @{}
    foreach ($n in $convars.Keys) {
        $r = $convars[$n]
        $outC[$n] = @{ Realm = (& $diffRealm $r); Default = $r.Default; Flags = $r.Flags; Help = $r.Help; Min = $r.Min; Max = $r.Max }
    }
    $outCmd = @{}
    foreach ($n in $commands.Keys) {
        $r = $commands[$n]
        $realm = if ($r.Server -and $r.Client) { 'shared' } elseif ($r.Server) { 'server' } else { 'client' }
        $outCmd[$n] = @{ Realm = $realm; Help = $r.Help }
    }
    return @{ Available = $true; Convars = $outC; Commands = $outCmd }
}

# The merged convar/concommand model - a flat list of rows:
#   @{ Kind='convar'|'command'; Name; Realm; Default; Flags=@(); Help; Min; Max;
#      IsDebug; SourceFile; SourceLine }
# SourceFile/Line are $null for an execution-only (dynamic) registration.
function Get-ConVarModel {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)
    $RepoRoot = (Resolve-Path $RepoRoot).Path

    $static = Get-ConVarStaticScan $RepoRoot
    $exec   = Get-ConVarExecCapture $RepoRoot

    $rows = [System.Collections.Generic.List[object]]::new()

    $convarNames = @($static.Convars.Keys) + @($exec.Convars.Keys) | Select-Object -Unique
    foreach ($name in $convarNames) {
        $s = $static.Convars[$name]
        $x = $exec.Convars[$name]
        $realm   = if ($x) { $x.Realm } elseif ($s) { $s.Realm } else { 'shared' }
        $default = if ($x -and $x.Default) { $x.Default } elseif ($s -and $s.Default) { $s.Default } else { '' }
        $flags   = if ($x -and @($x.Flags).Count) { @($x.Flags) } elseif ($s) { @($s.Flags) } else { @() }
        $help    = if ($s -and $s.Help) { $s.Help } elseif ($x -and $x.Help) { $x.Help } else { '' }
        $min     = if ($s -and $null -ne $s.Min) { $s.Min } elseif ($x) { $x.Min } else { $null }
        $max     = if ($s -and $null -ne $s.Max) { $s.Max } elseif ($x) { $x.Max } else { $null }
        $isDebug = ($name -match 'debug') -or ($s -and $s.IsDebug)
        $rows.Add([pscustomobject]@{
            Kind = 'convar'; Name = $name; Realm = $realm; Default = $default; Flags = @($flags)
            Help = $help; Min = $min; Max = $max; IsDebug = [bool]$isDebug
            SourceFile = $(if ($s) { $s.File } else { $null }); SourceLine = $(if ($s) { $s.Line } else { $null })
        })
    }

    $commandNames = @($static.Commands.Keys) + @($exec.Commands.Keys) | Select-Object -Unique
    foreach ($name in $commandNames) {
        $s = $static.Commands[$name]
        $x = $exec.Commands[$name]
        $realm   = if ($x) { $x.Realm } elseif ($s) { $s.Realm } else { 'shared' }
        $help    = if ($s -and $s.Help) { $s.Help } elseif ($x -and $x.Help) { $x.Help } else { '' }
        $isDebug = ($name -match 'debug') -or ($s -and $s.IsDebug)
        $rows.Add([pscustomobject]@{
            Kind = 'command'; Name = $name; Realm = $realm; Default = $null; Flags = @()
            Help = $help; Min = $null; Max = $null; IsDebug = [bool]$isDebug
            SourceFile = $(if ($s) { $s.File } else { $null }); SourceLine = $(if ($s) { $s.Line } else { $null })
        })
    }

    return @($rows)
}
