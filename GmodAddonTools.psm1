# GmodAddonTools - shared GMod addon build/dev tooling.
#
# Public API (see GmodAddonTools.psd1 FunctionsToExport):
#   Install-GmodTools    - provision pinned tooling into a consumer's .tools/
#   Invoke-WikiGen       - render the API type-reference wiki from annotations
#   New-AddonHarness     - load an addon's content Lua headless under MoonSharp
#   Get-HarnessMeta      - the harness's Vector/Angle/Color/Material metatables
#   ConvertFrom-LuaValue - walk a MoonSharp value into PowerShell objects
#
# The internal helpers each source defines (Install-Archive, Parse-Annotations,
# Render-Class, ConvertFrom-LuaValue's Format-LuaNum, ...) stay module-private.

. "$PSScriptRoot/src/install.ps1"
. "$PSScriptRoot/src/harness/harness.ps1"
. "$PSScriptRoot/src/lsp/lsp-client.ps1"
. "$PSScriptRoot/src/wiki/hooks.ps1"
. "$PSScriptRoot/src/wiki/convars.ps1"
. "$PSScriptRoot/src/wiki/catalogue.ps1"
. "$PSScriptRoot/src/wiki/generate.ps1"

Export-ModuleMember -Function @(
    'Install-GmodTools',
    'Invoke-WikiGen',
    'New-AddonHarness',
    'Get-HarnessMeta',
    'ConvertFrom-LuaValue'
)
