# GitHub Windows runners are elevated. Exercise the actual supported desktop
# account context in an isolated, disposable standard-user process.
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
    Start-Service seclogon
    $credential = [pscredential]::new("$env:COMPUTERNAME\$user", (ConvertTo-SecureString $password -AsPlainText -Force))
    $powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $process = Start-Process -FilePath $powershell -Credential $credential -LoadUserProfile -WorkingDirectory $root -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File $root\run.ps1" -PassThru
    $end = (Get-Date).AddMinutes(5)
    while (!(Test-Path "$root\result.txt") -and !$process.HasExited -and (Get-Date) -lt $end) { Start-Sleep -Seconds 1 }
    if (Test-Path "$root\output.log") { Get-Content "$root\output.log" }
    if ($process.HasExited) { Write-Host "Standard-user launcher exit: $($process.ExitCode)" }
    if (!(Test-Path "$root\result.txt")) { throw 'Standard-user daemon smoke timed out' }
    if ([int](Get-Content "$root\result.txt") -ne 0) { throw 'Standard-user daemon smoke failed' }
} finally {
    if ($process -and !$process.HasExited) { $process.Kill(); $process.WaitForExit() }
    if ($created) { Remove-LocalUser -Name $user }
    if (Test-Path $root) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
}
