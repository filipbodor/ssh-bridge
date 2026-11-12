$root=Join-Path $env:LOCALAPPDATA 'IsaacLink'
Remove-Item (Join-Path $root 'stop') -ErrorAction SilentlyContinue
Start-Process -FilePath (Join-Path $root 'IsaacLink.exe')
