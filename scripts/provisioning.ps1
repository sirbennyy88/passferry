<#
.SYNOPSIS
    Provisions new users from source forests into the target domain.

.DESCRIPTION
    Replacement for the "User Account Migration Wizard" portion of ADMT 3.2.
    Runs as a scheduled task on a member server in the target forest.
    Queries each configured source forest for users created/modified since
    the last run, creates or updates matching users in target, and stamps
    a back-reference attribute so the password sync broker can find them.

    Does NOT migrate passwords. That's the password filter + broker job.
    Does NOT migrate SID History. Add Move-ADObject logic if you need it,
    but for new-user provisioning to a fresh forest you usually don't.

.NOTES
    Run as: gMSA with delegated rights:
      - Read-all on each source forest
      - Create/Modify users in target OU(s) in target
    Schedule: every 15 minutes (adjust as needed)

    Idempotency: safe to re-run. Uses whenChanged + state file watermark.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\config.json",
    [string]$StatePath  = "$PSScriptRoot\state.json",
    [string]$LogPath    = "$PSScriptRoot\logs\provisioning_$(Get-Date -Format yyyyMMdd).log",
    [switch]$WhatIf
)

#region Logging
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $line | Tee-Object -FilePath $LogPath -Append | Write-Host
}
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
#endregion

#region Config & state
if (-not (Test-Path $ConfigPath)) {
    @{
        TargetDomain  = 'target.example'
        TargetDC      = 'target-dc01.target.example'
        TargetOU      = 'OU=Migrated Users,OU=Target,DC=target,DC=example'
        DefaultUserPasswordLength = 24  # random temp pwd until real sync arrives
        # Where to stamp the legacy objectGUID on the target user.
        # The broker uses this to find the matching target user when a password
        # change comes in. Run scripts/preflight-check.ps1 to verify the chosen
        # attribute isn't already in use. Common safe choices: extensionAttribute15,
        # extensionAttribute14. If you have clean employeeID data, use that instead.
        BackrefAttribute = 'extensionAttribute15'
        SourceForests = @(
            @{
                Name        = 'source-a'
                Domain      = 'source-a.example'
                DC          = 'dc01.source-a.example'
                SearchBase  = 'OU=Users,DC=source-a,DC=test'
                # filter for users that should sync; tighten this to a group if you can
                LdapFilter  = '(&(objectClass=user)(objectCategory=person)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))'
            }
            @{
                Name        = 'source-b'
                Domain      = 'source-b.example'
                DC          = 'dc01.source-b.example'
                SearchBase  = 'OU=Users,DC=source-b,DC=test'
                LdapFilter  = '(&(objectClass=user)(objectCategory=person)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))'
            }
        )
        AttributeMap = @{
            # source attribute  -> target attribute
            'givenName'         = 'givenName'
            'sn'                = 'sn'
            'displayName'       = 'displayName'
            'mail'              = 'mail'
            'telephoneNumber'   = 'telephoneNumber'
            'title'             = 'title'
            'department'        = 'department'
            'company'           = 'company'
            'employeeID'        = 'employeeID'
        }
    } | ConvertTo-Json -Depth 6 | Set-Content $ConfigPath -Encoding UTF8
    Write-Log "Wrote default config to $ConfigPath. Edit it and re-run." WARN
    exit 0
}
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

if (Test-Path $StatePath) {
    $state = Get-Content $StatePath -Raw | ConvertFrom-Json
} else {
    $state = [pscustomobject]@{ LastRunByForest = @{} }
}
# coerce to hashtable for easier mutation
$lastRun = @{}
if ($state.LastRunByForest) {
    $state.LastRunByForest.PSObject.Properties | ForEach-Object { $lastRun[$_.Name] = $_.Value }
}
#endregion

#region Helpers
function New-RandomPassword {
    param([int]$Length = 24)
    # 4 character classes, cryptographically random
    Add-Type -AssemblyName System.Web
    $pwd = [System.Web.Security.Membership]::GeneratePassword($Length, 4)
    ConvertTo-SecureString -String $pwd -AsPlainText -Force
}

function Get-LegacyUsers {
    param($Forest, [datetime]$Since)
    $sinceFileTime = $Since.ToFileTimeUtc()
    # whenChanged is more reliable than whenCreated for picking up modifications
    $filter = "$($Forest.LdapFilter)(whenChanged>=$($Since.ToString('yyyyMMddHHmmss.0Z')))"
    Get-ADUser `
        -Server $Forest.DC `
        -SearchBase $Forest.SearchBase `
        -LDAPFilter $filter `
        -Properties (@($cfg.AttributeMap.PSObject.Properties.Name) + @('whenChanged','objectGUID','sAMAccountName','userPrincipalName'))
}

function Get-TargetUserBySourceGuid {
    param([string]$SourceGuid)
    # We stamp the source objectGUID into the configured BackrefAttribute at create time
    $attr = $cfg.BackrefAttribute
    Get-ADUser `
        -Server $cfg.TargetDC `
        -LDAPFilter "($attr=$SourceGuid)" `
        -Properties $attr, employeeID `
        -ErrorAction SilentlyContinue | Select-Object -First 1
}

function New-TargetSamAccountName {
    param($SourceUser)
    # naive: use legacy sAM, append forest tag if collision
    $base = $SourceUser.sAMAccountName
    if (-not (Get-ADUser -Server $cfg.TargetDC -Filter "sAMAccountName -eq '$base'" -ErrorAction SilentlyContinue)) {
        return $base
    }
    # collision — try suffixing with a forest abbreviation
    $forestTag = ($SourceUser._SourceForestName -split '-')[-1]
    $alt = "$base.$forestTag"
    if ($alt.Length -gt 20) { $alt = $alt.Substring(0,20) }
    if (-not (Get-ADUser -Server $cfg.TargetDC -Filter "sAMAccountName -eq '$alt'" -ErrorAction SilentlyContinue)) {
        return $alt
    }
    # last resort: numeric suffix
    for ($i = 1; $i -le 99; $i++) {
        $candidate = ("{0}{1}" -f $base, $i)
        if ($candidate.Length -gt 20) { $candidate = $candidate.Substring(0,20) }
        if (-not (Get-ADUser -Server $cfg.TargetDC -Filter "sAMAccountName -eq '$candidate'" -ErrorAction SilentlyContinue)) {
            return $candidate
        }
    }
    throw "Cannot find a free sAMAccountName for $($SourceUser.sAMAccountName)"
}

function Build-TargetAttributes {
    param($SourceUser)
    $attrs = @{}
    foreach ($prop in $cfg.AttributeMap.PSObject.Properties) {
        $srcVal = $SourceUser.$($prop.Name)
        if ($null -ne $srcVal -and $srcVal -ne '') {
            $attrs[$prop.Value] = $srcVal
        }
    }
    # always stamp the back-reference
    $attrs[$cfg.BackrefAttribute] = $SourceUser.objectGUID.Guid
    return $attrs
}

function Sync-User {
    param($SourceUser)

    $sourceGuid = $SourceUser.objectGUID.Guid
    $existing = Get-TargetUserBySourceGuid -SourceGuid $sourceGuid

    $targetAttrs = Build-TargetAttributes -SourceUser $SourceUser

    if ($existing) {
        # UPDATE path
        Write-Log "Updating target user $($existing.SamAccountName) (source: $($SourceUser.sAMAccountName)@$($SourceUser._SourceForestName))"
        if ($WhatIf) { return }
        try {
            Set-ADUser -Server $cfg.TargetDC -Identity $existing.DistinguishedName -Replace $targetAttrs -ErrorAction Stop
        } catch {
            Write-Log "Update FAILED for $($existing.SamAccountName): $_" ERROR
        }
    } else {
        # CREATE path
        $sam = New-TargetSamAccountName -SourceUser $SourceUser
        $upn = "$sam@$($cfg.TargetDomain)"
        $tempPwd = New-RandomPassword -Length $cfg.DefaultUserPasswordLength

        Write-Log "Creating target user $sam (source: $($SourceUser.sAMAccountName)@$($SourceUser._SourceForestName))"
        if ($WhatIf) { return }
        try {
            New-ADUser `
                -Server $cfg.TargetDC `
                -Path $cfg.TargetOU `
                -Name $SourceUser.displayName `
                -SamAccountName $sam `
                -UserPrincipalName $upn `
                -AccountPassword $tempPwd `
                -Enabled $true `
                -OtherAttributes $targetAttrs `
                -ErrorAction Stop
        } catch {
            Write-Log "Create FAILED for $sam : $_" ERROR
        }
    }
}
#endregion

#region Main
Write-Log "=== Provisioning run start ==="
Write-Log "Target DC: $($cfg.TargetDC), target OU: $($cfg.TargetOU)"

$thisRunStart = Get-Date

foreach ($forest in $cfg.SourceForests) {
    $forestKey = $forest.Name
    $since = if ($lastRun.ContainsKey($forestKey)) {
        [datetime]::Parse($lastRun[$forestKey])
    } else {
        # first run: don't pull all of history. Look back 7 days.
        (Get-Date).AddDays(-7)
    }

    Write-Log "[$forestKey] querying since $since"
    try {
        $users = Get-LegacyUsers -Forest $forest -Since $since
    } catch {
        Write-Log "[$forestKey] query FAILED: $_" ERROR
        continue
    }

    Write-Log "[$forestKey] found $($users.Count) candidate user(s)"
    foreach ($u in $users) {
        # tag with source forest for downstream logic
        $u | Add-Member -NotePropertyName _SourceForestName -NotePropertyValue $forestKey -Force
        Sync-User -SourceUser $u
    }

    # update watermark on success only
    $lastRun[$forestKey] = $thisRunStart.ToString('o')
}

# persist state
[pscustomobject]@{ LastRunByForest = $lastRun } | ConvertTo-Json | Set-Content $StatePath -Encoding UTF8
Write-Log "=== Provisioning run end ==="
#endregion
