"""Install SSH aliases with host keys supplied through a trusted channel."""
import argparse
import os
from pathlib import Path
import re


def host_key(path):
    fields = Path(path).read_text().strip().split()
    if len(fields) < 2 or fields[0] != "ssh-ed25519" or not re.fullmatch(r"[A-Za-z0-9+/=]+", fields[1]):
        raise ValueError("Expected an Ed25519 public host-key file")
    return " ".join(fields[:2])


def quoted(path):
    value = str(Path(path).expanduser().resolve())
    if any(char in value for char in ('"', '\n', '\r')):
        raise ValueError("Invalid SSH configuration path")
    return '"' + value + '"'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--relay-identity", required=True)
    parser.add_argument("--laptop-identity", required=True)
    parser.add_argument("--relay-host-key", required=True)
    parser.add_argument("--laptop-host-key", required=True)
    parser.add_argument("--user", default="Student")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*", args.host) or not 1 <= args.port <= 65535:
        parser.error("Invalid relay hostname or port")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.user):
        parser.error("Invalid workstation username")
    for identity in (args.relay_identity, args.laptop_identity):
        if not Path(identity).expanduser().is_file():
            parser.error("Identity file does not exist: " + identity)
    keys = "isaac-relay " + host_key(args.relay_host_key) + "\nisaac-laptop " + host_key(args.laptop_host_key) + "\n"
    ssh = Path.home()/".ssh"
    includes = ssh/"config.d"
    includes.mkdir(parents=True, exist_ok=True, mode=0o700)
    known = ssh/"isaac_link_known_hosts"
    if known.exists() and known.read_text() != keys:
        raise ValueError("Existing pinned keys differ; verify the change before replacing them")
    config = includes/"isaac-link.conf"
    shared = ("    IdentitiesOnly yes\n    ForwardAgent no\n    StrictHostKeyChecking yes\n"
              "    UserKnownHostsFile " + quoted(known) + "\n"
              "    ServerAliveInterval 30\n    ServerAliveCountMax 3\n")
    content = (f"Host isaac-relay\n    HostName {args.host}\n    Port {args.port}\n"
               "    User client\n    HostKeyAlias isaac-relay\n    IdentityFile " + quoted(args.relay_identity) + "\n" + shared +
               f"\nHost isaac-student\n    HostName 127.0.0.1\n    Port 22022\n    User {args.user}\n"
               "    ProxyJump isaac-relay\n    HostKeyAlias isaac-laptop\n    IdentityFile " + quoted(args.laptop_identity) + "\n" + shared)
    main_config = ssh/"config"
    previous = main_config.read_text() if main_config.exists() else ""
    include = "Include " + quoted(config)
    if main_config.exists() and include not in previous.splitlines():
        backup = ssh/"config.before-isaac-link"
        if not backup.exists():
            backup.write_text(previous)
            backup.chmod(0o600)
    known.write_text(keys)
    known.chmod(0o600)
    config.write_text(content)
    config.chmod(0o600)
    if include not in previous.splitlines():
        main_config.write_text(include + "\n" + previous)
        main_config.chmod(0o600)
    print("Configured: ssh isaac-student")


if __name__ == "__main__":
    main()
