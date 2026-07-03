# Minimal synchronous LSP client over stdio, for driving glua_ls headless.
#
# Speaks just enough JSON-RPC to resolve types: initialize -> hover -> shutdown,
# plus a generic null reply to any server-initiated request so the server never
# blocks waiting on us. Cross-file types only resolve once the workspace is
# indexed, which the server only does when it is given workspaceFolders (rootUri
# alone indexes nothing); it signals no progress, so callers didOpen their target
# files and poll a canary hover until types start resolving.

function Test-LspProp($obj, [string]$name) {
    return ($null -ne $obj) -and ($obj.PSObject.Properties.Name -contains $name)
}

function ConvertTo-FileUri([string]$path) {
    $full = [System.IO.Path]::GetFullPath($path) -replace '\\', '/'
    if ($full -notmatch '^/') { $full = "/$full" }
    return "file://" + ($full -replace ' ', '%20')
}

function Write-LspFrame($stream, $obj) {
    $json = $obj | ConvertTo-Json -Depth 40 -Compress
    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
    $head = [System.Text.Encoding]::ASCII.GetBytes("Content-Length: $($body.Length)`r`n`r`n")
    $stream.Write($head, 0, $head.Length)
    $stream.Write($body, 0, $body.Length)
    $stream.Flush()
}

function Read-LspFrame($stream) {
    $hdr = [System.Collections.Generic.List[byte]]::new()
    while ($true) {
        $b = $stream.ReadByte()
        if ($b -lt 0) { return $null }
        $hdr.Add([byte]$b)
        $c = $hdr.Count
        if ($c -ge 4 -and $hdr[$c - 4] -eq 13 -and $hdr[$c - 3] -eq 10 -and $hdr[$c - 2] -eq 13 -and $hdr[$c - 1] -eq 10) { break }
    }
    $headerText = [System.Text.Encoding]::ASCII.GetString($hdr.ToArray())
    $len = 0
    foreach ($line in ($headerText -split "`r`n")) {
        if ($line -match '^(?i)Content-Length:\s*(\d+)') { $len = [int]$Matches[1] }
    }
    if ($len -le 0) { return '' }
    $buf = [byte[]]::new($len)
    $off = 0
    while ($off -lt $len) {
        $r = $stream.Read($buf, $off, $len - $off)
        if ($r -le 0) { break }
        $off += $r
    }
    return [System.Text.Encoding]::UTF8.GetString($buf, 0, $off)
}

function Send-LspNotification($server, [string]$method, $params) {
    Write-LspFrame $server.In @{ jsonrpc = '2.0'; method = $method; params = $params }
}

function Invoke-LspRequest($server, [string]$method, $params) {
    $id = $server.NextId
    $server.NextId = $id + 1
    Write-LspFrame $server.In @{ jsonrpc = '2.0'; id = $id; method = $method; params = $params }
    while ($true) {
        $raw = Read-LspFrame $server.Out
        if ($null -eq $raw) { return $null }
        if ($raw -eq '') { continue }
        $msg = $raw | ConvertFrom-Json
        $hasId = Test-LspProp $msg 'id'
        $hasMethod = Test-LspProp $msg 'method'
        if ($hasId -and -not $hasMethod -and $msg.id -eq $id) { return $msg }
        if ($hasId -and $hasMethod) {
            # Server-initiated request (registerCapability, workDoneProgress/create,
            # etc.) - a null result keeps it moving without us implementing it.
            Write-LspFrame $server.In @{ jsonrpc = '2.0'; id = $msg.id; result = $null }
        }
    }
}

function Start-LspServer([string]$exePath, [string]$rootPath) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $exePath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $rootPath
    $proc = [System.Diagnostics.Process]::Start($psi)

    $server = [pscustomobject]@{
        Process = $proc
        In      = $proc.StandardInput.BaseStream
        Out     = $proc.StandardOutput.BaseStream
        NextId  = 1
    }

    $rootUri = ConvertTo-FileUri $rootPath
    $initParams = @{
        processId        = $PID
        rootUri          = $rootUri
        workspaceFolders = @(@{ uri = $rootUri; name = 'root' })
        capabilities     = @{
            workspace    = @{ workspaceFolders = $true; configuration = $true }
            textDocument = @{ hover = @{ contentFormat = @('markdown', 'plaintext') } }
        }
    }
    $null = Invoke-LspRequest $server 'initialize' $initParams
    Send-LspNotification $server 'initialized' @{}
    return $server
}

function Open-LspDocument($server, [string]$filePath) {
    $text = [System.IO.File]::ReadAllText($filePath)
    Send-LspNotification $server 'textDocument/didOpen' @{
        textDocument = @{ uri = (ConvertTo-FileUri $filePath); languageId = 'lua'; version = 1; text = $text }
    }
}

function Stop-LspServer($server) {
    try {
        $null = Invoke-LspRequest $server 'shutdown' $null
        Send-LspNotification $server 'exit' $null
    } catch {}
    Start-Sleep -Milliseconds 200
    if (-not $server.Process.HasExited) { $server.Process.Kill() }
}

# Hover the token at (1-based) line/char and return the resolved type string, or
# '' when the analyzer has no concrete type. Retries while the server is still
# indexing (it answers hovers with an error until the workspace is loaded).
function Get-LspHoverType($server, [string]$filePath, [int]$line, [int]$char, [int]$retries = 60) {
    $params = @{
        textDocument = @{ uri = (ConvertTo-FileUri $filePath) }
        position     = @{ line = ($line - 1); character = ($char - 1) }
    }
    for ($attempt = 0; $attempt -lt $retries; $attempt++) {
        $resp = Invoke-LspRequest $server 'textDocument/hover' $params
        if ($null -eq $resp) { return '' }
        if (Test-LspProp $resp 'error') { Start-Sleep -Milliseconds 400; continue }
        if (-not (Test-LspProp $resp 'result')) { return '' }
        $result = $resp.result
        if ($null -eq $result) { return '' }
        $value = $null
        if ($result.contents -is [string]) { $value = $result.contents }
        elseif (Test-LspProp $result.contents 'value') { $value = $result.contents.value }
        if (-not $value) { return '' }
        foreach ($ln in ($value -split "`n")) {
            if ($ln -match '(?:local|global|param)?\s*[\w]+\s*:\s*(\S+)') {
                return ($Matches[1].TrimEnd('{', ',').Trim())
            }
        }
        return ''
    }
    return ''
}
