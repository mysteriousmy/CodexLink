#!/usr/bin/env python3
"""Create a private local signing key once. No secrets are printed."""

import os, secrets, subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
local = root / ".local"
local.mkdir(mode=0o700, exist_ok=True)
key = local / "codexlink-release.jks"
properties = root / "client/android/key.properties"
if key.exists() or properties.exists():
    if not (key.exists() and properties.exists()):
        raise SystemExit(
            "Signing files are incomplete; restore your existing key and key.properties."
        )
    print("Existing release signing files retained.")
else:
    password = secrets.token_hex(32)
    subprocess.run(
        [
            "keytool",
            "-genkeypair",
            "-keystore",
            str(key),
            "-alias",
            "codexlink",
            "-keyalg",
            "RSA",
            "-keysize",
            "3072",
            "-validity",
            "10000",
            "-dname",
            "CN=CodexLink Personal",
            "-storepass:env",
            "CODEXLINK_SIGNING_PASSWORD",
            "-keypass:env",
            "CODEXLINK_SIGNING_PASSWORD",
        ],
        check=True,
        env={**os.environ, "CODEXLINK_SIGNING_PASSWORD": password},
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    key.chmod(0o600)
    fd = os.open(properties, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as out:
        out.write(
            f"storePassword={password}\nkeyPassword={password}\nkeyAlias=codexlink\nstoreFile={key}\n"
        )
    print(
        "Created private release key in .local and android/key.properties. Keep both for future APK upgrades."
    )
