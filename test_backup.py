"""Self-check for the crypto path. Run: python test_backup.py

ponytail: asserts, no framework. Covers round-trip, wrong passphrase, tamper,
and that two encryptions of the same input differ (fresh salt+nonce).
"""
import os
import sys

from cryptography.exceptions import InvalidTag

from memory_backup import MAGIC, decrypt, encrypt

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

    print("\nall crypto checks passed")


if __name__ == "__main__":
    main()
