"""Self-check for the crypto path. Run: python test_backup.py

ponytail: asserts, no framework. Covers round-trip, wrong passphrase, tamper,
and that two encryptions of the same input differ (fresh salt+nonce).
"""
import gzip
import io
import os
import sys
import tarfile

from cryptography.exceptions import InvalidTag

from memory_backup import MAGIC, decrypt, encrypt, inspect_archive

PW = "correct horse battery staple"


def main() -> None:
    data = os.urandom(50_000)

    blob = encrypt(data, PW)
    assert blob.startswith(MAGIC), "missing format marker"
    assert decrypt(blob, PW) == data, "round-trip lost data"
    print("ok  round-trip")

    try:
        decrypt(blob, "wrong passphrase")
        sys.exit("FAIL: wrong passphrase decrypted")
    except InvalidTag:
        print("ok  wrong passphrase rejected")

    tampered = bytearray(blob)
    tampered[-1] ^= 0x01
    try:
        decrypt(bytes(tampered), PW)
        sys.exit("FAIL: tampered ciphertext accepted")
    except InvalidTag:
        print("ok  tampered ciphertext rejected")

    # header is authenticated as AAD, so corrupting it must also fail
    bad_header = b"XXXXXX" + blob[len(MAGIC):]
    try:
        decrypt(bad_header, PW)
        sys.exit("FAIL: bad magic accepted")
    except ValueError:
        print("ok  bad header rejected")

    assert encrypt(data, PW) != encrypt(data, PW), "salt/nonce are not fresh per file"
    print("ok  salt+nonce unique per archive")

    # --- archive inspection (what `verify` relies on) ---------------------
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for name, body in (("wiki/index.md", b"# hi"), ("db/index.sqlite", b"x"), ("config.toml", b"")):
            info = tarfile.TarInfo(name)
            info.size = len(body)
            tf.addfile(info, io.BytesIO(body))
    tar = buf.getvalue()

    assert sorted(inspect_archive(tar)) == ["config.toml", "db", "wiki"], "top-level entries wrong"
    print("ok  archive inspection lists top-level entries")

    try:
        inspect_archive(b"not a gzip stream at all")
        sys.exit("FAIL: non-gzip payload accepted")
    except ValueError:
        print("ok  non-gzip payload rejected")

    empty = io.BytesIO()
    with tarfile.open(fileobj=empty, mode="w:gz"):
        pass
    try:
        inspect_archive(empty.getvalue())
        sys.exit("FAIL: empty archive accepted")
    except ValueError:
        print("ok  empty archive rejected")

    # the real path: encrypt a tarball, decrypt it, read its index
    assert sorted(inspect_archive(decrypt(encrypt(tar, PW), PW))) == ["config.toml", "db", "wiki"]
    print("ok  encrypt -> decrypt -> inspect round-trip")

    print("\nall checks passed")


if __name__ == "__main__":
    main()
