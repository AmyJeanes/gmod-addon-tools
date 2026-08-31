#!/usr/bin/env pwsh
# Regression test for the bounded LSP reader (src/lsp/lsp-client.ps1).
#
# Before the fix, Read-LspFrame's ReadByte() had no timeout, so a server that accepted a
# request but never replied blocked the synchronous reader forever - the failure behind the
# hook-surface typing gate appearing to "hang". This drives the real Invoke-LspRequest
# against a mock server that answers `initialize` then goes silent, and asserts the next
# request throws a bounded TimeoutException instead of blocking.
#
# Exits 0 on pass, 1 on failure. Needs no glua_ls; safe in CI.

$ErrorActionPreference = 'Stop'
$manifest = Join-Path (Split-Path -Parent $PSScriptRoot) 'GmodAddonTools.psd1'
Import-Module $manifest -Force

# Mock server: reply to the first request (initialize), then stay alive and never answer
# again. Speaks just enough LSP framing to complete the handshake.
$mock = @'
$in = [Console]::OpenStandardInput()
$out = [Console]::OpenStandardOutput()
function Read-Frame($s) {
    $hdr = [System.Collections.Generic.List[byte]]::new()
    while ($true) {
        $b = $s.ReadByte(); if ($b -lt 0) { return $null }
        $hdr.Add([byte]$b); $c = $hdr.Count
        if ($c -ge 4 -and $hdr[$c-4] -eq 13 -and $hdr[$c-3] -eq 10 -and $hdr[$c-2] -eq 13 -and $hdr[$c-1] -eq 10) { break }
    }
    $h = [System.Text.Encoding]::ASCII.GetString($hdr.ToArray()); $len = 0
    foreach ($l in ($h -split "`r`n")) { if ($l -match '^(?i)Content-Length:\s*(\d+)') { $len = [int]$Matches[1] } }
    $buf = [byte[]]::new($len); $off = 0
    while ($off -lt $len) { $r = $s.Read($buf, $off, $len - $off); if ($r -le 0) { break }; $off += $r }
    return [System.Text.Encoding]::UTF8.GetString($buf, 0, $off)
}
$raw = Read-Frame $in
$msg = $raw | ConvertFrom-Json
$resp = @{ jsonrpc = '2.0'; id = $msg.id; result = @{ capabilities = @{} } } | ConvertTo-Json -Compress -Depth 10
$body = [System.Text.Encoding]::UTF8.GetBytes($resp)
$head = [System.Text.Encoding]::ASCII.GetBytes("Content-Length: $($body.Length)`r`n`r`n")
$out.Write($head, 0, $head.Length); $out.Write($body, 0, $body.Length); $out.Flush()
while ($true) { Start-Sleep -Milliseconds 250 }   # stay alive, never answer again
'@
$mockPath = Join-Path ([System.IO.Path]::GetTempPath()) ("mock-lsp-silent-" + [guid]::NewGuid().ToString('N') + ".ps1")
Set-Content -LiteralPath $mockPath -Value $mock -Encoding utf8

$result = & (Get-Module GmodAddonTools) {
    param($mockPath)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName   # the running pwsh
    $psi.ArgumentList.Add('-NoProfile'); $psi.ArgumentList.Add('-File'); $psi.ArgumentList.Add($mockPath)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $server = [pscustomobject]@{
        Process = $proc; In = $proc.StandardInput.BaseStream; Out = $proc.StandardOutput.BaseStream
        NextId = 1; ReadTimeoutMs = 1500
    }
    try {
        $init = Invoke-LspRequest $server 'initialize' @{ processId = $PID }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $threw = $false; $exType = $null
        try { $null = Invoke-LspRequest $server 'textDocument/hover' @{ position = @{ line = 0; character = 0 } } }
        catch { $threw = $true; $exType = $_.Exception.GetType().Name }
        $sw.Stop()
        [pscustomobject]@{ InitOk = ($null -ne $init); Threw = $threw; ExType = $exType; ElapsedMs = [int]$sw.ElapsedMilliseconds }
    } finally {
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
    }
} $mockPath

Remove-Item -LiteralPath $mockPath -Force -ErrorAction SilentlyContinue

$fail = 0
function Assert([bool]$cond, [string]$name) { if ($cond) { Write-Host "PASS  $name" -ForegroundColor Green } else { Write-Host "FAIL  $name" -ForegroundColor Red; $script:fail++ } }

Assert $result.InitOk                          "initialize handshake completes against mock"
Assert $result.Threw                           "a silent request throws instead of hanging"
Assert ($result.ExType -eq 'TimeoutException') "the throw is a TimeoutException (got: $($result.ExType))"
Assert ($result.ElapsedMs -ge 1000)            "waited at least the read-timeout ($($result.ElapsedMs)ms)"
Assert ($result.ElapsedMs -lt 8000)            "bounded well under a hang ($($result.ElapsedMs)ms)"

if ($fail) { Write-Host "`n$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "`nAll assertions passed." -ForegroundColor Green
exit 0
