[CmdletBinding()]
param(
    [ValidateSet('set', 'get', 'list', 'remove', 'default')]
    [string]$Action = 'list',
    [string]$Name,
    [string]$HostName,
    [int]$Port,
    [string]$User,
    [string]$WorkDir,
    [string]$IdentityFile,
    [string]$Password,
    [string]$PasswordEnv,
    [string]$Config
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ssh-common.ps1')

try {
    $configPath = Resolve-SshRemoteConfigPath -Config $Config -ForWrite
    $configObj = Read-SshRemoteConfig -Path $configPath

    switch ($Action) {
        'list' {
            $items = @()
            foreach ($p in $configObj.profiles.PSObject.Properties) {
                $value = $p.Value
                $portValue = Get-SshRemoteProperty $value 'port'
                $auth = 'agent'
                if ((Get-SshRemoteProperty $value 'password') -or (Get-SshRemoteProperty $value 'passwordEnv')) { $auth = 'password' }
                elseif (Get-SshRemoteProperty $value 'identityFile') { $auth = 'key' }
                $items += [ordered]@{
                    name = $p.Name
                    host = Get-SshRemoteProperty $value 'host'
                    port = if ($portValue) { [int]$portValue } else { 22 }
                    user = Get-SshRemoteProperty $value 'user'
                    workdir = Get-SshRemoteProperty $value 'workdir'
                    auth = $auth
                }
            }
            Write-SshRemoteJson ([ordered]@{
                    ok = $true
                    action = 'list'
                    configPath = $configPath
                    data = [ordered]@{
                        defaultProfile = (Get-SshRemoteProperty $configObj 'defaultProfile')
                        profiles = $items
                    }
                })
            exit 0
        }
        'get' {
            if (-not $Name) { throw "Provide -Name." }
            $value = Get-SshRemoteProperty $configObj.profiles $Name
            if (-not $value) { throw "Profile '$Name' not found." }
            $safe = [ordered]@{}
            foreach ($prop in $value.PSObject.Properties) {
                if ($prop.Name -eq 'password') { $safe['hasPassword'] = $true; continue }
                $safe[$prop.Name] = $prop.Value
            }
            Write-SshRemoteJson ([ordered]@{
                    ok = $true
                    action = 'get'
                    name = $Name
                    configPath = $configPath
                    data = [ordered]@{
                        name = $Name
                        profile = $safe
                    }
                })
            exit 0
        }
        'set' {
            if (-not $Name) { throw "Provide -Name." }
            if (-not $HostName) { throw "Provide -HostName." }
            if (-not $User) { throw "Provide -User." }
            $existing = Get-SshRemoteProperty $configObj.profiles $Name
            $profileData = [ordered]@{}
            if ($existing) {
                foreach ($prop in $existing.PSObject.Properties) { $profileData[$prop.Name] = $prop.Value }
            }
            $profileData['host'] = $HostName
            if ($Port -gt 0) {
                $profileData['port'] = $Port
            } elseif (-not $profileData['port']) {
                $profileData['port'] = 22
            }
            $profileData['user'] = $User
            if ($WorkDir) { $profileData['workdir'] = $WorkDir }
            if ($IdentityFile) { $profileData['identityFile'] = $IdentityFile }
            if ($Password) { $profileData['password'] = $Password; $profileData.Remove('passwordEnv') }
            if ($PasswordEnv) { $profileData['passwordEnv'] = $PasswordEnv; $profileData.Remove('password') }
            $configObj.profiles | Add-Member -NotePropertyName $Name -NotePropertyValue ([pscustomobject]$profileData) -Force
            if (-not (Get-SshRemoteProperty $configObj 'defaultProfile')) { $configObj.defaultProfile = $Name }
            $dir = Split-Path -Parent $configPath
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            $json = $configObj | ConvertTo-Json -Depth 10
            [System.IO.File]::WriteAllText($configPath, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
            Write-SshRemoteJson ([ordered]@{ ok = $true; action = 'set'; name = $Name; configPath = $configPath })
            exit 0
        }
        'remove' {
            if (-not $Name) { throw "Provide -Name." }
            if (-not (Get-SshRemoteProperty $configObj.profiles $Name)) { throw "Profile '$Name' not found." }
            $newProfiles = [ordered]@{}
            foreach ($p in $configObj.profiles.PSObject.Properties) {
                if ($p.Name -ne $Name) { $newProfiles[$p.Name] = $p.Value }
            }
            $configObj.profiles = [pscustomobject]$newProfiles
            if ((Get-SshRemoteProperty $configObj 'defaultProfile') -eq $Name) { $configObj.defaultProfile = $null }
            $json = $configObj | ConvertTo-Json -Depth 10
            [System.IO.File]::WriteAllText($configPath, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
            Write-SshRemoteJson ([ordered]@{ ok = $true; action = 'remove'; name = $Name; configPath = $configPath })
            exit 0
        }
        'default' {
            if (-not $Name) { throw "Provide -Name." }
            if (-not (Get-SshRemoteProperty $configObj.profiles $Name)) { throw "Profile '$Name' not found." }
            $configObj.defaultProfile = $Name
            $json = $configObj | ConvertTo-Json -Depth 10
            [System.IO.File]::WriteAllText($configPath, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
            Write-SshRemoteJson ([ordered]@{ ok = $true; action = 'default'; name = $Name; configPath = $configPath })
            exit 0
        }
    }
} catch {
    Write-SshRemoteJson ([ordered]@{
            ok = $false
            action = $Action
            error = $_.Exception.Message
        })
    exit 1
}
