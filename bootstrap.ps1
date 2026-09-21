<#
.SYNOPSIS
  One-line entry point. Elevates, installs git, clones this repo, runs setup.ps1.

.DESCRIPTION
  Run this from any PowerShell on Lap A:

    irm https://raw.githubusercontent.com/<you>/ai-memory/main/bootstrap.ps1 | iex

  Set $env:AI_MEMORY_OPS_REPO first if your fork lives elsewhere.
#>
[CmdletBinding()]
param(
    [string] $RepoUrl = $(if ($env:AI_MEMORY_OPS_REPO) { $env:AI_MEMORY_OPS_REPO } else { 'https://github.com/REPLACE-ME/ai-memory.git' }),
    [string] $Dest    = 'C:\ai-memory-ops',
    [ValidateSet('Wireguard', 'Lan')] [string] $Reach = 'Wireguard'
)

$ErrorActionPreference = 'Stop'

if ($RepoUrl -match 'REPLACE-ME') {
    throw "Set the repo URL first: `$env:AI_MEMORY_OPS_REPO = 'https://github.com/you/ai-memory.git'"
}

# --- elevate ---------------------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Re-launching as Administrator..." -ForegroundColor Yellow
    $self = Join-Path $env:TEMP 'ai-memory-bootstrap.ps1'
    $MyInvocation.MyCommand.ScriptBlock.ToString() | Set-Content $self -Encoding UTF8
    Start-Process powershell -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $self,
        '-RepoUrl', $RepoUrl, '-Dest', $Dest, '-Reach', $Reach
    )
    return
}

# --- git -------------------------------------------------------------------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Git..." -ForegroundColor Gray
    winget install --id Git.Git --silent --accept-package-agreements --accept-source-agreements | Out-Null
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}

# --- clone / update --------------------------------------------------------
if (Test-Path (Join-Path $Dest '.git')) {
    Write-Host "Updating $Dest" -ForegroundColor Gray
    git -C $Dest pull --ff-only
}
else {
    Write-Host "Cloning into $Dest" -ForegroundColor Gray
    git clone --depth 1 $RepoUrl $Dest
}

# --- run -------------------------------------------------------------------
& (Join-Path $Dest 'setup.ps1') -Reach $Reach
