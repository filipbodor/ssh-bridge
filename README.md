# SSH Bridge

Reach a Windows workstation over ordinary SSH when neither computer has a public
IP address or router access. A small OpenSSH relay runs on Railway (or any Docker
host). The workstation connects outward at Windows login; a Mac or Linux client
connects through the relay. GPU workloads stay on the workstation.

```text
Mac / Linux -- SSH client role --> relay <-- SSH device role -- Windows
                    encrypted inner SSH session --> Student account
```

This is a small, single-workstation setup, not a general VPN. It works with any
terminal-based workload and requires an existing Windows OpenSSH server,
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

## Existing installations and the naming migration

New installs use `SSHBridge.exe`, `%LOCALAPPDATA%\SSHBridge`, and the aliases
`ssh-bridge-relay` / `ssh-bridge-workstation`. The relay protocol, usernames,
forwarding ports, environment-variable names and key material have not changed.
An existing connector remains compatible with the renamed relay source.

The client configurator adds `ssh-bridge.conf` and a separate pinned-host file.
It leaves existing includes, aliases and identity files untouched, so old SSH
commands remain available during migration. Do not remove the old configuration
until both routes have been verified against the real workstation.

For a Windows installation originally named Isaac Link, use
`windows/Stage-LegacyMigration.ps1` **only when the workstation is reachable**.
It compiles the renamed connector in a separate folder, copies the existing
identity with its ACL, preserves the relay address/port and pinned public key,
and refuses existing destinations. It does not start or stop a connector, change
a startup shortcut, or remove the legacy files. Old names appear only in this
migration helper and migration tests; there is one connector implementation.

Staging is not activation. Do not run the fresh installer over a legacy remote
installation or launch both connectors: only one can own the forwarded port.
A later activation must have an independent automatic rollback, remote login
verification and a subsequent reboot/sign-in check before removing the legacy
startup entry. Staging deliberately provides no automatic switchover.
Keep the running Railway endpoint and keys unchanged while the workstation is
offline; deploying the renamed image is a separate operation.

## Deploy the relay

Generate an Ed25519 host key and a separate client-to-relay key outside the
repository. The Windows installer generates its own device key if needed.

```sh
ssh-keygen -t ed25519 -f /secure/path/relay_host_ed25519
ssh-keygen -t ed25519 -f ~/.ssh/ssh_bridge_relay_client
```

The relay host key must have no passphrase for unattended startup. A client key
may use a passphrase when a local SSH agent is available; keep agent forwarding
disabled. Keep these private keys out of Git and the Docker build context.

Create a Railway service from this repository using its Dockerfile. Configure these variables in
Railway's secret storage:

| Variable | Value |
| --- | --- |
| `RELAY_HOST_KEY_B64` | Base64 of the relay host private-key file |
| `DEVICE_PUBLIC_KEY` | One `ssh-ed25519 ...` public key from Windows |
| `CLIENT_PUBLIC_KEY` | One `ssh-ed25519 ...` client public key |

The image deliberately fails to start if any required key is absent. Host keys
must persist across deployments through the secret variable; a volume is not
needed. In the service settings, use exactly one replica, disable service sleeping,
and select an on-failure restart policy. Railway's legacy `railway.toml` config is
not used. Add a Railway TCP
proxy for internal port **2222** and record the assigned hostname and public port.
Only the relay SSH listener is public; the workstation forwarding port remains
on relay loopback.

For a custom hostname, create a DNS-only CNAME to the assigned Railway TCP
hostname. The assigned public TCP port is still required. HTTP domain routing
and HTTPS proxies do not replace an SSH TCP endpoint.

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
`%LOCALAPPDATA%\SSHBridge`, pins the relay host key, and creates an **SSH Bridge**
shortcut in the current user's Startup folder. Authorize the printed device
public key on the relay before expecting it to connect.

The connector retries after network errors, detects dead connections with SSH
keepalives, and prevents duplicate instances within the same Windows session.
Logs are capped to two approximately 1 MiB files. Run `windows/Stop.ps1` to stop
it and `windows/Start.ps1` to resume. Removing the Startup shortcut disables
automatic launch; it does not uninstall or stop Windows OpenSSH Server.

When installing through an SSH session, use `-NoStart`: Windows may terminate
child processes when that session closes. If the target user is already signed
into the desktop, an administrator can run
`windows/Start-LoggedOnUser.ps1 -User Student` to start the connector in that
existing desktop session without storing the user's password. This creates an
on-demand task running with the user's limited token. The Startup shortcut
remains responsible for automatic launch on future logins.

The supervisor turns on the machine, signs into the configured Windows user,
and leaves it powered, online and awake. Connecting does not wake a sleeping
computer. Signing out terminates that user's connector; locking the screen
normally leaves it running.

## Connect from Mac or Linux

Use the configurator with public host-key files obtained through a trusted channel:

```sh
python3 client/configure.py --host relay.example.net --port 12345 \
  --relay-identity ~/.ssh/ssh_bridge_relay_client --laptop-identity ~/.ssh/id_ed25519 \
  --relay-host-key /secure/path/relay_host_ed25519.pub \
  --laptop-host-key /secure/path/workstation_host_ed25519.pub
```

It adds a dedicated SSH config include, preserves existing configuration and
refuses to silently replace different pinned keys. Alternatively, copy
`examples/ssh_config` into your private SSH configuration and replace its
placeholders. Keep the pinned relay and workstation public host keys in
`~/.ssh/ssh_bridge_known_hosts`, using aliases `ssh-bridge-relay` and `ssh-bridge-workstation`.

```sh
ssh ssh-bridge-workstation
ssh ssh-bridge-workstation whoami
scp results.txt ssh-bridge-workstation:results.txt
```

An AI agent on the client can invoke the same SSH alias, keeping its AI account
credentials on the client. This provides terminal and file access, not automatic
streaming of the remote desktop.

### Long-running jobs

An ordinary SSH disconnect can terminate processes launched directly from that
shell. To run a training job independently, invoke `windows/Start-DetachedJob.ps1`
under the standard Windows user, supplying the interpreter's full path, its
arguments and a working directory. For example:

```powershell
.\windows\Start-DetachedJob.ps1 -FilePath 'C:\Python311\python.exe' -Arguments 'train.py --headless' -WorkingDirectory 'C:\work\training'
```

The helper uses Task Scheduler's COM interface, which also works when the
PowerShell ScheduledTasks CIM cmdlets are inaccessible over SSH. It creates a
uniquely named task with the current user's limited interactive token and no
stored password. The user must remain signed into Windows. Configure the job
itself to write logs and checkpoints; sign-out, shutdown and reboot still stop
the job. Manage or remove the returned task name using Windows Task Scheduler.

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
docker build -t ssh-bridge-relay:local .
python3 -m unittest discover -s tests -v
```

Tests create temporary keys and a disposable local relay. They verify forwarding
and reject extra ports, role crossover, shell sessions and unknown keys. No
deployment credentials are required. The Windows CI job compiles the connector.

After deploying, run the explicit live check against your configured aliases:

```sh
python3 tools/verify_live.py --alias ssh-bridge-workstation --relay-alias ssh-bridge-relay \
  --expected-user 'WORKSTATION\user' --report .state/live-verification.json
```

This verifies the Windows user token, concurrent sessions, a checksum-verified
file transfer round trip, and authentication/forwarding restrictions on the
actual public endpoint. It creates and removes a uniquely named directory under
the workstation's temporary directory. Test a real Windows restart and sign-in,
and a change of network, before relying on unattended access.

MIT licensed. Runtime packages in the container retain their respective licenses.
