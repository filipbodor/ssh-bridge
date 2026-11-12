"""Run a PowerShell script on the Dell using pinned SSH host authentication."""
import argparse
import base64
import subprocess
import sys
from pathlib import Path


def run(script, host, known_hosts, user="Student", timeout=45):
    script = ("[Console]::OutputEncoding=[System.Text.Encoding]::UTF8\n"
              "$OutputEncoding=[System.Text.Encoding]::UTF8\n"
              "$ProgressPreference='SilentlyContinue'\n" + script)
    encoded = base64.b64encode(script.encode("utf-16le")).decode()
    return subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ForwardAgent=no",
         "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8",
         "-o", f"UserKnownHostsFile={known_hosts}",
         "-o", "IdentitiesOnly=yes", "-i", str(Path.home() / '.ssh/id_ed25519'),
         f"{user}@{host}", "powershell.exe", "-NoProfile",
         "-NonInteractive", "-EncodedCommand", encoded],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout,
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--user", default="Student")
    parser.add_argument("--host", required=True)
    parser.add_argument("--known-hosts", required=True)
    args = parser.parse_args()
    result = run(sys.stdin.read(), args.host, args.known_hosts, args.user)
    print(result.stdout, end="")
    print(result.stderr, end="", file=sys.stderr)
    sys.exit(result.returncode)
