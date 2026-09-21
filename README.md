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

## Three things the script cannot do for you

1. **Save the backup passphrase.** Printed once, at the end. Store it off this
   laptop. It is the only key to your Drive backups — nobody, including you, can
   recover them without it.
2. **Forward UDP 51820 on your router.** One rule, once. Only needed for
   `-Reach Wireguard`. Give Lap A a DHCP reservation while you're in there.
3. **Set up Lap B.** Install WireGuard, import `lap-b.conf`, run the printed
   `install-mcp` line.

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
python memory_backup.py verify     # restore newest into a temp dir and assert it's real
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

## Troubleshooting

| Symptom | Fix |
|---|---|
| Service won't start | `%LOCALAPPDATA%\ai-memory\logs\ai-memory.err.log` |
| Lap B can't connect | Is the WireGuard tunnel active on Lap B? Is UDP 51820 forwarded? Did your home IP change — check `Endpoint` in `lap-b.conf` |
| `401` with a token | Key was revoked or truncated. `ai-memory api-key add --username <you> --label lap-b` |
| Lap A rebooted, server gone | It shouldn't. `Get-Service ai-memory`. Never start the server from a Scheduled Task — it is silently killed at the next reboot. |
| `winget` not found | Install "App Installer" from the Microsoft Store |
| The window vanished | It shouldn't any more, but the full transcript is at `%TEMP%\ai-memory-setup-*.log` |
| Native command "crashes" the script | Every native call goes through the `Native` wrapper. If you add one, wrap it — see the comment above `function Native` in setup.ps1. |
| "python is not usable yet in this window" | Windows won't expose a just-installed python to an already-open shell. Close it, open a new admin PowerShell, re-run. |

## Layout

```
bootstrap.ps1       one-line entry: elevate, install git, clone, run setup
setup.ps1           steps 0-6
memory_backup.py    backup / restore / verify / prune, AES-256-GCM
test_backup.py      crypto self-check (no framework, just asserts)
tests.ps1           offline checks for setup.ps1 (AST-loads its functions, runs nothing)
lap-b.conf          generated; gitignored; holds a private key
```
