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
        [switch]      $Check,
        [switch]      $Strict
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
# $relRoot is the root that source paths are made relative to (the temp mirror when
# scanning an injected tree); $lineOffsets maps a rel path to the number of injected
# header lines to subtract, so a method's source link still points at the real line.
function Parse-Annotations([string]$root, [string]$relRoot, [hashtable]$lineOffsets) {
    if (-not $relRoot) { $relRoot = $RepoRoot }
    if (-not $lineOffsets) { $lineOffsets = @{} }
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
        $functions = @()
        foreach ($m in $t.members) {
            if ($m.type -eq 'field') {
                $fname = $m.name
                $ftype = if ($m.typ) { $m.typ } else { '' }
                # emmylua encodes optionality as a trailing '?'; index signatures ([k]) are always optional.
                $optional = $ftype.EndsWith('?') -or $fname.StartsWith('[')
                $desc = if ($m.description) { ($m.description -replace '\r?\n', ' ').Trim() } else { '' }
                $fields += @{ Name = $fname; Type = $ftype; Optional = $optional; Desc = $desc }
            }
            elseif ($m.type -eq 'fn') {
                # A method member. The public-API surface opts in with a ---@api doc tag,
                # which emmylua surfaces in tag_content. Params/returns/loc come straight
                # from the model (loc gives the exact source line).
                $fdesc = if ($m.description) { ($m.description -replace '\r?\n', ' ').Trim() } else { '' }
                $fparams = @()
                foreach ($p in @($m.params)) { $fparams += @{ Name = $p.name; Type = $(if ($p.typ) { $p.typ } else { '' }) } }
                $freturns = @()
                foreach ($r in @($m.returns)) { $rt = if ($r -is [string]) { $r } elseif ($r.typ) { $r.typ } else { '' }; if ($rt) { $freturns += $rt } }
                $srcRel = $null; $srcLine = $null
                if ($m.loc -and $m.loc.file) {
                    $abs = ($m.loc.file -replace '\\', '/')
                    $rootFwd = ($relRoot -replace '\\', '/').TrimEnd('/')
                    if ($abs.StartsWith($rootFwd, [System.StringComparison]::OrdinalIgnoreCase)) { $srcRel = $abs.Substring($rootFwd.Length).TrimStart('/') }
                    $srcLine = $m.loc.line
                    if ($srcRel -and $srcLine -and $lineOffsets.ContainsKey($srcRel)) { $srcLine = $srcLine - $lineOffsets[$srcRel] }
                }
                $functions += @{
                    Name = $m.name; IsMeth = [bool]$m.is_meth
                    IsApi = @($m.tag_content | Where-Object { $_.tag_name -eq 'api' }).Count -gt 0
                    Params = $fparams; Returns = $freturns; Desc = $fdesc
                    SourceFile = $srcRel; SourceLine = $srcLine
                }
            }
        }

        $classes[$name] = @{ Name = $name; Parent = $parent; Blurb = $blurb; Fields = $fields; Functions = $functions }
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

# --- Entity method typing (pre-scan injection) -------------------------------
# GMod entity/weapon methods are defined as `function ENT:Method` where ENT is an
# untyped shared global, so emmylua can't attach them to the entity's ---@class. A
# functions category with a Source folder opts in: we mirror the lua tree to a temp
# dir and prepend `---@class <Class>` + `local ENT = ENT` to every file in that folder,
# so the folder's methods attach to that class - folder-scoped, so one entity's
# methods never leak onto another (a single global bind does). It all happens in the
# copy emmylua reads; real source is never touched, and no `self`-typing diagnostics
# land on the method bodies. A rel-path -> injected-line-count map keeps source links
# pointing at the real (un-injected) line.
function New-InjectedScanTree($injections) {
    $tempRepo = Join-Path ([System.IO.Path]::GetTempPath()) ("gmod-addon-wiki-inject-" + [guid]::NewGuid().ToString('N'))
    $tempLua  = Join-Path $tempRepo 'lua'
    Copy-Item -LiteralPath $LuaRoot -Destination $tempLua -Recurse -Force
    $lineOffsets = @{}
    foreach ($inj in $injections) {
        $global      = if ($inj.Global) { $inj.Global } else { 'ENT' }
        $header      = "---@class $($inj.Class)`nlocal $global = $global`n"
        $headerLines = @([regex]::Matches($header, "`n")).Count
        $srcDir = Join-Path $tempRepo $inj.Source
        if (-not (Test-Path -LiteralPath $srcDir)) { Write-Warning "Injection source '$($inj.Source)' not found - skipped."; continue }
        foreach ($file in (Get-ChildItem -LiteralPath $srcDir -Filter *.lua -File -Recurse)) {
            [System.IO.File]::WriteAllText($file.FullName, $header + [System.IO.File]::ReadAllText($file.FullName))
            $rel = (($file.FullName.Substring($tempRepo.Length)).TrimStart('\', '/') -replace '\\', '/')
            $lineOffsets[$rel] = $headerLines
        }
    }
    return @{ TempRepo = $tempRepo; ScanLuaRoot = $tempLua; RelRoot = $tempRepo; LineOffsets = $lineOffsets }
}

# --- Ownership ---------------------------------------------------------------

# The clean scan is the field/class model. Entity methods (`function ENT:X`) can't
# attach here because ENT is an untyped shared global - that needs the injected scan
# below. Binding a class to ENT also makes emmylua infer every `ENT.x = ` / `self.x = `
# assignment as a field, so we take only the injected scan's *methods* and keep this
# scan's fields, leaving Roots field pages limited to the real ---@field declarations.
$parsed  = Parse-Annotations $LuaRoot
$classes = $parsed.Classes

$injections = @($Categories | Where-Object { $_.Source -and $_.Class } |
    ForEach-Object { @{ Source = $_.Source; Class = $_.Class; Global = $_.Global } })
if ($injections.Count) {
    $injectTree = New-InjectedScanTree $injections
    try {
        $injected = (Parse-Annotations $injectTree.ScanLuaRoot $injectTree.RelRoot $injectTree.LineOffsets).Classes
        foreach ($inj in $injections) {
            if (-not $injected.Contains($inj.Class)) { continue }
            if ($classes.Contains($inj.Class)) { $classes[$inj.Class].Functions = $injected[$inj.Class].Functions }
            else { $classes[$inj.Class] = $injected[$inj.Class] }
        }
    } finally {
        if (Test-Path -LiteralPath $injectTree.TempRepo) {
            Remove-Item -LiteralPath $injectTree.TempRepo -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

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

# The github blob base (`.../blob/<branch>`) for the repo checked out at $sourceRoot,
# so source locations can be linked. Branch comes from the current HEAD - the wiki
# is regenerated on push to the default branch, so that is the ref being documented.
function Get-GitHubBlobBaseUrl([string]$sourceRoot) {
    $gitConfig = Join-Path $sourceRoot '.git/config'
    $gitHead   = Join-Path $sourceRoot '.git/HEAD'
    if (-not (Test-Path -LiteralPath $gitConfig) -or -not (Test-Path -LiteralPath $gitHead)) { return $null }
    $content = Get-Content -LiteralPath $gitConfig -Raw
    $m = [regex]::Match($content, 'url\s*=\s*(?:https://github\.com/|git@github\.com:)([^/\s]+/[^/\s]+?)(?:\.git)?\s*(?:\r?\n|$)')
    if (-not $m.Success) { return $null }
    $head = (Get-Content -LiteralPath $gitHead -Raw).Trim()
    $branch = if ($head -match 'ref:\s*refs/heads/(.+)$') { $Matches[1].Trim() } else { 'HEAD' }
    return "https://github.com/$($m.Groups[1].Value)/blob/$branch"
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

# --- Hook pages (Kind = 'hooks') ---------------------------------------------
# A hooks category renders the hooks the addon fires (from Get-HookModel) instead
# of class field tables. Receiver and argument types are linked through the same
# Render-Type used for class fields, so an owned entity/struct links to its wiki
# page and a GMod built-in links to the facepunch reference.

# The argument list inside a hook's signature - `name`: type, comma-separated. The
# colon binds a linked type to its argument so it never reads as a separate argument.
# Literals and untyped values show just the value/name; returns '' when there are none.
function Render-HookArgs($hookArgs, [string]$thisPage) {
    $list = @($hookArgs)
    if ($list.Count -eq 0) { return '' }
    $parts = foreach ($a in $list) {
        $disp = '`' + (Format-Cell $a.Display) + '`'
        if ($a.IsLiteral) { $disp }                                                          # value speaks for itself
        elseif (Test-HookTypeResolved $a.Type) { "${disp}: $(Render-Type $a.Type $thisPage)" }
        else { "${disp}: _unknown_" }                                                        # untyped at source - type it later
    }
    return ($parts -join ', ')
}

function Format-Realm([string]$realm) {
    return (($realm -split '/') | ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1) }) -join '/'
}

# The hook name, linked to the source of its fired site when the repo's github
# blob base is known.
function Render-HookName($h) {
    $code = "``$($h.Name)``"
    if ($sourceBlobBase -and $h.SourceFile) { return "[$code]($sourceBlobBase/$($h.SourceFile)#L$($h.SourceLine))" }
    return $code
}

# One hook section. The first column is the hook's call signature (name + args);
# gamemode hooks are game-wide, so their table omits "Fired on".
function Build-HookSection([string]$title, [string]$subtitle, $rows, [string]$thisPage, [bool]$showFiredOn, $commonEntities) {
    $rows = @($rows)
    $commonEntities = @($commonEntities)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("## $title")
    [void]$sb.AppendLine()
    if ($subtitle) { [void]$sb.AppendLine($subtitle); [void]$sb.AppendLine() }
    if ($rows.Count -eq 0) { [void]$sb.AppendLine("_None._"); [void]$sb.AppendLine(); return $sb.ToString() }
    if ($showFiredOn) {
        [void]$sb.AppendLine("| Hook | Realm | Fired on |")
        [void]$sb.AppendLine("|-|-|-|")
    } else {
        [void]$sb.AppendLine("| Hook | Realm |")
        [void]$sb.AppendLine("|-|-|")
    }
    foreach ($h in ($rows | Sort-Object Name)) {
        $sig = "$(Render-HookName $h)($(Render-HookArgs $h.Args $thisPage))"
        $realm = Format-Realm $h.Realm
        if ($showFiredOn) {
            $firedOn =
                if ($h.IsCommon -and $commonEntities.Count) { ($commonEntities | ForEach-Object { Render-Type $_ $thisPage }) -join ' / ' }
                elseif (@($h.FiredOn).Count) { (@($h.FiredOn) | ForEach-Object { Render-Type $_ $thisPage }) -join ' / ' }
                else { '_Unknown (missing type info)_' }
            [void]$sb.AppendLine("| $sig | $realm | $firedOn |")
        } else {
            [void]$sb.AppendLine("| $sig | $realm |")
        }
    }
    [void]$sb.AppendLine()
    return $sb.ToString()
}

function Build-HooksBlock($cat) {
    $bus = @(@($hookModel) | Where-Object { $_.System -eq 'bus' })
    $gm  = @(@($hookModel) | Where-Object { $_.System -eq 'gmod' })
    $sb = New-Object System.Text.StringBuilder
    # Only emit a section that has hooks - a gamemode-only addon shows no Entity section.
    # The bus lives on ENT for most addons but SWEP for weapons - the category can override.
    $entListen = if ($cat.EntityListen) { $cat.EntityListen } else { 'ENT:AddHook(name, id, func)' }
    $commonEntities = @($cat.CommonEntities)
    if ($bus.Count) { [void]$sb.Append((Build-HookSection "Entity hooks" "Listen with ``$entListen``." $bus $cat.File $true $commonEntities)) }
    if ($gm.Count)  { [void]$sb.Append((Build-HookSection "Gamemode hooks" 'Listen with `hook.Add(name, id, func)`.' $gm $cat.File $false @())) }
    return $sb.ToString().TrimEnd()
}

# Hard gate: every fired hook must resolve a receiver (bus hooks) and a type for
# each non-literal argument. A genuinely dynamic value is annotated `---@param x any`
# (which hovers as exactly `any`) and accepted; anything still unresolved (`any?`,
# `unknown`, or nothing) fails generation, so the gap gets typed at the source
# rather than silently shipping an untyped entry.
function Assert-HookTypesResolved($model) {
    $gaps = [System.Collections.Generic.List[object]]::new()
    foreach ($h in @($model)) {
        $loc = "$($h.SourceFile):$($h.SourceLine)"
        if ($h.System -eq 'bus' -and @($h.FiredOn).Count -eq 0) {
            $gaps.Add([pscustomobject]@{ Name = $h.Name; Loc = $loc; Detail = 'receiver type unresolved' })
        }
        foreach ($a in @($h.Args)) {
            if ($a.IsLiteral -or (Test-HookTypeResolved $a.Type) -or ($a.Type -eq 'any')) { continue }
            $what = if ($a.Type) { "'$($a.Type)'" } else { 'no type' }
            $gaps.Add([pscustomobject]@{ Name = $h.Name; Loc = $loc; Detail = "argument '$($a.Display)' is $what" })
        }
    }
    if ($gaps.Count -eq 0) { return }
    Write-Host ""
    Write-Host "Hook reference blocked: $($gaps.Count) unresolved type(s)." -ForegroundColor Red
    Write-Host "Type each at the source, or mark a genuinely dynamic value with ---@param x any:"
    $locWidth = ($gaps | ForEach-Object { $_.Loc.Length } | Measure-Object -Maximum).Maximum
    foreach ($g in $gaps) { Write-Host ("  {0,-34}{1}  {2}" -f $g.Name, $g.Loc.PadRight($locWidth), $g.Detail) }
    Write-Host ""
    throw "Hook reference has $($gaps.Count) unresolved type(s) - see the list above."
}

# --- Convar pages (Kind = 'convars') -----------------------------------------
# A convars category renders the convars and console commands an addon registers
# (from Get-ConVarModel - a union of a static scan and a dual-realm headless run).
# Debug-named entries are grouped into their own subsection at the bottom.

# The convar/command name, linked to its source: exact file#Lline when the static
# scan located it, or a file-level link (no line) for a dynamic registration the
# execution capture only pins to the addon file whose load created it.
function Render-ConVarName($e) {
    $code = "``$($e.Name)``"
    if (-not ($sourceBlobBase -and $e.SourceFile)) { return $code }
    $anchor = if ($e.SourceLine) { "#L$($e.SourceLine)" } else { '' }
    return "[$code]($sourceBlobBase/$($e.SourceFile)$anchor)"
}

function Render-ConVarDefault($e) {
    $d = if ([string]::IsNullOrEmpty([string]$e.Default)) { '_(empty)_' } else { "``$(Format-Cell ([string]$e.Default))``" }
    if ($null -ne $e.Min -and $null -ne $e.Max) { $d += " ($($e.Min)-$($e.Max))" }
    elseif ($null -ne $e.Min) { $d += " (min $($e.Min))" }
    elseif ($null -ne $e.Max) { $d += " (max $($e.Max))" }
    return $d
}

function Render-ConVarFlags($e) {
    $f = @($e.Flags) | Sort-Object
    if ($f.Count -eq 0) { return '-' }
    return ($f | ForEach-Object { "``$_``" }) -join ' '
}

function Render-ConVarTable($rows) {
    $rows = @($rows | Where-Object { $_ })
    $sb = New-Object System.Text.StringBuilder
    if ($rows.Count -eq 0) { [void]$sb.AppendLine('_None._'); [void]$sb.AppendLine(); return $sb.ToString() }
    [void]$sb.AppendLine('| ConVar | Default | Flags | Realm | Description |')
    [void]$sb.AppendLine('|-|-|-|-|-|')
    foreach ($e in ($rows | Sort-Object Name)) {
        $desc = if ($e.Help) { Format-Cell $e.Help } else { '-' }
        [void]$sb.AppendLine("| $(Render-ConVarName $e) | $(Render-ConVarDefault $e) | $(Render-ConVarFlags $e) | $(Format-Realm $e.Realm) | $desc |")
    }
    [void]$sb.AppendLine()
    return $sb.ToString()
}

function Render-CommandTable($rows) {
    $rows = @($rows | Where-Object { $_ })
    $sb = New-Object System.Text.StringBuilder
    if ($rows.Count -eq 0) { [void]$sb.AppendLine('_None._'); [void]$sb.AppendLine(); return $sb.ToString() }
    [void]$sb.AppendLine('| Command | Realm | Description |')
    [void]$sb.AppendLine('|-|-|-|')
    foreach ($e in ($rows | Sort-Object Name)) {
        $desc = if ($e.Help) { Format-Cell $e.Help } else { '-' }
        [void]$sb.AppendLine("| $(Render-ConVarName $e) | $(Format-Realm $e.Realm) | $desc |")
    }
    [void]$sb.AppendLine()
    return $sb.ToString()
}

function Build-ConVarsBlock($cat) {
    $convars  = @($convarModel | Where-Object { $_.Kind -eq 'convar' })
    $commands = @($convarModel | Where-Object { $_.Kind -eq 'command' })
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('## ConVars'); [void]$sb.AppendLine()
    [void]$sb.Append((Render-ConVarTable ($convars | Where-Object { -not $_.IsDebug })))
    [void]$sb.AppendLine('## Console Commands'); [void]$sb.AppendLine()
    [void]$sb.Append((Render-CommandTable ($commands | Where-Object { -not $_.IsDebug })))

    $dbgCv  = @($convars  | Where-Object { $_.IsDebug })
    $dbgCmd = @($commands | Where-Object { $_.IsDebug })
    if ($dbgCv.Count -or $dbgCmd.Count) {
        [void]$sb.AppendLine('## Debug'); [void]$sb.AppendLine()
        [void]$sb.AppendLine('_Developer-facing debug convars and commands._'); [void]$sb.AppendLine()
        if ($dbgCv.Count)  { [void]$sb.AppendLine('### Debug convars');  [void]$sb.AppendLine(); [void]$sb.Append((Render-ConVarTable $dbgCv)) }
        if ($dbgCmd.Count) { [void]$sb.AppendLine('### Debug commands'); [void]$sb.AppendLine(); [void]$sb.Append((Render-CommandTable $dbgCmd)) }
    }
    return $sb.ToString().TrimEnd()
}

# --- Catalogue pages (Kind = 'catalogue') ------------------------------------
# A catalogue lists an addon's actual registered instances (from Get-CatalogueRows),
# grouped and columned entirely from the category config - the module holds no
# per-addon knowledge. Labels/descriptions come from the addon's en.json via a
# config-supplied key template; the entry name links to its exact source line.

# The field-name placeholders in a "{a}.{b}" key template.
function Get-CatTemplateFields([string]$tmpl) {
    if (-not $tmpl) { return @() }
    return @([regex]::Matches($tmpl, '\{(\w+)\}') | ForEach-Object { $_.Groups[1].Value })
}

# Resolve a key template against a row's fields; empty placeholders collapse, so an
# absent optional segment (a setting with no subsection) yields a clean, dotless key.
function Resolve-CatTemplate([string]$tmpl, $fields) {
    $out = [regex]::Replace($tmpl, '\{(\w+)\}', { param($m) [string]$fields[$m.Groups[1].Value] })
    return ($out -replace '\.\.+', '.').Trim('.')
}

function Get-CatLabel($cat, $row) {
    $key = Resolve-CatTemplate $cat.Labels.Key $row.Fields
    if ($catI18n.ContainsKey($key)) { return $catI18n[$key] }
    return [string]$row.Fields[$cat.Labels.Fallback]
}
function Get-CatDescription($cat, $row) {
    $key = (Resolve-CatTemplate $cat.Labels.Key $row.Fields) + '.Description'
    if ($catI18n.ContainsKey($key)) { return $catI18n[$key] }
    return $null
}

# The entry label, linked to its exact source line.
function Render-CatEntryName([string]$label, $row) {
    $label = Format-Cell $label
    if (-not ($sourceBlobBase -and $row.SourceFile)) { return $label }
    $anchor = if ($row.SourceLine) { "#L$($row.SourceLine)" } else { '' }
    return "[$label]($sourceBlobBase/$($row.SourceFile)$anchor)"
}

# A group heading: the i18n phrase for the group's LabelKey if it has one, else the
# raw group value (top-level sections read fine as-is; subsections get a nicer name).
function Get-CatGroupHeading($group, $row) {
    if ($group.LabelKey) {
        $key = Resolve-CatTemplate $group.LabelKey $row.Fields
        if ($catI18n.ContainsKey($key)) { return $catI18n[$key] }
    }
    return [string]$row.Fields[$group.By]
}

# One column's cell for a row. A plain field is optionally value-mapped, key-named,
# linked to another page, or range-suffixed; Desc pulls the i18n description; RunsOn
# joins boolean flags with an optional realm suffix.
function Render-CatCell($cat, $col, $row) {
    if ($col.Desc) { $d = Get-CatDescription $cat $row; return $(if ($d) { Format-Cell $d } else { '-' }) }
    if ($col.RunsOn) {
        $on = foreach ($f in ($col.RunsOn -split ',')) { if ($row.Fields[$f] -eq 'true') { $f } }
        $realm = ''
        if ($col.Realm) { foreach ($k in $col.Realm.Keys) { if ($row.Fields[$k] -eq 'true') { $realm = " ($($col.Realm[$k]))" } } }
        $s = ((@($on) -join ', ') + $realm).Trim()
        return $(if ($s) { $s } else { '-' })
    }
    $v = [string]$row.Fields[$col.F]
    if ([string]::IsNullOrEmpty($v)) { return '-' }
    if ($col.Map) { return $(if ($col.Map.ContainsKey($v)) { $col.Map[$v] } else { $v }) }
    if ($col.KeyName) { $v = Get-CatKeyName $catKeyMap $v }
    if ($col.Link) { return "[``$v``]($($col.Link))" }
    # Code-span value-like cells (a default, a key); leave label-like cells (a type
    # name) plain.
    $cell = if ($col.Code) { "``$(Format-Cell $v)``" } else { Format-Cell $v }
    if ($col.Range) {
        $rp = $col.Range -split ','
        $mn = $row.Fields[$rp[0]]; $mx = $row.Fields[$rp[1]]
        if ($null -ne $mn -and $null -ne $mx) { $cell += " ($mn-$mx)" }
    }
    return $cell
}

# One catalogue table. A column flagged SkipEmptyColumn is dropped when no row in
# this table has a value for it, so e.g. a convar column isn't all dashes on the
# client-only sections.
function Render-CatTable($cat, $rows) {
    $rows = @($rows | Where-Object { $_ })
    if ($rows.Count -eq 0) { return '' }
    $cols = [System.Collections.Generic.List[object]]::new()
    foreach ($c in @($cat.Columns)) {
        if ($c.SkipEmptyColumn -and $c.F) {
            $has = $false
            foreach ($r in $rows) { if (-not [string]::IsNullOrEmpty([string]$r.Fields[$c.F])) { $has = $true; break } }
            if (-not $has) { continue }
        }
        $cols.Add($c)
    }
    $headers = @($cat.NameHeader) + @($cols | ForEach-Object { $_.H })
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('| ' + ($headers -join ' | ') + ' |')
    [void]$sb.AppendLine('|' + ('-|' * $headers.Count))
    foreach ($row in ($rows | Sort-Object Id)) {
        $cells = @(Render-CatEntryName (Get-CatLabel $cat $row) $row) + @($cols | ForEach-Object { Render-CatCell $cat $_ $row })
        [void]$sb.AppendLine('| ' + ($cells -join ' | ') + ' |')
    }
    [void]$sb.AppendLine()
    return $sb.ToString()
}

# The fields the config needs pulled from each registration (dedup, order-preserving).
function Get-CatNeededFields($cat) {
    $need = [System.Collections.Generic.List[string]]::new()
    $add = { param($x) if ($x -and -not $need.Contains($x)) { [void]$need.Add($x) } }
    # A table-shaped registration takes its id from a field (so rows can sort by it);
    # an id-table one takes it from the first argument, needing no field.
    if ($cat.Arg -ne 'id-table') { & $add $(if ($cat.Id) { $cat.Id } else { 'id' }) }
    foreach ($f in (Get-CatTemplateFields $cat.Labels.Key)) { & $add $f }
    & $add $cat.Labels.Fallback
    foreach ($g in @($cat.Group)) { & $add $g.By; foreach ($f in (Get-CatTemplateFields $g.LabelKey)) { & $add $f } }
    if ($cat.Where) { & $add $cat.Where.Field }
    foreach ($c in @($cat.Columns)) {
        & $add $c.F
        if ($c.Range) { foreach ($r in ($c.Range -split ',')) { & $add $r } }
        if ($c.RunsOn) { foreach ($r in ($c.RunsOn -split ',')) { & $add $r } }
        if ($c.Realm) { foreach ($k in $c.Realm.Keys) { & $add $k } }
    }
    return @($need)
}

# Render a catalogue category: scan its registrations, filter, group (0-2 levels,
# level-1 rows shown before their subsections), and render each group as a table.
function Build-CatalogueBlock($cat) {
    $rows = Get-CatalogueRows -RepoRoot $RepoRoot -Register $cat.Register `
        -Arg $(if ($cat.Arg) { $cat.Arg } else { 'table' }) `
        -IdField $(if ($cat.Id) { $cat.Id } else { 'id' }) -Fields (Get-CatNeededFields $cat)
    if ($cat.Where) { $rows = @($rows | Where-Object { [string]$_.Fields[$cat.Where.Field] -eq $cat.Where.Equals }) }

    $groups = @($cat.Group)
    $sb = New-Object System.Text.StringBuilder
    if ($groups.Count -eq 0) {
        [void]$sb.Append((Render-CatTable $cat $rows))
        return $sb.ToString().TrimEnd()
    }
    $l0 = $groups[0].By
    foreach ($sec in ($rows | Group-Object { [string]$_.Fields[$l0] } | Sort-Object Name)) {
        [void]$sb.AppendLine("## $(Get-CatGroupHeading $groups[0] $sec.Group[0])"); [void]$sb.AppendLine()
        if ($groups.Count -eq 1) {
            [void]$sb.Append((Render-CatTable $cat $sec.Group))
            continue
        }
        $l1 = $groups[1].By
        $direct = @($sec.Group | Where-Object { -not $_.Fields[$l1] })
        if ($direct.Count) { [void]$sb.Append((Render-CatTable $cat $direct)) }
        foreach ($sub in ($sec.Group | Where-Object { $_.Fields[$l1] } | Group-Object { [string]$_.Fields[$l1] } | Sort-Object Name)) {
            [void]$sb.AppendLine("### $(Get-CatGroupHeading $groups[1] $sub.Group[0])"); [void]$sb.AppendLine()
            [void]$sb.Append((Render-CatTable $cat $sub.Group))
        }
    }
    return $sb.ToString().TrimEnd()
}

# --- Function pages (Kind = 'functions') -------------------------------------
# A functions category renders a namespace class's methods that opt into the public
# API with a ---@api doc tag. The signature's params and return are type-linked
# through the same Render-Type used for class fields; the name links to the exact
# source line. Untyped params/returns show `_unknown_`, improving as the source gets
# typed (same as the hooks page).

function Render-FunctionArgs($params, [string]$thisPage) {
    $list = @($params)
    if ($list.Count -eq 0) { return '' }
    $parts = foreach ($p in $list) {
        $disp = '`' + (Format-Cell $p.Name) + '`'
        if (Test-HookTypeResolved $p.Type) { "${disp}: $(Render-Type $p.Type $thisPage)" } else { "${disp}: _unknown_" }
    }
    return ($parts -join ', ')
}

# emmylua infers a return type from the body even with no ---@return; the early-exit
# idiom `return x and f()` / `return x or y` yields a boolean-literal type (`false?`,
# `true`, `true|false`) that no author hand-annotates (they'd write `boolean`). A return
# composed solely of boolean literals and nil is that inferred noise - hide it, so a
# void/callback function reads as a bare signature. A real type in the union (e.g.
# `Entity|false`) is kept whole.
function Test-InferredBooleanReturn([string]$type) {
    $parts = @(($type.TrimEnd('?') -split '\|') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($parts.Count -eq 0) { return $false }
    foreach ($p in $parts) { if ($p -notin @('true', 'false', 'nil')) { return $false } }
    return $true
}

# Only show a return arrow for a resolved return type. emmylua infers a return from
# the body even when there's no ---@return (so a void-ish function would otherwise
# read `-> _unknown_`); an author surfaces a real return by annotating ---@return.
# Inferred boolean-literal noise (see Test-InferredBooleanReturn) is dropped too.
function Render-FunctionReturn($returns, [string]$thisPage) {
    $list = @($returns | Where-Object { (Test-HookTypeResolved $_) -and (-not (Test-InferredBooleanReturn $_)) })
    if ($list.Count -eq 0) { return '' }
    return ' -> ' + ((@($list) | ForEach-Object { Render-Type $_ $thisPage }) -join ', ')
}

# The method name, `Class:Method` (or `Class.func`), linked to its source line.
function Render-FunctionName([string]$className, $fn, [string]$thisPage) {
    $sep = if ($fn.IsMeth) { ':' } else { '.' }
    $code = "``$className$sep$($fn.Name)``"
    if ($sourceBlobBase -and $fn.SourceFile) { return "[$code]($sourceBlobBase/$($fn.SourceFile)#L$($fn.SourceLine))" }
    return $code
}

# A networked property's name, linked to its NetworkVar declaration line.
function Render-NetVarName($nv) {
    $code = "``$($nv.Name)``"
    if ($sourceBlobBase -and $nv.SourceFile) { return "[$code]($sourceBlobBase/$($nv.SourceFile)#L$($nv.SourceLine))" }
    return $code
}

# A functions page renders the class's ---@api methods, and (when the category opts in
# with NetworkVars=$true) a table of the entity's networked properties and their
# generated Get/Set accessors - the public interface of entities driven by NetworkVars
# rather than tagged methods. -Combined appends these below a Roots field table (one
# page per entity), so the Methods heading is forced; standalone it appears only when
# netvars share the page. Combined returns '' (not '_None._') when there's nothing.
function Build-FunctionsBlock($cat, [switch]$Combined) {
    $cls = $classes[$cat.Class]
    $fns = if ($cls) { @($cls.Functions | Where-Object { $_.IsApi } | Sort-Object Name) } else { @() }
    $netvars = if ($cat.NetworkVars -and $cat.Source) { @(Get-NetworkVarModel -RepoRoot $RepoRoot -Source $cat.Source | Sort-Object Name) } else { @() }
    $sb = New-Object System.Text.StringBuilder

    if ($fns.Count -eq 0 -and $netvars.Count -eq 0) {
        if ($Combined) { return '' }
        [void]$sb.AppendLine('_None._'); return $sb.ToString().TrimEnd()
    }

    if ($fns.Count) {
        if ($Combined -or $netvars.Count) { [void]$sb.AppendLine('## Methods'); [void]$sb.AppendLine() }
        [void]$sb.AppendLine('| Function | Description |')
        [void]$sb.AppendLine('|-|-|')
        foreach ($fn in $fns) {
            $sig = "$(Render-FunctionName $cat.Class $fn $cat.File)($(Render-FunctionArgs $fn.Params $cat.File))$(Render-FunctionReturn $fn.Returns $cat.File)"
            $desc = if ($fn.Desc) { Format-Cell $fn.Desc } else { '-' }
            [void]$sb.AppendLine("| $sig | $desc |")
        }
    }

    if ($netvars.Count) {
        if ($fns.Count) { [void]$sb.AppendLine() }
        [void]$sb.AppendLine('## Network variables'); [void]$sb.AppendLine()
        [void]$sb.AppendLine('| Variable | Type | Getter | Setter |')
        [void]$sb.AppendLine('|-|-|-|-|')
        foreach ($nv in $netvars) {
            [void]$sb.AppendLine("| $(Render-NetVarName $nv) | $(Render-Type $nv.Type $cat.File) | ``Get$($nv.Name)()`` | ``Set$($nv.Name)(value)`` |")
        }
    }
    return $sb.ToString().TrimEnd()
}

# The generated table block for one category page (the intro above the markers is
# hand-written and preserved). Registry categories (hooks/convars/catalogue/functions)
# render their entries; every other renders class field tables.
function Build-CategoryBlock($cat) {
    if ($cat.Kind -eq 'hooks') { return Build-HooksBlock $cat }
    if ($cat.Kind -eq 'convars') { return Build-ConVarsBlock $cat }
    if ($cat.Kind -eq 'catalogue') { return Build-CatalogueBlock $cat }
    if ($cat.Kind -eq 'functions') { return Build-FunctionsBlock $cat }
    $withDefault = Test-PageHasDefaults $cat
    $sb = New-Object System.Text.StringBuilder
    foreach ($n in $pageList[$cat.File]) {
        [void]$sb.Append((Render-Class $classes[$n] $cat.File $withDefault))
    }
    # A class-field (Roots) page that also names an entity Class carries that entity's
    # methods/netvars below its fields - one unified page per entity.
    if ($cat.Class) { [void]$sb.Append((Build-FunctionsBlock $cat -Combined)) }
    return $sb.ToString().TrimEnd()
}

# A registry category (hooks/convars/catalogue) is always live; a functions category
# is live if its namespace class exists; class categories are live only if they own
# at least one class.
$registryKinds = @('hooks', 'convars', 'catalogue', 'functions')
$liveCats = @($Categories | Where-Object {
    ($_.Kind -in @('hooks', 'convars', 'catalogue')) -or
    ($_.Kind -eq 'functions' -and $classes.Contains($_.Class)) -or
    $pageList[$_.File].Count -gt 0
})

# Source links (registry pages + combined entity pages) point at the repo's github
# blob base, resolved once.
$sourceBlobBase = $null
if ($Categories | Where-Object { ($_.Kind -in $registryKinds) -or $_.Source }) {
    $sourceBlobBase = Get-GitHubBlobBaseUrl $RepoRoot
}

# The fired-hook model, resolved once (spawns glua_ls), only if a hooks page exists.
$hookModel = $null
if ($Categories | Where-Object { $_.Kind -eq 'hooks' }) {
    Write-Host "Resolving fired hooks via glua_ls..."
    $hookModel = Get-HookModel -RepoRoot $RepoRoot
    # -Strict turns unresolved hook types into a generation failure; without it they
    # render as bare names (a visible, non-blocking prompt to type them at the source).
    if ($Strict) { Assert-HookTypesResolved $hookModel }
}

# The convar/concommand model (static scan + dual-realm headless run), only if a
# convars page exists.
$convarModel = $null
if ($Categories | Where-Object { $_.Kind -eq 'convars' }) {
    Write-Host "Resolving convars (static scan + dual-realm headless run)..."
    $convarModel = Get-ConVarModel -RepoRoot $RepoRoot
}

# Catalogue shared inputs (the en.json label map + key-name map), resolved once if
# any catalogue page exists. Each catalogue's rows are scanned in Build-CatalogueBlock.
$catI18n = $null
$catKeyMap = $null
if ($Categories | Where-Object { $_.Kind -eq 'catalogue' }) {
    Write-Host "Cataloguing registries..."
    $catI18n = Get-CatI18n $RepoRoot
    $catKeyMap = Get-CatKeyMap $RepoRoot
}

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

# Remove orphaned generated pages: a wiki .md carrying our generated marker that no
# category produces any more (a category was renamed or removed). Hand-written pages
# have no marker, so they are never touched. The CI wiki commit is `git add -A`, so a
# deletion here propagates.
$managed = @{}
foreach ($t in $targets) { $managed[(Split-Path -Leaf $t.Path)] = $true }
foreach ($md in (Get-ChildItem -LiteralPath $WikiPath -Filter *.md -File)) {
    if ($managed.ContainsKey($md.Name)) { continue }
    $body = Get-Content -LiteralPath $md.FullName -Raw
    if ($body -and $body.Contains($BeginMarker)) {
        if (-not $Check) { Remove-Item -LiteralPath $md.FullName -Force }
        Write-Host ("  {0,-9} {1}" -f 'removed', $md.Name)
    }
}

}   # end function Invoke-WikiGen
