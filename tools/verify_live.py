"""Explicit live checks against a configured workstation and SSH relay.

Creates and removes only a uniquely named directory under the remote TEMP folder.
Reports contain test results, not credentials. Not run automatically in CI.
"""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid


def command(args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, encoding="utf-8",
                          errors="replace", timeout=kwargs.pop("timeout", 30), **kwargs)


def ps(alias, script):
    prefix = ("$ErrorActionPreference='Stop'\n$ProgressPreference='SilentlyContinue'\n"
              "[Console]::OutputEncoding=[Text.Encoding]::UTF8\n")
    encoded = base64.b64encode((prefix + script).encode("utf-16le")).decode()
    return command(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", alias,
                    "powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded])


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--alias", required=True)
    parser.add_argument("--relay-alias", required=True)
    parser.add_argument("--expected-user", required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    results = []

    def check(name, work):
        start = time.monotonic()
        try:
            work()
            result = {"name": name, "passed": True}
        except Exception as exc:
            result = {"name": name, "passed": False, "error": str(exc)}
        result["seconds"] = round(time.monotonic() - start, 2)
        results.append(result)
        print(("PASS " if result["passed"] else "FAIL ") + name, flush=True)

    def identity():
        result = ps(args.alias, r'''$p=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
[pscustomobject]@{User=(whoami);Admin=$p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);AgentForwarded=[bool]$env:SSH_AUTH_SOCK} | ConvertTo-Json -Compress''')
        require(result.returncode == 0, "Remote command failed")
        data = json.loads(result.stdout.lstrip("\ufeff"))
        require(data["User"].lower() == args.expected_user.lower(), "Wrong Windows account")
        require(not data["Admin"], "Workstation session has an administrator token")
        require(not data["AgentForwarded"], "An SSH agent was forwarded")

    check("standard-user identity and no forwarded agent", identity)

    def concurrent():
        def attempt(index):
            marker = "SSH_BRIDGE_SESSION_" + str(index)
            result = ps(args.alias, "Write-Output '" + marker + "'")
            require(result.returncode == 0 and marker in result.stdout, "Concurrent session failed")
        with ThreadPoolExecutor(max_workers=3) as pool:
            list(pool.map(attempt, range(3)))

    check("three concurrent SSH sessions", concurrent)

    with tempfile.TemporaryDirectory(prefix="ssh-bridge-live-") as temp:
        root = Path(temp)

        def transfer():
            payload = os.urandom(1024 * 1024)
            source = root/"upload.bin"
            source.write_bytes(payload)
            marker = "ssh-bridge-test-" + uuid.uuid4().hex
            result = ps(args.alias, "$dir=Join-Path $env:TEMP '" + marker + "'\n"
                        "New-Item -ItemType Directory -Path $dir | Out-Null\nWrite-Output $dir")
            require(result.returncode == 0, "Could not create temporary transfer directory")
            remote_dir = result.stdout.strip().lstrip("\ufeff")
            require(remote_dir.endswith(marker), "Unexpected temporary directory")
            remote_file = remote_dir.replace("\\", "/") + "/transfer test.bin"
            scp = ["scp", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
            try:
                result = command(scp + [str(source), args.alias + ":" + remote_file])
                require(result.returncode == 0, "Upload failed")
                safe_file = remote_file.replace("'", "''")
                result = ps(args.alias, "(Get-FileHash -LiteralPath '" + safe_file + "' -Algorithm SHA256).Hash")
                require(result.returncode == 0 and result.stdout.strip().lower() == hashlib.sha256(payload).hexdigest(),
                        "Remote file checksum differs")
                downloaded = root/"download.bin"
                result = command(scp + [args.alias + ":" + remote_file, str(downloaded)])
                require(result.returncode == 0 and downloaded.read_bytes() == payload, "Downloaded bytes differ")
            finally:
                safe_dir = remote_dir.replace("'", "''")
                result = ps(args.alias, "Remove-Item -LiteralPath '" + safe_dir + "' -Recurse -Force")
                require(result.returncode == 0, "Temporary directory cleanup failed")

        check("1 MiB file transfer round trip with spaces and checksums", transfer)

        def blocked_shell():
            result = command(["ssh", "-T", "-o", "BatchMode=yes", args.relay_alias, "echo", "SHOULD_NOT_RUN"])
            require(result.returncode == 255 and "open failed" in result.stderr.lower()
                    and "SHOULD_NOT_RUN" not in result.stdout, "Relay shell was not explicitly rejected")

        check("public relay refuses shell sessions", blocked_shell)

        def blocked_forward():
            result = command(["ssh", "-T", "-o", "BatchMode=yes", "-W", "127.0.0.1:22", args.relay_alias])
            require(result.returncode != 0 and "administratively prohibited" in result.stderr,
                    "Relay did not reject the extra target port")

        check("public relay refuses forwarding to other ports", blocked_forward)

        stranger = root/"stranger"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(stranger)], check=True)

        def wrong_host_key():
            known = root/"wrong_known_hosts"
            # Use the target alias's configured trust label, not its network address.
            config = command(["ssh", "-G", args.alias])
            label = next(line.split(" ", 1)[1] for line in config.stdout.splitlines() if line.startswith("hostkeyalias "))
            known.write_text(label + " " + stranger.with_suffix(".pub").read_text())
            result = command(["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                              "-o", "UserKnownHostsFile=" + str(known), "-o", "GlobalKnownHostsFile=/dev/null",
                              args.alias, "whoami"])
            require(result.returncode != 0 and "REMOTE HOST IDENTIFICATION HAS CHANGED" in result.stderr,
                    "A mismatched workstation host key was not explicitly rejected")

        check("workstation host-key mismatch is rejected", wrong_host_key)

        def unknown_key():
            config = command(["ssh", "-G", args.relay_alias])
            values = dict(line.split(" ", 1) for line in config.stdout.splitlines() if " " in line)
            result = command(["ssh", "-F", "/dev/null", "-T", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
                              "-o", "ForwardAgent=no", "-o", "StrictHostKeyChecking=yes",
                              "-o", "UserKnownHostsFile=" + values["userknownhostsfile"],
                              "-o", "HostKeyAlias=" + values["hostkeyalias"], "-i", str(stranger),
                              "-p", values["port"], "-W", "127.0.0.1:22022", values["user"] + "@" + values["hostname"]])
            require(result.returncode != 0 and "Permission denied" in result.stderr,
                    "An unknown relay key was not explicitly rejected")

        check("public relay rejects an unknown private key", unknown_key)

    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps({"tests": results, "passed": all(r["passed"] for r in results)}, indent=2) + "\n")
    return 0 if all(r["passed"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
