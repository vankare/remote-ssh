Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SshRemoteProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($prop) { return $prop.Value }
    return $null
}

function Resolve-SshRemoteConfigPath {
    param([string]$Config, [switch]$ForWrite)
    if ($Config) { return [System.IO.Path]::GetFullPath($Config) }
    if ($env:SSH_REMOTE_CONFIG) { return [System.IO.Path]::GetFullPath($env:SSH_REMOTE_CONFIG) }
    return [System.IO.Path]::Combine($env:USERPROFILE, '.config', 'ssh-remote', 'servers.json')
}

function Read-SshRemoteConfig {
    param([string]$Path)
    $emptyProfiles = [pscustomobject]@{}
    $empty = [pscustomobject]@{ defaultProfile = $null; profiles = $emptyProfiles }
    if (-not (Test-Path -LiteralPath $Path)) { return $empty }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $empty }
    $obj = $raw | ConvertFrom-Json
    if (-not (Get-SshRemoteProperty $obj 'profiles')) {
        $obj | Add-Member -NotePropertyName profiles -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not (Get-SshRemoteProperty $obj 'defaultProfile')) {
        $obj | Add-Member -NotePropertyName defaultProfile -NotePropertyValue $null -Force
    }
    return $obj
}

function Resolve-SshRemoteProfile {
    param($ConfigObj, [string]$Name, [hashtable]$Overrides = @{})
    $resolvedName = $Name
    if (-not $resolvedName) { $resolvedName = Get-SshRemoteProperty $ConfigObj 'defaultProfile' }
    if (-not $resolvedName) {
        $names = @($ConfigObj.profiles.PSObject.Properties | ForEach-Object { $_.Name })
        if ($names.Count -eq 1) { $resolvedName = $names[0] }
    }
    $result = [ordered]@{}
    if ($resolvedName) {
        $profileValue = Get-SshRemoteProperty $ConfigObj.profiles $resolvedName
        if ($profileValue) {
            foreach ($p in $profileValue.PSObject.Properties) { $result[$p.Name] = $p.Value }
        } elseif ($Name) {
            throw "Profile '$Name' was not found in the config file."
        }
    }
    foreach ($key in $Overrides.Keys) {
        $value = $Overrides[$key]
        if ($null -ne $value -and "$value" -ne '') { $result[$key] = $value }
    }
    if (-not $result.Contains('host') -or -not $result['host']) {
        throw "No host configured. Pass -Profile or -HostName."
    }
    if (-not $result.Contains('user') -or -not $result['user']) {
        throw "No user configured. Pass -User or add it to the profile."
    }
    if (-not $result.Contains('port') -or -not $result['port']) { $result['port'] = 22 }
    $result['profile'] = $resolvedName
    return [pscustomobject]$result
}

function Get-SshRemotePassword {
    param($SshProfile, [string]$Password, [string]$PasswordEnv)
    if ($Password) { return $Password }
    if ($PasswordEnv) {
        $value = [Environment]::GetEnvironmentVariable($PasswordEnv)
        if (-not $value) { throw "Environment variable '$PasswordEnv' is empty or not set." }
        return $value
    }
    $plain = Get-SshRemoteProperty $SshProfile 'password'
    if ($plain) { return [string]$plain }
    $envName = Get-SshRemoteProperty $SshProfile 'passwordEnv'
    if ($envName) {
        $value = [Environment]::GetEnvironmentVariable([string]$envName)
        if (-not $value) { throw "Environment variable '$envName' is empty or not set." }
        return $value
    }
    return $null
}

function Quote-SshRemoteBashSingle {
    param([string]$Value)
    return "'" + ($Value -replace "'", "'\''") + "'"
}

function ConvertTo-SshRemoteNativeArg {
    param([string]$Arg)
    if ($Arg -notmatch '[\s"]') { return $Arg }
    $escaped = $Arg -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Write-SshRemoteJson {
    param($Object)
    $json = $Object | ConvertTo-Json -Depth 8 -Compress
    [Console]::Out.Write($json)
    [Console]::Out.Write("`n")
}

function Find-SshRemoteCommand {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-SshRemoteBaseOptions {
    param($SshProfile)
    $connectTimeout = Get-SshRemoteProperty $SshProfile 'connectTimeout'
    if (-not $connectTimeout) { $connectTimeout = 10 }
    $alive = Get-SshRemoteProperty $SshProfile 'serverAliveInterval'
    if (-not $alive) { $alive = 30 }
    $strict = Get-SshRemoteProperty $SshProfile 'strictHostKeyChecking'
    if (-not $strict) { $strict = 'accept-new' }
    return @('-o', "ConnectTimeout=$connectTimeout", '-o', "ServerAliveInterval=$alive", '-o', "StrictHostKeyChecking=$strict")
}

function Get-SshRemoteShellArgs {
    param($SshProfile)
    $shell = Get-SshRemoteProperty $SshProfile 'remoteShell'
    if (-not $shell) { $shell = 'bash -s' }
    return @(([string]$shell) -split '\s+')
}

function Get-SshRemoteTarget {
    param($SshProfile)
    return ("{0}@{1}" -f $SshProfile.user, $SshProfile.host)
}

function New-SshRemoteScript {
    param($SshProfile, [string]$Command, [switch]$NoWorkDir, [string]$WorkDir)
    $dir = $WorkDir
    if (-not $NoWorkDir -and -not $dir) { $dir = Get-SshRemoteProperty $SshProfile 'workdir' }
    $normalized = ($Command -replace "`r`n", "`n") -replace "`r", "`n"
    $builder = New-Object System.Text.StringBuilder
    if ($dir) {
        $quoted = Quote-SshRemoteBashSingle ([string]$dir)
        [void]$builder.Append("cd -- $quoted || { printf 'ssh-remote: cannot cd to %s\n' $quoted >&2; exit 125; }`n")
    }
    [void]$builder.Append($normalized)
    if (-not $normalized.EndsWith("`n")) { [void]$builder.Append("`n") }
    return $builder.ToString()
}

function Invoke-SshRemoteProcess {
    param(
        [string]$FileName,
        [string[]]$Arguments,
        [string]$InputText,
        [int]$TimeoutSec = 120,
        [hashtable]$Environment = @{},
        [int]$MaxOutputChars = 1000000,
        [string]$WorkingDirectory
    )
    if ($TimeoutSec -lt 1) { throw "TimeoutSec must be at least 1." }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $psi.Arguments = (($Arguments | ForEach-Object { ConvertTo-SshRemoteNativeArg $_ }) -join ' ')
    foreach ($key in $Environment.Keys) { $psi.EnvironmentVariables[$key] = [string]$Environment[$key] }
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $started = Get-Date
    if (-not $proc.Start()) { throw "Failed to start $FileName" }
    if ($null -ne $InputText) { $proc.StandardInput.Write($InputText) }
    $proc.StandardInput.Close()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $timedOut = $false
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        $timedOut = $true
        try { $proc.Kill() } catch { }
    }
    $proc.WaitForExit()
    try { $stdout = $stdoutTask.Result } catch { $stdout = '' }
    try { $stderr = $stderrTask.Result } catch { $stderr = '' }
    $elapsed = [int]((Get-Date) - $started).TotalMilliseconds
    $exitCode = if ($timedOut) { 124 } else { $proc.ExitCode }
    $stdoutTruncated = $false
    $stderrTruncated = $false
    if ($stdout.Length -gt $MaxOutputChars) { $stdout = $stdout.Substring(0, $MaxOutputChars); $stdoutTruncated = $true }
    if ($stderr.Length -gt $MaxOutputChars) { $stderr = $stderr.Substring(0, $MaxOutputChars); $stderrTruncated = $true }
    return [pscustomobject]@{
        exitCode = $exitCode
        stdout = $stdout
        stderr = $stderr
        durationMs = $elapsed
        timedOut = $timedOut
        stdoutTruncated = $stdoutTruncated
        stderrTruncated = $stderrTruncated
    }
}

function New-SshRemoteAskpass {
    param([string]$Password)
    $path = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("ssh-remote-askpass-" + [guid]::NewGuid().ToString('N') + ".sh"))
    $body = "#!/bin/sh`nprintf '%s\n' `"`$SSH_REMOTE_PASSWORD`"`n"
    [System.IO.File]::WriteAllText($path, $body, (New-Object System.Text.UTF8Encoding($false)))
    try { & chmod 700 $path } catch { }
    return $path
}

function Invoke-SshCommand {
    param(
        $SshProfile,
        [string]$Password,
        [string]$Script,
        [int]$TimeoutSec = 120,
        [int]$MaxOutputChars = 1000000
    )
    $isWindows = ($env:OS -eq 'Windows_NT')
    $port = [int]$SshProfile.port
    $target = Get-SshRemoteTarget $SshProfile
    $baseOpts = Get-SshRemoteBaseOptions $SshProfile
    $identity = Get-SshRemoteProperty $SshProfile 'identityFile'
    $shellArgs = Get-SshRemoteShellArgs $SshProfile
    $tempFiles = @()
    try {
        if ($Password) {
            if ($isWindows) {
                $plink = Find-SshRemoteCommand 'plink'
                if ($plink) {
                    $scriptFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("ssh-remote-" + [guid]::NewGuid().ToString('N') + ".sh"))
                    [System.IO.File]::WriteAllText($scriptFile, $Script, (New-Object System.Text.UTF8Encoding($false)))
                    $tempFiles += $scriptFile
                    $sshArgs = @('-ssh', '-batch', '-P', "$port", '-pw', $Password)
                    if ($identity) { $sshArgs += @('-i', $identity) }
                    $hostKey = Get-SshRemoteProperty $SshProfile 'hostKey'
                    if ($hostKey) { $sshArgs += @('-hostkey', [string]$hostKey) }
                    $sshArgs += @('-m', $scriptFile, $target)
                    $result = Invoke-SshRemoteProcess -FileName $plink -Arguments $sshArgs -InputText $null -TimeoutSec $TimeoutSec -Environment @{} -MaxOutputChars $MaxOutputChars
                    return [pscustomobject]@{ result = $result; method = 'plink' }
                }
                $sshpass = Find-SshRemoteCommand 'sshpass'
                if ($sshpass) {
                    $ssh = Find-SshRemoteCommand 'ssh'
                    if (-not $ssh) { throw "ssh executable not found." }
                    $sshArgs = @('-p', "$port") + $baseOpts
                    if ($identity) { $sshArgs += @('-i', $identity, '-o', 'IdentitiesOnly=yes') }
                    $sshArgs += @('-o', 'BatchMode=no', '--', $target) + $shellArgs
                    $result = Invoke-SshRemoteProcess -FileName $sshpass -Arguments (@('-p', $Password, $ssh) + $sshArgs) -InputText $Script -TimeoutSec $TimeoutSec -Environment @{} -MaxOutputChars $MaxOutputChars
                    return [pscustomobject]@{ result = $result; method = 'sshpass' }
                }
                throw "Password auth on Windows requires plink.exe (PuTTY) or sshpass. Install one, or switch the profile to key auth."
            }
            $ssh = Find-SshRemoteCommand 'ssh'
            if (-not $ssh) { throw "ssh executable not found." }
            $sshArgs = @('-p', "$port") + $baseOpts
            if ($identity) { $sshArgs += @('-i', $identity, '-o', 'IdentitiesOnly=yes') }
            $sshArgs += @('-o', 'BatchMode=no', '--', $target) + $shellArgs
            $sshpass = Find-SshRemoteCommand 'sshpass'
            if ($sshpass) {
                $result = Invoke-SshRemoteProcess -FileName $sshpass -Arguments (@('-p', $Password, $ssh) + $sshArgs) -InputText $Script -TimeoutSec $TimeoutSec -Environment @{} -MaxOutputChars $MaxOutputChars
                return [pscustomobject]@{ result = $result; method = 'sshpass' }
            }
            $askpass = New-SshRemoteAskpass $Password
            $tempFiles += $askpass
            $envs = @{
                SSH_ASKPASS = $askpass
                SSH_ASKPASS_REQUIRE = 'force'
                DISPLAY = ':0'
                SSH_REMOTE_PASSWORD = $Password
            }
            $result = Invoke-SshRemoteProcess -FileName $ssh -Arguments $sshArgs -InputText $Script -TimeoutSec $TimeoutSec -Environment $envs -MaxOutputChars $MaxOutputChars
            return [pscustomobject]@{ result = $result; method = 'askpass' }
        }
        $ssh = Find-SshRemoteCommand 'ssh'
        if (-not $ssh) { throw "ssh executable not found." }
        $sshArgs = @('-p', "$port") + $baseOpts
        if ($identity) { $sshArgs += @('-i', $identity, '-o', 'IdentitiesOnly=yes') }
        $sshArgs += @('-o', 'BatchMode=yes', '--', $target) + $shellArgs
        $result = Invoke-SshRemoteProcess -FileName $ssh -Arguments $sshArgs -InputText $Script -TimeoutSec $TimeoutSec -Environment @{} -MaxOutputChars $MaxOutputChars
        return [pscustomobject]@{ result = $result; method = 'key' }
    } finally {
        foreach ($file in $tempFiles) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-SshScp {
    param(
        $SshProfile,
        [string]$Password,
        [string]$Source,
        [string]$Destination,
        [int]$TimeoutSec = 120,
        [string]$WorkingDirectory
    )
    $isWindows = ($env:OS -eq 'Windows_NT')
    $port = [int]$SshProfile.port
    $identity = Get-SshRemoteProperty $SshProfile 'identityFile'
    $baseOpts = Get-SshRemoteBaseOptions $SshProfile
    if ($Password) {
        if ($isWindows) {
            $pscp = Find-SshRemoteCommand 'pscp'
            if ($pscp) {
                $scpArgs = @('-batch', '-P', "$port", '-pw', $Password)
                if ($identity) { $scpArgs += @('-i', $identity) }
                $hostKey = Get-SshRemoteProperty $SshProfile 'hostKey'
                if ($hostKey) { $scpArgs += @('-hostkey', [string]$hostKey) }
                $scpArgs += @($Source, $Destination)
                $result = Invoke-SshRemoteProcess -FileName $pscp -Arguments $scpArgs -InputText $null -TimeoutSec $TimeoutSec -Environment @{} -MaxOutputChars 1000000 -WorkingDirectory $WorkingDirectory
                return [pscustomobject]@{ result = $result; method = 'pscp' }
            }
            $sshpass = Find-SshRemoteCommand 'sshpass'
            $scp = Find-SshRemoteCommand 'scp'
            if ($sshpass -and $scp) {
                $scpArgs = @('-P', "$port") + $baseOpts
                if ($identity) { $scpArgs += @('-i', $identity, '-o', 'IdentitiesOnly=yes') }
                $scpArgs += @($Source, $Destination)
                $result = Invoke-SshRemoteProcess -FileName $sshpass -Arguments (@('-p', $Password, $scp) + $scpArgs) -InputText $null -TimeoutSec $TimeoutSec -Environment @{} -MaxOutputChars 1000000 -WorkingDirectory $WorkingDirectory
                return [pscustomobject]@{ result = $result; method = 'sshpass' }
            }
            throw "Password file transfer on Windows requires pscp.exe (PuTTY) or sshpass. Install one, or use key auth."
        }
        $scp = Find-SshRemoteCommand 'scp'
        if (-not $scp) { throw "scp executable not found." }
        $scpArgs = @('-P', "$port") + $baseOpts
        if ($identity) { $scpArgs += @('-i', $identity, '-o', 'IdentitiesOnly=yes') }
        $scpArgs += @($Source, $Destination)
        $sshpass = Find-SshRemoteCommand 'sshpass'
        if ($sshpass) {
            $result = Invoke-SshRemoteProcess -FileName $sshpass -Arguments (@('-p', $Password, $scp) + $scpArgs) -InputText $null -TimeoutSec $TimeoutSec -Environment @{} -MaxOutputChars 1000000 -WorkingDirectory $WorkingDirectory
            return [pscustomobject]@{ result = $result; method = 'sshpass' }
        }
        $askpass = New-SshRemoteAskpass $Password
        try {
            $envs = @{
                SSH_ASKPASS = $askpass
                SSH_ASKPASS_REQUIRE = 'force'
                DISPLAY = ':0'
                SSH_REMOTE_PASSWORD = $Password
            }
            $result = Invoke-SshRemoteProcess -FileName $scp -Arguments $scpArgs -InputText $null -TimeoutSec $TimeoutSec -Environment $envs -MaxOutputChars 1000000 -WorkingDirectory $WorkingDirectory
        } finally {
            Remove-Item -LiteralPath $askpass -Force -ErrorAction SilentlyContinue
        }
        return [pscustomobject]@{ result = $result; method = 'askpass' }
    }
    $scp = Find-SshRemoteCommand 'scp'
    if (-not $scp) { throw "scp executable not found." }
    $scpArgs = @('-P', "$port") + $baseOpts
    if ($identity) { $scpArgs += @('-i', $identity, '-o', 'IdentitiesOnly=yes') }
    $scpArgs += @('-o', 'BatchMode=yes', $Source, $Destination)
    $result = Invoke-SshRemoteProcess -FileName $scp -Arguments $scpArgs -InputText $null -TimeoutSec $TimeoutSec -Environment @{} -MaxOutputChars 1000000 -WorkingDirectory $WorkingDirectory
    return [pscustomobject]@{ result = $result; method = 'key' }
}
