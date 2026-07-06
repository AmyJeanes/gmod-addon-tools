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
