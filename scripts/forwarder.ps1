<#
.SYNOPSIS
    User-mode forwarder. Drains the PassFerryFilter named pipe and POSTs each
    captured password change to the sync broker over HTTPS with mTLS.

.DESCRIPTION
    Runs as a Windows service on every DC where the password filter DLL is
    installed. Wrap with NSSM (or sc.exe with srvany) — see RUN.md.

    The pipe is created HERE (not by the DLL). The DLL connects to it.
    Pipe DACL grants Write to LocalSystem only (LSASS runs as LocalSystem).
#>

[CmdletBinding()]
param(
    [string]$BrokerUrl       = 'https://broker.target.example:8443/sync',
    [string]$ClientCertThumb = '<thumbprint of client cert>',
    [string]$SourceForestTag = 'source-a',  # set per-DC via service args
    [string]$LogPath         = 'C:\ProgramData\PassFerryForwarder\forwarder.log'
)

#region Logging
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    Add-Content -Path $LogPath -Value $line
}
#endregion

#region Pipe server
Add-Type -AssemblyName System.Core

function New-PipeSecurity {
    # Allow LocalSystem to write (the DLL runs in LSASS = SYSTEM).
    # Allow this service's identity to read.
    $sec = New-Object System.IO.Pipes.PipeSecurity
    $sysSid = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'  # SYSTEM
    $rule1 = New-Object System.IO.Pipes.PipeAccessRule(
        $sysSid,
        [System.IO.Pipes.PipeAccessRights]::Write -bor [System.IO.Pipes.PipeAccessRights]::CreateNewInstance,
        [System.Security.AccessControl.AccessControlType]::Allow)
    $sec.AddAccessRule($rule1)

    # The service itself needs FullControl to create/own the pipe
    $self = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule2 = New-Object System.IO.Pipes.PipeAccessRule(
        $self,
        [System.IO.Pipes.PipeAccessRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow)
    $sec.AddAccessRule($rule2)
    return $sec
}

function Read-PipeMessage {
    param([System.IO.Pipes.NamedPipeServerStream]$Pipe)
    $reader = New-Object System.IO.BinaryReader($Pipe, [System.Text.Encoding]::Unicode, $true)
    try {
        $uLen = $reader.ReadUInt16()
        $userBytes = $reader.ReadBytes($uLen)
        $username = [System.Text.Encoding]::Unicode.GetString($userBytes)

        $pLen = $reader.ReadUInt16()
        $pwdBytes = $reader.ReadBytes($pLen)
        $password = [System.Text.Encoding]::Unicode.GetString($pwdBytes)

        # zero out the buffer ASAP
        for ($i = 0; $i -lt $pwdBytes.Length; $i++) { $pwdBytes[$i] = 0 }

        return [pscustomobject]@{
            Username = $username
            Password = $password
        }
    } finally {
        $reader.Dispose()
    }
}
#endregion

#region HTTPS forward
function Send-ToBroker {
    param([string]$Username, [string]$Password)

    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $ClientCertThumb }
    if (-not $cert) {
        Write-Log "Client cert $ClientCertThumb not found in LocalMachine\My" ERROR
        return $false
    }

    $body = @{
        sourceForest    = $SourceForestTag
        sAMAccountName  = $Username
        password        = $Password
        timestamp       = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Compress

    try {
        $resp = Invoke-RestMethod `
            -Uri $BrokerUrl `
            -Method Post `
            -Body $body `
            -ContentType 'application/json' `
            -Certificate $cert `
            -TimeoutSec 10
        Write-Log "Forwarded pwd change for $Username (forest=$SourceForestTag) -> broker accepted: $($resp.status)"
        return $true
    } catch {
        Write-Log "Broker POST failed for $Username : $_" ERROR
        return $false
    }
}
#endregion

#region Main loop
Write-Log "=== Forwarder starting (forest tag: $SourceForestTag, broker: $BrokerUrl) ==="

while ($true) {
    try {
        $sec = New-PipeSecurity
        $pipe = New-Object System.IO.Pipes.NamedPipeServerStream(
            'PassFerryFilter',
            [System.IO.Pipes.PipeDirection]::In,
            10,                                                 # max instances
            [System.IO.Pipes.PipeTransmissionMode]::Byte,
            [System.IO.Pipes.PipeOptions]::None,
            4096, 4096,
            $sec)

        Write-Log "Waiting for password change..."
        $pipe.WaitForConnection()

        $msg = Read-PipeMessage -Pipe $pipe
        $pipe.Disconnect()
        $pipe.Dispose()

        if ($msg.Username -and $msg.Password) {
            $ok = Send-ToBroker -Username $msg.Username -Password $msg.Password
            if (-not $ok) {
                # TODO: persist to a local retry queue (encrypted file, DPAPI)
                # For prototype, we just log and drop. Production MUST queue.
                Write-Log "DROPPED password change for $($msg.Username) — broker unreachable" WARN
            }
            # zero the password string (best-effort in PS — strings are immutable)
            $msg.Password = $null
            [System.GC]::Collect()
        }
    } catch {
        Write-Log "Pipe loop error: $_" ERROR
        Start-Sleep -Seconds 2
    }
}
#endregion
