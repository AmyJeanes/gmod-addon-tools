# Hook model provider for the wiki generator.
#
# Enumerates the hooks an addon FIRES - its entity hook bus (CallHook /
# CallCommonHook / ...) and native gamemode hooks (hook.Call / hook.Run) - and
# reconstructs each call's signature. Register sites (AddHook) are ignored: we
# document what an addon fires (its extension points), not what it listens to.
# Receiver and argument types are resolved by hovering the call-site expressions
# through glua_ls (src/lsp/lsp-client.ps1), so they match editor hover and improve
# as the source gets typed. Returns a flat list of hook rows; the wiki generator
# renders and type-links them (reusing Render-Type).

function Get-HookRealm([string]$file) {
    $n = [System.IO.Path]::GetFileName($file).ToLower()
    if ($n -eq 'cl_init.lua') { return 'client' }
    if ($n -eq 'init.lua') { return 'server' }
    if ($n -eq 'shared.lua') { return 'shared' }
    if ($n -like 'cl_*') { return 'client' }
    if ($n -like 'sv_*') { return 'server' }
    if ($n -like 'sh_*') { return 'shared' }
    return 'shared'
}

# Split a call's top-level, comma-separated arguments starting at the '(' index.
# Respects nested (), [], {} and string literals. Returns each segment's text and
# its 0-based start offset in the line (best-effort for single-line calls).
function Split-HookCallArgs([string]$line, [int]$open) {
    $segs = [System.Collections.Generic.List[object]]::new()
    $len = $line.Length
    $i = $open + 1
    $depth = 1
    $segStart = $i
    $inStr = $false; $q = ''
    while ($i -lt $len) {
        $ch = $line[$i]
        if ($inStr) {
            if ($ch -eq '\') { $i += 2; continue }
            if ($ch -eq $q) { $inStr = $false }
            $i++; continue
        }
        if ($ch -eq '"' -or $ch -eq "'") { $inStr = $true; $q = $ch; $i++; continue }
        if ($ch -eq '(' -or $ch -eq '[' -or $ch -eq '{') { $depth++; $i++; continue }
        if ($ch -eq ')' -or $ch -eq ']' -or $ch -eq '}') {
            $depth--
            if ($depth -eq 0) { $segs.Add(@{ Text = $line.Substring($segStart, $i - $segStart); StartIdx = $segStart }); return $segs }
            $i++; continue
        }
        if ($ch -eq ',' -and $depth -eq 1) {
            $segs.Add(@{ Text = $line.Substring($segStart, $i - $segStart); StartIdx = $segStart })
            $segStart = $i + 1; $i++; continue
        }
        if ($ch -eq '-' -and ($i + 1 -lt $len) -and $line[$i + 1] -eq '-') { break }
        $i++
    }
    if ($segStart -lt $len) { $segs.Add(@{ Text = $line.Substring($segStart, $len - $segStart); StartIdx = $segStart }) }
    return $segs
}

# Classify one argument segment: a literal (self-evident type) or an identifier
# expression whose type we resolve by hovering its last identifier token.
function Get-HookArgToken([string]$segText, [int]$startIdx0) {
    $trim = $segText.Trim()
    if ($trim -eq '') { return $null }
    if ($trim -match '^(true|false)$') { return @{ Display = $trim; IsLiteral = $true; LitType = 'boolean' } }
    if ($trim -eq 'nil') { return @{ Display = 'nil'; IsLiteral = $true; LitType = 'nil' } }
    if ($trim -match '^-?(0x[0-9a-fA-F]+|\d+\.?\d*|\.\d+)$') { return @{ Display = $trim; IsLiteral = $true; LitType = 'number' } }
    if ($trim -match '^["'']') { return @{ Display = $trim; IsLiteral = $true; LitType = 'string' } }
    if ($trim.StartsWith('{')) { return @{ Display = '{...}'; IsLiteral = $true; LitType = 'table' } }
    if ($trim -eq '...') { return @{ Display = '...'; IsLiteral = $true; LitType = 'vararg' } }
    $mm = [regex]::Matches($segText, '[A-Za-z_][A-Za-z0-9_]*')
    if ($mm.Count -eq 0) { return @{ Display = $trim; IsLiteral = $false; HoverCol = $null } }
    $last = $mm[$mm.Count - 1]
    # A call expression (foo(), self:Get()) - hovering the last identifier resolves the
    # function, not its return type, so leave it unresolved rather than emit a bogus type.
    if ($segText.Substring($last.Index + $last.Length).TrimStart().StartsWith('(')) {
        return @{ Display = $trim; IsLiteral = $false; HoverCol = $null }
    }
    return @{ Display = $trim; IsLiteral = $false; HoverCol = ($startIdx0 + $last.Index + 1) }
}

function Get-HookLastIdentCol([string]$expr, [int]$startIdx0) {
    $mm = [regex]::Matches($expr, '[A-Za-z_][A-Za-z0-9_]*')
    if ($mm.Count -eq 0) { return $null }
    $last = $mm[$mm.Count - 1]
    return ($startIdx0 + $last.Index + 1)
}

function Test-HookTypeResolved([string]$t) {
    if (-not $t) { return $false }
    return ($t.TrimEnd('?')) -notin @('any', 'unknown', 'nil', 'void', '')
}

function Merge-HookRealm($realms) {
    $d = @($realms | Select-Object -Unique)
    if ($d.Count -eq 1) { return $d[0] }
    if ($d -contains 'shared' -or ($d -contains 'client' -and $d -contains 'server')) { return 'shared' }
    return ($d -join '/')
}

function Resolve-GluaLs([string]$repoRoot) {
    $exe = if ($IsWindows -or ($null -eq $IsWindows -and $env:OS -eq 'Windows_NT')) { 'glua_ls.exe' } else { 'glua_ls' }
    return (Join-Path $repoRoot ".tools/bin/$exe")
}

# Scan + resolve + reconcile. Returns an array of hook rows:
#   @{ System='bus'|'gmod'; Name; Realm; FiredOn=@(typeStrings);
#      Args=@(@{Display;Type;IsLiteral}); Sources=@("rel:line") }
function Get-HookModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [switch] $NoLsp
    )

    $RepoRoot = (Resolve-Path $RepoRoot).Path
    $luaRoot = Join-Path $RepoRoot 'lua'
    $busMethods = 'CallHook', 'CallCommonHook', 'CallClientHook', 'CallClientCommonHook', 'CallSharedHook'
    $reBus = ':(?<m>' + ($busMethods -join '|') + ')\('
    $reGm = 'hook\.(?<m>Call|Run)\('
    $reAny = 'CallHook|CallCommonHook|CallClientHook|CallClientCommonHook|CallSharedHook|hook\.(Call|Run)'

    # --- scan ---
    $fires = [System.Collections.Generic.List[object]]::new()
    $files = Get-ChildItem -Path $luaRoot -Recurse -Filter *.lua -File |
        Where-Object { $_.FullName -notmatch '[\\/]gmod_wire_expression2[\\/]' }

    foreach ($f in $files) {
        $realm = Get-HookRealm $f.FullName
        $rel = $f.FullName.Substring($RepoRoot.Length + 1) -replace '\\', '/'
        $lines = [System.IO.File]::ReadAllLines($f.FullName)
        for ($li = 0; $li -lt $lines.Count; $li++) {
            $line = $lines[$li]
            if ($line -notmatch $reAny) { continue }

            foreach ($sys in @('bus', 'gmod')) {
                $re = if ($sys -eq 'bus') { $reBus } else { $reGm }
                foreach ($mt in [regex]::Matches($line, $re)) {
                    $open = $mt.Index + $mt.Length - 1
                    $segs = @(Split-HookCallArgs $line $open)
                    if ($segs.Count -lt 1) { continue }
                    $name = $segs[0].Text.Trim()
                    if ($name -notmatch '^(["''])([\w\-]+)\1$') { continue }  # dynamic name -> skip
                    $hookName = $Matches[2]

                    $recvExpr = $null; $recvCol = $null
                    if ($sys -eq 'bus') {
                        $before = $line.Substring(0, $mt.Index).TrimEnd()
                        $rm = [regex]::Match($before, '[\w.]+$')
                        if ($rm.Success) {
                            $recvExpr = $rm.Value
                            $recvCol = Get-HookLastIdentCol $recvExpr ($mt.Index - $recvExpr.Length)
                        }
                    }

                    # gamemode hook.Call passes GAMEMODE as the 2nd arg (skip it); hook.Run does not.
                    $skip = if ($sys -eq 'gmod' -and $mt.Groups['m'].Value -eq 'Call') { 2 } else { 1 }
                    $argSegs = if ($segs.Count -gt $skip) { $segs[$skip..($segs.Count - 1)] } else { @() }

                    $args = @()
                    foreach ($s in $argSegs) {
                        $tok = Get-HookArgToken $s.Text $s.StartIdx
                        if ($null -ne $tok) { $args += $tok }
                    }

                    $fires.Add([pscustomobject]@{
                        System = $sys; Name = $hookName; Method = $mt.Groups['m'].Value
                        Realm = $realm; File = $rel; Line = ($li + 1)
                        RecvCol = $recvCol; RecvType = $null; Args = $args
                    })
                }
            }
        }
    }

    # --- enrich via LSP ---
    $gluaLs = Resolve-GluaLs $RepoRoot
    if (-not $NoLsp -and -not (Test-Path -LiteralPath $gluaLs)) {
        Write-Warning "glua_ls not found at $gluaLs - hook argument types will be omitted (run Initialize-GmodTools)."
        $NoLsp = $true
    }

    if (-not $NoLsp) {
        $srv = Start-LspServer $gluaLs $RepoRoot
        try {
            foreach ($rel in ($fires | Select-Object -ExpandProperty File -Unique)) {
                Open-LspDocument $srv (Join-Path $RepoRoot $rel)
            }
            # Wait for workspace indexing: poll a canary receiver until it resolves.
            $canary = $fires | Where-Object { $_.RecvCol } | Select-Object -First 1
            if ($canary) {
                $full = Join-Path $RepoRoot $canary.File
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                while ($sw.Elapsed.TotalSeconds -lt 60) {
                    if (Test-HookTypeResolved (Get-LspHoverType $srv $full $canary.Line $canary.RecvCol 1)) { break }
                    Start-Sleep -Milliseconds 500
                }
            }
            foreach ($fire in $fires) {
                $full = Join-Path $RepoRoot $fire.File
                if ($fire.RecvCol) { $fire.RecvType = Get-LspHoverType $srv $full $fire.Line $fire.RecvCol 3 }
                foreach ($a in $fire.Args) {
                    if ($a.IsLiteral) { $a.Type = $a.LitType; continue }
                    $a.Type = if ($a.HoverCol) { Get-LspHoverType $srv $full $fire.Line $a.HoverCol 3 } else { '' }
                }
            }
        } finally { Stop-LspServer $srv }
    } else {
        foreach ($fire in $fires) { foreach ($a in $fire.Args) { $a.Type = if ($a.IsLiteral) { $a.LitType } else { '' } } }
    }

    # --- reconcile ---
    $hooks = foreach ($g in ($fires | Group-Object System, Name)) {
        $sites = $g.Group
        # Pick the canonical fire site: most type-resolved args, then most args, then most
        # real-identifier args (so callers get named params over arg1/arg2), then a stable
        # File/Line tie-break. Without the last two, ties are broken by file-scan order, which
        # differs Windows vs Linux - so local and CI would pick different sites and churn.
        $best = $sites | Sort-Object `
            @{ Expression = { ($_.Args | Where-Object { Test-HookTypeResolved $_.Type }).Count }; Descending = $true }, `
            @{ Expression = { $_.Args.Count }; Descending = $true }, `
            @{ Expression = { ($_.Args | Where-Object { $_.Display -match '^[A-Za-z_]\w*$' -and $_.Display -notin @('nil', 'true', 'false') }).Count }; Descending = $true }, `
            @{ Expression = { $_.File } }, `
            @{ Expression = { $_.Line } } | Select-Object -First 1
        $recvTypes = @($sites | Where-Object { Test-HookTypeResolved $_.RecvType } | Select-Object -ExpandProperty RecvType -Unique)
        if ($recvTypes.Count -gt 1 -and $recvTypes -contains 'Entity') { $recvTypes = @($recvTypes | Where-Object { $_ -ne 'Entity' }) }
        [pscustomobject]@{
            System     = $sites[0].System
            Name       = $sites[0].Name
            Realm      = Merge-HookRealm ($sites.Realm)
            FiredOn    = $recvTypes
            # A *Common* call (CallCommonHook / CallClientCommonHook) cascades across
            # the exterior and interior, so it runs on both regardless of the receiver.
            IsCommon   = [bool]@($sites | Where-Object { $_.Method -match 'Common' }).Count
            Args       = $best.Args
            SourceFile = $best.File
            SourceLine = $best.Line
        }
    }
    return @($hooks)
}
