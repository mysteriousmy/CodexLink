# GitHub Windows runners are elevated. Exercise the actual supported desktop
# account context outside the runner's non-breakaway Windows job.
param([Parameter(Mandatory)][string]$Gateway, [Parameter(Mandatory)][string]$Codex)
$ErrorActionPreference = 'Stop'
$user = 'cld' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$password = 'A1!' + [guid]::NewGuid().ToString('N')
$root = Join-Path $env:SystemDrive ($user + '-smoke')
$python = (Get-Command python).Source
$created = $false
$bootstrapProcess = $null
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
import os, runpy, sys, traceback
from pathlib import Path
os.environ['TEMP'] = os.environ['TMP'] = r'$root\tmp'
sys.argv = [r'$root\smoke.py', r'$root\CodexLink.Server.exe', r'$root\package\bin\codex.exe']
with open(r'$root\output.log', 'w', encoding='utf-8') as log:
    sys.stdout = sys.stderr = log
    try:
        runpy.run_path(sys.argv[0], run_name='__main__')
        code = 0
    except BaseException:
        traceback.print_exc()
        code = 1
Path(r'$root\result.txt').write_text(str(code))
sys.exit(code)
"@ | Set-Content "$root\run.py"
    $powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    Start-Service seclogon
    $credential = [pscredential]::new("$env:COMPUTERNAME\$user", (ConvertTo-SecureString $password -AsPlainText -Force))
    $credential | Export-Clixml "$root\credential.xml"
    @"
`$ErrorActionPreference = 'Stop'
try {
    `$credential = Import-Clixml '$root\credential.xml'
    `$start = New-Object System.Diagnostics.ProcessStartInfo
    `$start.FileName = '$python'
    `$start.Arguments = '$root\run.py'
    `$start.WorkingDirectory = '$root'
    `$start.UseShellExecute = `$false
    `$start.LoadUserProfile = `$true
    `$start.UserName = `$credential.GetNetworkCredential().UserName
    `$start.Domain = `$credential.GetNetworkCredential().Domain
    `$start.Password = `$credential.Password
    `$process = [System.Diagnostics.Process]::Start(`$start)
    if (!`$process.WaitForExit(240000)) { `$process.Kill(); throw 'Standard-user launcher timed out' }
    if (!(Test-Path '$root\result.txt')) { throw "Launcher exited without a result: `$(`$process.ExitCode)" }
} catch {
    `$_ | Out-File '$root\bootstrap-error.log'
    Set-Content '$root\result.txt' 1
}
"@ | Set-Content "$root\bootstrap.ps1"
    # WMI's documented breakaway flag leaves the runner's job before creating
    # the ordinary-user process. Only this disposable CI environment uses it.
    $startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ CreateFlags = [uint32]16777216; ShowWindow = [uint16]0 }
    $launch = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = "`"$powershell`" -NoProfile -ExecutionPolicy Bypass -File `"$root\bootstrap.ps1`""
        CurrentDirectory = $root
        ProcessStartupInformation = $startup
    }
    if ($launch.ReturnValue -ne 0) { throw "WMI launcher failed: $($launch.ReturnValue)" }
    $bootstrapProcess = Get-Process -Id $launch.ProcessId -ErrorAction SilentlyContinue
    $end = (Get-Date).AddMinutes(5)
    while (!(Test-Path "$root\result.txt") -and (Get-Date) -lt $end) {
        Start-Sleep -Seconds 1
        if (!$bootstrapProcess -or $bootstrapProcess.HasExited) { break }
    }
    if (Test-Path "$root\output.log") { Get-Content "$root\output.log" }
    if (Test-Path "$root\bootstrap-error.log") { Get-Content "$root\bootstrap-error.log" }
    if (!(Test-Path "$root\result.txt")) { throw 'Standard-user daemon smoke timed out' }
    if ([int](Get-Content "$root\result.txt") -ne 0) { throw 'Standard-user daemon smoke failed' }
} finally {
    if ($bootstrapProcess -and !$bootstrapProcess.HasExited) {
        if (!$bootstrapProcess.WaitForExit(5000)) { $bootstrapProcess.Kill(); $bootstrapProcess.WaitForExit() }
    }
    if ($created) { Remove-LocalUser -Name $user }
    if (Test-Path $root) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
}
