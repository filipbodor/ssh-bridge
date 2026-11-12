param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')][string]$RelayHost,
    [Parameter(Mandatory=$true)][ValidateRange(1,65535)][int]$RelayPort,
    [Parameter(Mandatory=$true)][string]$RelayHostPublicKey,
    [switch]$NoStart
)
$ErrorActionPreference='Stop'
$install=Join-Path $env:LOCALAPPDATA 'IsaacLink'
$sshDir=Join-Path $env:USERPROFILE '.ssh'
$key=Join-Path $sshDir 'isaac_relay_ed25519'
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$executable=Join-Path $install 'IsaacLink.exe'
if (!(Test-Path $compiler)) { throw '.NET Framework C# compiler is not available.' }
$parts=$RelayHostPublicKey.Trim() -split '\s+'
if ($parts.Count -lt 2 -or $parts[0] -ne 'ssh-ed25519' -or $parts[1] -notmatch '^[A-Za-z0-9+/=]+$') {
    throw 'Expected a pinned Ed25519 relay host public key.'
}
New-Item -ItemType Directory -Path $install -Force | Out-Null
New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
if (!(Test-Path $key)) {
    $command='"' + "$env:WINDIR\System32\OpenSSH\ssh-keygen.exe" + '" -q -t ed25519 -f "' + $key + '" -N "" -C isaac-device'
    & cmd.exe /c $command
    if ($LASTEXITCODE -ne 0) { throw 'Could not generate device key.' }
}
& $compiler /nologo /target:winexe "/out:$executable" (Join-Path $PSScriptRoot 'Connector.cs')
if ($LASTEXITCODE -ne 0) { throw 'Connector compilation failed.' }
[IO.File]::WriteAllText((Join-Path $install 'connection.ini'), "host=$RelayHost`r`nport=$RelayPort`r`n", [Text.Encoding]::ASCII)
[IO.File]::WriteAllText((Join-Path $install 'known_hosts'), "isaac-relay $($parts[0]) $($parts[1])`r`n", [Text.Encoding]::ASCII)
Remove-Item (Join-Path $install 'stop') -ErrorAction SilentlyContinue
$startup=[Environment]::GetFolderPath('Startup')
$shell=New-Object -ComObject WScript.Shell
$shortcut=$shell.CreateShortcut((Join-Path $startup 'Isaac Link.lnk'))
$shortcut.TargetPath=$executable
$shortcut.WorkingDirectory=$install
$shortcut.Description='Connect this laptop to its SSH relay'
$shortcut.Save()
if (!$NoStart) { Start-Process -FilePath $executable }
Write-Output 'Installed for the current Windows user. Device public key:'
Get-Content "$key.pub"
