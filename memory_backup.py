#!/usr/bin/env python3
"""Encrypted backup/restore for an ai-memory data directory.

ai-memory's own `backup` is a hot online backup (SQLite online-backup API), so the
server keeps running. This wraps it with AES-256-GCM before the archive touches
Google Drive, and prunes old copies.

Subcommands: backup | restore | verify | prune

ponytail: one file, one dependency (cryptography). No incremental backups --
retention is enforced by deleting files, not by diffing them.
"""
from __future__ import annotations

import argparse
import datetime as dt
import io
import os
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt

MAGIC = b"AIMEM1"           # file format marker + version
SALT_LEN = 16
NONCE_LEN = 12
# scrypt cost. n=2**15 keeps derivation near ~100ms on a laptop.
SCRYPT_N, SCRYPT_R, SCRYPT_P = 2**15, 8, 1
CHUNK_NOTE = "archives are encrypted whole; ai-memory backups are small enough to fit in RAM"


# ---------------------------------------------------------------- crypto

def _derive(passphrase: str, salt: bytes) -> bytes:
    kdf = Scrypt(salt=salt, length=32, n=SCRYPT_N, r=SCRYPT_R, p=SCRYPT_P)
    return kdf.derive(passphrase.encode("utf-8"))


def encrypt(plaintext: bytes, passphrase: str) -> bytes:
    salt = os.urandom(SALT_LEN)
    nonce = os.urandom(NONCE_LEN)
    key = _derive(passphrase, salt)
    # MAGIC is authenticated but not encrypted, so a truncated//swapped header fails loudly.
    ct = AESGCM(key).encrypt(nonce, plaintext, MAGIC)
    return MAGIC + salt + nonce + ct


def decrypt(blob: bytes, passphrase: str) -> bytes:
    if not blob.startswith(MAGIC):
        raise ValueError("not an AIMEM1 archive (wrong file or corrupted header)")
    off = len(MAGIC)
    salt = blob[off:off + SALT_LEN]
    nonce = blob[off + SALT_LEN:off + SALT_LEN + NONCE_LEN]
    ct = blob[off + SALT_LEN + NONCE_LEN:]
    key = _derive(passphrase, salt)
    # raises InvalidTag on wrong passphrase OR tampered ciphertext -- same signal, by design
    return AESGCM(key).decrypt(nonce, ct, MAGIC)


# ---------------------------------------------------------------- helpers

def passphrase_or_die() -> str:
    p = os.environ.get("AI_MEMORY_BACKUP_PASSPHRASE")
    if not p:
        sys.exit("AI_MEMORY_BACKUP_PASSPHRASE is not set. Without it, backups cannot be read.")
    return p


def auth_token(data_dir: str) -> str | None:
    """The root bearer token.

    `ai-memory backup` is not a disk operation -- it POSTs /admin/backup to the
    running server, which returns 401 without this. setup.ps1 exports it and
    also drops it in the data dir; env wins.
    """
    tok = os.environ.get("AI_MEMORY_AUTH_TOKEN")
    if tok:
        return tok.strip()
    f = Path(data_dir) / ".root-token"
    if f.is_file():
        return f.read_text().strip() or None
    return None


def run(cmd: list[str], data_dir: str | None = None) -> None:
    print("  $", " ".join(cmd))
    env = os.environ.copy()
    if data_dir:
        tok = auth_token(data_dir)
        if tok:
            env["AI_MEMORY_AUTH_TOKEN"] = tok
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if r.returncode != 0:
        hint = ""
        if "401" in (r.stdout + r.stderr) or "auth required" in (r.stdout + r.stderr):
            hint = ("\n\nThe server rejected the request. Set AI_MEMORY_AUTH_TOKEN, or make sure "
                    f"{Path(data_dir or '.') / '.root-token'} exists and holds the root token.")
        sys.exit(f"command failed ({r.returncode}):\n{r.stdout}\n{r.stderr}{hint}")


def stamp() -> str:
    return dt.datetime.now().strftime("%Y-%m-%d_%H%M")


def archives(dest: Path) -> list[Path]:
    return sorted(dest.glob("ai-memory-*.tar.gz.enc"))


# ---------------------------------------------------------------- commands

def cmd_backup(a) -> None:
    dest = Path(a.dest)
    dest.mkdir(parents=True, exist_ok=True)
    pw = passphrase_or_die()

    with tempfile.TemporaryDirectory() as tmp:
        raw = Path(tmp) / f"ai-memory-{stamp()}.tar.gz"
        print(f"[1/4] hot backup -> {raw.name}")
        run([a.exe, "--data-dir", a.data_dir, "backup", "--to", str(raw)], a.data_dir)

        print(f"[2/4] encrypt ({raw.stat().st_size / 1e6:.1f} MB)")
        blob = encrypt(raw.read_bytes(), pw)

        out = dest / (raw.name + ".enc")
        print(f"[3/4] write -> {out}")
        out.write_bytes(blob)
        # plaintext tarball dies with the TemporaryDirectory

    print("[4/4] prune")
    cmd_prune(a)
    print(f"OK  {out}")


def cmd_prune(a) -> None:
    keep = a.keep
    found = archives(Path(a.dest))
    for old in found[:-keep] if len(found) > keep else []:
        print(f"  removing {old.name}")
        old.unlink()
    print(f"  {min(len(found), keep)} archive(s) retained (keep={keep})")


def cmd_restore(a) -> None:
    pw = passphrase_or_die()
    src = Path(a.src) if a.src else (archives(Path(a.dest))[-1] if archives(Path(a.dest)) else None)
    if src is None:
        sys.exit("no archives found to restore")
    print(f"[1/2] decrypt {src.name}")
    plain = decrypt(src.read_bytes(), pw)

    with tempfile.TemporaryDirectory() as tmp:
        tar = Path(tmp) / "restore.tar.gz"
        tar.write_bytes(plain)
        print(f"[2/2] restore -> {a.data_dir}")
        print("      NOTE: ai-memory refuses if the server is still running.")
        run([a.exe, "restore", "--from", str(tar), "--data-dir", a.data_dir, "--force"], a.data_dir)
    print("OK restored")


def inspect_archive(plain: bytes) -> list[str]:
    """Top-level entries inside the decrypted tarball."""
    if plain[:2] != b"\x1f\x8b":
        raise ValueError("decrypted payload is not gzip -- this is not an ai-memory backup")
    with tarfile.open(fileobj=io.BytesIO(plain), mode="r:gz") as tf:
        names = tf.getnames()
    if not names:
        raise ValueError("archive is empty")
    tops = sorted({n.split("/")[0] for n in names if n and n != "."})
    return tops


def cmd_verify(a) -> None:
    """Prove the newest archive is decryptable and structurally an ai-memory backup.

    Deliberately does NOT call `ai-memory restore`: restore refuses to run while
    an ai-memory process is alive, and on this setup the server never stops.
    Decrypting and reading the tar index proves the passphrase works, the
    ciphertext is intact, and the payload is the real thing -- which is what
    actually goes wrong. Use --deep for a true restore (stop the service first).
    """
    pw = passphrase_or_die()
    found = archives(Path(a.dest))
    if not found:
        sys.exit("FAIL: no archives to verify")
    src = found[-1]
    print(f"verifying {src.name} ({src.stat().st_size / 1e6:.1f} MB)")

    plain = decrypt(src.read_bytes(), pw)   # raises on wrong passphrase or tampering
    tops = inspect_archive(plain)
    print(f"  decrypts, and contains: {', '.join(tops)}")

    expected = {"wiki", "db", "config.toml"}
    if not (expected & set(tops)):
        sys.exit(f"FAIL: archive has none of {sorted(expected)} at top level -- got {tops}")

    if not a.deep:
        print("OK archive is intact and readable")
        return

    print("  --deep: restoring into a temp dir (requires the service stopped)")
    with tempfile.TemporaryDirectory() as tmp:
        tar = Path(tmp) / "v.tar.gz"
        tar.write_bytes(plain)
        target = Path(tmp) / "data"
        target.mkdir()
        run([a.exe, "restore", "--from", str(tar), "--data-dir", str(target), "--force"], a.data_dir)
        wiki = target / "wiki"
        if not wiki.is_dir():
            sys.exit(f"FAIL: no wiki/ in restored tree ({[p.name for p in target.iterdir()]})")
        print(f"  wiki/ restored with {len(list(wiki.rglob('*.md')))} markdown page(s)")
    print("OK backup is fully restorable")


# ---------------------------------------------------------------- cli

def main() -> None:
    default_data = os.environ.get("AI_MEMORY_DATA_DIR") or str(
        Path(os.environ.get("LOCALAPPDATA", Path.home())) / "ai-memory")
    default_exe = os.environ.get("AI_MEMORY_EXE") or str(Path(default_data) / "ai-memory.exe")
    default_dest = os.environ.get("AI_MEMORY_BACKUP_DEST") or str(Path.home() / "ai-memory-backups")

    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--exe", default=default_exe, help="path to ai-memory.exe")
    p.add_argument("--data-dir", default=default_data, help="ai-memory data directory")
    p.add_argument("--dest", default=default_dest, help="where .enc archives live (Drive folder)")
    p.add_argument("--keep", type=int, default=14, help="how many archives to retain")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("backup").set_defaults(fn=cmd_backup)
    sub.add_parser("prune").set_defaults(fn=cmd_prune)
    v = sub.add_parser("verify")
    v.add_argument("--deep", action="store_true",
                   help="also run a real ai-memory restore into a temp dir (stop the service first)")
    v.set_defaults(fn=cmd_verify)
    r = sub.add_parser("restore")
    r.add_argument("--src", help="specific .enc file (default: newest in --dest)")
    r.set_defaults(fn=cmd_restore)

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
