<#
.SYNOPSIS
    Sync broker. Receives password change events from legacy forwarders and
    sets the password on the matching user in the target domain.

.DESCRIPTION
    Runs as a Windows service on broker.target.example. Listens on HTTPS with
    mutual TLS. Authorizes incoming requests by client cert thumbprint.

    On each accepted request, finds the target user by the configured
    back-reference attribute (default extensionAttribute15, which holds the
    legacy objectGUID populated at provisioning time) and calls
    Set-ADAccountPassword via LDAPS.

    The BackrefAttribute parameter MUST match what scripts/provisioning.ps1 stamps.
    If you change one, change both.
#>

[CmdletBinding()]
param(
    [string]$ListenPrefix    = 'https://+:8443/',
    [string]$ServerCertThumb = '<server cert thumbprint>',
    [string]$TargetDC         = 'target-dc01.target.example',
    [string]$BackrefAttribute = 'extensionAttribute15',
    [string]$AllowedClientCertThumbs = 'C:\ProgramData\PassFerryBroker\allowed-clients.txt',
    [string]$LogPath         = 'C:\ProgramData\PassFerryBroker\broker.log'
)

#region Logging
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    Add-Content -Path $LogPath -Value $line
}
#endregion

#region Cert binding
# One-time setup (run as admin BEFORE starting the service):
#   netsh http add sslcert ipport=0.0.0.0:8443 ^
#     certhash=<ServerCertThumb> appid={00000000-0000-0000-0000-000000000000} ^
#     clientcertnegotiation=enable
#   netsh http add urlacl url=https://+:8443/ user="NT SERVICE\PassFerryBroker"

function Get-AllowedThumbs {
    if (-not (Test-Path $AllowedClientCertThumbs)) {
        Write-Log "Allowed-clients file missing: $AllowedClientCertThumbs" ERROR
        return @()
    }
    Get-Content $AllowedClientCertThumbs |
        Where-Object { $_ -and $_ -notmatch '^\s*#' } |
        ForEach-Object { $_.Trim().ToUpper() }
}
#endregion

#region target user lookup
function Get-TargetMatch {
    param([string]$SourceForest, [string]$LegacySam)
    # Strategy: forwarder doesn't send objectGUID (it's not in the LSASS payload),
    # so we resolve legacy SAM -> legacy objectGUID via the source forest, then
    # match in target by the configured BackrefAttribute.
    #
    # In production you'd want the forwarder to send the objectGUID alongside
    # the SAM (cheap to read in user-mode after the password event), to avoid
    # this round-trip. For prototype we keep the LSASS DLL minimal.

    $legacyDc = switch ($SourceForest) {
        'source-a' { 'dc01.source-a.example' }
        'source-b' { 'dc01.source-b.example' }
        default    { $null }
    }
    if (-not $legacyDc) {
        Write-Log "Unknown source forest: $SourceForest" WARN
        return $null
    }

    try {
        $legacyUser = Get-ADUser -Server $legacyDc -Identity $LegacySam -Properties objectGUID -ErrorAction Stop
    } catch {
        Write-Log "Legacy user $LegacySam not found in $SourceForest : $_" WARN
        return $null
    }

    $sourceGuid = $legacyUser.objectGUID.Guid
    $targetUser = Get-ADUser -Server $TargetDC `
        -LDAPFilter "($BackrefAttribute=$sourceGuid)" `
        -Properties $BackrefAttribute -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $targetUser) {
        Write-Log "No target match for legacy GUID $sourceGuid (sam=$LegacySam, forest=$SourceForest, lookup attr=$BackrefAttribute). Has provisioning run yet?" WARN
        return $null
    }
    return $targetUser
}

function Set-TargetPassword {
    param([Microsoft.ActiveDirectory.Management.ADUser]$TargetUser, [string]$NewPassword)
    $secure = ConvertTo-SecureString -String $NewPassword -AsPlainText -Force
    try {
        Set-ADAccountPassword -Server $TargetDC `
            -Identity $TargetUser.DistinguishedName `
            -NewPassword $secure -Reset -ErrorAction Stop
        Write-Log "Password set on target user $($TargetUser.SamAccountName)"
        return $true
    } catch {
        Write-Log "Set-ADAccountPassword FAILED for $($TargetUser.SamAccountName): $_" ERROR
        return $false
    }
}
#endregion

#region HTTP listener
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($ListenPrefix)
$listener.Start()
Write-Log "=== Broker listening on $ListenPrefix ==="

while ($listener.IsListening) {
    try {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response

        # mTLS auth — we trust client thumb, not just any cert chain
        $clientCert = $req.GetClientCertificate()
        if (-not $clientCert) {
            $res.StatusCode = 401
            $res.Close()
            Write-Log "Rejected: no client cert from $($req.RemoteEndPoint)" WARN
            continue
        }
        $thumb = $clientCert.Thumbprint.ToUpper()
        if ((Get-AllowedThumbs) -notcontains $thumb) {
            $res.StatusCode = 403
            $res.Close()
            Write-Log "Rejected: client cert $thumb not on allow-list (from $($req.RemoteEndPoint))" WARN
            continue
        }

        if ($req.HttpMethod -ne 'POST' -or $req.Url.AbsolutePath -ne '/sync') {
            $res.StatusCode = 404
            $res.Close()
            continue
        }

        $reader = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
        $body = $reader.ReadToEnd()
        $reader.Close()

        $payload = $body | ConvertFrom-Json
        $forest = $payload.sourceForest
        $sam    = $payload.sAMAccountName
        $pwd    = $payload.password

        Write-Log "Recv pwd change: forest=$forest sam=$sam (cert=$thumb)"

        $targetUser = Get-TargetMatch -SourceForest $forest -LegacySam $sam
        $resultStatus = 'no-match'
        if ($targetUser) {
            $ok = Set-TargetPassword -TargetUser $targetUser -NewPassword $pwd
            $resultStatus = if ($ok) { 'ok' } else { 'set-failed' }
        }

        # zero the password
        $pwd = $null
        [System.GC]::Collect()

        $resBody = @{ status = $resultStatus } | ConvertTo-Json -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($resBody)
        $res.ContentType = 'application/json'
        $res.StatusCode = 200
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.Close()

    } catch {
        Write-Log "Listener loop error: $_" ERROR
        try { $ctx.Response.StatusCode = 500; $ctx.Response.Close() } catch { }
    }
}
#endregion
