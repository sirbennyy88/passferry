# Sync broker — install & run

## Server prep

On `broker.target.example`:

1. Install **RSAT-AD-PowerShell**:
   ```powershell
   Install-WindowsFeature -Name RSAT-AD-PowerShell
   ```
2. Make sure the broker server can resolve all source DCs by FQDN (DNS
   conditional forwarders, or a stub zone).
3. Ensure LDAPS is configured on `target-dc01.target.example` (port 636 reachable).

## Service account (gMSA in target)

```powershell
# On a Target DC:
New-ADServiceAccount -Name 'gmsa-passferry-broker' `
    -DNSHostName 'gmsa-passferry-broker.target.example' `
    -PrincipalsAllowedToRetrieveManagedPassword 'broker$'

# On broker.target.example:
Install-ADServiceAccount -Identity 'gmsa-passferry-broker'
```

### Delegate the right rights

The broker must be able to **reset passwords** on the target OU only — not
domain-wide. In ADUC: target OU → Delegate Control → `SOURCE-A\gmsa-passferry-broker$`
→ "Reset user passwords and force password change at next logon" → unbound.
Repeat for each OU containing migrated users.

The broker also needs **read** rights on each source forest's user OU (to
resolve SAM → objectGUID). A Domain Users-equivalent read is fine — no
write rights in legacy.

## Server cert + HTTP.SYS binding

Issue a server cert with SAN `broker.target.example`. Place in `LocalMachine\My`.
Note the thumbprint.

Bind it to port 8443 with **client cert negotiation enabled**:

```cmd
netsh http add sslcert ipport=0.0.0.0:8443 ^
    certhash=<SERVER_THUMB> ^
    appid={00000000-0000-0000-0000-000000000000} ^
    clientcertnegotiation=enable

netsh http add urlacl url=https://+:8443/ user="SOURCE-A\gmsa-passferry-broker$"
```

(The URL ACL must use the gMSA. If you change accounts later, `delete` and
re-add.)

## Allow-list of forwarder client certs

Create `C:\ProgramData\PassFerryBroker\allowed-clients.txt`. One thumbprint per
line, comments with `#`:

```
# source-a DCs
ABCDEF0123456789...
1234567890ABCDEF...
# source-b DCs
0000111122223333...
```

The broker rereads this on every request, so you can add/remove DCs without
restarting the service.

## Install with NSSM

```powershell
C:\Tools\nssm\nssm.exe install PassFerryBroker powershell.exe
C:\Tools\nssm\nssm.exe set PassFerryBroker AppParameters `
    "-NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\PassFerryBroker\broker.ps1 -ServerCertThumb <SERVER_THUMB> -TargetDC target-dc01.target.example"
C:\Tools\nssm\nssm.exe set PassFerryBroker ObjectName 'TARGET\gmsa-passferry-broker$' ''
C:\Tools\nssm\nssm.exe set PassFerryBroker Start SERVICE_AUTO_START
C:\Tools\nssm\nssm.exe set PassFerryBroker AppStdout C:\ProgramData\PassFerryBroker\stdout.log
C:\Tools\nssm\nssm.exe set PassFerryBroker AppStderr C:\ProgramData\PassFerryBroker\stderr.log

Start-Service PassFerryBroker
```

## Firewall

```powershell
New-NetFirewallRule -DisplayName 'PassFerryBroker mTLS in' `
    -Direction Inbound -Protocol TCP -LocalPort 8443 `
    -RemoteAddress <legacy-DC-subnets> -Action Allow
```

## Smoke test from a forwarder DC

```powershell
$cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq '<CLIENT_THUMB>' }
$body = '{"sourceForest":"source-a","sAMAccountName":"testuser1","password":"Sup3r-Tempor4ry!","timestamp":"2026-04-30T12:00:00Z"}'
Invoke-RestMethod -Uri https://broker.target.example:8443/sync `
    -Method Post -Body $body -ContentType 'application/json' `
    -Certificate $cert
# expect: { "status": "ok" }   or   "no-match"   if testuser1 isn't provisioned yet
```
