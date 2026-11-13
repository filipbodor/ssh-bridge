# Prepare the renamed connector without touching the only working remote route.
param(
    [string]$LegacyDirectory=(Join-Path $env:LOCALAPPDATA 'IsaacLink'),
    [string]$DestinationDirectory=(Join-Path $env:LOCALAPPDATA 'SSHBridge'),
    [string]$LegacyKey=(Join-Path $env:USERPROFILE '.ssh\isaac_relay_ed25519'),
    [string]$DestinationKey=(Join-Path $env:USERPROFILE '.ssh\ssh_bridge_relay_ed25519')
)
$ErrorActionPreference='Stop'
if ([IO.Path]::GetFullPath($LegacyDirectory) -eq [IO.Path]::GetFullPath($DestinationDirectory)) {
    throw 'Staging must use a separate directory.'
}
# Refuse to overwrite any existing installation or key, including a partial stage.
if ((Test-Path $DestinationDirectory) -or (Test-Path $DestinationKey)) {
    throw 'Destination already exists. Review it before staging again.'
}
foreach ($file in @($LegacyKey,"$LegacyKey.pub",(Join-Path $LegacyDirectory 'connection.ini'),(Join-Path $LegacyDirectory 'known_hosts'))) {
    if (!(Test-Path $file -PathType Leaf)) { throw "Missing legacy file: $file" }
}
$known=(Get-Content (Join-Path $LegacyDirectory 'known_hosts') -Raw).Trim()
if ($known -notmatch '^isaac-relay\s+(ssh-ed25519\s+[A-Za-z0-9+/=]+)\s*$') {
    throw 'Unexpected legacy host-key file; verify the pinned relay key manually.'
}
$hostKey=$Matches[1]
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (!(Test-Path $compiler)) { throw '.NET Framework C# compiler is not available.' }
New-Item -ItemType Directory -Path $DestinationDirectory | Out-Null
New-Item -ItemType Directory -Path (Split-Path $DestinationKey -Parent) -Force | Out-Null
Copy-Item $LegacyKey $DestinationKey
Set-Acl -Path $DestinationKey -AclObject (Get-Acl $LegacyKey)
Copy-Item "$LegacyKey.pub" "$DestinationKey.pub"
Copy-Item (Join-Path $LegacyDirectory 'connection.ini') (Join-Path $DestinationDirectory 'connection.ini')
[IO.File]::WriteAllText((Join-Path $DestinationDirectory 'known_hosts'), "ssh-bridge-relay $hostKey`r`n", [Text.Encoding]::ASCII)
$exe=Join-Path $DestinationDirectory 'SSHBridge.exe'
& $compiler /nologo /target:winexe "/out:$exe" (Join-Path $PSScriptRoot 'Connector.cs')
if ($LASTEXITCODE -ne 0) { throw 'Connector compilation failed. Legacy installation remains untouched.' }
# Deliberately do not start the new connector: only one device may publish the relay port.
# Do not alter the legacy shortcut, process, stop file, key, config, or scheduled task.
Write-Output 'Staged only. Existing connector and login startup remain unchanged.'
Write-Output 'Activation requires a separate, rollback-protected handoff and remote verification.'
