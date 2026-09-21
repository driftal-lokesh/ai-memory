<#
.SYNOPSIS
  One-line entry point. Elevates, installs git, clones this repo, runs setup.ps1.

.DESCRIPTION
  Run this from any PowerShell on Lap A:

    irm https://raw.githubusercontent.com/driftal-lokesh/ai-memory/main/bootstrap.ps1 | iex

  Defaults to driftal-lokesh/ai-memory. Set $env:AI_MEMORY_OPS_REPO to override.
#>
[CmdletBinding()]
param(
    [string] $RepoUrl = $(if ($env:AI_MEMORY_OPS_REPO) { $env:AI_MEMORY_OPS_REPO } else { 'https://github.com/driftal-lokesh/ai-memory.git' }),
    [string] $Dest    = 'C:\ai-memory-ops',
    [ValidateSet('Wireguard', 'Lan')] [string] $Reach = 'Wireguard'
)

$ErrorActionPreference = 'Stop'

# git and winget both log progress to stderr. On PowerShell 5.1 a redirected
# native stderr line becomes an ErrorRecord, and ErrorActionPreference='Stop'
# makes emitting one terminating -- even when the command succeeded. On 7.3+ the
# equivalent trap is $PSNativeCommandUseErrorActionPreference. Disarm both.
if (Get-Variable PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue) {
    $global:PSNativeCommandUseErrorActionPreference = $false
}
function Native {
    param([Parameter(Mandatory)] [scriptblock] $Block)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = 0
        $out = & $Block 2>&1 | Out-String
        $script:NativeExit = $global:LASTEXITCODE
        return $out
    }
    finally { $ErrorActionPreference = $prev }
}

# --- elevate ---------------------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Re-launching as Administrator..." -ForegroundColor Yellow
    $self = Join-Path $env:TEMP 'ai-memory-bootstrap.ps1'
    $MyInvocation.MyCommand.ScriptBlock.ToString() | Set-Content $self -Encoding UTF8
    Start-Process powershell -Verb RunAs -ArgumentList @(
        '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $self,
        '-RepoUrl', $RepoUrl, '-Dest', $Dest, '-Reach', $Reach
    )
    Write-Host "An Administrator window has opened. Continue there." -ForegroundColor Cyan
    return
}

# --- git -------------------------------------------------------------------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Git..." -ForegroundColor Gray
    $wg = Native { winget install --id Git.Git --silent --accept-package-agreements --accept-source-agreements }
    if ($script:NativeExit -ne 0 -and $wg -notmatch 'already installed|No newer package') {
        Write-Host $wg.Trim() -ForegroundColor Yellow
    }
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}

# --- clone / update --------------------------------------------------------
if (Test-Path (Join-Path $Dest '.git')) {
    Write-Host "Updating $Dest" -ForegroundColor Gray
    $out = Native { git -C $Dest pull --ff-only }
    if ($script:NativeExit -ne 0) { throw "git pull failed:`n$out" }
}
else {
    Write-Host "Cloning into $Dest" -ForegroundColor Gray
    $out = Native { git clone --depth 1 $RepoUrl $Dest }
    if ($script:NativeExit -ne 0) { throw "git clone failed:`n$out" }
}

# --- run -------------------------------------------------------------------
$setup = Join-Path $Dest 'setup.ps1'
if (-not (Test-Path $setup)) { throw "clone succeeded but $setup is missing" }
& $setup -Reach $Reach
