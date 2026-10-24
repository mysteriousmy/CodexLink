# GitHub Windows runners are elevated. Exercise the actual supported desktop
# account context. Hosted runner job restrictions can still reject daemon startup.
param([Parameter(Mandatory)][string]$Gateway, [Parameter(Mandatory)][string]$Codex)
$ErrorActionPreference = 'Stop'
$user = 'cld' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$password = 'A1!' + [guid]::NewGuid().ToString('N')
$root = Join-Path $env:SystemDrive ($user + '-smoke')
$python = (Get-Command python).Source
$created = $false
$process = $null
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
    Start-Service seclogon
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $python
    $start.Arguments = "$root\run.py"
    $start.WorkingDirectory = $root
    $start.UseShellExecute = $false
    $start.LoadUserProfile = $true
    $start.UserName = $user
    $start.Domain = $env:COMPUTERNAME
    $start.Password = ConvertTo-SecureString $password -AsPlainText -Force
    $process = [System.Diagnostics.Process]::Start($start)
    $end = (Get-Date).AddMinutes(5)
    while (!(Test-Path "$root\result.txt") -and (Get-Date) -lt $end) {
        Start-Sleep -Seconds 1
        if (!$process -or $process.HasExited) { break }
    }
    if (Test-Path "$root\output.log") { Get-Content "$root\output.log" }
    if (!(Test-Path "$root\result.txt")) { throw 'Standard-user daemon smoke timed out' }
    if ([int](Get-Content "$root\result.txt") -ne 0) { throw 'Standard-user daemon smoke failed' }
} finally {
    if ($process -and !$process.HasExited) {
        if (!$process.WaitForExit(5000)) { $process.Kill(); $process.WaitForExit() }
    }
    if ($created) { Remove-LocalUser -Name $user }
    if (Test-Path $root) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
}
