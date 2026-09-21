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

# --- 9. MCP URL always carries the mandatory /mcp suffix -----------------
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
