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

function H ($t) { Write-Host ""; Write-Host "--- $t " -ForegroundColor Cyan }
function L ($t) { Write-Host "  $t" }

$exe = Join-Path $DataDir 'ai-memory.exe'

H 'service'
$svc = Get-Service 'ai-memory' -ErrorAction SilentlyContinue
if ($svc) {
    L "status      $($svc.Status)"
    $wmi = Get-CimInstance Win32_Service -Filter "Name='ai-memory'" -ErrorAction SilentlyContinue
    if ($wmi) {
        L "start mode  $($wmi.StartMode)"
        L "account     $($wmi.StartName)"
        L "exit code   $($wmi.ExitCode)"
        L "path        $($wmi.PathName)"
    }
}
else { L 'not installed' }

H 'process'
$procs = Get-Process 'ai-memory' -ErrorAction SilentlyContinue
if ($procs) { $procs | ForEach-Object { L "pid $($_.Id)  started $($_.StartTime)" } }
else { L 'no ai-memory.exe running' }

H "port $Port"
$conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($conn) {
    foreach ($c in $conn) {
        $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
        L "listening: $($c.LocalAddress):$($c.LocalPort) by $(if ($p) { "$($p.ProcessName) (pid $($p.Id))" } else { "pid $($c.OwningProcess)" })"
    }
}
else { L 'nothing is listening' }

H 'http'
try {
    $r = Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$Port/mcp" -TimeoutSec 5
    L "GET /mcp -> $($r.StatusCode)"
}
catch {
    $code = 0
    if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
    if ($code) { L "GET /mcp -> $code (the server IS up; $code is a valid answer)" }
    else { L "GET /mcp -> no response: $($_.Exception.Message)" }
}

H 'logs'
$logs = Join-Path $DataDir 'logs'
if (Test-Path $logs) {
    $any = $false
    Get-ChildItem $logs -Filter '*.log' | ForEach-Object {
        $tail = Get-Content $_.FullName -Tail 30 -ErrorAction SilentlyContinue
        if ($tail) {
            $any = $true
            Write-Host ""
            Write-Host "  == $($_.Name) ==" -ForegroundColor Yellow
            $tail | ForEach-Object { L $_ }
        }
    }
    if (-not $any) { L "no log content in $logs" }
}
else { L "no log directory at $logs" }

H 'windows event log'
Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager' } -MaxEvents 40 -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match 'ai-memory' } |
    Select-Object -First 5 |
    ForEach-Object { L "$($_.TimeCreated)  $($_.Message -replace "`r?`n", ' ')" }

H 'running the server directly (6s)'
if (-not (Test-Path $exe)) { L "missing: $exe" }
else {
    $tokFile = Join-Path $DataDir '.root-token'
    if (Test-Path $tokFile) { $env:AI_MEMORY_AUTH_TOKEN = (Get-Content $tokFile -Raw).Trim() }
    $o = Join-Path $env:TEMP 'aim-doc-out.txt'
    $e = Join-Path $env:TEMP 'aim-doc-err.txt'
    Remove-Item $o, $e -ErrorAction SilentlyContinue
    $a = "--data-dir `"$DataDir`" serve --transport http --bind 0.0.0.0:$Port --enable-web"
    L "$exe $a"
    Write-Host ""
    try {
        $proc = Start-Process -FilePath $exe -ArgumentList $a -NoNewWindow -PassThru `
            -RedirectStandardOutput $o -RedirectStandardError $e
        Start-Sleep 6
        $alive = -not $proc.HasExited
        if ($alive) { try { $proc.Kill() } catch { } }
        foreach ($f in @($e, $o)) {
            if ((Test-Path $f) -and (Get-Item $f).Length -gt 0) { Get-Content $f -Tail 25 | ForEach-Object { L $_ } }
        }
        Write-Host ""
        if ($alive) { Write-Host "  VERDICT: the server runs fine directly. The fault is the service wrapper." -ForegroundColor Green }
        else { Write-Host "  VERDICT: the server exited by itself (code $($proc.ExitCode)). Reason above." -ForegroundColor Yellow }
    }
    catch { L "could not launch: $($_.Exception.Message)" }
}

Write-Host ""
