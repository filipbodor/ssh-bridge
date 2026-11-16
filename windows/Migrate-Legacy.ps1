# Guard a connector handoff with a separate Task Scheduler watchdog.
# The legacy app/key remain available until a later reboot has been verified.
param(
    [ValidateSet('Initialize','Launch','Begin','Watch','Confirm','Rollback','Status','Library')][string]$Mode='Status',
    [string]$StateDirectory=(Join-Path $env:LOCALAPPDATA 'SSHBridge\Migration'),
    [string]$LegacyDirectory=(Join-Path $env:LOCALAPPDATA 'IsaacLink'),
    [string]$NewDirectory=(Join-Path $env:LOCALAPPDATA 'SSHBridge'),
    [string]$StartupDirectory=[Environment]::GetFolderPath('Startup'),
    [ValidatePattern('^[A-Za-z0-9 _.-]{1,70}$')][string]$TaskPrefix='SSHBridge Migration',
    [ValidateRange(30,900)][int]$ConfirmationSeconds=240
)
$ErrorActionPreference='Stop'

function Write-JsonAtomic($Path,$Value) {
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temp,($Value | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    if (Test-Path $Path) { [IO.File]::Replace($temp,$Path,$null) } else { [IO.File]::Move($temp,$Path) }
}
function Read-Json($Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
function Utc-Now { [DateTime]::UtcNow }
function Add-Log($Text) { Add-Content -LiteralPath (Join-Path $StateDirectory 'migration.log') -Value ((Utc-Now).ToString('o')+' '+$Text) }
function Find-Connector($Path) { @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Path)) -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Path }) }
function Scheduler-Folder { $s=New-Object -ComObject Schedule.Service; $s.Connect(); $s.GetFolder('\') }
function Start-OwnedTask($Name) { $null=(Scheduler-Folder).GetTask($Name).Run($null) }
function Stop-OwnedTask($Name) { $task=(Scheduler-Folder).GetTask($Name); if ($task.State -eq 4) { $task.Stop(0) } }
function New-OwnedTask($Name,$Program,$Arguments,$Directory) {
    $s=New-Object -ComObject Schedule.Service; $s.Connect(); $folder=$s.GetFolder('\')
    $exists=$null; try { $exists=$folder.GetTask($Name) } catch {}
    if ($exists) { throw "Task already exists; refusing overwrite: $Name" }
    $d=$s.NewTask(0)
    $d.RegistrationInfo.Description='SSH Bridge guarded legacy migration; no stored password.'
    $d.Principal.UserId="$env:COMPUTERNAME\$env:USERNAME"; $d.Principal.LogonType=3; $d.Principal.RunLevel=0
    $d.Settings.DisallowStartIfOnBatteries=$false; $d.Settings.StopIfGoingOnBatteries=$false
    $d.Settings.ExecutionTimeLimit='PT0S'; $d.Settings.MultipleInstances=2
    $a=$d.Actions.Create(0); $a.Path=$Program; $a.Arguments=$Arguments; $a.WorkingDirectory=$Directory
    $null=$folder.RegisterTaskDefinition($Name,$d,2,"$env:COMPUTERNAME\$env:USERNAME",$null,3)
}
function With-StateLock($Action) {
    $mutex=[Threading.Mutex]::new($false,('Local\SSHBridgeMigrationState-'+$env:USERNAME))
    try {
        if (!$mutex.WaitOne(15000)) { throw 'Migration state lock timed out.' }
        try { & $Action } finally { $mutex.ReleaseMutex() }
    } finally { $mutex.Dispose() }
}
function Invoke-Rollback($Config,$ExpectedAttempt=$null) {
    With-StateLock {
        $state=Read-Json $Config.StateFile
        if ($ExpectedAttempt -and ($state.attemptId -ne $ExpectedAttempt -or $state.phase -eq 'confirmed')) { return }
        Add-Log 'Rollback requested; stopping only the staged connector.'
        New-Item -ItemType File -Path (Join-Path $Config.NewDirectory 'stop') -Force | Out-Null
        for($i=0;$i -lt 15 -and (Find-Connector $Config.NewExe).Count -gt 0;$i++) { Start-Sleep -Seconds 1 }
        Stop-OwnedTask $Config.NewTask
        Copy-Item -LiteralPath $Config.LegacyShortcutBackup -Destination $Config.LegacyShortcut -Force
        if (Test-Path $Config.NewShortcut) {
            $link=(New-Object -ComObject WScript.Shell).CreateShortcut($Config.NewShortcut)
            if ($link.Arguments -notlike ('*'+$StateDirectory+'*')) { throw 'Unrecognized new startup shortcut; refusing removal.' }
            Remove-Item -LiteralPath $Config.NewShortcut
        }
        Remove-Item (Join-Path $Config.LegacyDirectory 'stop') -ErrorAction SilentlyContinue
        Start-OwnedTask $Config.LegacyTask
        $state.phase='rolled_back'; $state.finished=(Utc-Now).ToString('o')
        Write-JsonAtomic $Config.StateFile $state
        Add-Log 'Legacy startup restored and legacy connector launch requested.'
    }
}

if ($Mode -eq 'Library') { return }
if ($Mode -eq 'Initialize') {
    if (Test-Path $StateDirectory) { throw 'Migration directory exists; inspect it rather than overwrite recovery state.' }
    $legacyExe=Join-Path $LegacyDirectory 'IsaacLink.exe'; $newExe=Join-Path $NewDirectory 'SSHBridge.exe'
    $legacyShortcut=Join-Path $StartupDirectory 'Isaac Link.lnk'; $newShortcut=Join-Path $StartupDirectory 'SSH Bridge.lnk'
    foreach($file in @($legacyExe,$newExe,$legacyShortcut)) { if (!(Test-Path $file -PathType Leaf)) { throw "Missing: $file" } }
    if (Test-Path $newShortcut) { throw 'New startup shortcut already exists.' }
    if ((Get-Content (Join-Path $LegacyDirectory 'connection.ini') -Raw) -cne (Get-Content (Join-Path $NewDirectory 'connection.ini') -Raw)) { throw 'Relay endpoint changed.' }
    New-Item -ItemType Directory -Path $StateDirectory | Out-Null
    $script=Join-Path $StateDirectory 'Migrate-Legacy.ps1'; Copy-Item -LiteralPath $PSCommandPath -Destination $script
    $backup=Join-Path $StateDirectory 'legacy-startup.lnk'; Copy-Item -LiteralPath $legacyShortcut -Destination $backup
    $config=[ordered]@{StateFile=(Join-Path $StateDirectory 'state.json'); LegacyDirectory=$LegacyDirectory; NewDirectory=$NewDirectory; LegacyExe=$legacyExe; NewExe=$newExe; LegacyShortcut=$legacyShortcut; NewShortcut=$newShortcut; LegacyShortcutBackup=$backup; Script=$script; Shell=(Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'); ControllerTask=($TaskPrefix+' Controller'); WatchTask=($TaskPrefix+' Watchdog'); NewTask=($TaskPrefix+' Connector'); LegacyTask=($TaskPrefix+' Recovery'); ConfirmationSeconds=$ConfirmationSeconds}
    Write-JsonAtomic (Join-Path $StateDirectory 'config.json') $config
    Write-JsonAtomic $config.StateFile ([ordered]@{phase='initialized';attemptId='';deadline='';newPid=0;finished='';error=''})
    $base='-NoProfile -NonInteractive -WindowStyle Hidden -File "'+$script+'" -StateDirectory "'+$StateDirectory+'" -Mode '
    New-OwnedTask $config.WatchTask $config.Shell ($base+'Watch') $StateDirectory
    New-OwnedTask $config.NewTask $newExe '' $NewDirectory
    New-OwnedTask $config.LegacyTask $legacyExe '' $LegacyDirectory
    New-OwnedTask $config.ControllerTask $config.Shell ($base+'Begin') $StateDirectory
    Add-Log 'Initialized independent watchdog/controller/connector/recovery tasks; no running connector changed.'
    Write-Output 'Initialized. Launch performs the guarded handoff; Confirm must follow a fresh verified SSH login.'
    exit
}
$config=Read-Json (Join-Path $StateDirectory 'config.json')
if ($Mode -eq 'Status') { Get-Content $config.StateFile; exit }
if ($Mode -eq 'Launch') { Start-OwnedTask $config.ControllerTask; Write-Output 'Detached guarded handoff requested.'; exit }
if ($Mode -eq 'Watch') {
    $state=Read-Json $config.StateFile; $attempt=$state.attemptId
    Write-JsonAtomic (Join-Path $StateDirectory 'watchdog-ready.json') @{attemptId=$attempt;pid=$PID;ready=(Utc-Now).ToString('o')}
    Add-Log ('Independent watchdog armed for attempt '+$attempt)
    while($true) {
        $state=Read-Json $config.StateFile
        if ($state.attemptId -ne $attempt -or $state.phase -eq 'confirmed' -or $state.phase -eq 'rolled_back') { break }
        if ((Utc-Now) -ge [DateTime]::Parse($state.deadline).ToUniversalTime()) { Invoke-Rollback $config $attempt; break }
        Start-Sleep -Seconds 1
    }
    exit
}
if ($Mode -eq 'Begin') {
    if ((Find-Connector $config.NewExe).Count -gt 0) { Add-Log 'New connector already running; no duplicate handoff.'; exit }
    $state=[ordered]@{phase='armed';attemptId=[guid]::NewGuid().ToString('N');deadline=(Utc-Now).AddSeconds($config.ConfirmationSeconds).ToString('o');newPid=0;finished='';error=''}
    Write-JsonAtomic $config.StateFile $state
    Remove-Item (Join-Path $StateDirectory 'watchdog-ready.json') -ErrorAction SilentlyContinue
    Start-OwnedTask $config.WatchTask
    $ready=$false
    for($i=0;$i -lt 20;$i++) {
        $path=Join-Path $StateDirectory 'watchdog-ready.json'
        if ((Test-Path $path) -and (Read-Json $path).attemptId -eq $state.attemptId) { $ready=$true; break }
        Start-Sleep -Seconds 1
    }
    if (!$ready) { throw 'Independent watchdog did not arm; legacy connector was not touched.' }
    try {
        Add-Log 'Watchdog ready. Requesting legacy connector stop.'
        New-Item -ItemType File -Path (Join-Path $config.LegacyDirectory 'stop') -Force | Out-Null
        for($i=0;$i -lt 25 -and (Find-Connector $config.LegacyExe).Count -gt 0;$i++) { Start-Sleep -Seconds 1 }
        if ((Find-Connector $config.LegacyExe).Count -gt 0) { throw 'Legacy connector did not exit cooperatively.' }
        Remove-Item (Join-Path $config.NewDirectory 'stop') -ErrorAction SilentlyContinue
        Start-OwnedTask $config.NewTask
        $process=$null
        for($i=0;$i -lt 20;$i++) { $process=Find-Connector $config.NewExe | Select-Object -First 1; if ($process) { break }; Start-Sleep -Seconds 1 }
        if (!$process) { throw 'New connector did not start.' }
        $state.newPid=$process.Id; $state.phase='awaiting_confirmation'; Write-JsonAtomic $config.StateFile $state
        Add-Log ('New connector PID '+$process.Id+' started; awaiting a fresh remote confirmation.')
    } catch { Add-Log $_.Exception.Message; throw }
    exit
}
if ($Mode -eq 'Confirm') {
    With-StateLock {
        $state=Read-Json $config.StateFile
        if ($state.phase -ne 'awaiting_confirmation') { throw 'No handoff awaiting confirmation.' }
        if ((Utc-Now).AddSeconds(15) -ge [DateTime]::Parse($state.deadline).ToUniversalTime()) { throw 'Too close to rollback deadline; let rollback finish and try again.' }
        $process=Find-Connector $config.NewExe | Where-Object {$_.Id -eq $state.newPid}
        if (!$process) { throw 'Expected new connector is not running.' }
        $link=(New-Object -ComObject WScript.Shell).CreateShortcut($config.NewShortcut)
        $link.TargetPath=$config.Shell; $link.Arguments='-NoProfile -NonInteractive -WindowStyle Hidden -File "'+$config.Script+'" -Mode Launch -StateDirectory "'+$StateDirectory+'"'; $link.WorkingDirectory=$StateDirectory; $link.Description='Start SSH Bridge with timed legacy recovery'; $link.WindowStyle=7; $link.Save()
        # The saved backup is retained, and rollback restores it if confirmation fails.
        Remove-Item -LiteralPath $config.LegacyShortcut -ErrorAction SilentlyContinue
        $state.phase='confirmed';$state.finished=(Utc-Now).ToString('o');Write-JsonAtomic $config.StateFile $state
        Add-Log 'Fresh SSH route confirmed. New guarded login shortcut installed; legacy recovery retained.'
        Write-Output 'Confirmed. Next Windows login starts a new guarded attempt and needs a fresh confirmation, otherwise it returns to legacy automatically.'
    }
    exit
}
if ($Mode -eq 'Rollback') { Invoke-Rollback $config; Write-Output 'Rollback requested.' }
