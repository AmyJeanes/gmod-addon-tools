# Consumer script templates

Drop-in replacements for an addon's `scripts/`, applied by hand at the moment the addon's
`gmod-addon-tools` pin is bumped to a version that provides what they call.

## `glua-check.ps1`

Calls `Invoke-GluaCheck`, so it requires the pin to be at **v0.31.3 or later**. Applying it
while the addon still pins v0.31.2 breaks that addon's CI, because the function does not exist
in the checked-out module.

It replaces a driver that carried this:

```powershell
& (Join-Path $PSScriptRoot 'install-tools.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

`install-tools.ps1` ends on a PowerShell function call, so `$LASTEXITCODE` is `$null` rather
than 0. `$null -ne 0` is true, the guard fires, and `exit $null` reports **exit code 0** - a
green run that never invoked the checker. Five of six addons were in that state locally.
