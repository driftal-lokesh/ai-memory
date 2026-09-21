# ai-memory ops

One-shot Windows setup for a private [ai-memory](https://github.com/akitaonrails/ai-memory)
server, plus encrypted daily backups to Google Drive.

**Lap A** runs the server and never sleeps. **Lap B** connects to it over an
encrypted WireGuard tunnel and gets the same memory from anywhere.

```
Lap A (Windows, always on)
  ai-memory.exe ── WinSW service ── 0.0.0.0:49374
       │
  %LOCALAPPDATA%\ai-memory\{wiki,raw,db,logs}
       │
  memory_backup.py (daily 02:00)
       │  AES-256-GCM
       ▼
  G:\My Drive\ai-memory-backups\*.enc
       ▲
       │  WireGuard  10.8.0.0/24
       │
Lap B ── Claude Code ── http://10.8.0.1:49374/mcp
```

## Run it

On Lap A, in any PowerShell:

```powershell
irm https://raw.githubusercontent.com/driftal-lokesh/ai-memory/main/bootstrap.ps1 | iex
```

It elevates itself, installs git, clones to `C:\ai-memory-ops`, and runs `setup.ps1`.

Already cloned? Just:

```powershell
.\setup.ps1
```

### Options

| Flag | Default | Meaning |
|---|---|---|
| `-Reach Wireguard` | ✅ | Lap B works from anywhere. Needs one router port-forward. |
| `-Reach Lan` | | No router changes. Lap B must be on the same Wi-Fi. |
| `-SkipDrive` | | Backups stay local instead of going to Google Drive. |
| `-KeepBackups 14` | 14 | How many daily archives to retain. |
| `-SecretsFile <path>` | `Desktop\ai-memory-secrets.txt` | Where the recovery sheet is written. |
| `-AllowedHosts '*'` | `*` | Host-header allowlist. Open by default. |
| `-KeyLabels a,b,c` | `lap-a,lap-b` | One `aim_` API key per agent. |
| `-Port 49374` | 49374 | ai-memory listen port. |
| `-WgPort 51820` | 51820 | WireGuard UDP port (the one you forward). |

Every step is idempotent. Re-running is safe and repairs a partial install.

Works on PowerShell 5.1 (the Windows default) and 7.x. The two editions trap
native-command stderr differently, so all native calls go through one wrapper.

## What it does

| Step | |
|---|---|
| 0 | winget-installs Git, Python 3.12, WireGuard, Google Drive for Desktop; pip-installs `cryptography` |
| 1 | Downloads the ai-memory Windows release, extracts to `%LOCALAPPDATA%\ai-memory`, runs `init` |
| 2 | Detects the LAN IP, generates WireGuard keys + `lap-b.conf`, installs the tunnel service, writes firewall rules |
| 3 | Launches Google Drive, waits for you to sign in, finds the mount, creates the backup folder |
| 4 | Generates the auth token, installs the WinSW service, disables sleep, creates per-machine `aim_` API keys, wires this laptop's Claude Code, registers the daily backup task |
| 5 | Runs 8 end-to-end checks and reports every failure with its cause |
| 6 | Prints Lap B's MCP JSON, the backup passphrase, and the router instructions |

## The recovery sheet

Setup writes `ai-memory-secrets.txt` to your Desktop and ACLs it to your user
alone. It holds the backup passphrase, all three tokens, Lap B's MCP JSON, the
full `lap-b.conf`, and the web UI credentials — everything needed to rebuild
this from nothing.

It is plaintext by necessity. Move it into a password manager and delete it.
Leaving the passphrase only on this laptop defeats the point of the backups.

## Three things the script cannot do for you

1. **Save the backup passphrase.** Printed once, at the end. Store it off this
   laptop. It is the only key to your Drive backups — nobody, including you, can
   recover them without it.
2. **Forward UDP 51820 on your router.** One rule, once. Only needed for
   `-Reach Wireguard`. Give Lap A a DHCP reservation while you're in there.
3. **Set up Lap B.** Install WireGuard, import `lap-b.conf`, run the printed
   `install-mcp` line.

## The [auth] keys, and why each one is required

From `crates/ai-memory-cli/src/commands/serve.rs`:

```rust
fn human_auth_intended(auth, bootstrap_completed, any_password) -> bool {
    bootstrap_completed || any_password
        || secret_configured(auth.initial_root_password)
        || secret_configured(auth.recovery_token)
}

if human_mode && !secure_cookie { bail!("refusing human authentication on
    non-loopback plain HTTP address ...") }
```

`recovery_token` is mandatory — without it the server exits with *"human
authentication is enabled but no recoverable root user exists"*. But setting it
is itself one of the four things that arms `human_mode`. So `human_mode` cannot
be turned off, and disabling or deleting users does not help.

That leaves exactly one way to bind non-loopback: `secure_cookie = true`. It
only marks the `ai_memory_session` cookie `Secure`, and no MCP client uses
cookies — they all send `Authorization: Bearer`, which "has precedence over
every browser credential". So it costs nothing here.

| key | why |
|---|---|
| `recovery_token` | else: no recoverable root user exists |
| `token_pepper` | required for native `aim_` API keys — and baked into their hashes, so changing it invalidates every existing key |
| `bearer_token` | root credential for admin calls and backups |
| `secure_cookie = true` | else: refuses to bind non-loopback |

There is no browser UI and nothing needs a password.

## Multiple agents

Every agent gets its own `aim_` key, so any one can be revoked without touching
the others.

```powershell
.\setup.ps1 -KeyLabels lap-a,lap-b,cursor,codex,ci
```

```powershell
ai-memory api-key add --username <you> --label <name>
ai-memory api-key list
ai-memory api-key revoke <id>
```

All of them point at the same URL, each with its own token:

```json
{ "mcpServers": { "ai-memory": {
    "url": "http://10.8.0.1:49374/mcp",
    "headers": { "Authorization": "Bearer aim_..." } } } }
```

## The network is open on purpose

- Firewall accepts TCP 49374 from **any** source address.
- Bind is `0.0.0.0`.
- The Host allowlist is enumerated automatically.

The bearer token is the access control — the server refuses unauthenticated
non-loopback requests and will not start without a token, so it cannot be
switched off.

### The Host allowlist has no wildcard

```rust
fn host_allowed(host: &str, allowed_hosts: &[String]) -> bool {
    allowed_hosts.iter().any(|allowed| {
        host.eq_ignore_ascii_case(allowed)
            || host_without_port(host).eq_ignore_ascii_case(allowed)
    })
}
```

Exact matching only. `*` is compared as a literal hostname, so setting it
rejects **every** request with `403 forbidden host`.

`-AllowedHosts auto` (the default) enumerates localhost, `127.0.0.1`, `::1`,
every IPv4 and IPv6 address this machine owns, the WireGuard address, the
machine name and its FQDN. The port is stripped before comparison, so bare
names are enough.

To add one by hand:

```powershell
.\setup.ps1 -AllowedHosts 'localhost,127.0.0.1,10.8.0.1,my-box.lan'
```

Setup verifies this with a real authenticated request after the service starts
— the allowlist is enforced per request, so a healthy service proves nothing
about it — and rebuilds the list once if it gets a 403.

## Security shape

- The MCP port is firewalled to the WireGuard subnet only — not reachable from
  your LAN, let alone the internet.
- WireGuard is the only thing exposed. It does not respond to unauthenticated
  packets, so port scanners see nothing.
- ai-memory refuses unauthenticated non-loopback requests regardless
  (`"Unauthenticated non-loopback HTTP now fails closed"`).
- One user, one `aim_` API key per machine. Lose Lap B → `ai-memory api-key revoke <id>`
  and Lap A keeps working.
- Backups are AES-256-GCM with a scrypt-derived key. Google sees ciphertext.

Plain HTTP inside the tunnel is deliberate — WireGuard already encrypts, so a
TLS reverse proxy would add moving parts for no gain.

## Backups

`memory_backup.py` wraps `ai-memory backup`, which is a **hot** backup — the
server keeps running (it uses the SQLite online-backup API for a consistent
snapshot).

```powershell
python memory_backup.py backup     # backup, encrypt, upload, prune
python memory_backup.py verify     # decrypt newest and check its contents (safe while the server runs)
python memory_backup.py verify --deep   # real restore into a temp dir (Stop-Service ai-memory first)
python memory_backup.py prune      # enforce retention only
python memory_backup.py restore    # DANGER: overwrites live data. Stop-Service ai-memory first.
python test_backup.py              # crypto self-check
pwsh -File tests.ps1               # offline checks for setup.ps1 (24 of them)
```

Retention is enforced by deleting files. There is no incremental backup — if
archives get large, lower `-KeepBackups` rather than adding machinery.

### Restoring onto a new laptop

```powershell
Stop-Service ai-memory
python memory_backup.py restore --src "G:\My Drive\ai-memory-backups\ai-memory-2026-09-21_0200.tar.gz.enc"
Start-Service ai-memory
```

`AI_MEMORY_BACKUP_PASSPHRASE` must be set to the passphrase you saved.

## When something is wrong

```powershell
.\doctor.ps1
```

Reads only, changes nothing. Reports the service state and account, any running
process, what holds port 49374, the HTTP response, every server log, the Windows
event log entries, and then runs the server directly for six seconds to show
what it actually says. It ends with a verdict: either the server runs fine on
its own (so the fault is the service wrapper) or it exited by itself (with the
reason printed above).

## Troubleshooting

| Symptom | Fix |
|---|---|
| Service won't start | setup prints the last 25 lines of every server log for you. If it says the service is "marked for deletion", close Services.msc and Event Viewer, or reboot. |
| Port 49374 already held | setup names the process holding it. A stale `ai-memory.exe` is the usual culprit: `Stop-Process -Name ai-memory -Force` |
| Lap B can't connect | Is the WireGuard tunnel active on Lap B? Is UDP 51820 forwarded? Did your home IP change — check `Endpoint` in `lap-b.conf` |
| `401` with a valid-looking `aim_` key | The key was minted under a different `[auth].token_pepper` and no longer verifies — the server's own words are "restore the original pepper from configuration backup". Re-run `setup.ps1`; it detects this and remints. |
| `403 forbidden host` | The Host your client sends is not in the allowlist, which has no wildcard. `.\setup.ps1 -AllowedHosts '...'` |
| Backup fails with `401 auth required` | `backup` is a server call (`POST /admin/backup`), not a disk operation. It needs `AI_MEMORY_AUTH_TOKEN` — setup exports it, and also writes `%LOCALAPPDATA%\ai-memory\.root-token`. |
| `restore` refuses to run | Another ai-memory process is alive. `Stop-Service ai-memory` first. |
| Lap A rebooted, server gone | It shouldn't. `Get-Service ai-memory`. Never start the server from a Scheduled Task — it is silently killed at the next reboot. |
| `winget` not found | Install "App Installer" from the Microsoft Store |
| Service restarts forever ("terminated unexpectedly, N time(s)") | Run `.\doctor.ps1`. If it reports `human authentication is enabled but no recoverable root user`, setup now writes `[auth].recovery_token` into `config.toml` — re-run it. Note this is armed by a human user existing, **not** by `--enable-web`, so dropping that flag alone does not fix it. |
| The window vanished | It shouldn't any more, but the full transcript is at `%TEMP%\ai-memory-setup-*.log` |
| Native command "crashes" the script | Every native call goes through the `Native` wrapper. If you add one, wrap it — see the comment above `function Native` in setup.ps1. |
| "python is not usable yet in this window" | Windows won't expose a just-installed python to an already-open shell. Close it, open a new admin PowerShell, re-run. |

## Layout

```
bootstrap.ps1       one-line entry: elevate, install git, clone, run setup
setup.ps1           steps 0-6
memory_backup.py    backup / restore / verify / prune, AES-256-GCM
test_backup.py      crypto self-check (no framework, just asserts)
doctor.ps1          read-only diagnosis when the service will not serve
tests.ps1           offline checks for setup.ps1 (AST-loads its functions, runs nothing)
lap-b.conf          generated; gitignored; holds a private key
```
