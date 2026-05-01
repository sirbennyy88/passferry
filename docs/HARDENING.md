# Hardening & rollout

Lab works → now make it not embarrassing in production. Realistic budget:
**a full weekend**, plus a half-day rollback rehearsal on a weeknight before
the real deploy.

## Things the prototype skips that production needs

### 1. Retry queue in the forwarder

The prototype drops password changes if the broker is down. Production must
queue and retry.

**Implementation sketch**:
- On send failure, write the payload to `C:\ProgramData\PassFerryForwarder\queue\<guid>.bin`
- Encrypt the file with **DPAPI machine scope** (`ProtectedData` class). The
  forwarder service running as gMSA can decrypt; nothing else on the box can.
- On startup and every 60s, drain the queue: try each file, delete on success,
  leave on failure with attempt counter in filename.
- Cap queue at 1000 entries — after that, refuse new writes and alert. Better
  to miss a few changes loudly than fill the disk silently.

### 2. Forwarder pipe payload should include source objectGUID

The prototype has the broker do a round-trip back to the source DC just to
get the GUID. That's an extra failure point. Better:

- Forwarder, after reading the pipe, immediately calls `Get-ADUser` on the
  local source DC with the SAM (cheap, in-process) and gets the GUID
- Adds GUID to the JSON before posting to broker
- Broker becomes a pure pass-through: GUID → extensionAttribute15 lookup → set

This also means the broker doesn't need RSAT for the source forests, just
for target. Smaller attack surface on the broker.

### 3. Health endpoint + monitoring

Add `GET /health` to the broker. Returns `{"status":"ok","targetDC":"reachable","queueDepth":0}`.
Point your monitoring at it.

Forwarder: emit a heartbeat every 5 minutes to a known log file. Have your
monitoring alert if it stops.

### 4. Audit trail

Both forwarder and broker logs need to be:
- Rotated daily, kept 90 days
- Shipped to a SIEM or central log host
- Locked down: only the service account can write, only Domain Admins can
  read

`Set-Acl` on `C:\ProgramData\PassFerryForwarder` and `...\PassFerryBroker`. Owner
= the gMSA, allow Domain Admins read, deny Authenticated Users.

### 5. Cert rotation runbook

Each forwarder DC has a client cert that expires. Each broker server has a
server cert that expires. Document:

- Where the certs are issued (template name, CA)
- How to rotate without downtime: issue new cert, add new thumb to allow-list,
  switch service config to new thumb, remove old thumb from allow-list
- Calendar reminder 30 days before earliest expiry

### 6. Disable RC4 explicitly

Server 2025 deprecates RC4 but doesn't always block it. For LDAPS to target,
verify only AES is in use:

```powershell
# On Target DCs:
$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters'
New-ItemProperty -Path $key -Name 'SupportedEncryptionTypes' `
    -Value 0x18 -PropertyType DWord -Force
# 0x18 = AES128 + AES256, no RC4, no DES
```

### 7. Don't log passwords. Ever.

Audit your code:

```powershell
Select-String -Path *.ps1 -Pattern 'password' -CaseSensitive:$false
```

Make sure no `Write-Log` ever takes `$pwd` as input. The prototype is clean
on this; verify after any future edits.

## GPO deployment of the DLL

For each source forest, create a GPO scoped to **Domain Controllers** OU:

### Step 1 — Trusted Publisher

`Computer Config → Policies → Windows Settings → Security Settings →
Public Key Policies → Trusted Publishers` → import your code-signing cert.

### Step 2 — Deploy the DLL file

Use a software distribution method, *not* GPO file copy. GPO file copy is
fragile. Options:
- SCCM / Intune package (preferred if you have it)
- Manual deploy via PowerShell remoting + DSC pull
- For 3-4 DCs per forest, honestly: just do it by hand with PowerShell once

### Step 3 — Registry entry for `Notification Packages`

`Computer Config → Preferences → Windows Settings → Registry`:
- Hive: HKLM
- Key: `SYSTEM\CurrentControlSet\Control\Lsa`
- Value name: `Notification Packages`
- Type: REG_MULTI_SZ
- Action: **Update** (not Replace — there are other values like `scecli`)
- Value: existing values + `passferry_filter` on its own line

⚠️ Replace mode will wipe `scecli` and break your password policies. Always
Update with the full list.

### Step 4 — Forwarder service install

GPO `Scheduled Task` (immediate task, run-once) that pulls the forwarder
.ps1 from a SYSVOL location and runs `nssm install`. Or do it by hand on
each DC — for 3-4 DCs per forest you're not winning anything by automating.

### Step 5 — Stagger rollout

**Never deploy to all DCs in a forest at once.** If the DLL has a latent
bug that takes down LSASS, you've taken down all auth.

Suggested order per forest:
1. Day 1: one DC, watch for 24h
2. Day 2: one more DC if Day 1 is clean
3. Day 3+: rest

## Rollback procedure (rehearse before prod!)

If a DC starts misbehaving and you suspect the filter:

```powershell
# As admin on the DC:
Stop-Service PassFerryForwarder

# Remove from Notification Packages
$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
$current = (Get-ItemProperty -Path $key -Name 'Notification Packages').'Notification Packages'
$new = $current | Where-Object { $_ -ne 'passferry_filter' }
Set-ItemProperty -Path $key -Name 'Notification Packages' -Value $new -Type MultiString

Restart-Computer -Force
```

If the DC won't boot at all:
- Boot to DSRM (F8 / advanced boot options)
- Same registry edit
- Reboot

You should rehearse this end-to-end on a lab DC at least once before
touching production.

## Pre-prod checklist

- [ ] DLL is signed with production code-signing cert (not lab cert)
- [ ] Lab cert removed from Trusted Publishers everywhere
- [ ] Forwarder client certs issued from production CA
- [ ] Broker server cert SAN matches actual broker FQDN
- [ ] Broker firewall rule restricts source IPs to source DC subnets
- [ ] Allow-list file `allowed-clients.txt` is owner-restricted, audited
- [ ] Logs ship to SIEM; tested by triggering a known event
- [ ] Health monitoring tested (kill broker → alert fires)
- [ ] Retry queue in forwarder implemented and tested
- [ ] Rollback rehearsed on a lab DC within last 7 days
- [ ] Console/iLO access verified for every source DC
- [ ] Change window scheduled, comms sent
- [ ] Backout decision tree documented (if X happens, do Y)

## What this whole stack does NOT do

Be honest with stakeholders about gaps:

- **No SID History migration** — add `Move-ADObject` to provisioning if needed
- **No GPO/OU/group migration** — out of scope, separate effort
- **No password reverse-sync** (target → Legacy) — one-way only
- **Initial password load** for users that exist in legacy *before* the DLL
  is deployed — they keep their old password until they next change it. If
  you need to flush them through, force a password change at next logon
  cluster-wide on the relevant OUs (be ready for the helpdesk calls).
- **Doesn't migrate workstations** — legacy users authenticating to legacy
  workstations still hit source DCs. The pipeline is for target being the
  source-of-truth identity store going forward.
