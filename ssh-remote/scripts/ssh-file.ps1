[CmdletBinding()]
param(
    [string]$Profile,
    [string]$HostName,
    [int]$Port,
    [string]$User,
    [string]$IdentityFile,
    [string]$Password,
    [string]$PasswordEnv,
    [string]$Config,
    [Parameter(Mandatory = $true)][ValidateSet('read', 'write')][string]$Action,
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$Content,
    [string]$ContentFile,
    [string]$LocalFile,
    [ValidateSet('utf8', 'base64')][string]$Encoding = 'utf8',
    [switch]$Binary,
    [int]$TimeoutSec = 120
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ssh-common.ps1')

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ssh-remote-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

try {
    $configPath = Resolve-SshRemoteConfigPath -Config $Config
    $configObj = Read-SshRemoteConfig -Path $configPath

    $overrides = @{}
    if ($HostName) { $overrides['host'] = $HostName }
    if ($Port) { $overrides['port'] = $Port }
    if ($User) { $overrides['user'] = $User }
    if ($IdentityFile) { $overrides['identityFile'] = $IdentityFile }

    $sshProfile = Resolve-SshRemoteProfile -ConfigObj $configObj -Name $Profile -Overrides $overrides
    $resolvedPassword = Get-SshRemotePassword -SshProfile $sshProfile -Password $Password -PasswordEnv $PasswordEnv
    $remoteSpec = "$($sshProfile.user)@$($sshProfile.host):$Path"
    $useBase64 = ($Binary -or $Encoding -eq 'base64')

    if ($Action -eq 'read') {
        $localName = 'download.bin'
        $run = Invoke-SshScp -SshProfile $sshProfile -Password $resolvedPassword -Source $remoteSpec -Destination $localName -TimeoutSec $TimeoutSec -WorkingDirectory $tempDir
        if ($run.result.exitCode -ne 0) {
            Write-SshRemoteJson ([ordered]@{
                    ok = $false
                    action = 'read'
                    path = $Path
                    exitCode = $run.result.exitCode
                    stderr = $run.result.stderr
                    error = "scp failed with exit code $($run.result.exitCode)."
                    authMethod = $run.method
                })
            exit 1
        }
        $localPath = Join-Path $tempDir $localName
        $bytes = [System.IO.File]::ReadAllBytes($localPath)
        if ($useBase64) {
            $contentOut = [Convert]::ToBase64String($bytes)
            $encodingOut = 'base64'
        } else {
            $contentOut = [System.Text.Encoding]::UTF8.GetString($bytes)
            $encodingOut = 'utf8'
        }
        Write-SshRemoteJson ([ordered]@{
                ok = $true
                action = 'read'
                path = $Path
                encoding = $encodingOut
                bytes = $bytes.Length
                content = $contentOut
                authMethod = $run.method
            })
        exit 0
    }

    $localName = 'upload.bin'
    $localPath = Join-Path $tempDir $localName
    if ($LocalFile) {
        if (-not (Test-Path -LiteralPath $LocalFile)) { throw "Local file not found: $LocalFile" }
        Copy-Item -LiteralPath $LocalFile -Destination $localPath -Force
    } elseif ($ContentFile) {
        if (-not (Test-Path -LiteralPath $ContentFile)) { throw "Content file not found: $ContentFile" }
        if ($useBase64) {
            $text = Get-Content -LiteralPath $ContentFile -Raw -Encoding UTF8
            $bytes = [Convert]::FromBase64String($text.Trim())
            [System.IO.File]::WriteAllBytes($localPath, $bytes)
        } else {
            Copy-Item -LiteralPath $ContentFile -Destination $localPath -Force
        }
    } elseif ($PSBoundParameters.ContainsKey('Content')) {
        if ($useBase64) {
            $bytes = [Convert]::FromBase64String($Content.Trim())
            [System.IO.File]::WriteAllBytes($localPath, $bytes)
        } else {
            [System.IO.File]::WriteAllText($localPath, $Content, (New-Object System.Text.UTF8Encoding($false)))
        }
    } else {
        throw "Provide -Content, -ContentFile, or -LocalFile."
    }

    $size = (Get-Item -LiteralPath $localPath).Length
    $run = Invoke-SshScp -SshProfile $sshProfile -Password $resolvedPassword -Source $localName -Destination $remoteSpec -TimeoutSec $TimeoutSec -WorkingDirectory $tempDir
    if ($run.result.exitCode -ne 0) {
        Write-SshRemoteJson ([ordered]@{
                ok = $false
                action = 'write'
                path = $Path
                exitCode = $run.result.exitCode
                stderr = $run.result.stderr
                error = "scp failed with exit code $($run.result.exitCode)."
                authMethod = $run.method
            })
        exit 1
    }
    Write-SshRemoteJson ([ordered]@{
            ok = $true
            action = 'write'
            path = $Path
            bytes = $size
            authMethod = $run.method
        })
    exit 0
} catch {
    Write-SshRemoteJson ([ordered]@{
            ok = $false
            action = $Action
            path = $Path
            error = $_.Exception.Message
        })
    exit 1
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
