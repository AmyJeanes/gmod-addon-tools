@{
    RootModule        = 'GmodAddonTools.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b7e6f2a1-4c9d-4a3e-9f2b-1d8c6a5e3b04'
    Author            = 'Amy Jeanes'
    Description       = 'Shared build/dev tooling for Garry''s Mod addons: tool provisioning, wiki-API generation, and the headless Lua harness.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Install-GmodTools',
        'Invoke-WikiGen',
        'New-AddonHarness',
        'ConvertFrom-LuaValue',
        'Get-HarnessMeta'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
