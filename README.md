# Isaac Link

Reach a Windows workstation over ordinary SSH when neither computer has a public
IP address or router access. A small OpenSSH relay runs on Railway (or any Docker
host). The workstation connects outward at Windows login; a Mac or Linux client
connects through the relay. GPU workloads stay on the workstation.

```text
Mac / Linux -- SSH client role --> relay <-- SSH device role -- Windows
                    encrypted inner SSH session --> Student account
```

This is a small, single-workstation setup, not a general VPN. It can be used for
other workloads besides Isaac Sim. It requires an existing Windows OpenSSH server,
an authorized workstation login key, an internet connection, and an awake laptop.

## Security model

- Distinct keys authenticate the workstation and client to the relay.
- The device role may create only `127.0.0.1:22022` on the relay.
- The client role may connect only to that loopback port.
- Neither role can open a shell, agent forwarding, a TTY, or a general proxy.
- The workstation authenticates the client again using its normal SSH key.
- Host keys are pinned at both hops. Never populate trusted keys from an
  unauthenticated network scan without comparing their fingerprints independently.
- The relay sees connection metadata and encrypted inner SSH traffic. It cannot
  decrypt the inner connection when the workstation host key is verified.
- No GitHub, Railway or AI account credentials belong on the workstation.
- The Windows administrator can inspect and modify the workstation, including
  its files and connector key. The connector key grants only its restricted
  relay role; it does not authenticate to the client computer.

## Deploy the relay

Generate an Ed25519 host key and a separate client-to-relay key outside the
repository. The Windows installer generates its own device key if needed.

```sh
ssh-keygen -t ed25519 -f /secure/path/relay_host_ed25519
ssh-keygen -t ed25519 -f ~/.ssh/isaac_relay_client
```

The relay host key must have no passphrase for unattended startup. A client key
may use a passphrase when a local SSH agent is available; keep agent forwarding
disabled. Keep these private keys out of Git and the Docker build context.

Create a Railway service from this repository. Configure these variables in
Railway's secret storage:

| Variable | Value |
| --- | --- |
| `RELAY_HOST_KEY_B64` | Base64 of the relay host private-key file |
| `DEVICE_PUBLIC_KEY` | One `ssh-ed25519 ...` public key from Windows |
| `CLIENT_PUBLIC_KEY` | One `ssh-ed25519 ...` client public key |

The image deliberately fails to start if any required key is absent. Host keys
must persist across deployments through the secret variable; a volume is not
needed. Use exactly one replica and disable service sleeping. Add a Railway TCP
proxy for internal port **2222** and record the assigned hostname and public port.
Only the relay SSH listener is public; the workstation forwarding port remains
on relay loopback.

## Install on Windows

Run as the Windows account that will perform the work, normally a standard user.
Windows OpenSSH Server must already be configured to start automatically and
accept that account's login key. The connector itself needs no administrator
rights, no VPN driver, and no PowerShell execution-policy changes.

From a PowerShell session where local scripts are permitted:

```powershell
.\windows\Install.ps1 -RelayHost relay.example.net -RelayPort 12345 -RelayHostPublicKey 'ssh-ed25519 REPLACE_HOST_PUBLIC_KEY'
```

If script execution is restricted, an administrator should review and sign or
deploy the installer according to the machine's policy. Do not disable policy
protections globally. The compiled connector runs without PowerShell.

The installer uses the built-in .NET Framework C# compiler, stores the app in
`%LOCALAPPDATA%\IsaacLink`, pins the relay host key, and creates an **Isaac Link**
shortcut in the current user's Startup folder. Authorize the printed device
public key on the relay before expecting it to connect.

The connector retries after network errors, detects dead connections with SSH
keepalives, and prevents duplicate instances within the same Windows session.
Logs are capped to two approximately 1 MiB files. Run `windows/Stop.ps1` to stop
it and `windows/Start.ps1` to resume. Removing the Startup shortcut disables
automatic launch; it does not uninstall or stop Windows OpenSSH Server.

The supervisor turns on the machine, signs into the configured Windows user,
and leaves it powered, online and awake. Connecting does not wake a sleeping
computer. Signing out terminates that user's connector; locking the screen
normally leaves it running.

## Connect from Mac or Linux

Copy `examples/ssh_config` into your private SSH configuration and replace its
placeholders. Keep the pinned relay and workstation public host keys in
`~/.ssh/isaac_link_known_hosts`, using aliases `isaac-relay` and `isaac-laptop`.

```sh
ssh isaac-student
ssh isaac-student whoami
scp results.txt isaac-student:results.txt
```

An AI agent on the client can invoke the same SSH alias, keeping its AI account
credentials on the client. This provides terminal and file access, not automatic
streaming of the remote desktop. Unattended training should save checkpoints
and be launched independently of the lifetime of an interactive SSH session.

## Costs and operations

The relay needs no GPU, database or persistent volume. It consumes memory while
running, CPU during connections and encryption, and billable egress for relayed
traffic. Measure actual use instead of assuming it will remain free. Prefer
terminal output over continuous video, and avoid repeatedly copying large model
files. A Railway workspace spending cap can affect unrelated services too.

Keep OpenSSH packages updated by rebuilding the image. A relay deployment briefly
interrupts sessions; the Windows connector reconnects automatically. If a key is
compromised, replace that role's public key and redeploy. Remove the corresponding
workstation authorized key separately if workstation access must be revoked.

## Verify locally

Requires Docker, Python 3 and OpenSSH client tools:

```sh
docker build -t isaac-link-relay:local .
python3 -m unittest discover -s tests -v
```

Tests create temporary keys and a disposable local relay. They verify forwarding
and reject extra ports, role crossover, shell sessions and unknown keys. No
deployment credentials are required. The Windows CI job compiles the connector.

MIT licensed. Runtime packages in the container retain their respective licenses.
