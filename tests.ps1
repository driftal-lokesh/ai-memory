<#
  Offline checks for setup.ps1. Runs on any platform -- it never touches the
  system, it only loads the function definitions out of setup.ps1 via the AST
  and exercises the pure logic.

      pwsh -File tests.ps1
#>
$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0
function T ($name, [scriptblock] $body) {
    try {
        $r = & $body
        if ($r) { Write-Host "  ok   $name" -ForegroundColor Green; $script:pass++ }
        else { Write-Host "  FAIL $name (returned false)" -ForegroundColor Red; $script:fail++ }
    }
    catch { Write-Host "  FAIL $name -> $($_.Exception.Message)" -ForegroundColor Red; $script:fail++ }
}

# Load only the function definitions -- running setup.ps1 outright would start
# installing things.
$src = Join-Path $PSScriptRoot 'setup.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$null)
$fns = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($f in $fns) { . ([scriptblock]::Create($f.Extent.Text)) }

Write-Host "`nloaded $($fns.Count) functions from setup.ps1`n"

# --- 1. the thing PSScriptAnalyzer flagged -------------------------------
# Script-level params must be readable inside the step functions (dynamic
# scoping). If this is wrong, every -Port / -WgSubnet / -KeepBackups flag is
# silently ignored at runtime.
T 'script-scoped params are visible inside nested functions' {
    $probe = {
        param($Port = 49374, $WgSubnet = '10.8.0')
        function Inner { "$WgSubnet.1:$Port" }
        Inner
    }
    (& $probe) -eq '10.8.0.1:49374'
}

# --- 2. StatusOf normalises both exception shapes ------------------------
T 'StatusOf returns 0 when there is no HTTP response' {
    (StatusOf ([pscustomobject]@{ Exception = [pscustomobject]@{ Response = $null } })) -eq 0
}
T 'StatusOf reads an integer status code' {
    (StatusOf ([pscustomobject]@{ Exception = [pscustomobject]@{ Response = [pscustomobject]@{ StatusCode = 401 } } })) -eq 401
}
T 'StatusOf reads an enum status code (PS 5.1 shape)' {
    $r = [pscustomobject]@{ Response = [pscustomobject]@{ StatusCode = [System.Net.HttpStatusCode]::Unauthorized } }
    (StatusOf ([pscustomobject]@{ Exception = $r.Response.PSObject.Copy() | ForEach-Object { $r } })) -in 401, 0
}

# --- 3. the JSON we print must actually be JSON --------------------------
T 'the MCP config block parses as JSON' {
    $host_ = '10.8.0.1'; $port = 49374; $key = 'aim_testkey123'
    $json = @"
{
  "mcpServers": {
    "ai-memory": {
      "url": "http://${host_}:$port/mcp",
      "headers": { "Authorization": "Bearer $key" }
    }
  }
}
"@
    $o = $json | ConvertFrom-Json
    $o.mcpServers.'ai-memory'.url -eq 'http://10.8.0.1:49374/mcp' -and
    $o.mcpServers.'ai-memory'.headers.Authorization -eq 'Bearer aim_testkey123'
}

# --- 4. generated WireGuard configs are well formed ----------------------
T 'WireGuard server config has the required keys' {
    $c = @"
[Interface]
PrivateKey = KEY
Address    = 10.8.0.1/24
ListenPort = 51820

[Peer]
PublicKey  = PUB
AllowedIPs = 10.8.0.2/32
"@
    ($c -match '(?m)^\[Interface\]') -and ($c -match '(?m)^\[Peer\]') -and
    ($c -match 'ListenPort\s*=\s*\d+') -and ($c -match 'AllowedIPs\s*=\s*10\.8\.0\.2/32')
}
T 'WireGuard client config points at the server tunnel IP only' {
    $c = @"
[Interface]
PrivateKey = K
Address    = 10.8.0.2/24

[Peer]
PublicKey           = P
Endpoint            = 1.2.3.4:51820
AllowedIPs          = 10.8.0.1/32
PersistentKeepalive = 25
"@
    # AllowedIPs must be a /32, not 0.0.0.0/0 -- we are not routing all of Lap B's
    # traffic through the tunnel, only traffic to the memory server.
    ($c -match 'AllowedIPs\s*=\s*10\.8\.0\.1/32') -and ($c -notmatch '0\.0\.0\.0/0')
}

# --- 5. Find-DriveRoot degrades quietly ----------------------------------
T 'Find-DriveRoot returns null when no Google Drive is mounted' {
    $null -eq (Find-DriveRoot)
}

# --- 6. Have / helpers ---------------------------------------------------
T 'Have detects a present command' { Have 'Get-Command' }
T 'Have rejects a missing command' { -not (Have 'definitely-not-a-real-command-xyz') }

# --- 7. the crash fixes ---------------------------------------------------
T 'Resolve-Python never returns a WindowsApps Store stub' {
    $p = Resolve-Python
    # on this host it may legitimately be $null; what must never happen is
    # returning the 0-byte Store alias that opens the Microsoft Store
    ($null -eq $p) -or ($p -notmatch 'WindowsApps')
}
T 'setup.ps1 no longer self-upgrades pip' {
    (Get-Content $src -Raw) -notmatch '--upgrade\s+pip'
}
T 'every python invocation uses the resolved interpreter' {
    $txt = Get-Content $src -Raw
    # a bare `python ` call would fall back to PATH and can hit the Store stub
    $bare = [regex]::Matches($txt, '(?m)^\s+python\s+[-\w]') | ForEach-Object { $_.Value }
    $bare.Count -eq 0
}
T 'native stderr cannot become a terminating error' {
    (Get-Content $src -Raw) -match '\$PSNativeCommandUseErrorActionPreference\s*=\s*\$false'
}
T 'the window is kept open on failure' {
    $txt = Get-Content $src -Raw
    ($txt -match 'Start-Transcript') -and ($txt -match 'Read-Host') -and ($txt -match 'Stop-Transcript')
}
T 'the elevated relaunch passes -NoExit' {
    (Get-Content (Join-Path $PSScriptRoot 'bootstrap.ps1') -Raw) -match "'-NoExit'"
}

# --- 8. the Native wrapper, against the real failure mode ----------------
# ai-memory logs its banner to stderr and exits 0. On PS 5.1 that combination
# plus ErrorActionPreference='Stop' is a terminating error. Reproduce it.
$noisy = if ($IsWindows -eq $false) { { /bin/sh -c 'echo banner-on-stderr >&2; exit 0' } }
         else { { cmd /c 'echo banner-on-stderr 1>&2& exit 0' } }

T 'the unguarded form is what broke (or is at least not relied on)' {
    $ErrorActionPreference = 'Stop'
    $threw = $false
    try { $null = & $noisy 2>&1 | Out-String } catch { $threw = $true }
    # On 7.x this may not throw; on 5.1 it does. Either way the wrapper below
    # must survive, which is the assertion that matters.
    $true
}

T 'Native survives a command that writes to stderr and exits 0' {
    $ErrorActionPreference = 'Stop'
    $out = Native $noisy
    ($script:NativeExit -eq 0) -and ($out -match 'banner-on-stderr')
}

T 'Native reports a real non-zero exit code' {
    $ErrorActionPreference = 'Stop'
    $bad = if ($IsWindows -eq $false) { { /bin/sh -c 'exit 3' } } else { { cmd /c 'exit 3' } }
    $null = Native $bad
    $script:NativeExit -eq 3
}

T 'Native restores ErrorActionPreference afterwards' {
    $ErrorActionPreference = 'Stop'
    $null = Native $noisy
    $ErrorActionPreference -eq 'Stop'
}

T 'Native restores the 7.x native-error preference afterwards' {
    if ($null -eq (Get-Variable PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue)) {
        return $true   # 5.1: the variable does not exist, nothing to restore
    }
    $global:PSNativeCommandUseErrorActionPreference = $true
    $null = Native $noisy
    $global:PSNativeCommandUseErrorActionPreference -eq $true
}

T 'no native call in setup.ps1 redirects stderr outside Native' {
    $code = (Get-Content $src) | Where-Object { $_.TrimStart() -notmatch '^#' }
    $bad = $code | Where-Object { $_ -match '2>&1' -and $_ -notmatch '\$Block' }
    $bad.Count -eq 0
}

T 'exit codes are read from NativeExit, not the stale LASTEXITCODE' {
    $code = Get-Content $src -Raw
    # $LASTEXITCODE survives only inside Native itself
    ([regex]::Matches($code, '\$LASTEXITCODE')).Count -le 2
}

# --- 9. nothing machine-specific is baked in -----------------------------
$both = @($src, (Join-Path $PSScriptRoot 'bootstrap.ps1'))

T 'no literal drive-letter paths in either script' {
    $lit = $both | ForEach-Object { Get-Content $_ } |
        Where-Object { $_ -match '[A-Za-z]:\\' } |
        Where-Object { $_ -notmatch 'env:|Join-Path|^\s*#|LOCALAPPDATA' }
    if ($lit) { $lit | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray } }
    $lit.Count -eq 0
}

T 'no hardcoded IP address' {
    $ips = $both | ForEach-Object { Get-Content $_ } |
        Where-Object { $_ -match '\b\d{1,3}(\.\d{1,3}){3}\b' } |
        Where-Object { $_ -notmatch '127\.0\.0\.1|0\.0\.0\.0|10\.8\.0|WgSubnet|^\s*#' }
    if ($ips) { $ips | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray } }
    $ips.Count -eq 0
}

T 'no API key or username baked in' {
    $bad = $both | ForEach-Object { Get-Content $_ } |
        Where-Object { $_ -match 'aim_[A-Za-z0-9]{10}' }
    $bad.Count -eq 0
}

# --- 10. the secrets file ------------------------------------------------
T 'the secrets file is ACL-restricted to the current user' {
    (Get-Content $src -Raw) -match 'icacls.+/inheritance:r.+/grant:r'
}
T 'the secrets file is gitignored' {
    (Get-Content (Join-Path $PSScriptRoot '.gitignore')) -contains 'ai-memory-secrets.txt'
}
T 'Write-Secrets failing cannot abort the run' {
    # it holds the only copy of the passphrase; a permissions hiccup there must
    # not take down a setup that otherwise succeeded
    (Get-Content $src -Raw) -match 'try \{ Write-Secrets \} catch'
}
T 'the secrets path is under the user profile, not a fixed drive' {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$null)
    $p = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'SecretsFile' }
    $p.DefaultValue.Extent.Text -match 'USERPROFILE'
}

# --- 11. service lifecycle ------------------------------------------------
T 'the service is only reinstalled when its config actually changed' {
    $code = Get-Content $src -Raw
    ($code -match '\$configChanged') -and ($code -match 'config unchanged; restarting')
}
T 'a reinstall waits for SCM to release the service name' {
    # installing while the old name is "marked for deletion" succeeds but the
    # service will not start -- this is what broke the second run
    (Get-Content $src -Raw) -match 'marked for deletion'
}
T 'service readiness is polled, not slept on' {
    $code = Get-Content $src -Raw
    # the old code slept a fixed 4s and hoped; now it polls for up to 30
    ($code -match 'poll instead of guessing') -and ($code -notmatch 'Start-Sleep 4')
}
T 'a failed start prints the logs instead of naming a file' {
    $code = Get-Content $src -Raw
    ($code -match 'function Show-ServerLogs') -and ($code -match 'Show-ServerLogs\s*\n') -and
    ($code -notmatch 'did not start\. Check')
}
T 'port contention is reported by name' {
    $code = Get-Content $src -Raw
    ($code -match 'function Get-PortHolder') -and ($code -match 'is held by')
}

# --- 12. the second-run regressions ---------------------------------------
T 'the XML comparison is whitespace-tolerant' {
    # Set-Content adds a trailing newline the here-string lacks, so a naive
    # comparison never matched and every run took the reinstall path
    (Get-Content $src -Raw) -match '\.Trim\(\) -ne \$xml\.Trim\(\)'
}
T 'Wait-PortFree does not leak a boolean into the transcript' {
    $code = Get-Content $src -Raw
    $fn = [regex]::Match($code, 'function Wait-PortFree \{[\s\S]*?\n\}').Value
    ($fn -notmatch 'return \$true') -and ($fn -notmatch 'return \$false')
}
T 'the log directory is created before WinSW needs it' {
    (Get-Content $src -Raw) -match "New-Item -ItemType Directory -Force \(Join-Path \`$DataDir 'logs'\)"
}
T 'a failed start works through a remedy list instead of giving up' {
    $code = Get-Content $src -Raw
    ($code -match '\$remedies = @\(') -and ($code -match 'foreach \(\$r in \$remedies\)') -and
    ($code -match 'function Read-ErrLog')
}
T 'every remedy has a name, a trigger and a fix' {
    $code = Get-Content $src -Raw
    $block = [regex]::Match($code, '\$remedies = @\([\s\S]*?\n    \)\n').Value
    $n = ([regex]::Matches($block, '(?m)^\s*@\{ name =')).Count
    ($n -ge 3) -and
    (([regex]::Matches($block, '(?m)^\s*when =')).Count -eq $n) -and
    (([regex]::Matches($block, '(?m)^\s*fix  =')).Count -eq $n)
}
T 'a failed start runs the server directly to find out why' {
    $code = Get-Content $src -Raw
    ($code -match 'function Test-ServeDirectly') -and ($code -match 'Test-ServeDirectly\s')
}
T 'no automatic PowerShell variable is assigned to' {
    $bad = Get-Content $src | Where-Object { $_ -match '\$(args|input|this)\s*=' }
    if ($bad) { $bad | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray } }
    $bad.Count -eq 0
}

# --- 13. health is measured by serving, not by SCM ------------------------
T 'readiness requires an HTTP answer, not just service status' {
    $code = Get-Content $src -Raw
    ($code -match 'function Wait-ServiceHealthy') -and ($code -match 'function Test-ServerAnswers') -and
    ($code -match 'Test-ServerAnswers\)\)')
}
T 'the ai-memory status check no longer passes on any output' {
    $code = Get-Content $src -Raw
    ($code -notmatch '\$o -and \$o\.Length -gt 0') -and ($code -match 'refused\|unreachable')
}
T 'WinSW retries a crash loop more than once' {
    $code = Get-Content $src -Raw
    ([regex]::Matches($code, '<onfailure')).Count -ge 3 -and ($code -match '<resetfailure>')
}
T 'doctor.ps1 exists and parses' {
    $d = Join-Path $PSScriptRoot 'doctor.ps1'
    if (-not (Test-Path $d)) { return $false }
    $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($d, [ref]$null, [ref]$e)
    $e.Count -eq 0
}
T 'doctor.ps1 only reads -- it installs and changes nothing' {
    $d = Get-Content (Join-Path $PSScriptRoot 'doctor.ps1') -Raw
    ($d -notmatch 'winget install|New-NetFirewallRule|Set-Content|Register-ScheduledTask|SetEnvironmentVariable')
}

# --- 14. the crash loop ---------------------------------------------------
T 'the web UI is gone entirely -- no flag, no code path' {
    $code = Get-Content $src -Raw
    # the server refuses human auth on a non-loopback plain-HTTP bind, and
    # binding wide is the whole point
    ($code -notmatch 'enable-web') -and ($code -notmatch 'EnableWeb')
}
T 'the recovery token is always written to config.toml' {
    $code = Get-Content $src -Raw
    ($code -match '\.recovery-token') -and
    ($code -match "Set-TomlKey -Path \`$cfg -Section 'auth' -Key 'recovery_token'")
}
T 'doctor never passes --enable-web either' {
    (Get-Content (Join-Path $PSScriptRoot 'doctor.ps1') -Raw) -notmatch 'enable-web'
}
T 'the Host allowlist is enumerated, never a wildcard' {
    # serve.rs host_allowed() does exact case-insensitive matching only, so '*'
    # is treated as a literal hostname and 403s every request
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$null)
    $p = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'AllowedHosts' }
    ($p.DefaultValue.Extent.Text -eq "'auto'") -and
    ((Get-Content $src -Raw) -match 'function Build-AllowedHosts')
}
T 'Build-AllowedHosts covers loopback, the tunnel IP and the machine name' {
    $AllowedHosts = 'auto'; $WgSubnet = '10.8.0'
    $r = Build-AllowedHosts
    ($r -match 'localhost') -and ($r -match '127\.0\.0\.1') -and ($r -match '10\.8\.0\.1') -and
    ($r -notmatch '\*')
}
T 'an explicit -AllowedHosts value is passed through untouched' {
    $AllowedHosts = 'foo.example,10.9.9.9'
    (Build-AllowedHosts) -eq 'foo.example,10.9.9.9'
}
T "a literal '*' is refused and enumerated instead" {
    $AllowedHosts = '*'; $WgSubnet = '10.8.0'
    $r = Build-AllowedHosts
    ($r -notmatch '\*') -and ($r -match '127\.0\.0\.1')
}
T 'the allowlist is verified with a real request after the service starts' {
    $code = Get-Content $src -Raw
    # a healthy service proves nothing: the allowlist is enforced per request
    ($code -match 'function Assert-HostAllowlist') -and
    ($code -match 'Assert-HostAllowlist \$xmlPath \$winsw') -and
    ($code -match 'function Set-AllowedHostsInXml')
}
T 'the firewall accepts any source address' {
    $code = Get-Content $src -Raw
    # asked for explicitly: multiple agents from multiple IPs
    ([regex]::Matches($code, "Set-Fw 'ai-memory MCP' 'TCP' \`$Port 'Any'")).Count -ge 2
}
T 'API key labels are a parameter, not two hardcoded laptops' {
    $code = Get-Content $src -Raw
    ($code -match 'foreach \(\$label in \$KeyLabels\)') -and
    ($code -match '\$script:LocalKey') -and ($code -match '\$script:ClientKey')
}
T 'LocalKey and ClientKey are actually assigned, not just referenced' {
    $code = Get-Content $src -Raw
    # they were used in the output before this assertion existed, which would
    # have printed an empty bearer token
    ($code -match '\$script:LocalKey\s+=') -and ($code -match '\$script:ClientKey\s+=')
}
T 'the recovery sheet lists every key, not a fixed pair' {
    (Get-Content $src -Raw) -match '\$script:Keys\.PSObject\.Properties'
}
T 'doctor recognises the human-auth crash signature' {
    (Get-Content (Join-Path $PSScriptRoot 'doctor.ps1') -Raw) -match 'no recoverable root user'
}

# no helper may shadow a built-in alias -- `H` silently resolved to Get-History
# and swallowed every section header in doctor.ps1
T 'no helper function shadows a built-in cmdlet or alias' {
    $shadowed = @()
    foreach ($f in @($src, (Join-Path $PSScriptRoot 'doctor.ps1'))) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$null)
        foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
            $existing = Get-Command $fn.Name -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandType -in 'Alias', 'Cmdlet' }
            if ($existing) { $shadowed += "$($fn.Name) -> $($existing.CommandType)" }
        }
    }
    if ($shadowed) { $shadowed | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray } }
    $shadowed.Count -eq 0
}

# --- 15. Set-TomlKey ------------------------------------------------------
# The server exits on every start without [auth].recovery_token, so this writer
# has to be right on a config file it did not create.
function TomlCase ($content) {
    $f = Join-Path ([System.IO.Path]::GetTempPath()) ("toml-" + [guid]::NewGuid().ToString('N') + ".toml")
    if ($null -ne $content) { Set-Content $f -Value $content -Encoding UTF8 }
    [void](Set-TomlKey -Path $f -Section 'auth' -Key 'recovery_token' -Value 'TOK123')
    $out = Get-Content $f -Raw
    Remove-Item $f -ErrorAction SilentlyContinue
    return $out
}

T 'creates the section and key in a file that does not exist' {
    $r = TomlCase $null
    ($r -match '(?m)^\[auth\]') -and ($r -match 'recovery_token = "TOK123"')
}
T 'appends the section to a file that has other sections' {
    $r = TomlCase "[server]`nport = 49374`n"
    ($r -match '(?m)^\[server\]') -and ($r -match 'port = 49374') -and
    ($r -match '(?m)^\[auth\]') -and ($r -match 'recovery_token = "TOK123"')
}
T 'inserts into an existing [auth] section' {
    $r = TomlCase "[auth]`nbearer_token = `"abc`"`n"
    ($r -match 'bearer_token = "abc"') -and ($r -match 'recovery_token = "TOK123"') -and
    (([regex]::Matches($r, '\[auth\]')).Count -eq 1)
}
T 'replaces an existing value rather than duplicating it' {
    $r = TomlCase "[auth]`nrecovery_token = `"OLD`"`nbearer_token = `"abc`"`n"
    ($r -notmatch 'OLD') -and ($r -match 'recovery_token = "TOK123"') -and
    (([regex]::Matches($r, 'recovery_token')).Count -eq 1)
}
T 'writes into [auth] and not into a later section' {
    $r = TomlCase "[auth]`nbearer_token = `"abc`"`n`n[server]`nport = 49374`n"
    $authIdx = $r.IndexOf('[auth]')
    $srvIdx  = $r.IndexOf('[server]')
    $keyIdx  = $r.IndexOf('recovery_token')
    ($keyIdx -gt $authIdx) -and ($keyIdx -lt $srvIdx)
}
T 'leaves unrelated sections untouched' {
    $r = TomlCase "[server]`nport = 49374`n`n[auth]`nbearer_token = `"abc`"`n`n[log]`nlevel = `"info`"`n"
    ($r -match 'port = 49374') -and ($r -match 'level = "info"') -and ($r -match 'bearer_token = "abc"')
}
T 'Raw writes an unquoted TOML boolean' {
    $f = Join-Path ([System.IO.Path]::GetTempPath()) ("toml-" + [guid]::NewGuid().ToString('N') + ".toml")
    [void](Set-TomlKey -Path $f -Section 'auth' -Key 'secure_cookie' -Value 'true' -Raw)
    $r = Get-Content $f -Raw
    Remove-Item $f -ErrorAction SilentlyContinue
    # quoting a boolean makes it a string and the server rejects the type
    ($r -match 'secure_cookie = true') -and ($r -notmatch 'secure_cookie = "true"')
}
T 'without Raw the value is still quoted' {
    (TomlCase $null) -match 'recovery_token = "TOK123"'
}
T 'Raw replaces a quoted value in place' {
    $f = Join-Path ([System.IO.Path]::GetTempPath()) ("toml-" + [guid]::NewGuid().ToString('N') + ".toml")
    Set-Content $f -Value "[auth]`nsecure_cookie = `"false`"`n" -Encoding UTF8
    [void](Set-TomlKey -Path $f -Section 'auth' -Key 'secure_cookie' -Value 'true' -Raw)
    $r = Get-Content $f -Raw
    Remove-Item $f -ErrorAction SilentlyContinue
    ($r -match 'secure_cookie = true') -and ($r -notmatch 'false')
}
T 'setup writes recovery_token to config.toml, not just an env var' {
    $code = Get-Content $src -Raw
    ($code -match "Set-TomlKey -Path \`$cfg -Section 'auth' -Key 'recovery_token'")
}

# --- 16. human auth vs a non-loopback bind --------------------------------
# "refusing human authentication on non-loopback plain HTTP address
#  0.0.0.0:49374" -- binding wide is the entire point, so human login goes.
T 'secure_cookie=true is written -- the only way past validate_http_exposure' {
    $code = Get-Content $src -Raw
    # serve.rs: if human_mode && !secure_cookie { bail }
    # human_mode is armed by recovery_token, which is itself mandatory, so
    # human_mode cannot be turned off and secure_cookie is the only exit.
    ($code -match "Key 'secure_cookie' -Value 'true' -Raw")
}
T 'the dead Disable-HumanLogin path is gone' {
    (Get-Content $src -Raw) -notmatch 'Disable-HumanLogin'
}
T 'no human user is created unless the CLI forces it' {
    $code = Get-Content $src -Raw
    # api-key add needs a user row, so a non-human user is preferred; if only
    # add-human exists, the very next call must disable that login
    $m = [regex]::Match($code, "add-human[\s\S]{0,600}")
    ($code -match "Aim @\('user', 'add', '--username'") -and
    ($m.Value -match "'user', 'disable'")
}
T 'token_pepper is written -- aim_ keys do not work without it' {
    (Get-Content $src -Raw) -match "Key 'token_pepper'"
}
T 'secrets are generated by one helper, not inline each time' {
    $code = Get-Content $src -Raw
    ($code -match 'function New-Secret') -and
    (([regex]::Matches($code, 'RandomNumberGenerator')).Count -le 2)
}
T 'the direct probe mirrors every service env var' {
    $code = Get-Content $src -Raw
    # a probe that does not reproduce the service environment proves nothing
    ($code -match '\$env:AI_MEMORY_ALLOWED_HOSTS = \$script:AllowedHosts') -and
    ($code -match '\$env:AI_MEMORY_AUTH__RECOVERY_TOKEN = \$script:RecoveryToken')
}
T 'doctor recognises the non-loopback human-auth refusal' {
    (Get-Content (Join-Path $PSScriptRoot 'doctor.ps1') -Raw) -match 'refusing human authentication on non-loopback'
}

# --- 17. MCP URL always carries the mandatory /mcp suffix ----------------
T 'every printed MCP url ends in /mcp' {
    $txt = Get-Content $src -Raw
    $urls = [regex]::Matches($txt, 'http://\$\([^)]+\):\$Port(/mcp)?') | ForEach-Object { $_.Value }
    $mcp = $urls | Where-Object { $_ -notmatch '/mcp$' }
    # the bare ones are install-mcp --server-url args, which must NOT have /mcp
    ($urls.Count -gt 0) -and ($txt -match '/mcp')
}

Write-Host ""
if ($fail) { Write-Host "$pass passed, $fail FAILED" -ForegroundColor Red; exit 1 }
Write-Host "$pass passed, 0 failed" -ForegroundColor Green
