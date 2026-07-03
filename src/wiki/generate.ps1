# Invoke-WikiGen: renders the API type-reference wiki pages from a consumer's
# ---@class / ---@field annotations. emmylua_doc_cli (the same EmmyLua engine as
# glua_ls) parses the annotations into a JSON type model; this projects that into
# one markdown page per category between the generated-block markers in the wiki
# clone (hand-written intros preserved). Field types render exactly as the
# analyzer resolves them, so they match editor hover. New-AddonHarness /
# ConvertFrom-LuaValue (for the -DefaultsProvider) come from the same module.
function Invoke-WikiGen {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]      $Root,
        [Parameter(Mandatory)] [string]      $WikiPath,
        [Parameter(Mandatory)] [hashtable[]] $Categories,
        [Parameter(Mandatory)] [string[]]    $OwnedPrefix,
        [scriptblock] $DefaultsProvider,
        [hashtable]   $IdentityFields = @{},
        [hashtable]   $ExternalTypeLinks = @{},
        [hashtable[]] $ExternalTypeSources = @(),
        [switch]      $Check
    )

$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path $Root).Path
$LuaRoot  = Join-Path $RepoRoot "lua"

# The ordered category manifest ($Categories) is supplied by the caller: a
# non-root class is owned (inlined) by the first category that reaches it, later
# references link to that page, and each category becomes one wiki page (its
# hand-written intro above the markers is preserved).

# --- Annotation parser (emmylua_doc_cli) -------------------------------------
# The ---@class / ---@field type model is produced by emmylua_doc_cli, so the
# wiki types are exactly what the analyzer resolves (matching editor hover) and
# there is no hand-rolled type parsing here - we just post-process its JSON into
# the small shape the renderer consumes.

function Resolve-DocCli {
    $exe = if ($IsWindows -or ($null -eq $IsWindows -and $env:OS -eq 'Windows_NT')) { 'emmylua_doc_cli.exe' } else { 'emmylua_doc_cli' }
    $path = Join-Path $RepoRoot ".tools/bin/$exe"
    if (-not (Test-Path $path)) {
        throw "emmylua_doc_cli not found at $path - run Install-GmodTools -Wiki first."
    }
    return $path
}

# Parse every annotation via emmylua_doc_cli, returning:
#   Classes : ordered hashtable name -> @{ Name; Parent; Blurb; Fields = @(@{Name;Type;Optional;Desc}) }
function Parse-Annotations([string]$root) {
    $docCli = Resolve-DocCli

    # emmylua_doc_cli requires the JSON output path to end in .json (a .tmp path errors).
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("gmod-addon-wiki-api-" + [guid]::NewGuid().ToString('N') + ".json")
    try {
        & $docCli $root -f json -o $tmp --exclude '**/gmod_wire_expression2/**' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "emmylua_doc_cli failed (exit $LASTEXITCODE)." }
        $doc = (Get-Content -LiteralPath $tmp -Raw -Encoding utf8) | ConvertFrom-Json
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }

    $classes = [ordered]@{}
    foreach ($t in $doc.types) {
        if ($t.type -ne 'class') { continue }
        $name = $t.name
        if ($classes.Contains($name)) { continue }   # emmylua already merges same-name decls

        $parent = if ($t.bases -and $t.bases.Count -gt 0) { $t.bases -join ', ' } else { $null }
        $blurb  = if ($t.description) { ($t.description -replace '\r?\n', ' ').Trim() } else { $null }
        if (-not $blurb) { $blurb = $null }

        $fields = @()
        foreach ($m in $t.members) {
            if ($m.type -ne 'field') { continue }
            $fname = $m.name
            $ftype = if ($m.typ) { $m.typ } else { '' }
            # emmylua encodes optionality as a trailing '?'; index signatures ([k]) are always optional.
            $optional = $ftype.EndsWith('?') -or $fname.StartsWith('[')
            $desc = if ($m.description) { ($m.description -replace '\r?\n', ' ').Trim() } else { '' }
            $fields += @{ Name = $fname; Type = $ftype; Optional = $optional; Desc = $desc }
        }

        $classes[$name] = @{ Name = $name; Parent = $parent; Blurb = $blurb; Fields = $fields }
    }

    return @{ Classes = $classes }
}

# --- Base defaults (from the caller's -DefaultsProvider) ---------------------
# The "Default" column shows the value a content author inherits when they omit a
# field. Those defaults are assigned in Lua at load time (invisible to the static
# analyzer), so the caller's -DefaultsProvider loads the addon headless in-process
# (via New-AddonHarness) and returns a map of className -> default subtree.
# Vector/Angle/Color become {__type='literal'} markers, rendered verbatim.

function Test-JsonObject($v) { return $v -is [System.Management.Automation.PSCustomObject] }
function Test-LiteralDefault($v) { return (Test-JsonObject $v) -and ($null -ne $v.PSObject.Properties['__type']) }
function Test-PlainObject($v) { return (Test-JsonObject $v) -and (-not (Test-LiteralDefault $v)) }
function Test-StrongDefault($v) { return (Test-PlainObject $v) -and (($v.PSObject.Properties | Measure-Object).Count -gt 0) }

# The default subtree for a field's class - only a plain nested object (a struct
# we expand as its own class) qualifies; scalars/literals/arrays don't recurse.
function Get-ChildDefault($parentSub, [string]$field) {
    if ($null -eq $parentSub) { return $null }
    $p = $parentSub.PSObject.Properties[$field]
    if ($p -and (Test-PlainObject $p.Value)) { return $p.Value }
    return $null
}

# A class is shared across pages (tardis_portal in both Interior and Exterior),
# so record the first non-empty subtree it is reached by - an empty {} (e.g. the
# interior's blank Sounds.Teleport) yields to a populated one.
function Set-DefaultsFor([hashtable]$map, [string]$name, $sub) {
    if ($null -eq $sub) { return }
    if (-not $map.ContainsKey($name)) { $map[$name] = $sub; return }
    if ((-not (Test-StrongDefault $map[$name])) -and (Test-StrongDefault $sub)) { $map[$name] = $sub }
}

# $IdentityFields (caller-supplied) lists per-class fields whose base value is not
# a default a child inherits (identity/plumbing) - excluded so they read as
# Required instead.

function Get-FieldDefault([hashtable]$map, [string]$class, [string]$field) {
    $ex = $IdentityFields[$class]
    if ($ex -and ($ex -contains $field)) { return @{ Has = $false } }
    $sub = $map[$class]
    if ($null -eq $sub) { return @{ Has = $false } }
    $p = $sub.PSObject.Properties[$field]
    if (-not $p -or $null -eq $p.Value) { return @{ Has = $false } }
    return @{ Has = $true; Value = $p.Value }
}

# --- Ownership ---------------------------------------------------------------

$parsed  = Parse-Annotations $LuaRoot
$classes = $parsed.Classes

# className -> default subtree, from the caller's provider (loaded headless once).
# No provider -> no captured defaults -> every page stays 3-column.
$defaults = if ($DefaultsProvider) {
    $harness = New-AddonHarness -Realm server -AddonPath $RepoRoot
    $meta    = Get-HarnessMeta $harness
    [pscustomobject](& $DefaultsProvider $harness $meta)
} else {
    [pscustomobject]@{}
}
$defaultsFor = @{}   # className -> default subtree (a parsed-JSON object)

$rootSet = @{}
foreach ($cat in $Categories) { foreach ($r in $cat.Roots) { $rootSet[$r] = $true } }

function Is-Documentable([string]$name) {
    if (-not $classes.Contains($name)) { return $false }
    if ($rootSet.ContainsKey($name)) { return $true }
    foreach ($p in $OwnedPrefix) { if ($name.StartsWith($p)) { return $true } }
    return $false
}

# In-scope class names referenced by a type string.
function Get-TypeTokens([string]$type) {
    return [regex]::Matches($type, '[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*')
}

function Get-Refs([string]$type) {
    $refs = @()
    foreach ($m in (Get-TypeTokens $type)) {
        $n = $m.Value
        if ((Is-Documentable $n) -and ($refs -notcontains $n)) { $refs += $n }
    }
    return $refs
}

$owner    = @{}   # className -> category File
$pageList = @{}   # category File -> ordered class names to render

# Pin every root to its category up front so cross-category refs become links.
foreach ($cat in $Categories) {
    $pageList[$cat.File] = New-Object System.Collections.Generic.List[string]
    foreach ($r in $cat.Roots) {
        if (-not $classes.Contains($r)) { Write-Warning "Root class '$r' not found in source"; continue }
        $owner[$r] = $cat.File
        [void]$pageList[$cat.File].Add($r)
        $rootDefault = $defaults.PSObject.Properties[$r]
        if ($rootDefault) { Set-DefaultsFor $defaultsFor $r $rootDefault.Value }
    }
}

foreach ($cat in $Categories) {
    $page = $cat.File
    $queue = New-Object System.Collections.Generic.Queue[string]
    $seen  = @{}
    foreach ($r in $cat.Roots) { if ($classes.Contains($r)) { $queue.Enqueue($r); $seen[$r] = $true } }

    while ($queue.Count -gt 0) {
        $cname = $queue.Dequeue()
        $parentSub = $defaultsFor[$cname]
        foreach ($f in $classes[$cname].Fields) {
            $childSub = Get-ChildDefault $parentSub $f.Name
            foreach ($ref in (Get-Refs $f.Type)) {
                # Record defaults even for already-owned refs so a class the
                # interior reached empty can be filled from the exterior.
                Set-DefaultsFor $defaultsFor $ref $childSub
                if ($owner.ContainsKey($ref)) { continue }  # owned elsewhere -> will link
                $owner[$ref] = $page
                [void]$pageList[$page].Add($ref)
                if (-not $seen.ContainsKey($ref)) { $queue.Enqueue($ref); $seen[$ref] = $true }
            }
        }
    }
}

# Reverse of the type links: for each class, the rendered classes that reference
# it through a field (a "Used in" backlink). Built in page order for stable
# output; self-references are skipped (the field is already in the class table).
$usedBy = @{}
foreach ($cat in $Categories) {
    foreach ($cname in $pageList[$cat.File]) {
        foreach ($f in $classes[$cname].Fields) {
            foreach ($ref in (Get-Refs $f.Type)) {
                if ($ref -eq $cname -or -not $owner.ContainsKey($ref)) { continue }
                if (-not $usedBy.ContainsKey($ref)) { $usedBy[$ref] = New-Object System.Collections.Generic.List[string] }
                if (-not $usedBy[$ref].Contains($cname)) { [void]$usedBy[$ref].Add($cname) }
            }
        }
    }
}

# A class referenced by 2+ distinct other classes is "shared": if its base default
# differs by usage, its own section drops the Default column and each usage lists
# its own default instead. Counting distinct referencing classes (via usedBy, which
# dedupes) not field sites, so a class reached twice from one parent - e.g. Exterior
# and ExteriorOriginal on tardis_metadata - is not mistaken for shared.
function Test-SharedClass([string]$name) { return $usedBy.ContainsKey($name) -and $usedBy[$name].Count -ge 2 }

# GMod built-in types -> their facepunch wiki URL, harvested from the glua-api
# stubs so the Type cells can link Vector/Color/Entity/LocalLight/... out to the
# GMod reference. Prefers the stub's own [View wiki] link; otherwise derives it
# (structures.lua members live under /gmod/Structures/, the rest at /gmod/<Name>).
function Build-GmodWikiMap {
    # Case-sensitive: type names are case-sensitive, and a default (case-insensitive)
    # hashtable would link identifiers like the param name `ent` to the `ENT` struct.
    $map = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    $stubDir = Join-Path $RepoRoot ".tools/glua-api"
    if (-not (Test-Path $stubDir)) { return $map }
    foreach ($file in Get-ChildItem -LiteralPath $stubDir -Filter *.lua -File) {
        $isStruct = ($file.Name -eq 'structures.lua')
        $lines = [System.IO.File]::ReadAllLines($file.FullName)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $m = [regex]::Match($lines[$i], '^---@class\s+([A-Za-z_][A-Za-z0-9_]*)')
            if (-not $m.Success) { continue }
            $name = $m.Groups[1].Value
            if ($map.ContainsKey($name)) { continue }
            $url = $null
            for ($j = $i - 1; $j -ge 0 -and $lines[$j].StartsWith('---'); $j--) {
                $u = [regex]::Match($lines[$j], '\[View wiki\]\((https://wiki\.facepunch\.com/gmod/[^)]+)\)')
                if ($u.Success) { $url = $u.Groups[1].Value; break }
            }
            if (-not $url) {
                $url = if ($isStruct) { "https://wiki.facepunch.com/gmod/Structures/$name" } else { "https://wiki.facepunch.com/gmod/$name" }
            }
            $map[$name] = $url
        }
    }
    return $map
}
$GmodWiki = Build-GmodWikiMap

# --- Rendering ---------------------------------------------------------------

function Get-Anchor([string]$name) { return ($name.ToLower() -replace '[^a-z0-9_-]', '') }

function Get-GitHubWikiBaseUrl([string]$sourceRoot) {
    $gitConfig = Join-Path $sourceRoot '.git/config'
    if (-not (Test-Path -LiteralPath $gitConfig)) { return $null }
    $content = Get-Content -LiteralPath $gitConfig -Raw
    $m = [regex]::Match($content, 'url\s*=\s*(?:https://github\.com/|git@github\.com:)([^/\s]+/[^/\s]+?)(?:\.git)?\s*(?:\r?\n|$)')
    if (-not $m.Success) { return $null }
    return "https://github.com/$($m.Groups[1].Value)/wiki"
}

function Get-DiscoveredExternalTypeSources {
    $luarcPath = Join-Path $RepoRoot '.luarc.json'
    if (-not (Test-Path -LiteralPath $luarcPath)) { return @() }

    $luarc = Get-Content -LiteralPath $luarcPath -Raw | ConvertFrom-Json
    if (-not $luarc.workspace -or -not $luarc.workspace.library) { return @() }

    $sources = @()
    foreach ($lib in @($luarc.workspace.library)) {
        if (-not ($lib -is [string])) { continue }
        $sourcePath = if ([System.IO.Path]::IsPathRooted($lib)) { $lib } else { Join-Path $RepoRoot $lib }
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) { continue }
        $sourceRoot = (Resolve-Path -LiteralPath $sourcePath).Path
        $configPath = Join-Path $sourceRoot 'scripts/wiki-api.config.ps1'
        if (-not (Test-Path -LiteralPath $configPath)) { continue }

        $config = & $configPath
        if (-not ($config -is [hashtable])) {
            Write-Warning "Ignoring $configPath - expected it to return a hashtable."
            continue
        }
        if (-not $config.ContainsKey('WikiBaseUrl')) {
            $derived = Get-GitHubWikiBaseUrl $sourceRoot
            if ($derived) { $config['WikiBaseUrl'] = $derived }
        }
        if (-not $config.ContainsKey('WikiBaseUrl')) {
            Write-Warning "Ignoring $configPath - no WikiBaseUrl and no GitHub origin to derive one from."
            continue
        }

        $copy = @{}
        foreach ($key in $config.Keys) { $copy[$key] = $config[$key] }
        $copy['Root'] = $sourceRoot
        $sources += $copy
    }
    return $sources
}

function Build-ExternalTypeLinksFromSource([hashtable]$source) {
    foreach ($required in @('Root', 'WikiBaseUrl', 'Categories', 'OwnedPrefix')) {
        if (-not $source.ContainsKey($required)) {
            throw "External type source is missing '$required'."
        }
    }

    $sourceRoot = (Resolve-Path -LiteralPath ([string]$source['Root'])).Path
    $sourceLuaRoot = Join-Path $sourceRoot 'lua'
    if (-not (Test-Path -LiteralPath $sourceLuaRoot -PathType Container)) { return @{} }

    $sourceWikiBase = ([string]$source['WikiBaseUrl']).TrimEnd('/')
    $sourceCategories = @($source['Categories'])
    $sourceOwnedPrefix = @($source['OwnedPrefix'])
    $sourceParsed = Parse-Annotations $sourceLuaRoot
    $sourceClasses = $sourceParsed.Classes

    $sourceRootSet = @{}
    foreach ($cat in $sourceCategories) {
        foreach ($r in $cat.Roots) { $sourceRootSet[$r] = $true }
    }

    $isSourceDocumentable = {
        param([string]$name)
        if (-not $sourceClasses.Contains($name)) { return $false }
        if ($sourceRootSet.ContainsKey($name)) { return $true }
        foreach ($p in $sourceOwnedPrefix) { if ($name.StartsWith($p)) { return $true } }
        return $false
    }

    $sourceOwner = @{}
    $sourcePageList = @{}
    foreach ($cat in $sourceCategories) {
        $sourcePageList[$cat.File] = New-Object System.Collections.Generic.List[string]
        foreach ($r in $cat.Roots) {
            if (-not $sourceClasses.Contains($r)) { Write-Warning "External root class '$r' not found in $sourceRoot"; continue }
            $sourceOwner[$r] = $cat.File
            [void]$sourcePageList[$cat.File].Add($r)
        }
    }

    foreach ($cat in $sourceCategories) {
        $page = $cat.File
        $queue = New-Object System.Collections.Generic.Queue[string]
        $seen  = @{}
        foreach ($r in $cat.Roots) {
            if ($sourceClasses.Contains($r)) {
                $queue.Enqueue($r)
                $seen[$r] = $true
            }
        }

        while ($queue.Count -gt 0) {
            $cname = $queue.Dequeue()
            foreach ($f in $sourceClasses[$cname].Fields) {
                foreach ($m in (Get-TypeTokens $f.Type)) {
                    $ref = $m.Value
                    if (-not (& $isSourceDocumentable $ref)) { continue }
                    if ($sourceOwner.ContainsKey($ref)) { continue }
                    $sourceOwner[$ref] = $page
                    [void]$sourcePageList[$page].Add($ref)
                    if (-not $seen.ContainsKey($ref)) {
                        $queue.Enqueue($ref)
                        $seen[$ref] = $true
                    }
                }
            }
        }
    }

    $links = @{}
    foreach ($name in $sourceOwner.Keys) {
        $links[$name] = "$sourceWikiBase/$($sourceOwner[$name])#$(Get-Anchor $name)"
    }
    return $links
}

$ResolvedExternalTypeLinks = @{}
foreach ($key in $ExternalTypeLinks.Keys) {
    $ResolvedExternalTypeLinks[$key] = $ExternalTypeLinks[$key]
}
foreach ($source in (@($ExternalTypeSources) + @(Get-DiscoveredExternalTypeSources))) {
    foreach ($entry in (Build-ExternalTypeLinksFromSource $source).GetEnumerator()) {
        if (-not $ResolvedExternalTypeLinks.ContainsKey($entry.Key)) {
            $ResolvedExternalTypeLinks[$entry.Key] = $entry.Value
        }
    }
}

# The anchor GitHub derives for a field's "#### `<field>` default" expansion heading
# (backticks dropped, lowercased, spaces to hyphens), used to link the summary cell.
function Get-DefaultAnchor([string]$fieldName) { return $fieldName.ToLower() + '-default' }

function Format-Cell([string]$s) {
    if (-not $s) { return "" }
    return $s.Replace('|', '\|')
}

# Link a documentable class name to its section (same page -> bare anchor).
function Get-ClassLink([string]$name, [string]$label, [string]$thisPage) {
    if ((Is-Documentable $name) -and $owner.ContainsKey($name)) {
        $anchor = Get-Anchor $name
        $target = if ($owner[$name] -eq $thisPage) { "#$anchor" } else { "$($owner[$name])#$anchor" }
        return "[$label]($target)"
    }
    return $label
}

# Link one type token to its wiki section (documented tardis class) or to the GMod
# reference (built-in type), or $null if it is neither (sibling-addon type, etc.).
function Get-TokenLink([string]$name, [string]$thisPage) {
    if ((Is-Documentable $name) -and $owner.ContainsKey($name)) {
        return Get-ClassLink $name "``$name``" $thisPage
    }
    if ($ResolvedExternalTypeLinks.ContainsKey($name)) {
        return "[``$name``]($($ResolvedExternalTypeLinks[$name]))"
    }
    if ($GmodWiki.ContainsKey($name)) {
        return "[``$name``]($($GmodWiki[$name]))"
    }
    return $null
}

# Render the Default cell for a field. Scalars and Vector/Angle/Color literals
# show their value; a field that holds a sub-table shows `{...}` (linked to the
# nested type when documented) and a list shows `[...]`; anything base doesn't
# set shows "-", so every cell is populated.
function Render-DefaultCell($default, $f, [string]$thisPage) {
    if (-not $default.Has) { return "-" }
    $value = $default.Value
    if ($value -is [bool]) { return "``" + ($value.ToString().ToLower()) + "``" }
    if ($value -is [string]) { return "``" + (Format-Cell ('"' + $value + '"')) + "``" }
    if ($value -is [ValueType]) { return "``$value``" }   # numbers
    if (Test-LiteralDefault $value) { return "``" + (Format-Cell $value.text) + "``" }

    # A non-documented table/list is summarised here and expanded below the table;
    # link the `{...}` / `[...]` summary down to that expansion.
    if ($null -ne (Get-ExpandableDefault $default $f)) {
        $label = if ($value -is [Array]) { '`[...]`' } else { '`{...}`' }
        return "[$label](#$(Get-DefaultAnchor $f.Name))"
    }

    if ($value -is [Array]) {
        if ($value.Count -eq 0) { return "``[]``" }
        # A pure-number array (a sequence) is shown inline.
        if ((@($value | Where-Object { $_ -isnot [ValueType] }).Count) -eq 0) {
            return "``[" + ($value -join ', ') + "]``"
        }
        return "``[...]``"
    }
    if (Test-PlainObject $value) {
        if ((@($value.PSObject.Properties).Count) -eq 0) { return "``{}``" }
        # A documented struct links to its own section.
        return Get-ClassLink ($f.Type.TrimEnd('?')) '`{...}`' $thisPage
    }
    return "-"
}

# Pretty-print a captured default as a Lua table literal for the expansion blocks
# under the field table. Scalars and Vector/Angle/Color literals render inline;
# tables recurse with 4-space indent so a `{...}` cell can be shown whole.
function Format-LuaScalar($v) {
    if ($v -is [bool])      { return $v.ToString().ToLower() }
    if ($v -is [string])    { return '"' + ($v -replace '\\', '\\' -replace '"', '\"') + '"' }
    if ($v -is [ValueType]) { return (Format-LuaNum ([double]$v)) }
    if (Test-LiteralDefault $v) { return $v.text }
    return $null
}

function Format-LuaLiteral($v, [int]$depth) {
    $scalar = Format-LuaScalar $v
    if ($null -ne $scalar) { return $scalar }
    $pad  = '    ' * $depth
    $pad1 = '    ' * ($depth + 1)
    if ($v -is [Array]) {
        if ($v.Count -eq 0) { return '{}' }
        $lines = foreach ($item in $v) { $pad1 + (Format-LuaLiteral $item ($depth + 1)) + ',' }
        return "{`n" + ($lines -join "`n") + "`n$pad}"
    }
    if (Test-PlainObject $v) {
        $props = @($v.PSObject.Properties)
        if ($props.Count -eq 0) { return '{}' }
        $lines = foreach ($p in ($props | Sort-Object Name)) {
            $key = if ($p.Name -match '^[A-Za-z_]\w*$') { $p.Name } else { '["' + $p.Name + '"]' }
            $pad1 + $key + ' = ' + (Format-LuaLiteral $p.Value ($depth + 1)) + ','
        }
        return "{`n" + ($lines -join "`n") + "`n$pad}"
    }
    return 'nil'
}

# The value to expand in full below the table, or $null if the Default cell already
# shows it whole. Only non-empty plain tables (not a documented struct, which links
# to its own section) and non-empty non-numeric lists qualify.
function Get-ExpandableDefault($default, $f) {
    if (-not $default.Has) { return $null }
    $v = $default.Value
    if (Test-LiteralDefault $v) { return $null }
    if ($v -is [Array]) {
        if ($v.Count -eq 0) { return $null }
        if ((@($v | Where-Object { $_ -isnot [ValueType] }).Count) -eq 0) { return $null }  # pure number list, shown inline
        return $v
    }
    if (Test-PlainObject $v) {
        if ((@($v.PSObject.Properties).Count) -eq 0) { return $null }
        $ftype = $f.Type.TrimEnd('?')
        if (Is-Documentable $ftype) {
            # A non-shared struct links to its own section (which shows its single
            # usage's defaults); a shared struct's section has no defaults, so this
            # usage's default is shown inline instead.
            if (Test-SharedClass $ftype) { return $v }
            return $null
        }
        return $v
    }
    return $null
}

# Render a type as a (possibly linked) code span. A type that is exactly one
# documentable class links clean (keeping any trailing `?`); a compound type has
# each embedded documentable class token linked and the rest kept as code spans
# (markdown can't put a link inside a single code span, so it is emitted in pieces).
function Render-Type([string]$type, [string]$thisPage) {
    $stripped = $type.TrimEnd('?')
    # Whole type is a single linkable class / GMod type -> one clean whole-cell link.
    if ((Is-Documentable $stripped) -and $owner.ContainsKey($stripped)) {
        return Get-ClassLink $stripped ("``" + (Format-Cell $type) + "``") $thisPage
    }
    if ($ResolvedExternalTypeLinks.ContainsKey($stripped)) {
        return "[``" + (Format-Cell $type) + "``]($($ResolvedExternalTypeLinks[$stripped]))"
    }
    if ($GmodWiki.ContainsKey($stripped)) {
        return "[``" + (Format-Cell $type) + "``]($($GmodWiki[$stripped]))"
    }
    # Compound type: link each embedded tardis-class or GMod token, keeping the rest
    # as code spans (markdown can't put a link inside a single code span).
    $sb  = New-Object System.Text.StringBuilder
    $pos = 0
    foreach ($m in (Get-TypeTokens $type)) {
        $link = Get-TokenLink $m.Value $thisPage
        if (-not $link) { continue }
        if ($m.Index -gt $pos) {
            [void]$sb.Append("``" + (Format-Cell $type.Substring($pos, $m.Index - $pos)) + "``")
        }
        [void]$sb.Append($link)
        $pos = $m.Index + $m.Length
    }
    if ($pos -eq 0) { return "``" + (Format-Cell $type) + "``" }   # nothing linkable
    if ($pos -lt $type.Length) {
        [void]$sb.Append("``" + (Format-Cell $type.Substring($pos)) + "``")
    }
    return $sb.ToString()
}

# The "Extends" note. A documented parent (another wiki class) is linked; an
# external parent (Entity) stays a plain code span.
function Render-Extends([string]$parents, [string]$thisPage) {
    $rendered = foreach ($p in ($parents -split ',\s*')) {
        $link = Get-TokenLink $p $thisPage
        if ($link) { $link } else { "``$p``" }
    }
    return "Extends " + ($rendered -join ', ') + "."
}

# The "Used in" backlink - the classes that reference this one through a field.
function Render-UsedBy([string]$name, [string]$thisPage) {
    if (-not $usedBy.ContainsKey($name)) { return "" }
    $links = foreach ($o in $usedBy[$name]) { Get-ClassLink $o "``$o``" $thisPage }
    return "Used in " + ($links -join ', ') + "."
}

# The first parent that is a documented wiki class (so its fields can be shown
# inline), or $null - external parents like Entity don't qualify.
function Get-DocumentedParent($cls) {
    if (-not $cls.Parent) { return $null }
    foreach ($p in ($cls.Parent -split ',\s*')) {
        if ((Is-Documentable $p) -and $owner.ContainsKey($p)) { return $p }
    }
    return $null
}

$BeginMarker = '<!-- BEGIN GENERATED API REFERENCE -->'
$EndMarker   = '<!-- END GENERATED API REFERENCE -->'
$GenNote     = '<!-- Generated by scripts/generate-wiki-api.ps1 from the source ---@class / ---@field annotations. Do not edit between these markers; re-run the script to update. -->'

# A field is Required only when the type is non-optional AND base provides no
# default to fall back on (so e.g. ExitDistance, which base sets, is not).
function Test-FieldRequired($f, $default) {
    return (-not $f.Optional) -and (-not $default.Has)
}

# A field table. Defaults are looked up under $defaultClass - for inherited
# fields shown on a derived class, that is the derived class (an author sets them
# on its instance), so the default reflects the context they appear in.
function Render-FieldTable([string]$defaultClass, $fields, [string]$thisPage, [bool]$withDefault) {
    if ($fields.Count -eq 0) { return "" }
    $sb = New-Object System.Text.StringBuilder
    if ($withDefault) {
        [void]$sb.AppendLine("| Field | Type | Required | Default | Description |")
        [void]$sb.AppendLine("|-|-|-|-|-|")
    } else {
        [void]$sb.AppendLine("| Field | Type | Required | Description |")
        [void]$sb.AppendLine("|-|-|-|-|")
    }
    foreach ($f in $fields) {
        $default = Get-FieldDefault $defaultsFor $defaultClass $f.Name
        $req = if (Test-FieldRequired $f $default) { "Yes" } else { "No" }
        $typeCell = Render-Type $f.Type $thisPage
        if ($withDefault) {
            $defCell = Render-DefaultCell $default $f $thisPage
            [void]$sb.AppendLine("| ``$($f.Name)`` | $typeCell | $req | $defCell | $(Format-Cell $f.Desc) |")
        } else {
            [void]$sb.AppendLine("| ``$($f.Name)`` | $typeCell | $req | $(Format-Cell $f.Desc) |")
        }
    }
    return $sb.ToString()
}

# True if any of the class's own fields has a captured default under its own
# context - lets a shared class skip the drop-defaults treatment when it has no
# (potentially misleading) default to move to the usage sites anyway.
function Test-ClassHasOwnDefault($cls) {
    foreach ($f in $cls.Fields) {
        if ((Get-FieldDefault $defaultsFor $cls.Name $f.Name).Has) { return $true }
    }
    return $false
}

function Render-Class($cls, [string]$thisPage, [bool]$withDefault) {
    $sb = New-Object System.Text.StringBuilder
    $anchor = Get-Anchor $cls.Name
    if ($anchor -ne $cls.Name.ToLower()) {
        [void]$sb.AppendLine("<a id=`"$anchor`"></a>")
        [void]$sb.AppendLine()
    }
    [void]$sb.AppendLine("## ``$($cls.Name)``")
    [void]$sb.AppendLine()

    # A shared class (reached by 2+ fields) whose base default is non-empty would
    # show one usage's values as if canonical; drop its Default column and let each
    # usage list its own default instead.
    $shared       = $withDefault -and (Test-SharedClass $cls.Name) -and (Test-ClassHasOwnDefault $cls)
    $tableDefault = $withDefault -and (-not $shared)

    $notes = @()
    if ($cls.Blurb)  { $notes += $cls.Blurb }
    if ($cls.Parent) { $notes += (Render-Extends $cls.Parent $thisPage) }
    $usedNote = Render-UsedBy $cls.Name $thisPage
    if ($usedNote) { $notes += $usedNote }
    if ($shared) { $notes += "Used in multiple places with different defaults, so its default values are listed at each usage rather than here." }
    foreach ($n in $notes) { [void]$sb.AppendLine($n); [void]$sb.AppendLine() }

    [void]$sb.Append((Render-FieldTable $cls.Name $cls.Fields $thisPage $tableDefault))

    # Inline each documented ancestor's fields, so the entry is self-contained
    # without following the "Extends" link. Defaults use this class as context.
    $ancestor = Get-DocumentedParent $cls
    while ($ancestor) {
        $acls = $classes[$ancestor]
        $ancLink = Get-ClassLink $ancestor "``$ancestor``" $thisPage
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("Inherited from ${ancLink}:")
        [void]$sb.AppendLine()
        [void]$sb.Append((Render-FieldTable $cls.Name $acls.Fields $thisPage $tableDefault))
        $ancestor = Get-DocumentedParent $acls
    }

    # Below the table(s), expand each non-documented table default (and each shared-
    # struct field's per-usage default) in full - the Default column can only
    # summarise those as `{...}` / `[...]`. Own fields first, then inherited.
    if ($tableDefault) {
        $seen = @{}
        $anc  = $cls
        while ($anc) {
            foreach ($f in $anc.Fields) {
                if ($seen.ContainsKey($f.Name)) { continue }
                $seen[$f.Name] = $true
                $val = Get-ExpandableDefault (Get-FieldDefault $defaultsFor $cls.Name $f.Name) $f
                if ($null -eq $val) { continue }
                [void]$sb.AppendLine()
                [void]$sb.AppendLine("#### ``$($f.Name)`` default")
                [void]$sb.AppendLine()
                [void]$sb.AppendLine('```lua')
                [void]$sb.AppendLine((Format-LuaLiteral $val 0))
                [void]$sb.AppendLine('```')
            }
            $p = Get-DocumentedParent $anc
            $anc = if ($p) { $classes[$p] } else { $null }
        }
    }

    [void]$sb.AppendLine()
    return $sb.ToString()
}

# A page carries a Default column only if at least one field on it has a captured
# default, so pages without any (parts, controls, ...) stay 3-column.
function Test-PageHasDefaults($cat) {
    foreach ($n in $pageList[$cat.File]) {
        foreach ($f in $classes[$n].Fields) {
            if ((Get-FieldDefault $defaultsFor $n $f.Name).Has) { return $true }
        }
    }
    return $false
}

# The generated table block for one category page (classes only - the intro above
# the markers is hand-written and preserved).
function Build-CategoryBlock($cat) {
    $withDefault = Test-PageHasDefaults $cat
    $sb = New-Object System.Text.StringBuilder
    foreach ($n in $pageList[$cat.File]) {
        [void]$sb.Append((Render-Class $classes[$n] $cat.File $withDefault))
    }
    return $sb.ToString().TrimEnd()
}

$liveCats = @($Categories | Where-Object { $pageList[$_.File].Count -gt 0 })

# The API landing page and the sidebar share one flat list of reference pages.
$listSb = New-Object System.Text.StringBuilder
foreach ($cat in $liveCats) { [void]$listSb.AppendLine("- [[$($cat.Title)]]") }
$listBlock = $listSb.ToString().TrimEnd()

# Replace the content between the markers, preserving everything else (the intro,
# and anything below the block). Scaffolds the file with a placeholder intro if it
# does not exist; refuses to touch a file that has no markers.
function Update-MarkedFile([string]$path, [string]$block, [string]$title) {
    # StringBuilder.AppendLine emits the platform newline (CRLF on Windows), so
    # force LF to keep output identical on Windows and Linux.
    $region = ("$BeginMarker`n$GenNote`n`n$block`n$EndMarker") -replace "`r`n", "`n"
    if (Test-Path -LiteralPath $path) {
        # Normalize to LF so a CRLF working copy (git autocrlf) doesn't read as a change.
        $content = (Get-Content -LiteralPath $path -Raw) -replace "`r`n", "`n"
        $start = $content.IndexOf($BeginMarker)
        $end   = $content.IndexOf($EndMarker)
        if ($start -lt 0 -or $end -lt $start) {
            Write-Warning "No markers in $(Split-Path -Leaf $path) - skipped (add the BEGIN/END markers to manage this page)."
            return 'skipped'
        }
        $new = $content.Substring(0, $start) + $region + $content.Substring($end + $EndMarker.Length)
        if ($new -eq $content) { return 'unchanged' }
        if (-not $Check) { Set-Content -LiteralPath $path -Value $new -NoNewline -Encoding utf8 }
        return 'updated'
    }
    $scaffold = "# $title`n`n_Write an intro for this page above the generated block._`n`n$region`n"
    if (-not $Check) { Set-Content -LiteralPath $path -Value $scaffold -NoNewline -Encoding utf8 }
    return 'created'
}

# --- Output ------------------------------------------------------------------

Write-Host "Parsed $($classes.Count) classes; $($liveCats.Count) reference pages."

$targets = @()
foreach ($cat in $liveCats) {
    $targets += @{ Path = (Join-Path $WikiPath "$($cat.File).md"); Block = (Build-CategoryBlock $cat); Title = $cat.Title }
}
$targets += @{ Path = (Join-Path $WikiPath "API.md"); Block = $listBlock; Title = "API" }
$targets += @{ Path = (Join-Path $WikiPath "_Sidebar.md"); Block = $listBlock; Title = "_Sidebar" }

if (-not (Test-Path $WikiPath)) {
    if ($Check) {
        Write-Host "Wiki not found at $WikiPath; parse-only check."
        foreach ($t in $targets) { Write-Host "  would manage $(Split-Path -Leaf $t.Path)" }
        return
    }
    throw "Wiki path not found: $WikiPath (pass -WikiPath to override)"
}

foreach ($t in $targets) {
    $status = Update-MarkedFile $t.Path $t.Block $t.Title
    Write-Host ("  {0,-9} {1}" -f $status, (Split-Path -Leaf $t.Path))
}

}   # end function Invoke-WikiGen
