# Hook type-catalogue generator.
#
# Emits literal-string ---@overload lines for an addon's CallHook-bus hooks (from
# Get-HookModel, which already resolves each hook's receiver + payload types via
# glua_ls) and injects them into each entity's shared.lua directly above
# `function ENT:AddHook`, so a hook callback's payload params type WITHOUT a
# per-callback ---@param. Selection by literal hook-name is what does the work
# (verified against glua_check); a union ---@field does not scale past a few
# entries, so the block must sit on the real AddHook definition. The injected lines
# are self-identifying (`---@overload fun(self: <class>, name: ...`) and rewritten
# wholesale each run, so it is idempotent.

$script:HookLuaKeywords = @('nil', 'true', 'false', 'self', 'end', 'function', 'local', 'if', 'then',
    'else', 'elseif', 'for', 'in', 'do', 'while', 'repeat', 'until', 'return', 'break', 'and', 'or', 'not', 'goto')

# A valid, unique callback param name. Rejects Lua keywords / non-identifiers (literal
# args like `nil`/`false`) and any name already used in this callback (a duplicate param
# name is invalid Lua), falling back to argN.
function ConvertTo-HookParamName([string]$disp, [int]$i, $used) {
    $n = if ($disp -and $disp -match '^[A-Za-z_]\w*$' -and $disp -notin $script:HookLuaKeywords -and -not $used.Contains($disp)) { $disp } else { "arg$($i + 1)" }
    while ($used.Contains($n)) { $n = $n + '_' }
    [void]$used.Add($n)
    return $n
}

# Resolve a hovered arg type to something safe to emit inside an ---@overload. The LSP
# can hand back types that are invalid in this context - an unresolved generic (`T`), a
# `vararg`, or a truncated function type (`(fun(success:))`) - which would make glua_check
# error on the generated line. Anything not demonstrably clean falls back to `any` (the
# callback param stays loose, but the overload is always valid).
function ConvertTo-HookParamType([string]$t) {
    if (-not $t) { return 'any' }
    $b = $t.TrimEnd('?')
    if ($b -in @('any', 'unknown', 'nil', 'void', '')) { return 'any' }
    if ($b -match '^[A-Z]$') { return 'any' }                 # unresolved generic (T / K / V)
    if ($t -match '\bvararg\b') { return 'any' }              # a `...` arg - can't be a named param
    # unbalanced brackets, or a truncated function type with an empty slot -> not safe to emit
    foreach ($pair in @(@('(', ')'), @('[', ']'), @('<', '>'))) {
        if (([regex]::Matches($t, [regex]::Escape($pair[0]))).Count -ne ([regex]::Matches($t, [regex]::Escape($pair[1]))).Count) { return 'any' }
    }
    if ($t -match ':\s*\)' -or $t -match '\(\s*,' -or $t -match ',\s*\)') { return 'any' }
    # collapse the noisy literal-unions the LSP infers from bool-literal call args
    $t = $t -replace '\(boolean\|true\)', 'boolean' -replace '\(false\|true\)', 'boolean' -replace '\(boolean\|false\)', 'boolean'
    # Any remaining inferred literal-union (e.g. ("pop"|integer|string)) is noise for a hook
    # payload AND a frequent source of Windows/Linux glua_ls divergence - collapse to `any` so
    # the generated catalogue is byte-identical across platforms (local == CI).
    if ($t -match '^\([^)]*\|[^)]*\)\??$') { return 'any' }
    return $t
}

function Build-HookTypeCatalogue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [switch] $NoLsp
    )
    $Root = (Resolve-Path $Root).Path

    # Entities that host an AddHook bus: lua/entities/<class>/shared.lua defining ENT:AddHook.
    $entRoot = Join-Path $Root 'lua/entities'
    $busEntities = [ordered]@{}
    if (Test-Path $entRoot) {
        foreach ($dir in (Get-ChildItem $entRoot -Directory | Sort-Object Name)) {
            $sh = Join-Path $dir.FullName 'shared.lua'
            if ((Test-Path $sh) -and ([System.IO.File]::ReadAllText($sh) -match '(?m)^\s*function\s+ENT:AddHook\s*\(')) {
                $busEntities[$dir.Name] = $sh
            }
        }
    }
    if ($busEntities.Count -eq 0) { Write-Warning "No entity with an ENT:AddHook bus under $entRoot - nothing to do."; return @() }
    $commonEntities = @($busEntities.Keys)

    $model = Get-HookModel -RepoRoot $Root -NoLsp:$NoLsp

    $byEntity = @{}
    foreach ($ent in $commonEntities) { $byEntity[$ent] = [System.Collections.Generic.List[object]]::new() }
    foreach ($h in ($model | Where-Object { $_.System -eq 'bus' })) {
        $ft = @($h.FiredOn)
        if ($h.IsCommon) {
            $targets = $commonEntities
        }
        else {
            # A bare 'Entity' receiver means the LSP could not narrow to a door/tardis class;
            # the bus only exists on those entities, so apply the hook to all of them.
            $targets = @($ft | Where-Object { $_ -ne 'Entity' -and $byEntity.ContainsKey($_) })
            if (($ft -contains 'Entity') -or (-not $targets.Count)) { $targets = @($targets + $commonEntities) | Select-Object -Unique }
        }
        foreach ($ent in $targets) {
            if (-not $byEntity.ContainsKey($ent)) { continue }
            $used = [System.Collections.Generic.HashSet[string]]::new()
            [void]$used.Add('self')
            $cbParams = @("self: $ent")
            for ($i = 0; $i -lt @($h.Args).Count; $i++) {
                $a = $h.Args[$i]
                $cbParams += ("{0}: {1}" -f (ConvertTo-HookParamName $a.Display $i $used), (ConvertTo-HookParamType $a.Type))
            }
            # Trailing ... so a callback that takes MORE payload params than the canonical
            # CallHook site captured (a hook fired at varying arity) still matches - the extra
            # params fall to varargs instead of tripping redundant-parameter.
            $cb = "fun(" + (@($cbParams + '...') -join ', ') + ")"
            $byEntity[$ent].Add([pscustomobject]@{
                    Name = $h.Name
                    Line = ('---@overload fun(self: {0}, name: "{1}", id: string, func: {2})' -f $ent, $h.Name, $cb)
                })
        }
    }

    $changed = @()
    $totalOverloads = 0
    foreach ($ent in $busEntities.Keys) {
        $path = $busEntities[$ent]
        $overloads = @($byEntity[$ent] | Sort-Object Name -Unique | Select-Object -ExpandProperty Line)
        $totalOverloads += $overloads.Count

        $orig = [System.IO.File]::ReadAllText($path)
        $nl = if ($orig -match "`r`n") { "`r`n" } else { "`n" }
        $lines = [System.Collections.Generic.List[string]]([regex]::Split($orig, "`r`n|`n"))

        # Drop the previously-generated block (overloads + its markers) for idempotence.
        $genRe = '^\s*---@overload fun\(self:\s*' + [regex]::Escape($ent) + ',\s*name:'
        $markerRe = '^\s*--.*generated hook overloads'
        for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match $genRe -or $lines[$i] -match $markerRe) { $lines.RemoveAt($i) } }

        # Locate the AddHook definition and insert the fresh block directly above it.
        $defIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*function\s+ENT:AddHook\s*\(') { $defIdx = $i; break } }
        if ($defIdx -lt 0) { continue }
        $indent = ([regex]::Match($lines[$defIdx], '^\s*')).Value

        # Bracket the block with markers so it's obvious in-source that it's generated. Plain
        # `--` (not `---`) so the analyzer doesn't fold them into AddHook's doc description.
        $block = @()
        if ($overloads.Count) {
            $block += $indent + '-- >>> GENERATED hook overloads - do not edit; regen: scripts/generate-hook-types.ps1 >>>'
            $block += ($overloads | ForEach-Object { $indent + $_ })
            $block += $indent + '-- <<< END GENERATED hook overloads <<<'
        }
        for ($k = $block.Count - 1; $k -ge 0; $k--) { $lines.Insert($defIdx, $block[$k]) }

        $new = ($lines -join $nl)
        if ($new -ne $orig) {
            [System.IO.File]::WriteAllText($path, $new)
            $changed += $path
        }
    }

    Write-Host ("Hook catalogue: {0} bus hooks -> {1} overloads across {2} entit(y|ies); {3} file(s) updated." -f `
        @($model | Where-Object { $_.System -eq 'bus' }).Count, $totalOverloads, $busEntities.Count, $changed.Count) -ForegroundColor Green
    return $changed
}

# --- Custom GLOBAL hooks (hook.Call / hook.Run) ------------------------------
#
# glua-api's hook.lua types built-in gamemode hooks by carrying ~267 literal-string
# ---@overload lines above `function hook.Add`, so hook.Add("PlayerSpawn", id, fn)
# types fn's params. Custom global hooks (an addon's own hook.Run("wp-foo", ...))
# have no such overload, so their consumer callbacks stay `any`. We close that:
# Build-GlobalHookOverloads emits a committed fragment of overloads for an addon's
# OWN custom hooks, and Sync-GmodHookTypes splices them (plus any sibling addon's)
# directly above glua-api's `function hook.Add`. A committed redeclare in a separate
# file does NOT bind (glua-api's definition wins); only the splice does. A `--`
# comment in the overload chain does not detach the built-ins (both verified against
# glua_check on glua_ls 1.0.27).

# Markers bracketing the spliced block in the provisioned hook.lua. Plain `--` (not
# `---`) so the analyzer treats them as ordinary comments, not doc for hook.Add.
$script:HookSyncBegin = '-- >>> gmod-addon-tools custom-hook overloads (generated; regen: scripts/generate-hook-types.ps1) >>>'
$script:HookSyncEnd   = '-- <<< end gmod-addon-tools custom-hook overloads <<<'

# The hook names glua-api already types - the eventName of every ---@overload in
# hook.lua OUTSIDE our spliced block. Used to drop re-fires of native hooks
# (PlayerUse, CanTool) from an addon's fragment so we only emit its own customs.
function Get-BuiltinHookNames([string]$root) {
    $names = [System.Collections.Generic.HashSet[string]]::new()
    $hookLua = Join-Path $root '.tools/glua-api/hook.lua'
    if (-not (Test-Path $hookLua)) { return $names }
    $inSplice = $false
    foreach ($line in [System.IO.File]::ReadAllLines($hookLua)) {
        $t = $line.Trim()
        if ($t -eq $script:HookSyncBegin) { $inSplice = $true;  continue }
        if ($t -eq $script:HookSyncEnd)   { $inSplice = $false; continue }
        if ($inSplice) { continue }
        $m = [regex]::Match($line, '@overload fun\(eventName:\s*"([^"]+)"')
        if ($m.Success) { [void]$names.Add($m.Groups[1].Value) }
    }
    return $names
}

function Build-GlobalHookOverloads {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        # Fragment basename: types/<Id>_hook_overloads.lua. Names the addon whose customs
        # these are (e.g. 'wp'), so it reads right when discovered from a sibling repo.
        [Parameter(Mandatory)] [string] $Id,
        [switch] $NoLsp
    )
    $Root = (Resolve-Path $Root).Path
    $builtins = Get-BuiltinHookNames $Root

    $model  = Get-HookModel -RepoRoot $Root -NoLsp:$NoLsp
    $custom = @($model | Where-Object { $_.System -eq 'gmod' -and -not $builtins.Contains($_.Name) } | Sort-Object Name)

    $overloads = foreach ($h in $custom) {
        $used = [System.Collections.Generic.HashSet[string]]::new()
        $cbParams = @()
        for ($i = 0; $i -lt @($h.Args).Count; $i++) {
            $a = $h.Args[$i]
            $cbParams += ("{0}: {1}" -f (ConvertTo-HookParamName $a.Display $i $used), (ConvertTo-HookParamType $a.Type))
        }
        # Trailing ... so a consumer callback taking more params than the canonical fire
        # site captured still matches instead of tripping redundant-parameter.
        $cb = "fun(" + (@($cbParams + '...') -join ', ') + ")"
        '---@overload fun(eventName: "{0}", identifier: any, func: {1})' -f $h.Name, $cb
    }

    $typesDir = Join-Path $Root 'types'
    $fragPath = Join-Path $typesDir ("{0}_hook_overloads.lua" -f $Id)

    if (@($overloads).Count -eq 0) {
        if (Test-Path $fragPath) { Remove-Item $fragPath -Force; Write-Host "Global-hook overloads: none - removed $fragPath" -ForegroundColor Yellow; return @($fragPath) }
        Write-Host 'Global-hook overloads: no custom global hooks fired - nothing to emit.' -ForegroundColor Green
        return @()
    }

    # The redeclare is inert (glua-api's hook.Add wins) but required: a dangling
    # ---@overload with no function is an annotation-usage-error. Its params are typed
    # so the zero-untyped gate stays clean; Sync reads only the ---@overload lines.
    $body = @(
        '-- Generated custom global-hook overloads. Do not edit; regen: scripts/generate-hook-types.ps1.',
        '-- Sync-GmodHookTypes (Initialize-GmodTools) splices these into .tools/glua-api/hook.lua so',
        '-- hook.Add("<name>", ...) callbacks type their payload params. Inert on its own - the splice binds.',
        '',
        '---@param eventName string',
        '---@param identifier any',
        '---@param func function'
    ) + @($overloads) + @(
        'function hook.Add(eventName, identifier, func) end',
        ''
    )
    $new = ($body -join "`n")

    New-Item -ItemType Directory -Force -Path $typesDir | Out-Null
    $orig = if (Test-Path $fragPath) { ([System.IO.File]::ReadAllText($fragPath) -replace "`r`n", "`n") } else { '' }
    if ($orig -ne $new) {
        [System.IO.File]::WriteAllText($fragPath, $new)
        Write-Host ("Global-hook overloads: {0} custom hook(s) -> {1}" -f @($overloads).Count, $fragPath) -ForegroundColor Green
        return @($fragPath)
    }
    Write-Host ("Global-hook overloads: {0} custom hook(s) (unchanged)." -f @($overloads).Count) -ForegroundColor Green
    return @()
}

# Splice every custom-hook fragment (this repo's + each sibling addon's, discovered
# via .luarc.json workspace.library) into the provisioned hook.lua above `function
# hook.Add`. Idempotent (drops the prior block first), write-on-change. Called by
# Initialize-GmodTools after glua-api is provisioned; safe no-op if it isn't.
function Sync-GmodHookTypes {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Root)
    $Root = (Resolve-Path $Root).Path
    $hookLua = Join-Path $Root '.tools/glua-api/hook.lua'
    if (-not (Test-Path $hookLua)) { return }

    $searchRoots = [System.Collections.Generic.List[string]]::new()
    [void]$searchRoots.Add($Root)
    $luarc = Join-Path $Root '.luarc.json'
    if (Test-Path $luarc) {
        try {
            $cfg = Get-Content $luarc -Raw | ConvertFrom-Json
            foreach ($lib in @($cfg.workspace.library)) {
                if ($lib -notmatch '^\.\.') { continue }   # sibling addon roots only
                $abs = [System.IO.Path]::GetFullPath((Join-Path $Root $lib))
                if (Test-Path $abs) { [void]$searchRoots.Add($abs) }
            }
        } catch { Write-Warning "Sync-GmodHookTypes: could not parse $luarc - $($_.Exception.Message)" }
    }

    # Collect ---@overload lines, dedup by eventName (an addon owns its own names).
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $overloads = [System.Collections.Generic.List[string]]::new()
    foreach ($sr in $searchRoots) {
        $typesDir = Join-Path $sr 'types'
        if (-not (Test-Path $typesDir)) { continue }
        foreach ($frag in (Get-ChildItem $typesDir -Filter '*_hook_overloads.lua' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            foreach ($line in [System.IO.File]::ReadAllLines($frag.FullName)) {
                $m = [regex]::Match($line.Trim(), '^(---@overload fun\(eventName:\s*"([^"]+)".*)$')
                if ($m.Success -and $seen.Add($m.Groups[2].Value)) { $overloads.Add($m.Groups[1].Value) }
            }
        }
    }
    $ordered = @($overloads | Sort-Object)

    $orig = [System.IO.File]::ReadAllText($hookLua)
    $nl   = if ($orig -match "`r`n") { "`r`n" } else { "`n" }
    $lines = [System.Collections.Generic.List[string]]([regex]::Split($orig, "`r`n|`n"))

    # Drop the prior spliced block.
    $b = -1; $e = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq $script:HookSyncBegin) { $b = $i }
        elseif ($lines[$i].Trim() -eq $script:HookSyncEnd) { $e = $i; break }
    }
    if ($b -ge 0 -and $e -ge $b) { $lines.RemoveRange($b, $e - $b + 1) }

    if ($ordered.Count) {
        $defIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*function\s+hook\.Add\s*\(') { $defIdx = $i; break } }
        if ($defIdx -lt 0) { throw "Sync-GmodHookTypes: 'function hook.Add' not found in $hookLua" }
        $block = @($script:HookSyncBegin) + $ordered + @($script:HookSyncEnd)
        for ($k = $block.Count - 1; $k -ge 0; $k--) { $lines.Insert($defIdx, $block[$k]) }
    }

    $new = ($lines -join $nl)
    if ($new -ne $orig) {
        [System.IO.File]::WriteAllText($hookLua, $new)
        Write-Host ("Synced {0} custom-hook overload(s) into hook.lua." -f $ordered.Count) -ForegroundColor Green
    }
}
