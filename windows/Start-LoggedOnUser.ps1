# Optional administrative bootstrap when installing through SSH. No password is stored.
param([Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9_.-]+$')][string]$User)
$ErrorActionPreference='Stop'
$account=Get-LocalUser -Name $User
$profile=Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($account.SID.Value)"
$directory=Join-Path $profile.ProfileImagePath 'AppData\Local\IsaacLink'
$exe=Join-Path $directory 'IsaacLink.exe'
if (!(Test-Path $exe)) { throw 'Install the connector for this user first.' }
$action=New-ScheduledTaskAction -Execute $exe -WorkingDirectory $directory
$principal=New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$User" -LogonType Interactive -RunLevel Limited
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
$name="Isaac Link - $User launcher"
Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings -Description 'Start the connector in an existing user desktop session. Login startup uses the per-user Startup shortcut.' -Force | Out-Null
Start-ScheduledTask -TaskName $name
Write-Output 'Launch requested. The target user must already be signed into Windows.'
