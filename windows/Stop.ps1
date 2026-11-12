$root=Join-Path $env:LOCALAPPDATA 'IsaacLink'
New-Item -ItemType File -Path (Join-Path $root 'stop') -Force | Out-Null
Write-Output 'Connector will stop within a second. Local Windows SSH stays running.'
