<#
.SYNOPSIS
  Report why the ai-memory service is not serving. Changes nothing.

.EXAMPLE
  .\doctor.ps1
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string] $DataDir = "$env:LOCALAPPDATA\ai-memory",
    [int]    $Port    = 49374
)

$ErrorActionPreference = 'Continue'
if (Get-Variable PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue) {
    $global:PSNativeCommandUseErrorActionPreference = $false
}

function Section ($t) { Write-Host ""; Write-Host "--- $t " -ForegroundColor Cyan }
function Detail ($t) { Write-Host "  $t" }

$exe = Join-Path $DataDir 'ai-memory.exe'

Section 'service'
$svc = Get-Service 'ai-memory' -ErrorAction SilentlyContinue
if ($svc) {
    Detail "status      $($svc.Status)"
    $wmi = Get-CimInstance Win32_Service -Filter "Name='ai-memory'" -ErrorAction SilentlyContinue
    if ($wmi) {
        Detail "start mode  $($wmi.StartMode)"
        Detail "account     $($wmi.StartName)"
        Detail "exit code   $($wmi.ExitCode)"
        Detail "path        $($wmi.PathName)"
    }
}
else { Detail 'not installed' }

Section 'process'
$procs = Get-Process 'ai-memory' -ErrorAction SilentlyContinue
if ($procs) { $procs | ForEach-Object { Detail "pid $($_.Id)  started $($_.StartTime)" } }
else { Detail 'no ai-memory.exe running' }

Section "port $Port"
$conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($conn) {
    foreach ($c in $conn) {
        $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
        Detail "listening: $($c.LocalAddress):$($c.LocalPort) by $(if ($p) { "$($p.ProcessName) (pid $($p.Id))" } else { "pid $($c.OwningProcess)" })"
    }
}
else { Detail 'nothing is listening' }

Section 'http'
try {
    $r = Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$Port/mcp" -TimeoutSec 5
    Detail "GET /mcp -> $($r.StatusCode)"
}
catch {
    $code = 0
    if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
    if ($code) { Detail "GET /mcp -> $code (the server IS up; $code is a valid answer)" }
    else { Detail "GET /mcp -> no response: $($_.Exception.Message)" }
}

Section 'known failure signatures'
$errLog = Join-Path $DataDir 'logs\ai-memory-service.err.log'
if (Test-Path $errLog) {
    $txt = Get-Content $errLog -Raw
    if ($txt -match 'human authentication is enabled but no recoverable root user') {
        Write-Host "  MATCH: --enable-web armed human auth with no recovery token." -ForegroundColor Red
        Detail "       Fix: re-run setup.ps1 without -EnableWeb (the default now),"
        Detail "       or with -EnableWeb so it supplies a recovery token."
    }
    if ($txt -match 'single-instance serve lock') {
        Detail "note: a serve lock exists at $DataDir\.serve.lock (normal while running)"
    }
    if ($txt -match 'Address already in use|os error 10048') {
        Write-Host "  MATCH: something else already holds port $Port." -ForegroundColor Red
    }
}
else { Detail 'no error log yet' }

Section 'logs'
$logs = Join-Path $DataDir 'logs'
if (Test-Path $logs) {
    $any = $false
    Get-ChildItem $logs -Filter '*.log' | ForEach-Object {
        $tail = Get-Content $_.FullName -Tail 30 -ErrorAction SilentlyContinue
        if ($tail) {
            $any = $true
            Write-Host ""
            Write-Host "  == $($_.Name) ==" -ForegroundColor Yellow
            $tail | ForEach-Object { Detail $_ }
        }
    }
    if (-not $any) { Detail "no log content in $logs" }
}
else { Detail "no log directory at $logs" }

Section 'windows event log'
Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager' } -MaxEvents 40 -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match 'ai-memory' } |
    Select-Object -First 5 |
    ForEach-Object { Detail "$($_.TimeCreated)  $($_.Message -replace "`r?`n", ' ')" }

Section 'running the server directly (6s)'
if (-not (Test-Path $exe)) { Detail "missing: $exe" }
else {
    $tokFile = Join-Path $DataDir '.root-token'
    if (Test-Path $tokFile) { $env:AI_MEMORY_AUTH_TOKEN = (Get-Content $tokFile -Raw).Trim() }
    $recFile = Join-Path $DataDir '.recovery-token'
    if (Test-Path $recFile) { $env:AI_MEMORY_AUTH__RECOVERY_TOKEN = (Get-Content $recFile -Raw).Trim() }
    $o = Join-Path $env:TEMP 'aim-doc-out.txt'
    $e = Join-Path $env:TEMP 'aim-doc-err.txt'
    Remove-Item $o, $e -ErrorAction SilentlyContinue
    # deliberately without --enable-web: that flag arms human auth, which
    # refuses to boot without a recovery token and is the usual crash cause
    $a = "--data-dir `"$DataDir`" serve --transport http --bind 0.0.0.0:$Port"
    Detail "$exe $a"
    Write-Host ""
    try {
        $proc = Start-Process -FilePath $exe -ArgumentList $a -NoNewWindow -PassThru `
            -RedirectStandardOutput $o -RedirectStandardError $e
        Start-Sleep 6
        $alive = -not $proc.HasExited
        if ($alive) { try { $proc.Kill() } catch { } }
        foreach ($f in @($e, $o)) {
            if ((Test-Path $f) -and (Get-Item $f).Length -gt 0) { Get-Content $f -Tail 25 | ForEach-Object { Detail $_ } }
        }
        Write-Host ""
        if ($alive) { Write-Host "  VERDICT: the server runs fine directly. The fault is the service wrapper." -ForegroundColor Green }
        else { Write-Host "  VERDICT: the server exited by itself (code $($proc.ExitCode)). Reason above." -ForegroundColor Yellow }
    }
    catch { Detail "could not launch: $($_.Exception.Message)" }
}

Write-Host ""
