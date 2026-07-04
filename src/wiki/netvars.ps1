# NetworkVar accessor model for the wiki generator.
#
# A scripted entity's networked properties are declared with self:NetworkVar("Type",
# "Name") in SetupDataTables, which generates Get<Name>/Set<Name> accessors at runtime
# (no def site to ---@api-tag). For entities whose public interface is these accessors
# (e.g. world-portals' portal doors), a functions category opts in with NetworkVars=$true
# and this static scan lists them - name, Lua type and the generated accessors, each
# linked to its NetworkVar declaration.
#
# Only the plain forms are matched: NetworkVar("Type", "Name") and the slot form
# NetworkVar("Type", <slot>, "Name"). NetworkVarNotify (a change callback, not an
# accessor) is excluded by the required "(" directly after NetworkVar.

$script:NetVarLuaType = @{
    String = 'string'; Bool = 'boolean'; Float = 'number'; Int = 'number'
    Vector = 'Vector'; Angle = 'Angle'; Entity = 'Entity'
}

function Get-NetworkVarModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $Source
    )

    $srcDir = Join-Path $RepoRoot $Source
    if (-not (Test-Path -LiteralPath $srcDir)) { return @() }
    $rootFwd = ($RepoRoot -replace '\\', '/').TrimEnd('/')

    $rows = [System.Collections.Generic.List[object]]::new()
    $seen = @{}   # a var is declared once - first occurrence wins
    foreach ($file in (Get-ChildItem -LiteralPath $srcDir -Filter *.lua -File -Recurse)) {
        $rel = (($file.FullName -replace '\\', '/')).Substring($rootFwd.Length + 1)
        $lines = [System.IO.File]::ReadAllLines($file.FullName)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $m = [regex]::Match($lines[$i], ':NetworkVar\s*\(\s*"([A-Za-z]+)"\s*,\s*(?:\d+\s*,\s*)?"([A-Za-z0-9_]+)"')
            if (-not $m.Success) { continue }
            $name = $m.Groups[2].Value
            if ($seen.ContainsKey($name)) { continue }
            $seen[$name] = $true
            $raw = $m.Groups[1].Value
            $lua = if ($NetVarLuaType.ContainsKey($raw)) { $NetVarLuaType[$raw] } else { $raw }
            $rows.Add([pscustomobject]@{ Name = $name; RawType = $raw; Type = $lua; SourceFile = $rel; SourceLine = ($i + 1) })
        }
    }
    return $rows.ToArray()
}
