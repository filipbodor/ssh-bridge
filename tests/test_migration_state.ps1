# Test confirmation/rollback state safety with task scheduling isolated behind adapters.
$ErrorActionPreference='Stop'
$root=Join-Path $env:TEMP ('ssh-bridge-state-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    . (Join-Path $PSScriptRoot '..\windows\Migrate-Legacy.ps1') -Mode Library -StateDirectory $root
    $username=$env:USERNAME
    try {
        $env:USERNAME=$username.ToLower();$lower=State-MutexName
        $env:USERNAME=$username.ToUpper();$upper=State-MutexName
        if ($lower -cne $upper -or !$lower.StartsWith('Global\SSHBridgeMigrationState-S-')) { throw 'Migration mutex must use a cross-session, casing-independent user identity.' }
    } finally { $env:USERNAME=$username }
    function Start-OwnedTask($Name) { $script:launched=$Name }
    function Stop-OwnedTask($Name) { $script:stopped=$Name }
    function Find-Connector($Path) { @() }
    $config=[pscustomobject]@{StateFile=(Join-Path $root 'state.json');NewDirectory=(Join-Path $root 'new');LegacyDirectory=(Join-Path $root 'old');NewExe='fixture.exe';NewTask='new-fixture';LegacyTask='old-fixture';LegacyShortcutBackup=(Join-Path $root 'backup.lnk');LegacyShortcut=(Join-Path $root 'old.lnk');NewShortcut=(Join-Path $root 'new.lnk')}
    New-Item -ItemType Directory -Path $config.NewDirectory,$config.LegacyDirectory | Out-Null
    [IO.File]::WriteAllText($config.LegacyShortcutBackup,'original startup fixture')
    [IO.File]::WriteAllText((Join-Path $config.LegacyDirectory 'stop'),'')
    Write-JsonAtomic $config.StateFile @{phase='confirmed';attemptId='one';deadline='';newPid=12;finished='';error=''}
    Invoke-Rollback $config 'one'
    if ((Read-Json $config.StateFile).phase -ne 'confirmed' -or $script:launched) { throw 'Confirmed attempt was rolled back by a stale watchdog.' }
    Write-JsonAtomic $config.StateFile @{phase='awaiting_confirmation';attemptId='two';deadline='';newPid=12;finished='';error=''}
    Invoke-Rollback $config 'one'
    if ((Read-Json $config.StateFile).phase -ne 'awaiting_confirmation') { throw 'Stale attempt changed newer state.' }
    Invoke-Rollback $config 'two'
    if ((Read-Json $config.StateFile).phase -ne 'rolled_back') { throw 'Pending attempt did not roll back.' }
    if ($script:launched -ne 'old-fixture' -or $script:stopped -ne 'new-fixture') { throw 'Wrong task adapters called.' }
    if (Test-Path (Join-Path $config.LegacyDirectory 'stop')) { throw 'Legacy connector remains inhibited.' }
    if ((Get-Content $config.LegacyShortcut -Raw) -ne 'original startup fixture') { throw 'Original startup not restored.' }
    if (!(Test-Path (Join-Path $config.NewDirectory 'stop'))) { throw 'New connector not inhibited.' }
    Write-Output 'Migration state tests passed: stale/confirmed watchdogs cannot roll back; pending attempts restore legacy.'
} finally { Remove-Item $root -Force -Recurse }
