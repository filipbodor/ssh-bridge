$root=Join-Path $env:LOCALAPPDATA 'SSHBridge'
Remove-Item (Join-Path $root 'stop') -ErrorAction SilentlyContinue
Start-Process -FilePath (Join-Path $root 'SSHBridge.exe')
