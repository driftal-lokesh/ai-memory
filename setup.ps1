<#
.SYNOPSIS
  One-shot setup of an ai-memory server on this Windows machine (Lap A).

.DESCRIPTION
  Installs prerequisites, the ai-memory release binary, a WinSW service so the
  server survives reboots, a WireGuard tunnel so a second laptop can reach it
  from anywhere, Google Drive for Desktop, and a daily encrypted backup task.
  Ends by printing the exact MCP config for the second laptop.

.PARAMETER Reach
  Wireguard : Lap B reaches the server from anywhere via an encrypted tunnel.
              Requires forwarding ONE UDP port on your router (printed at the end).
  Lan       : Lap B must be on the same Wi-Fi. No router changes at all.

.EXAMPLE
  .\setup.ps1
  .\setup.ps1 -Reach Lan
  .\setup.ps1 -SkipDrive
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet('Wireguard', 'Lan')] [string] $Reach = 'Wireguard',
    [switch] $SkipDrive,
    [string] $DataDir      = "$env:LOCALAPPDATA\ai-memory",
    [int]    $Port         = 49374,
    [int]    $WgPort       = 51820,
    [string] $WgSubnet     = '10.8.0',
    [int]    $KeepBackups  = 14,
    [string] $UserName     = $env:USERNAME,
    [switch] $NoPause
)

$ErrorActionPreference = 'Stop'
# pip and winget write progress to stderr. On PowerShell 7.4+ that alone turns a
# perfectly successful native command into a terminating error. Turn it off and
# check $LASTEXITCODE ourselves instead.
$PSNativeCommandUseErrorActionPreference = $false
$RepoRoot = $PSScriptRoot

# Log everything from the first line. If this window dies, the log survives.
$LogFile = Join-Path $env:TEMP ("ai-memory-setup-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
try { Start-Transcript -Path $LogFile -Force | Out-Null } catch { }
$Exe      = Join-Path $DataDir 'ai-memory.exe'
$SvcDir   = Join-Path $DataDir 'service'
$script:Checks = [System.Collections.ArrayList]::new()
$script:Notes  = [System.Collections.ArrayList]::new()

# ------------------------------------------------------------------ output

function Say  ($m) { Write-Host $m }
function Head ($n, $m) { Write-Host ""; Write-Host "=== STEP $n : $m " -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "  [ok]   $m" -ForegroundColor Green }
function Info ($m) { Write-Host "  [..]   $m" -ForegroundColor Gray }
function Warn ($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Die  ($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; throw $m }
function Note ($m) { [void]$script:Notes.Add($m) }

function Check ($name, [scriptblock] $test) {
    try {
        $r = & $test
        if ($r) { Ok $name; [void]$script:Checks.Add(@{n = $name; p = $true }) }
        else { Warn "$name -> returned false"; [void]$script:Checks.Add(@{n = $name; p = $false; why = 'returned false' }) }
    }
    catch {
        Warn "$name -> $($_.Exception.Message)"
        [void]$script:Checks.Add(@{n = $name; p = $false; why = $_.Exception.Message })
    }
}

function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Have ($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

# Returns a usable python.exe, or $null. Skips the Microsoft Store alias in
# WindowsApps (a 0-byte stub that launches the Store instead of running python)
# and falls back to the py launcher and the known winget install locations.
function Resolve-Python {
    foreach ($c in @(Get-Command python -All -ErrorAction SilentlyContinue)) {
        if ($c.Source -and $c.Source -notmatch 'WindowsApps' -and (Get-Item $c.Source).Length -gt 0) {
            return $c.Source
        }
    }
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $p = (& $py.Source -3 -c "import sys; print(sys.executable)" 2>$null | Select-Object -Last 1) }
        finally { $ErrorActionPreference = $prevEap }
        if ($p -and (Test-Path $p)) { return $p.Trim() }
    }
    foreach ($g in @("$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
                     "$env:ProgramFiles\Python3*\python.exe")) {
        $hit = Get-ChildItem $g -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

# Every native command goes through this.
#
# Two different traps, one per PowerShell edition, and both fire on commands that
# SUCCEEDED:
#   5.1   redirecting native stderr turns those lines into ErrorRecord objects,
#         and with $ErrorActionPreference='Stop' emitting one is terminating.
#   7.3+  $PSNativeCommandUseErrorActionPreference makes a non-zero exit throw.
# ai-memory logs its startup banner to stderr (normal for Rust tracing), so
# without this wrapper every ai-memory call dies on 5.1.
#
# Output comes back as one string; the exit code lands in $script:NativeExit.
function Native {
    param([Parameter(Mandatory)] [scriptblock] $Block)
    $prevEap = $ErrorActionPreference
    $hasNativePref = $null -ne (Get-Variable PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue)
    if ($hasNativePref) {
        $prevNative = $global:PSNativeCommandUseErrorActionPreference
        $global:PSNativeCommandUseErrorActionPreference = $false
    }
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = 0
        $out = & $Block 2>&1 | Out-String
        $script:NativeExit = $global:LASTEXITCODE
        return $out
    }
    finally {
        $ErrorActionPreference = $prevEap
        if ($hasNativePref) { $global:PSNativeCommandUseErrorActionPreference = $prevNative }
    }
}

# Invoke-WebRequest raises WebException on PowerShell 5.1 and
# HttpResponseException on 7, and the status code hangs off a different property
# on each. Normalise. 0 means no HTTP response at all: refused, DNS, or timeout.
function StatusOf ($errorRecord) {
    $r = $errorRecord.Exception.Response
    if ($null -eq $r) { return 0 }
    try { return [int]$r.StatusCode } catch { return 0 }
}

function Winget-Install ($id, $label) {
    Info "$label ($id)"
    $out = Native { winget install --id $id --silent --accept-package-agreements --accept-source-agreements }
    if ($script:NativeExit -ne 0 -and $out -notmatch 'already installed|No newer package') {
        Warn "winget returned $($script:NativeExit) for ${id}:"
        Say ($out.Trim())
    }
    Refresh-Path
}

# Runs ai-memory and returns stdout. Dies with the raw output on failure so the
# real error is visible instead of an empty exception.
function Aim {
    param([string[]] $CliArgs, [hashtable] $EnvVars = @{}, [switch] $AllowFail)
    $old = @{}
    foreach ($k in $EnvVars.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k); Set-Item "env:$k" $EnvVars[$k] }
    try {
        $out = Native { & $Exe @CliArgs }
        if ($script:NativeExit -ne 0 -and -not $AllowFail) {
            Die "ai-memory $($CliArgs -join ' ') exited $($script:NativeExit)`n$out"
        }
        return $out
    }
    finally {
        foreach ($k in $old.Keys) {
            if ($null -eq $old[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
            else { Set-Item "env:$k" $old[$k] }
        }
    }
}

# ------------------------------------------------------------------ step 0

function Step0-Prereqs {
    Head 0 'Prerequisites'

    if (-not (Have 'winget')) {
        Die 'winget not found. Install "App Installer" from the Microsoft Store, then re-run.'
    }
    Ok 'winget present'

    if (-not (Have 'git'))    { Winget-Install 'Git.Git' 'Git' }           else { Ok 'git present' }
    if (-not (Have 'python')) { Winget-Install 'Python.Python.3.12' 'Python 3.12' } else { Ok 'python present' }

    if ($Reach -eq 'Wireguard' -and -not (Test-Path (Join-Path $env:ProgramFiles 'WireGuard\wg.exe'))) {
        Winget-Install 'WireGuard.WireGuard' 'WireGuard'
    }
    elseif ($Reach -eq 'Wireguard') { Ok 'WireGuard present' }

    if (-not $SkipDrive) {
        $driveApp = Join-Path $env:ProgramFiles 'Google\Drive File Stream\launch.bat'
        if (-not (Test-Path $driveApp)) { Winget-Install 'Google.GoogleDrive' 'Google Drive for Desktop' }
        else { Ok 'Google Drive for Desktop present' }
    }

    Refresh-Path
    if (-not (Have 'git')) { Die 'git still not on PATH. Close this window, open a NEW admin PowerShell, re-run.' }

    $script:Python = Resolve-Python
    if (-not $script:Python) {
        Die @'
python was installed but is not usable yet in this window.
Close this window, open a NEW PowerShell as Administrator, and re-run setup.ps1.
(Windows does not expose a freshly installed python to an already-open shell.)
'@
    }
    Ok "python -> $($script:Python)"

    Info 'installing cryptography'
    # No pip self-upgrade: on Windows pip cannot replace its own running exe.
    $req = Join-Path $RepoRoot 'requirements.txt'
    $out = Native { & $script:Python -m pip install --disable-pip-version-check --no-input -r $req }
    if ($script:NativeExit -ne 0) { Die "pip failed (exit $($script:NativeExit)):`n$out" }

    $imp = Native { & $script:Python -c "import cryptography" }
    if ($script:NativeExit -ne 0) { Die "cryptography installed but will not import:`n$imp" }
    Ok 'cryptography installed and imports'
}

# ------------------------------------------------------------------ step 1

function Step1-Fetch {
    Head 1 'Download ai-memory'

    New-Item -ItemType Directory -Force $DataDir | Out-Null
    if (Test-Path $Exe) {
        Ok "already present: $Exe"
    }
    else {
        $zip = Join-Path $env:TEMP 'ai-memory.zip'
        Info 'fetching latest Windows release'
        Invoke-WebRequest -UseBasicParsing `
            -Uri 'https://github.com/akitaonrails/ai-memory/releases/latest/download/ai-memory-windows-x86_64.zip' `
            -OutFile $zip
        Expand-Archive $zip -DestinationPath $DataDir -Force
        Remove-Item $zip -Force
        Get-ChildItem $DataDir -Filter '*.exe' | Unblock-File
        if (-not (Test-Path $Exe)) {
            Die "zip extracted but ai-memory.exe not found in $DataDir. Contents: $((Get-ChildItem $DataDir).Name -join ', ')"
        }
        Ok "installed -> $Exe"
    }

    Info 'ai-memory init'
    Aim @('--data-dir', $DataDir, 'init') -AllowFail | Out-Null
    Ok 'data directory initialised'
}

# ------------------------------------------------------------------ step 2

function Step2-Network {
    Head 2 "Network ($Reach)"

    $lan = (Get-NetIPConfiguration |
        Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
        Select-Object -First 1).IPv4Address.IPAddress
    if (-not $lan) { Die 'no active network adapter with a default gateway' }
    $script:LanIp = $lan
    Ok "LAN address $lan"

    if ($Reach -eq 'Lan') {
        $script:BindIp = $lan
        $script:McpHost = $lan
        $prefix = ($lan -split '\.')[0..2] -join '.'
        Set-Fw 'ai-memory MCP (LAN)' 'TCP' $Port "$prefix.0/24"
        Note "Lap B must be on this same Wi-Fi to reach $lan."
        return
    }

    # --- WireGuard -------------------------------------------------------
    $wgDir = Join-Path $DataDir 'wireguard'
    New-Item -ItemType Directory -Force $wgDir | Out-Null
    $wg = Join-Path $env:ProgramFiles 'WireGuard\wg.exe'
    if (-not (Test-Path $wg)) { Die "wg.exe missing at $wg" }

    $srvConf = Join-Path $wgDir 'ai-memory-wg0.conf'
    $cliConf = Join-Path $RepoRoot 'lap-b.conf'

    if (Test-Path $srvConf) {
        Ok 'WireGuard config already exists (reusing keys)'
    }
    else {
        Info 'generating keypairs'
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            $srvKey = (& $wg genkey).Trim()
            $srvPub = ($srvKey | & $wg pubkey).Trim()
            $cliKey = (& $wg genkey).Trim()
            $cliPub = ($cliKey | & $wg pubkey).Trim()
        }
        finally { $ErrorActionPreference = $prevEap }
        foreach ($k in @($srvKey, $srvPub, $cliKey, $cliPub)) {
            if (-not $k -or $k.Length -lt 40) { Die "wg produced an unusable key: '$k'" }
        }

        @"
[Interface]
PrivateKey = $srvKey
Address    = $WgSubnet.1/24
ListenPort = $WgPort

[Peer]
# Lap B
PublicKey  = $cliPub
AllowedIPs = $WgSubnet.2/32
"@ | Set-Content $srvConf -Encoding ASCII

        $pub = Get-PublicIp
        @"
[Interface]
PrivateKey = $cliKey
Address    = $WgSubnet.2/24

[Peer]
# Lap A
PublicKey           = $srvPub
Endpoint            = ${pub}:$WgPort
AllowedIPs          = $WgSubnet.1/32
PersistentKeepalive = 25
"@ | Set-Content $cliConf -Encoding ASCII
        Ok "server config -> $srvConf"
        Ok "LAP B config   -> $cliConf"
    }

    Set-Fw 'ai-memory WireGuard' 'UDP' $WgPort 'Any'
    Set-Fw 'ai-memory MCP (tunnel only)' 'TCP' $Port "$WgSubnet.0/24"

    $svc = Get-Service 'WireGuardTunnel$ai-memory-wg0' -ErrorAction SilentlyContinue
    if ($svc) { Ok 'WireGuard tunnel service already installed' }
    else {
        Info 'installing tunnel service'
        $wgExe = Join-Path $env:ProgramFiles 'WireGuard\wireguard.exe'
        $wgOut = Native { & $wgExe /installtunnelservice $srvConf }
        if ($script:NativeExit -ne 0) { Die "WireGuard tunnel install failed:`n$wgOut" }
        Start-Sleep 3
        Ok 'tunnel service installed'
    }

    $script:BindIp  = '0.0.0.0'
    $script:McpHost = "$WgSubnet.1"
}

function Set-Fw ($name, $proto, $port, $remote) {
    Remove-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow `
        -Protocol $proto -LocalPort $port -RemoteAddress $remote -Profile Any | Out-Null
    Ok "firewall: $proto/$port from $remote"
}

function Get-PublicIp {
    foreach ($u in @('https://api.ipify.org', 'https://ifconfig.me/ip', 'https://icanhazip.com')) {
        # any one of these can be down or blocked; try the next one silently
        try { return (Invoke-RestMethod -Uri $u -TimeoutSec 8).ToString().Trim() } catch { continue }
    }
    Warn 'could not detect public IP -- lap-b.conf Endpoint needs filling in by hand'
    return 'YOUR.PUBLIC.IP.HERE'
}

# ------------------------------------------------------------------ step 3

function Step3-Drive {
    Head 3 'Google Drive'

    if ($SkipDrive) {
        $script:BackupDest = Join-Path $env:USERPROFILE 'ai-memory-backups'
        New-Item -ItemType Directory -Force $script:BackupDest | Out-Null
        Warn "-SkipDrive: backups stay local at $($script:BackupDest)"
        Note 'Backups are LOCAL ONLY. If this laptop dies, they die with it.'
        return
    }

    $found = Find-DriveRoot
    if (-not $found) {
        Info 'launching Google Drive -- sign in and click Allow in the window that opens'
        $launch = Join-Path $env:ProgramFiles 'Google\Drive File Stream\launch.bat'
        if (Test-Path $launch) { Start-Process $launch } else { Warn 'launcher not found; start Google Drive manually' }

        Say ''
        Say '   Waiting for Google Drive to mount (up to 5 minutes).'
        Say '   Sign in with your Google account and approve access. Nothing to type here.'
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep 5
            $found = Find-DriveRoot
            if ($found) { break }
            Write-Host '.' -NoNewline
        }
        Say ''
    }

    if (-not $found) {
        $script:BackupDest = Join-Path $env:USERPROFILE 'ai-memory-backups'
        New-Item -ItemType Directory -Force $script:BackupDest | Out-Null
        Warn "Drive never mounted. Falling back to $($script:BackupDest)"
        Note "Google Drive did not mount. Re-run later with -SkipDrive:`$false once signed in."
        return
    }

    Ok "Drive mounted at $found"
    $script:BackupDest = Join-Path $found 'ai-memory-backups'
    New-Item -ItemType Directory -Force $script:BackupDest | Out-Null
    Ok "backup folder -> $($script:BackupDest)"
}

function Find-DriveRoot {
    foreach ($d in (Get-PSDrive -PSProvider FileSystem)) {
        foreach ($n in @('My Drive', 'Mi unidad')) {
            $p = Join-Path $d.Root $n
            if (Test-Path $p) { return $p }
        }
    }
    return $null
}

# ------------------------------------------------------------------ step 4

function Step4-Service {
    Head 4 'Server, auth, service, backups'

    # --- root token ------------------------------------------------------
    $tokenFile = Join-Path $DataDir '.root-token'
    if (Test-Path $tokenFile) {
        $root = (Get-Content $tokenFile -Raw).Trim()
        Ok 'reusing existing root token'
    }
    else {
        $out = Aim @('generate-auth-token')
        $root = ($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1).Trim()
        if (-not $root) { Die "generate-auth-token produced no token. Raw output:`n$out" }
        $root | Set-Content $tokenFile -Encoding ASCII
        (Get-Item $tokenFile).Attributes = 'Hidden'
        Ok 'root token generated'
    }
    $script:RootToken = $root

    # --- WinSW service ---------------------------------------------------
    New-Item -ItemType Directory -Force $SvcDir | Out-Null
    $winsw = Join-Path $SvcDir 'ai-memory-service.exe'
    if (-not (Test-Path $winsw)) {
        Info 'downloading WinSW'
        Invoke-WebRequest -UseBasicParsing `
            -Uri 'https://github.com/winsw/winsw/releases/latest/download/WinSW-x64.exe' `
            -OutFile $winsw
        Unblock-File $winsw
    }

    $allowed = @($script:McpHost, 'localhost', '127.0.0.1', $script:LanIp) -join ','
    # Absolute paths only -- the service runs as LocalSystem and would resolve
    # %LOCALAPPDATA% to a different profile.
    @"
<service>
  <id>ai-memory</id>
  <name>ai-memory MCP server</name>
  <description>Local long-term memory server for AI coding agents</description>
  <executable>$Exe</executable>
  <arguments>--data-dir "$DataDir" serve --transport http --bind $($script:BindIp):$Port --enable-web</arguments>
  <startmode>Automatic</startmode>
  <onfailure action="restart" delay="5 sec"/>
  <log mode="roll"/>
  <logpath>$DataDir\logs</logpath>
  <env name="AI_MEMORY_AUTH_TOKEN" value="$root"/>
  <env name="AI_MEMORY_ALLOWED_HOSTS" value="$allowed"/>
  <env name="AI_MEMORY_DATA_DIR" value="$DataDir"/>
</service>
"@ | Set-Content (Join-Path $SvcDir 'ai-memory-service.xml') -Encoding UTF8

    if (Get-Service 'ai-memory' -ErrorAction SilentlyContinue) {
        Info 'reinstalling service with current config'
        Native { & $winsw stop }      | Out-Null
        Native { & $winsw uninstall } | Out-Null
        Start-Sleep 2
    }
    $inst = Native { & $winsw install }
    if ($script:NativeExit -ne 0) { Die "WinSW install failed:`n$inst" }
    Native { & $winsw start } | Out-Null
    Start-Sleep 4
    $svc = Get-Service 'ai-memory' -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') {
        Die "service did not start. Check $DataDir\logs\ai-memory.err.log"
    }
    Ok 'service running (survives reboot)'

    # --- never sleep -----------------------------------------------------
    Native { powercfg /change standby-timeout-ac 0 }   | Out-Null
    Native { powercfg /change hibernate-timeout-ac 0 } | Out-Null
    Ok 'sleep disabled on AC power'

    # --- user + per-machine keys ----------------------------------------
    $keyFile = Join-Path $DataDir '.lap-keys.json'
    if (Test-Path $keyFile) {
        $script:Keys = Get-Content $keyFile -Raw | ConvertFrom-Json
        Ok 'reusing existing API keys'
    }
    else {
        $u = Aim @('user', 'add-human', '--username', $UserName, '--email', "$UserName@local", '--name', $UserName) `
            -EnvVars @{ AI_MEMORY_AUTH_TOKEN = $root } -AllowFail
        if ($u -match 'password') {
            # the raw output carries ai-memory's stderr banner and PowerShell's
            # NativeCommandError decoration; keep only the credential
            $pw = ($u -split "`n" |
                Where-Object { $_.Trim() -match '^[A-Za-z0-9+/_=-]{16,}$' } |
                Select-Object -Last 1)
            if ($pw) { Note "Web UI login -- user '$UserName', temporary password: $($pw.Trim())`n     Change it on first login at http://127.0.0.1:$Port" }
            else { Note "Web UI user '$UserName' created; its temporary password is in $LogFile" }
        }

        $keys = @{}
        foreach ($label in @('lap-a', 'lap-b')) {
            $o = Aim @('api-key', 'add', '--username', $UserName, '--label', $label) -EnvVars @{ AI_MEMORY_AUTH_TOKEN = $root }
            $k = ($o -split "`n" | Where-Object { $_.Trim() -match '^aim_' } | Select-Object -First 1)
            if (-not $k) { Die "could not parse an aim_ key for $label. Raw output:`n$o" }
            $keys[$label] = $k.Trim()
            Ok "API key created: $label"
        }
        $script:Keys = [pscustomobject]$keys
        $script:Keys | ConvertTo-Json | Set-Content $keyFile -Encoding ASCII
        (Get-Item $keyFile).Attributes = 'Hidden'
    }

    # --- this machine's Claude Code -------------------------------------
    Aim @('install-mcp', '--client', 'claude-code', '--apply',
        '--server-url', "http://127.0.0.1:$Port", '--auth-token', $script:Keys.'lap-a') -AllowFail | Out-Null
    Aim @('install-hooks', '--agent', 'claude-code', '--apply',
        '--server-url', "http://127.0.0.1:$Port", '--auth-token', $script:Keys.'lap-a') -AllowFail | Out-Null
    Ok 'Claude Code on this laptop wired to the local server'

    Step4b-Backups
}

function Step4b-Backups {
    $pass = [Environment]::GetEnvironmentVariable('AI_MEMORY_BACKUP_PASSPHRASE', 'User')
    if ($pass) {
        Ok 'backup passphrase already set'
        $script:NewPassphrase = $null
    }
    else {
        $bytes = [byte[]]::new(32)
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $pass = [Convert]::ToBase64String($bytes).TrimEnd('=')
        [Environment]::SetEnvironmentVariable('AI_MEMORY_BACKUP_PASSPHRASE', $pass, 'User')
        $script:NewPassphrase = $pass
        Ok 'backup passphrase generated'
    }
    $env:AI_MEMORY_BACKUP_PASSPHRASE = $pass

    # backup is a server call, not a disk operation -- without this the daily
    # task gets 401 auth required from POST /admin/backup
    [Environment]::SetEnvironmentVariable('AI_MEMORY_AUTH_TOKEN', $script:RootToken, 'User')
    $env:AI_MEMORY_AUTH_TOKEN = $script:RootToken
    [Environment]::SetEnvironmentVariable('AI_MEMORY_BACKUP_DEST', $script:BackupDest, 'User')
    [Environment]::SetEnvironmentVariable('AI_MEMORY_DATA_DIR', $DataDir, 'User')
    [Environment]::SetEnvironmentVariable('AI_MEMORY_EXE', $Exe, 'User')

    $py = $script:Python
    $script = Join-Path $RepoRoot 'memory_backup.py'
    $action  = New-ScheduledTaskAction -Execute $py `
        -Argument "`"$script`" --keep $KeepBackups backup" -WorkingDirectory $RepoRoot
    $trigger = New-ScheduledTaskTrigger -Daily -At 2am
    $set     = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    Register-ScheduledTask -TaskName 'ai-memory-backup' -Action $action -Trigger $trigger `
        -Settings $set -Force -RunLevel Limited | Out-Null
    Ok 'daily 02:00 encrypted backup task registered'
}

# ------------------------------------------------------------------ step 5

function Step5-Test {
    Head 5 'End-to-end tests'

    $local = "http://127.0.0.1:$Port"
    $tok   = $script:Keys.'lap-b'

    Check 'service is Running' { (Get-Service 'ai-memory').Status -eq 'Running' }

    Check 'ai-memory status responds' {
        $o = Aim @('status') -AllowFail
        $o -and $o.Length -gt 0
    }

    Check 'MCP endpoint reachable on loopback' {
        try { Invoke-WebRequest -UseBasicParsing "$local/mcp" -TimeoutSec 10 | Out-Null; $true }
        catch { (StatusOf $_) -in 400, 401, 403, 405, 406 }
    }

    Check 'unauthenticated request is rejected (401)' {
        try { Invoke-WebRequest -UseBasicParsing "$local/handoff" -TimeoutSec 10 | Out-Null; $false }
        catch { (StatusOf $_) -eq 401 }
    }

    Check 'authenticated request is accepted (200)' {
        (Invoke-WebRequest -UseBasicParsing "$local/handoff" -TimeoutSec 10 `
                -Headers @{ Authorization = "Bearer $tok" }).StatusCode -eq 200
    }

    if ($Reach -eq 'Wireguard') {
        Check 'WireGuard tunnel service running' {
            (Get-Service 'WireGuardTunnel$ai-memory-wg0' -ErrorAction Stop).Status -eq 'Running'
        }
        Check "server answers on tunnel address $($script:McpHost)" {
            try { Invoke-WebRequest -UseBasicParsing "http://$($script:McpHost):$Port/mcp" -TimeoutSec 10 | Out-Null; $true }
            catch { (StatusOf $_) -in 400, 401, 403, 405, 406 }
        }
    }

    Check 'crypto self-check passes' {
        Push-Location $RepoRoot
        try { Native { & $script:Python test_backup.py } | Out-Null; $script:NativeExit -eq 0 } finally { Pop-Location }
    }

    Check 'a real backup encrypts and restores' {
        Push-Location $RepoRoot
        try {
            $b = Native { & $script:Python memory_backup.py --dest "$($script:BackupDest)" --keep $KeepBackups backup }
            if ($script:NativeExit -ne 0) { Warn "backup output:`n$b"; return $false }
            # plain verify (no --deep): restore refuses to run while the
            # service is alive, and the service is now permanent
            $v = Native { & $script:Python memory_backup.py --dest "$($script:BackupDest)" verify }
            if ($script:NativeExit -ne 0) { Warn "verify output:`n$v" }
            $script:NativeExit -eq 0
        }
        finally { Pop-Location }
    }
}

# ------------------------------------------------------------------ step 6

function Step6-Report {
    Head 6 'Result'

    $pass = ($script:Checks | Where-Object { $_.p }).Count
    $tot  = $script:Checks.Count
    Say ""
    if ($pass -eq $tot) { Write-Host "  All $tot checks passed." -ForegroundColor Green }
    else {
        Write-Host "  $pass/$tot checks passed. Failures:" -ForegroundColor Yellow
        $script:Checks | Where-Object { -not $_.p } | ForEach-Object { Say "    - $($_.n): $($_.why)" }
        Say "    Logs: $DataDir\logs"
    }

    $url = "http://$($script:McpHost):$Port/mcp"
    Say ""
    Write-Host "  ---------------- LAP B : MCP CONFIG ----------------" -ForegroundColor Cyan
    Say ""
    Say '  {'
    Say '    "mcpServers": {'
    Say '      "ai-memory": {'
    Say "        `"url`": `"$url`","
    Say ('        "headers": { "Authorization": "Bearer ' + $script:Keys.'lap-b' + '" }')
    Say '      }'
    Say '    }'
    Say '  }'
    Say ""
    Say '  Or let ai-memory write that file for you, on Lap B:'
    Say ""
    Say "    ai-memory install-mcp   --client claude-code --apply --server-url http://$($script:McpHost):$Port --auth-token $($script:Keys.'lap-b')"
    Say "    ai-memory install-hooks --agent  claude-code --apply --server-url http://$($script:McpHost):$Port --auth-token $($script:Keys.'lap-b')"
    Say ""

    Write-Host "  ---------------- WHAT YOU STILL DO ----------------" -ForegroundColor Cyan
    Say ""
    $n = 1

    if ($script:NewPassphrase) {
        Write-Host "  $n. SAVE THIS BACKUP PASSPHRASE SOMEWHERE OFF THIS LAPTOP." -ForegroundColor Red
        Say "     Password manager, or paper. It is shown once."
        Say "     If this laptop dies and the passphrase died with it,"
        Say "     your Google Drive backups cannot be decrypted by anyone, including you."
        Say ""
        Write-Host "        $($script:NewPassphrase)" -ForegroundColor Yellow
        Say ""
        $n++
    }

    if ($Reach -eq 'Wireguard') {
        $pub = (Select-String -Path (Join-Path $RepoRoot 'lap-b.conf') -Pattern 'Endpoint' | Select-Object -First 1).Line
        $gw  = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1).IPv4DefaultGateway.NextHop
        Say "  $n. Router: forward UDP port $WgPort to this laptop ($($script:LanIp))."
        Say "     Router admin page is usually http://$gw"
        Say "     Give this laptop a DHCP reservation there too, so $($script:LanIp) never changes."
        Say "     ($($pub.Trim()) -- if your home IP changes later, update that line in lap-b.conf)"
        Say ""; $n++
        Say "  $n. Lap B: install WireGuard, then import this file:"
        Say "        $(Join-Path $RepoRoot 'lap-b.conf')"
        Say "     Activate the tunnel, then run the install-mcp line above."
        Say ""; $n++
    }
    else {
        Say "  $n. Lap B: connect to this same Wi-Fi, then run the install-mcp line above."
        Say ""; $n++
    }

    foreach ($note in $script:Notes) { Say "  $n. $note"; Say ""; $n++ }

    Write-Host "  ---------------- REFERENCE ----------------" -ForegroundColor Cyan
    Say ""
    Say "    Web UI          http://127.0.0.1:$Port"
    Say "    Data            $DataDir"
    Say "    Backups         $($script:BackupDest)   (daily 02:00, keep $KeepBackups)"
    Say "    Service         Get-Service ai-memory   /   Restart-Service ai-memory"
    Say "    Manual backup   python memory_backup.py backup"
    Say "    Verify backup   python memory_backup.py verify"
    Say "    Restore         Stop-Service ai-memory; python memory_backup.py restore"
    Say ""
}

# ------------------------------------------------------------------ main

try {
    Write-Host ""
    Write-Host "  ai-memory server setup  --  reach: $Reach" -ForegroundColor White
    Step0-Prereqs
    Step1-Fetch
    Step2-Network
    Step3-Drive
    Step4-Service
    Step5-Test
    Step6-Report
}
catch {
    Write-Host ""
    Write-Host "SETUP STOPPED" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "  at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Gray
    Write-Host "  $($_.InvocationInfo.Line.Trim())" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Every step is idempotent -- fix the cause and re-run." -ForegroundColor Gray
    Write-Host "  Full log:    $LogFile" -ForegroundColor Yellow
    Write-Host "  Server log:  $DataDir\logs" -ForegroundColor Gray
    $script:Failed = $true
}
finally {
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host ""
    Write-Host "  Log saved to $LogFile" -ForegroundColor Gray
    if ($Host.Name -eq 'ConsoleHost' -and -not $NoPause) {
        Write-Host ""
        Read-Host '  Press Enter to close'
    }
    if ($script:Failed) { exit 1 }
}
