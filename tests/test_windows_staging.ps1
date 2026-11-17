$ErrorActionPreference='Stop'
$root=Join-Path $env:TEMP ('ssh-bridge-stage-test-'+[guid]::NewGuid().ToString('N'))
$legacy=Join-Path $root 'legacy'
$stage=Join-Path $root 'new'
$key=Join-Path $root 'legacy-key'
$newKey=Join-Path $root 'new-key'
New-Item -ItemType Directory -Path $legacy -Force | Out-Null
try {
    [IO.File]::WriteAllText($key,'test-only private-key fixture')
    [IO.File]::WriteAllText("$key.pub",'ssh-ed25519 AAAATEST')
    [IO.File]::WriteAllText((Join-Path $legacy 'known_hosts'),"isaac-relay ssh-ed25519 AAAATEST`n")
    [IO.File]::WriteAllText((Join-Path $legacy 'connection.ini'),"host=relay.example.org`nport=44638`n")
    [IO.File]::WriteAllText((Join-Path $legacy 'IsaacLink.exe'),'legacy executable fixture')
    $files=@($key,"$key.pub",(Join-Path $legacy 'known_hosts'),(Join-Path $legacy 'connection.ini'),(Join-Path $legacy 'IsaacLink.exe'))
    $before=@{}; foreach($file in $files) { $before[$file]=(Get-FileHash $file).Hash }
    $startup=[Environment]::GetFolderPath('Startup')
    $shortcuts=@(Get-ChildItem $startup -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name | Sort-Object)
    $script=Join-Path $PSScriptRoot '..\windows\Stage-LegacyMigration.ps1'
    & $script -LegacyDirectory $legacy -DestinationDirectory $stage -LegacyKey $key -DestinationKey $newKey
    foreach($file in $files) { if ((Get-FileHash $file).Hash -ne $before[$file]) { throw "Legacy file modified: $file" } }
    if ((Get-FileHash $key).Hash -ne (Get-FileHash $newKey).Hash) { throw 'Device key changed.' }
    if ((Get-Content (Join-Path $stage 'known_hosts') -Raw).Trim() -ne 'ssh-bridge-relay ssh-ed25519 AAAATEST') { throw 'Host key not preserved.' }
    if (!(Test-Path (Join-Path $stage 'SSHBridge.exe'))) { throw 'No compiled connector.' }
    if (($shortcuts -join "`n") -cne (@(Get-ChildItem $startup -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name | Sort-Object) -join "`n")) { throw 'Startup entries changed.' }
    $refused=$false
    try { & $script -LegacyDirectory $legacy -DestinationDirectory $stage -LegacyKey $key -DestinationKey $newKey } catch { $refused=$true }
    if (!$refused) { throw 'Existing destination was not protected.' }
    Write-Output 'Staging preserves existing files and startup entries; refuses overwrites.'
} finally { Remove-Item $root -Recurse -Force }
