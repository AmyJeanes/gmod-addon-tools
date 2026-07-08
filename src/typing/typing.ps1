# Typing enforcement.
#
# glua_check catches WRONG types (0/0 gate) but never a MISSING one - an untyped
# param is a silent `any` that sails through. This flags that gap so new code
# skipping ---@param fails the build, without false-flagging code that already
# types via inference or gets its types from the API it plugs into.
#
# What is flagged: the params of the function DEFINITIONS an author owns at
# statement level - `local function f`, `function Name`, `function A:B`, `function
# A.B`, and a statement-level `name = function`. Their params are typed by the
# author, so an untyped one is a real gap.
#
# What is NOT flagged: an anonymous closure, or a closure that is a table field /
# call argument. Its parameter types come from the RECEIVER - the `fun(...)` type of
# the field it fills or the param it is passed to - not from a local ---@param.
# (A control's `ext_func`, a hook.Add callback, a Derma field, a net.Receive - all
# receiver-typed.) The enforcement for those is that the receiver is typed, which is
# itself a named definition the census covers; demanding a per-callback ---@param
# would be noise. A param is typed when it carries a real ---@param type, an explicit
# `---@param x any` (accepted like a vararg), or the analyzer resolves it to a
# concrete type (the method-inheritance rescue). A param literally named `_` is
# skipped outright as a discard, like a vararg.

$script:TypingLuaKeywords = @('nil', 'true', 'false', 'function', 'end', 'local', 'if', 'then',
    'else', 'elseif', 'for', 'in', 'do', 'while', 'repeat', 'until', 'return', 'break', 'and', 'or', 'not', 'goto', 'self')

# Wire Expression2 is a separate DSL (E2, not Lua), universally excluded from
# analysis (emmylua --exclude, the wiki scans, glua_check); it is the one principled
# hardcode. Everything else vendored is opted out per-file with `---@vendored`.
$script:TypingHardExcludeDirs = @('gmod_wire_expression2')

function Resolve-TypingDocCli([string]$RepoRoot) {
    $exe = if ($IsWindows -or ($null -eq $IsWindows -and $env:OS -eq 'Windows_NT')) { 'glua_doc_cli.exe' } else { 'glua_doc_cli' }
    $path = Join-Path $RepoRoot ".tools/bin/$exe"
    if (Test-Path $path) { return $path }
    return $null
}

# A concrete type is anything the analyzer resolved to a real name - NOT the empty /
# any / unknown placeholders an un-annotated param falls back to. `any` deliberately
# does NOT count: an explicit `---@param x any` is accepted on the source side (the
# annotation is present), so a JSON `any` only ever means "un-annotated, inferred to
# nothing" and must stay flagged.
function Test-ConcreteType([string]$typ) {
    if ([string]::IsNullOrWhiteSpace($typ)) { return $false }
    $b = $typ.TrimEnd('?').Trim()
    return $b -notin @('any', 'unknown', 'nil', 'null', 'void', '')
}

# "relpath:line" -> per-fn model @{ Params; Returns; Api; Name } for every fn the
# analyzer resolves (class methods, namespace/global fns). loc.line is the `function`
# keyword line, the same line the source scanner keys on, so the two reconcile by
# (file, line). Params drive the untyped-param rescue; Returns/Api drive the
# unknown-return gate.
function Get-EmmyFnModel([string]$RepoRoot, [string]$LuaRoot) {
    $model = @{}
    $docCli = Resolve-TypingDocCli $RepoRoot
    if (-not $docCli) { Write-Warning "glua_doc_cli not found - method inference rescue disabled (source scan only)."; return $model }

    # Load the repo's .luarc.json (glua-api + sibling libraries) - we scan lua/, which
    # has no config of its own, so an inherited param typed via a GMod global resolves.
    $cfgArgs = @()
    $luarc = Join-Path $RepoRoot '.luarc.json'
    if (Test-Path $luarc) { $cfgArgs = @('-c', $luarc) }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("gmod-typing-" + [guid]::NewGuid().ToString('N') + ".json")
    try {
        & $docCli $LuaRoot @cfgArgs -f json -o $tmp --exclude '**/gmod_wire_expression2/**' | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tmp)) { return $model }
        $doc = (Get-Content -LiteralPath $tmp -Raw -Encoding utf8) | ConvertFrom-Json
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }

    $rootFwd = ($RepoRoot -replace '\\', '/').TrimEnd('/')
    foreach ($t in $doc.types) {
        if ($t.type -ne 'class') { continue }
        foreach ($m in $t.members) {
            if ($m.type -ne 'fn' -or -not $m.loc -or -not $m.loc.file) { continue }
            $abs = ($m.loc.file -replace '\\', '/')
            if (-not $abs.StartsWith($rootFwd, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $rel = $abs.Substring($rootFwd.Length).TrimStart('/')
            $params = @{}
            foreach ($p in @($m.params)) { $params[$p.name] = [string]$p.typ }
            $returns = @()
            foreach ($r in @($m.returns)) { $rt = if ($r -is [string]) { $r } elseif ($r.typ) { $r.typ } else { '' }; if ($rt) { $returns += $rt } }
            $sep = if ($m.is_meth) { ':' } else { '.' }
            $model["${rel}:$($m.loc.line)"] = @{
                Params  = $params
                Returns = $returns
                Api     = (@($m.tag_content | Where-Object { $_.tag_name -eq 'api' }).Count -gt 0)
                Name    = "$($t.name)$sep$($m.name)"
            }
        }
    }
    return $model
}

# .lua files that a `.luarc.json` ignore entry excludes from analysis, so the scanner
# skips them too (single source of truth for exclusions, no path list in the scanner).
function Get-IgnoredLuaFiles([string]$RepoRoot, [string]$LuaRoot) {
    $ignored = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $luarc = Join-Path $RepoRoot '.luarc.json'
    if (-not (Test-Path $luarc)) { return , $ignored }
    $cfg = Get-Content -LiteralPath $luarc -Raw | ConvertFrom-Json
    $globs = @()
    foreach ($key in @('ignoreGlobs', 'Lua.workspace.ignoreDir')) {
        if ($cfg.PSObject.Properties[$key]) { $globs += @($cfg.$key) }
    }
    if ($cfg.workspace -and $cfg.workspace.ignoreDir) { $globs += @($cfg.workspace.ignoreDir) }
    $globs = @($globs | Where-Object { $_ -and ($_ -match '\.lua|\*\*|/$|^[^.]+$') })
    if (-not $globs.Count) { return , $ignored }
    $rootFwd = ($RepoRoot -replace '\\', '/').TrimEnd('/')
    foreach ($f in (Get-ChildItem $LuaRoot -Recurse -Filter '*.lua' -File)) {
        $rel = (($f.FullName -replace '\\', '/')).Substring($rootFwd.Length).TrimStart('/')
        foreach ($g in $globs) {
            $rx = '^' + [regex]::Escape(($g -replace '\\', '/')).Replace('\*\*', '.*').Replace('\*', '[^/]*') + '($|/)'
            if ($rel -match $rx) { [void]$ignored.Add($rel); break }
        }
    }
    return , $ignored
}

# Per-line @{ Depth; InLong }: the brace+paren nesting depth at the START of each line,
# and whether that line starts INSIDE a long bracket (a `[[ ]]` string or `--[[ ]]`
# block comment). A statement-level function definition sits at depth 0; a closure that
# is a table field or call argument sits at depth > 0 (opened by an enclosing `{`/`(`),
# which is how we tell "a definition the author owns" from "a receiver-typed callback".
# A line that starts inside a long bracket is comment/string text, not code, so def
# detection skips it. Lua comments and strings are lexed so their braces never skew the
# count.
function Get-LineStartDepths([string[]]$lines) {
    $depths = New-Object 'int[]' $lines.Count
    $inLong = New-Object 'bool[]' $lines.Count
    $depth = 0
    $longLevel = -1   # -1 = not inside a long bracket; >=0 = inside, with that many '='
    for ($li = 0; $li -lt $lines.Count; $li++) {
        $depths[$li] = $depth
        $inLong[$li] = ($longLevel -ge 0)
        $line = $lines[$li]
        $i = 0; $n = $line.Length
        while ($i -lt $n) {
            if ($longLevel -ge 0) {
                $close = ']' + ('=' * $longLevel) + ']'
                $idx = $line.IndexOf($close, $i)
                if ($idx -lt 0) { break }              # rest of line still inside the long bracket
                $i = $idx + $close.Length; $longLevel = -1
                continue
            }
            $ch = $line[$i]
            if ($ch -eq '-' -and $i + 1 -lt $n -and $line[$i + 1] -eq '-') {
                $lb = [regex]::Match($line.Substring($i), '^--\[(=*)\[')
                if ($lb.Success) { $longLevel = $lb.Groups[1].Value.Length; $i += $lb.Length; continue }
                break                                  # line comment to EOL
            }
            if ($ch -eq '"' -or $ch -eq "'") {
                $i++
                while ($i -lt $n) { if ($line[$i] -eq '\') { $i += 2 } elseif ($line[$i] -eq $ch) { $i++; break } else { $i++ } }
                continue
            }
            if ($ch -eq '[') {
                $lb = [regex]::Match($line.Substring($i), '^\[(=*)\[')
                if ($lb.Success) { $longLevel = $lb.Groups[1].Value.Length; $i += $lb.Length; continue }
            }
            if ($ch -eq '(' -or $ch -eq '{') { $depth++ }
            elseif ($ch -eq ')' -or $ch -eq '}') { if ($depth -gt 0) { $depth-- } }
            $i++
        }
    }
    return @{ Depth = $depths; InLong = $inLong }
}

# Everything the source scan needs, resolved once per repo.
function Get-TypingContext([string]$RepoRoot) {
    $RepoRoot = (Resolve-Path $RepoRoot).Path
    $LuaRoot = Join-Path $RepoRoot 'lua'
    return @{
        RepoRoot  = $RepoRoot
        LuaRoot   = $LuaRoot
        EmmyModel = Get-EmmyFnModel $RepoRoot $LuaRoot
        Ignored   = Get-IgnoredLuaFiles $RepoRoot $LuaRoot
    }
}

# The full parenthesised param list starting at line $i, col $col (the `(`); may span
# lines. Returns the inner text and the line it closed on.
function Get-ParamListText([string[]]$lines, [int]$i, [int]$col) {
    $depth = 0; $text = ''; $j = $i; $started = $false
    while ($j -lt $lines.Count) {
        $seg = if ($j -eq $i) { $lines[$j].Substring($col) } else { $lines[$j] }
        foreach ($ch in $seg.ToCharArray()) {
            if ($ch -eq '(') { $depth++; $started = $true; if ($depth -eq 1) { continue } }
            elseif ($ch -eq ')') { $depth--; if ($depth -eq 0) { return @{ Text = $text; End = $j } } }
            if ($started -and $depth -ge 1) { $text += $ch }
        }
        $j++
    }
    return @{ Text = $text; End = $j }
}

function Split-Params([string]$text) {
    $out = @()
    foreach ($part in $text.Split(',')) {
        $p = $part.Trim()
        if (-not $p) { continue }
        if ($p.StartsWith('...')) { $out += '...'; continue }
        $m = [regex]::Match($p, '^([A-Za-z_]\w*)')
        if ($m.Success) { $out += $m.Groups[1].Value }
    }
    return $out
}

# The names carrying a REAL ---@param type in the contiguous comment block directly
# above $fnLine, plus whether a `---@type fun(` types the whole closure. A bare
# `---@param x` with no type token does NOT count (the hardening) - only `---@param x
# <type>` (which includes the accepted `---@param x any`).
function Get-AnnotationsAbove([string[]]$lines, [int]$fnLine) {
    $typed = [System.Collections.Generic.HashSet[string]]::new()
    $hasFun = $false
    $k = $fnLine - 1
    while ($k -ge 0) {
        $s = $lines[$k].Trim()
        if ($s -eq '') { break }
        if (-not $s.StartsWith('--')) { break }
        # `---@param name? type` (EmmyLua optional-param syntax) - the `?` sits between
        # the name and the type, so allow it before requiring a type token.
        $mp = [regex]::Match($s, '^---?@param\s+([A-Za-z_]\w*|\.\.\.)\??\s+\S')
        if ($mp.Success) { [void]$typed.Add($mp.Groups[1].Value) }
        if ([regex]::IsMatch($s, '^---?@type\s+fun\s*\(')) { $hasFun = $true }
        $k--
    }
    return @{ Typed = $typed; HasFun = $hasFun }
}

# Scan one file's owned function definitions and return the untyped-param findings.
function Get-FileUntyped([string]$path, [string]$rel, [hashtable]$ctx) {
    $text = [System.IO.File]::ReadAllText($path)
    if ($text -match '(?m)^\s*---@vendored\b') { return @() }
    $lines = [regex]::Split($text, "`r`n|`n")
    $lineInfo = Get-LineStartDepths $lines
    $depths = $lineInfo.Depth
    $inLong = $lineInfo.InLong

    $reNamed = [regex]'^(?<indent>\s*)(?<local>local\s+)?function\s+(?<name>[\w.:]+)\s*\('
    $reAssign = [regex]'^(?<indent>\s*)(?<local>local\s+)?(?<name>[\w.\[\]"'':]+)\s*=\s*function\s*\('

    $findings = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($inLong[$i]) { continue }   # line starts inside a `[[ ]]` string / `--[[ ]]` block comment
        $line = $lines[$i]
        $name = $null; $kind = $null; $col = -1

        $m = $reNamed.Match($line)
        if ($m.Success) {
            $name = $m.Groups['name'].Value
            $col = $m.Value.Length - 1
            if ($name -match ':') { $kind = 'method' } elseif ($name -match '\.') { $kind = 'namespace' }
            elseif ($m.Groups['local'].Success) { $kind = 'local' } else { $kind = 'global' }
        }
        else {
            # A `name = function` is an owned definition only at statement level; inside a
            # `{` (table field) or `(` (call argument) it is a receiver-typed closure - skip.
            if ($depths[$i] -ne 0) { continue }
            $m2 = $reAssign.Match($line)
            if (-not $m2.Success) { continue }
            $name = $m2.Groups['name'].Value
            $fnIdx = $line.IndexOf('function', $m2.Groups['name'].Index)
            $col = $line.IndexOf('(', $fnIdx)
            if ($col -lt 0) { continue }
            $kind = if ($name -match '[.:]') { 'assign_field' } elseif ($m2.Groups['local'].Success) { 'assign_local' } else { 'assign_global' }
        }

        $pl = Get-ParamListText $lines $i $col
        # `_` is the discard-param convention - like a vararg it holds nothing worth typing.
        $params = @(Split-Params $pl.Text | Where-Object { $_ -ne 'self' -and $_ -ne '...' -and $_ -ne '_' })
        if (-not $params.Count) { continue }

        $ann = Get-AnnotationsAbove $lines $i
        if ($ann.HasFun) { continue }

        $emmy = $ctx.EmmyModel["${rel}:$($i + 1)"]
        $ep = if ($emmy) { $emmy.Params } else { $null }
        $untyped = @()
        foreach ($p in $params) {
            if ($ann.Typed.Contains($p)) { continue }                                        # explicit ---@param <type> (incl. `any`)
            if ($ep -and $ep.ContainsKey($p) -and (Test-ConcreteType $ep[$p])) { continue }   # inheritance/inference rescue
            $untyped += $p
        }
        if ($untyped.Count) {
            $findings += [pscustomobject]@{ File = $rel; Line = $i + 1; Kind = $kind; Name = $name; Params = $params; Untyped = $untyped }
        }
    }
    return $findings
}

# All untyped-param findings across the repo's lua tree.
function Get-GmodUntypedParams([string]$RepoRoot, [hashtable]$Context) {
    $ctx = if ($Context) { $Context } else { Get-TypingContext $RepoRoot }
    $rootFwd = ($ctx.RepoRoot -replace '\\', '/').TrimEnd('/')
    $findings = @()
    foreach ($f in (Get-ChildItem $ctx.LuaRoot -Recurse -Filter '*.lua' -File)) {
        $relParts = ($f.FullName -replace '\\', '/').Split('/')
        if ($relParts | Where-Object { $_ -in $script:TypingHardExcludeDirs }) { continue }
        $rel = (($f.FullName -replace '\\', '/')).Substring($rootFwd.Length).TrimStart('/')
        if ($ctx.Ignored.Contains($rel)) { continue }
        $findings += @(Get-FileUntyped $f.FullName $rel $ctx)
    }
    return $findings
}

# Annotation-rot: a ---@param whose name is not (or no longer) a parameter. Ported
# from the param-mismatch prototype - STALE (typo/leftover), DUP (declared twice),
# OVER (more ---@param lines than params). Single-line signatures only.
function Get-GmodParamMismatch([string]$RepoRoot, [hashtable]$Context) {
    $ctx = if ($Context) { $Context } else { Get-TypingContext $RepoRoot }
    $rootFwd = ($ctx.RepoRoot -replace '\\', '/').TrimEnd('/')
    $defPatterns = @(
        [regex]'^\s*local\s+function\s+([\w.]+)\s*\((.*?)\)\s*$',
        [regex]'^\s*function\s+([\w.:]+)\s*\((.*?)\)\s*$',
        [regex]'^\s*local\s+([\w]+)\s*=\s*function\s*\((.*?)\)\s*$',
        [regex]'^\s*([\w.\[\]"'']+)\s*=\s*function\s*\((.*?)\)\s*$'
    )
    $paramRe = [regex]'^\s*---@param\s+([\w.]+|\.\.\.)'
    $findings = @()
    foreach ($f in (Get-ChildItem $ctx.LuaRoot -Recurse -Filter '*.lua' -File)) {
        $relParts = ($f.FullName -replace '\\', '/').Split('/')
        if ($relParts | Where-Object { $_ -in $script:TypingHardExcludeDirs }) { continue }
        $rel = (($f.FullName -replace '\\', '/')).Substring($rootFwd.Length).TrimStart('/')
        if ($ctx.Ignored.Contains($rel)) { continue }
        $text = [System.IO.File]::ReadAllText($f.FullName)
        if ($text -match '(?m)^\s*---@vendored\b') { continue }
        $lines = [regex]::Split($text, "`r`n|`n")
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            $m = $null
            foreach ($pat in $defPatterns) { $m = $pat.Match($line); if ($m.Success) { break } }
            if (-not $m.Success) { continue }
            $nm = $m.Groups[1].Value; $ps = $m.Groups[2].Value
            if (($ps.ToCharArray() | Where-Object { $_ -eq '(' }).Count -ne ($ps.ToCharArray() | Where-Object { $_ -eq ')' }).Count) { continue }
            $isColon = $nm -match ':'
            $params = @($ps.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
            $anns = @(); $j = $i - 1
            while ($j -ge 0) {
                $l = $lines[$j]
                if ($l.Trim() -eq '') { break }
                if ($l -notmatch '^\s*--') { break }
                $pm = $paramRe.Match($l)
                if ($pm.Success) { $anns += $pm.Groups[1].Value }
                $j--
            }
            if (-not $anns.Count) { continue }
            $allowed = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($p in $params) { [void]$allowed.Add($p) }
            if ($isColon) { [void]$allowed.Add('self') }
            $stale = @($anns | Where-Object { -not $allowed.Contains($_) })
            $seen = @{}; $dup = @()
            foreach ($a in $anns) { if ($seen.ContainsKey($a)) { $dup += $a }; $seen[$a] = $true }
            $expected = $params.Count + $(if ($isColon) { 1 } else { 0 })
            $sev = if ($stale.Count) { 'STALE' } elseif ($dup.Count) { 'DUP' } elseif ($anns.Count -gt $expected) { 'OVER' } else { $null }
            if ($sev) { $findings += [pscustomobject]@{ Severity = $sev; File = $rel; Line = $i + 1; Name = $nm; Stale = $stale; Dup = $dup } }
        }
    }
    return $findings
}

# Any modeled function (class method or namespace fn the analyzer resolves in this repo)
# whose return contains `unknown` - a value the analyzer couldn't type at all. A void fn
# resolves to `nil` (not flagged, since glua_doc_cli models "no return" as nil), and any
# ---@return (a concrete type or the deliberate `any` escape) moves the type off `unknown`,
# so the gate is self-escaping. A nested unknown (an inferred table key/field) counts too.
# Vendored / .luarc-ignored files are skipped, matching the param gate. Not @api-scoped:
# glua_doc_cli resolves nearly every return, so an `unknown` anywhere is a real gap.
function Get-GmodUnknownReturns([string]$RepoRoot, [hashtable]$Context) {
    $ctx = if ($Context) { $Context } else { Get-TypingContext $RepoRoot }
    $findings = @()
    foreach ($key in $ctx.EmmyModel.Keys) {
        $fn = $ctx.EmmyModel[$key]
        if (-not @($fn.Returns | Where-Object { $_ -match '\bunknown\b' }).Count) { continue }
        $ci = $key.LastIndexOf(':')
        $file = $key.Substring(0, $ci)
        if ($ctx.Ignored.Contains($file)) { continue }
        $findings += [pscustomobject]@{
            Name = $fn.Name; Return = ($fn.Returns -join ', ')
            File = $file; Line = $key.Substring($ci + 1)
        }
    }
    return $findings
}

# Every non-literal argument a hook is fired with should resolve to a real type. Reuses
# Get-HookModel (glua_ls resolves each fire-site expression - including a call's method
# return type), so the gate and the rendered Hooks-Reference never disagree. A genuine
# `unknown`/nil (not `any`, not a literal) means the passed value's source is untyped -
# type the source, or pass a deliberate `any`. This is the one glua_ls-backed check, so
# it costs a few seconds on the biggest repo; the param/return checks stay glua_doc_cli.
function Get-GmodUnknownHookArgs([string]$RepoRoot) {
    $findings = @()
    foreach ($h in @(Get-HookModel -RepoRoot $RepoRoot)) {
        foreach ($a in @($h.Args)) {
            if ($a.IsLiteral -or -not (Test-HookTypeUnknown $a.Type)) { continue }
            $findings += [pscustomobject]@{ Hook = $h.Name; Arg = $a.Display; File = $h.SourceFile; Line = $h.SourceLine }
        }
    }
    return $findings
}

# The gate. Returns @{ Ok; Untyped; Mismatch; UnknownReturns; UnknownHookArgs } and prints
# a readable report. Ok is false when any untyped param, STALE/DUP/OVER mismatch, unknown
# return, or untyped hook argument remains.
function Test-GmodTyping {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [switch] $Quiet
    )
    $ctx = Get-TypingContext $RepoRoot
    $untyped = @(Get-GmodUntypedParams $ctx.RepoRoot $ctx)
    $mismatch = @(Get-GmodParamMismatch $ctx.RepoRoot $ctx | Where-Object { $_.Severity -in @('STALE', 'DUP', 'OVER') })
    $unknownReturns = @(Get-GmodUnknownReturns $ctx.RepoRoot $ctx)
    if (-not $Quiet) { Write-Host "Checking hook surface (glua_ls)..." -ForegroundColor DarkGray }
    $unknownHookArgs = @(Get-GmodUnknownHookArgs $ctx.RepoRoot)
    $ok = ($untyped.Count -eq 0) -and ($mismatch.Count -eq 0) -and ($unknownReturns.Count -eq 0) -and ($unknownHookArgs.Count -eq 0)

    if (-not $Quiet) {
        Write-Host ""
        if ($mismatch.Count) {
            Write-Host "Annotation mismatches ($($mismatch.Count)):" -ForegroundColor Red
            foreach ($g in ($mismatch | Sort-Object Severity, File, Line)) {
                $extra = if ($g.Stale.Count) { " stale: $($g.Stale -join ', ')" } elseif ($g.Dup.Count) { " dup: $($g.Dup -join ', ')" } else { '' }
                Write-Host ("  {0,-6} {1}:{2}  {3}{4}" -f $g.Severity, $g.File, $g.Line, $g.Name, $extra)
            }
            Write-Host ""
        }
        if ($untyped.Count) {
            $pc = ($untyped | ForEach-Object { $_.Untyped.Count } | Measure-Object -Sum).Sum
            Write-Host "Untyped params ($($untyped.Count) function(s), $pc param(s)):" -ForegroundColor Red
            foreach ($g in ($untyped | Sort-Object File, Line)) {
                Write-Host ("  {0}:{1}  {2}({3})  <- {4}" -f $g.File, $g.Line, $g.Name, ($g.Params -join ', '), ($g.Untyped -join ', '))
            }
            Write-Host ""
            Write-Host "Type each param, or mark a genuinely dynamic one ``---@param x any``; opt a vendored file out with ``---@vendored``." -ForegroundColor Yellow
            Write-Host ""
        }
        if ($unknownReturns.Count) {
            Write-Host "Unknown returns ($($unknownReturns.Count)):" -ForegroundColor Red
            foreach ($g in ($unknownReturns | Sort-Object File, Line)) {
                Write-Host ("  {0}:{1}  {2} -> {3}" -f $g.File, $g.Line, $g.Name, $g.Return)
            }
            Write-Host ""
            Write-Host "Add a ``---@return <type>`` to each (or ``---@return any`` if it is genuinely dynamic)." -ForegroundColor Yellow
            Write-Host ""
        }
        if ($unknownHookArgs.Count) {
            Write-Host "Untyped hook arguments ($($unknownHookArgs.Count)):" -ForegroundColor Red
            foreach ($g in ($unknownHookArgs | Sort-Object File, Line)) {
                Write-Host ("  {0}:{1}  {2}({3})" -f $g.File, $g.Line, $g.Hook, $g.Arg)
            }
            Write-Host ""
            Write-Host "Type the value passed at each fire site (or pass a deliberate ``---@param x any``)." -ForegroundColor Yellow
            Write-Host ""
        }
        if ($ok) { Write-Host "Typing gate: clean (0 untyped, 0 mismatches, 0 unknown returns, 0 untyped hook args)." -ForegroundColor Green }
    }
    return @{ Ok = $ok; Untyped = $untyped; Mismatch = $mismatch; UnknownReturns = $unknownReturns; UnknownHookArgs = $unknownHookArgs }
}
