# GitHub Windows runners are elevated. Exercise the actual supported desktop
# account context outside the runner's non-breakaway Windows job.
param([Parameter(Mandatory)][string]$Gateway, [Parameter(Mandatory)][string]$Codex)
$ErrorActionPreference = 'Stop'
$user = 'cld' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$password = 'A1!' + [guid]::NewGuid().ToString('N')
$root = Join-Path $env:SystemDrive ($user + '-smoke')
$python = (Get-Command python).Source
$created = $false
$task = $user + '-daemon-smoke'
$registered = $false
try {
    New-LocalUser -Name $user -Password (ConvertTo-SecureString $password -AsPlainText -Force) -AccountNeverExpires | Out-Null
    $created = $true
    Add-LocalGroupMember -Group (Get-LocalGroup -SID 'S-1-5-32-545').Name -Member $user
    New-Item -ItemType Directory $root, "$root\tmp", "$root\package" | Out-Null
    & icacls $root /grant "${user}:(OI)(CI)F" /T | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Test directory ACL failed' }
    Copy-Item $Gateway "$root\CodexLink.Server.exe"
    $packageRoot = Split-Path (Split-Path $Codex)
    if (!(Test-Path "$packageRoot\codex-package.json")) { throw 'Complete Codex package required' }
    Copy-Item "$packageRoot\*" "$root\package" -Recurse
    Copy-Item "$PSScriptRoot\smoke-daemon.py" "$root\smoke.py"
    # All interpolated paths are generated locally, not user input.
    @"
`$ErrorActionPreference = 'Stop'
`$env:TEMP = '$root\tmp'
`$env:TMP = '$root\tmp'
try {
    & '$python' '$root\smoke.py' '$root\CodexLink.Server.exe' '$root\package\bin\codex.exe' *> '$root\output.log'
    `$code = `$LASTEXITCODE
} catch {
    `$_ | Out-File '$root\output.log' -Append
    `$code = 1
}
Set-Content '$root\result.txt' `$code
exit `$code
"@ | Set-Content "$root\run.ps1"
    $powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"& '$root\run.ps1' *> '$root\launcher.log'`""
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments -WorkingDirectory $root
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $task -Action $action -Settings $settings -User "$env:COMPUTERNAME\$user" -Password $password -RunLevel Limited -Force | Out-Null
    $registered = $true
    Start-ScheduledTask -TaskName $task
    $end = (Get-Date).AddMinutes(5)
    while (!(Test-Path "$root\result.txt") -and (Get-Date) -lt $end) {
        Start-Sleep -Seconds 1
        $info = Get-ScheduledTaskInfo -TaskName $task
        if ($info.LastRunTime.Year -gt 2000 -and (Get-ScheduledTask -TaskName $task).State -ne 'Running') { break }
    }
    if (Test-Path "$root\output.log") { Get-Content "$root\output.log" }
    if (Test-Path "$root\launcher.log") { Get-Content "$root\launcher.log" }
    $info = Get-ScheduledTaskInfo -TaskName $task
    Write-Host "Standard-user task state: $((Get-ScheduledTask -TaskName $task).State); result: $($info.LastTaskResult)"
    if (!(Test-Path "$root\result.txt")) { throw 'Standard-user daemon smoke timed out' }
    if ([int](Get-Content "$root\result.txt") -ne 0) { throw 'Standard-user daemon smoke failed' }
} finally {
    if ($registered) {
        Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $task -Confirm:$false
    }
    if ($created) { Remove-LocalUser -Name $user }
    if (Test-Path $root) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
}
