# Registry-catalogue provider for the wiki generator.
#
# Where the class pages document a definition *schema* (the fields a registration
# may have), a catalogue lists the actual registered instances. This provider is
# generic: it statically scans a caller-named registration call (e.g. an addon's
# TARDIS:AddSetting / TARDIS:AddKeyBind) and extracts a caller-named set of fields
# from each. The scan is static, not headless, because such registrations often
# live in entity modules that never load headless, and because a static scan yields
# the exact source line per entry. All addon-specific knowledge - which function,
# which fields, the i18n key shape, the column layout - comes from the category
# config; nothing here is addon-specific.

# From the bracket at $open, return the substring between it and its match
# (string- and comment-aware, nesting-aware, multi-line).
function Get-CatBalanced([string]$text, [int]$open) {
    $len = $text.Length; $depth = 0; $inStr = $false; $q = ''
    for ($i = $open; $i -lt $len; $i++) {
        $c = $text[$i]
        if ($inStr) { if ($c -eq '\') { $i++ } elseif ($c -eq $q) { $inStr = $false }; continue }
        if ($c -eq '-' -and $i + 1 -lt $len -and $text[$i + 1] -eq '-') { while ($i -lt $len -and $text[$i] -ne "`n") { $i++ }; continue }
        if ($c -eq '"' -or $c -eq "'") { $inStr = $true; $q = $c; continue }
        if ($c -eq '(' -or $c -eq '{' -or $c -eq '[') { $depth++ }
        elseif ($c -eq ')' -or $c -eq '}' -or $c -eq ']') { $depth--; if ($depth -eq 0) { return $text.Substring($open + 1, $i - $open - 1) } }
    }
    return $text.Substring($open + 1)
}

# The scalar value of a `key = <literal|ident|ctor(...)>` at a table body's top
# level. A constructor call (Color(...), Vector(...)) is captured whole, not just
# its name, so a color/vector default renders as the value rather than "Color".
function Get-CatField([string]$body, [string]$key) {
    $m = [regex]::Match($body, "(?m)(?:^|,|\{)\s*$key\s*=\s*(""[^""]*""|'[^']*'|true|false|-?[\d.]+|[A-Za-z_]\w*)")
    if (-not $m.Success) { return $null }
    $v = $m.Groups[1].Value
    $end = $m.Index + $m.Length
    if ($v -match '^[A-Za-z_]\w*$' -and $end -lt $body.Length -and $body[$end] -eq '(') {
        return "$v(" + (Get-CatBalanced $body $end) + ')'
    }
    if ($v -match '^"(.*)"$' -or $v -match "^'(.*)'$") { return $Matches[1] }
    return $v
}

function Get-CatLine([string]$text, [int]$idx) { return ($text.Substring(0, $idx) -split "`n").Count }

# Blank out Lua block comments (--[[ ... ]], and the leveled --[==[ ... ]==]),
# replacing each with same-length whitespace so a commented-out registration is not
# scanned while source line numbers stay accurate. Line comments are handled inline
# by Get-CatBalanced.
function Remove-CatBlockComments([string]$text) {
    return [regex]::Replace($text, '--\[(=*)\[.*?\]\1\]', {
        param($m)
        -join ($m.Value.ToCharArray() | ForEach-Object { if ($_ -eq "`n") { "`n" } else { ' ' } })
    }, [System.Text.RegularExpressions.RegexOptions]::Singleline)
}

# The addon's en.json Phrases map (flat "A.B.C" key -> phrase), or an empty map.
function Get-CatI18n([string]$repoRoot) {
    $map = @{}
    $path = Join-Path $repoRoot 'i18n/languages/en.json'
    if (-not (Test-Path -LiteralPath $path)) { return $map }
    $en = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $phrases = if ($en.PSObject.Properties['Phrases']) { $en.Phrases } else { $en }
    foreach ($p in $phrases.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
    return $map
}

# KEY_*/MOUSE_* -> display name, harvested from a key table ([KEY_X] = { n = "Name" })
# anywhere in the addon, falling back to the stripped constant name.
function Get-CatKeyMap([string]$repoRoot) {
    $map = @{}
    foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'lua') -Recurse -Filter *.lua -File -ErrorAction SilentlyContinue)) {
        $t = [System.IO.File]::ReadAllText($f.FullName)
        if ($t -notmatch '\[KEY_\w+\]\s*=\s*\{n') { continue }
        foreach ($m in [regex]::Matches($t, '\[(KEY_\w+|MOUSE_\w+)\]\s*=\s*\{n\s*=\s*"([^"]*)"')) {
            if (-not $map.ContainsKey($m.Groups[1].Value)) { $map[$m.Groups[1].Value] = $m.Groups[2].Value }
        }
    }
    return $map
}

function Get-CatKeyName([hashtable]$keymap, [string]$k) {
    if (-not $k) { return $null }
    if ($keymap.ContainsKey($k)) { return $keymap[$k] }
    return ($k -replace '^KEY_', '' -replace '^MOUSE_', 'Mouse ')
}

# Scan every registration call named $Register and extract the requested $Fields
# from each. $Arg is 'table' (Register({...}), id from the $IdField field) or
# 'id-table' (Register("id", {...}), id from the first string argument). A field
# name may be dotted (convar.name) to reach into a nested sub-table. A field whose
# value is a file-local UPPER_CASE string constant (section = SETTING_SECTION) is
# resolved to that constant's value. Returns:
#   @{ Id; Fields = @{ name -> value }; SourceFile; SourceLine }
function Get-CatalogueRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $RepoRoot,
        [Parameter(Mandatory)] [string]   $Register,
        [string]   $Arg = 'table',
        [string]   $IdField = 'id',
        [string[]] $Fields = @()
    )
    $RepoRoot = (Resolve-Path $RepoRoot).Path
    $luaRoot = Join-Path $RepoRoot 'lua'
    $bareName = ($Register -split ':')[-1]
    $callRe = [regex]::Escape($Register) + '\s*\('
    $dotted = @($Fields | Where-Object { $_ -like '*.*' })
    $flat = @($Fields | Where-Object { $_ -notlike '*.*' })
    $nested = @($dotted | ForEach-Object { ($_ -split '\.', 2)[0] } | Select-Object -Unique)

    $rows = [System.Collections.Generic.List[object]]::new()
    $files = Get-ChildItem -LiteralPath $luaRoot -Recurse -Filter *.lua -File |
        Where-Object { $_.FullName -notmatch '[\\/](\.tools|\.luatypes)[\\/]' -and $_.FullName -notmatch 'gmod_wire_expression2' }

    foreach ($file in $files) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        if ($text -notmatch [regex]::Escape($bareName)) { continue }
        $text = Remove-CatBlockComments $text
        $rel = $file.FullName.Substring($RepoRoot.Length + 1) -replace '\\', '/'
        $localstr = @{}
        foreach ($lv in [regex]::Matches($text, '(?m)^\s*(?:local\s+)?([A-Z][A-Z0-9_]+)\s*=\s*"([^"]*)"')) { $localstr[$lv.Groups[1].Value] = $lv.Groups[2].Value }

        foreach ($m in [regex]::Matches($text, $callRe)) {
            $paren = Get-CatBalanced $text ($m.Index + $m.Length - 1)
            $id = $null
            if ($Arg -eq 'id-table') {
                $idm = [regex]::Match($paren, '^\s*"([^"]*)"'); if (-not $idm.Success) { continue }
                $id = $idm.Groups[1].Value
            }
            $bi = $paren.IndexOf('{'); if ($bi -lt 0) { continue }
            $body = Get-CatBalanced $paren $bi

            # Lift each nested sub-table out of the body so its inner keys can't
            # shadow a top-level field of the same name (e.g. convar.name vs name).
            $subs = @{}
            foreach ($p in $nested) {
                $pm = [regex]::Match($body, "(?:^|,|\{)\s*$p\s*=\s*\{")
                if (-not $pm.Success) { continue }
                $braceIdx = $body.IndexOf('{', $pm.Index + $pm.Length - 1)
                $subs[$p] = Get-CatBalanced $body $braceIdx
                $body = $body.Remove($pm.Index, ($braceIdx + $subs[$p].Length + 1) - $pm.Index)
            }

            $rowFields = @{}
            foreach ($f in $flat) {
                $v = Get-CatField $body $f
                if ($null -ne $v -and $localstr.ContainsKey($v)) { $v = $localstr[$v] }
                $rowFields[$f] = $v
            }
            foreach ($f in $dotted) {
                $parts = $f -split '\.', 2
                $rowFields[$f] = if ($subs.ContainsKey($parts[0])) { Get-CatField $subs[$parts[0]] $parts[1] } else { $null }
            }
            if ($Arg -ne 'id-table') { $id = $rowFields[$IdField] }

            $rows.Add([pscustomobject]@{ Id = $id; Fields = $rowFields; SourceFile = $rel; SourceLine = (Get-CatLine $text $m.Index) })
        }
    }
    return @($rows)
}
