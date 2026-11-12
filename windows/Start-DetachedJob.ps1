# Run a long job in the signed-in user's desktop session so an SSH disconnect
# does not terminate it. This does not survive Windows sign-out or reboot.
param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [string]$Arguments='',
    [string]$WorkingDirectory=$env:USERPROFILE,
    [ValidatePattern('^[A-Za-z0-9 _.-]{1,100}$')][string]$TaskName=('SSHBridge-Job-'+[Guid]::NewGuid().ToString('N'))
)
$ErrorActionPreference='Stop'
$program=(Get-Item -LiteralPath $FilePath).FullName
$directory=(Get-Item -LiteralPath $WorkingDirectory).FullName
$scheduler=New-Object -ComObject Schedule.Service
$scheduler.Connect()
$definition=$scheduler.NewTask(0)
$definition.RegistrationInfo.Description='Detached job started by SSH Bridge under the current user.'
$definition.Principal.UserId="$env:COMPUTERNAME\$env:USERNAME"
$definition.Principal.LogonType=3 # TASK_LOGON_INTERACTIVE_TOKEN; no stored password
$definition.Principal.RunLevel=0 # TASK_RUNLEVEL_LUA; no elevation
$definition.Settings.DisallowStartIfOnBatteries=$false
$definition.Settings.StopIfGoingOnBatteries=$false
$definition.Settings.ExecutionTimeLimit='PT0S'
$definition.Settings.MultipleInstances=2 # TASK_INSTANCES_IGNORE_NEW
$action=$definition.Actions.Create(0)
$action.Path=$program
$action.Arguments=$Arguments
$action.WorkingDirectory=$directory
$folder=$scheduler.GetFolder('\')
# TASK_CREATE only: never overwrite an existing task.
$task=$folder.RegisterTaskDefinition($TaskName,$definition,2,"$env:COMPUTERNAME\$env:USERNAME",$null,3)
$task.Run($null) | Out-Null
Write-Output $TaskName
