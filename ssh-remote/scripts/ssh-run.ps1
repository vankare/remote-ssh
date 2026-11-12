[CmdletBinding()]
param(
    [string]$Profile,
    [string]$HostName,
    [int]$Port,
    [string]$User,
    [string]$WorkDir,
    [switch]$NoWorkDir,
    [string]$IdentityFile,
    [string]$Password,
    [string]$PasswordEnv,
    [string]$Config,
    [string]$RemoteShell,
    [string]$Command,
    [string]$CommandFile,
    [int]$TimeoutSec = 120,
    [int]$MaxOutputChars = 1000000
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ssh-common.ps1')
$started = Get-Date

try {
    if (-not $Command -and -not $CommandFile) { throw "Provide -Command or -CommandFile." }
    if ($Command -and $CommandFile) { throw "Use only one of -Command and -CommandFile." }
    if ($CommandFile) {
        if (-not (Test-Path -LiteralPath $CommandFile)) { throw "Command file not found: $CommandFile" }
        $Command = Get-Content -LiteralPath $CommandFile -Raw -Encoding UTF8
    }

    $configPath = Resolve-SshRemoteConfigPath -Config $Config
    $configObj = Read-SshRemoteConfig -Path $configPath

    $overrides = @{}
    if ($HostName) { $overrides['host'] = $HostName }
    if ($Port) { $overrides['port'] = $Port }
    if ($User) { $overrides['user'] = $User }
    if ($WorkDir) { $overrides['workdir'] = $WorkDir }
    if ($IdentityFile) { $overrides['identityFile'] = $IdentityFile }
    if ($RemoteShell) { $overrides['remoteShell'] = $RemoteShell }

    $sshProfile = Resolve-SshRemoteProfile -ConfigObj $configObj -Name $Profile -Overrides $overrides
    $resolvedPassword = Get-SshRemotePassword -SshProfile $sshProfile -Password $Password -PasswordEnv $PasswordEnv
    $remoteScript = New-SshRemoteScript -SshProfile $sshProfile -Command $Command -NoWorkDir:$NoWorkDir -WorkDir $WorkDir
    $run = Invoke-SshCommand -SshProfile $sshProfile -Password $resolvedPassword -Script $remoteScript -TimeoutSec $TimeoutSec -MaxOutputChars $MaxOutputChars
    $r = $run.result

    $effectiveWorkDir = $null
    if (-not $NoWorkDir) {
        if ($WorkDir) { $effectiveWorkDir = $WorkDir } else { $effectiveWorkDir = Get-SshRemoteProperty $sshProfile 'workdir' }
    }

    $result = [ordered]@{
        ok = $true
        exitCode = $r.exitCode
        stdout = $r.stdout
        stderr = $r.stderr
        profile = $sshProfile.profile
        host = $sshProfile.host
        port = [int]$sshProfile.port
        user = $sshProfile.user
        workdir = $effectiveWorkDir
        authMethod = $run.method
        durationMs = $r.durationMs
        timedOut = $r.timedOut
        stdoutTruncated = $r.stdoutTruncated
        stderrTruncated = $r.stderrTruncated
    }
    Write-SshRemoteJson $result
    exit 0
} catch {
    $result = [ordered]@{
        ok = $false
        error = $_.Exception.Message
        durationMs = [int]((Get-Date) - $started).TotalMilliseconds
    }
    Write-SshRemoteJson $result
    exit 1
}
