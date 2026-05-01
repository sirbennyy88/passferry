# Known issues, risks, and pre-flight checks

Read this BEFORE building. There are several things that will silently break
the deployment if you don't validate them up front.

## 1. extensionAttribute15 may already be in use

The provisioning script and broker assume `extensionAttribute15` is free for
us to use as the legacy-objectGUID back-reference. **Validate before deploying.**

Run on a Target DC:

```powershell
# Are any of extensionAttribute1..15 already populated?
1..15 | ForEach-Object {
    $attr = "extensionAttribute$_"
    $count = (Get-ADUser -Filter "$attr -like '*'" -Properties $attr | Measure-Object).Count
    [pscustomobject]@{ Attribute = $attr; PopulatedUsers = $count }
}
```

What the result means:

| Result for `extensionAttribute15` | What to do |
|----------------------------------|------------|
| 0 populated users | Use it as planned |
| Some populated, all by Exchange/another tool | Pick a different one (1-15) and update code |
| Used inconsistently / unknown purpose | Find the owner first; don't just stomp on it |

**Other candidates if 15 is taken**: `extensionAttribute1` through `14` (same
deal — check each), or any other spare attribute your org isn't using. Common
already-claimed ones: 1-3 are often used by Exchange/Outlook for custom
address book fields. 14-15 are often free. `info` (the "notes" tab) is
sometimes free but is replicated to GAL so don't use it.

**Safer alternative — `employeeID`**: if your HR data populates this and it's
unique per person across all forests, use it instead. It's a published Active
Directory attribute, indexed, and semantically correct for this purpose. To
switch:

- In `scripts/provisioning.ps1`: change `Build-TargetAttributes` to copy
  `employeeID` from legacy → target (already in the AttributeMap default), and
  remove the `extensionAttribute15` stamping
- In `scripts/broker.ps1`: change `Get-TargetMatch` to look up by
  `employeeID` instead of `extensionAttribute15`
- The forwarder needs to send `employeeID` in the JSON payload — which means
  the forwarder must do a local lookup on legacy to fetch it after the pipe
  read

If `employeeID` is empty for any users, fallback chain: `employeeID` → `mail` →
`userPrincipalName`. Code that hardcodes a single attribute is brittle. Bake
the chain into `Get-TargetMatch`.

## 2. Source forests on Server 2022 (or older)

The DLL code is fully compatible with Server 2016, 2019, 2022, and 2025.
Same Win32 API, same registry path, same export signatures, same DLL binary.
**Compile once, deploy to any of them.**

Things that DO change with older OSes:

| Concern | 2016 | 2019 | 2022 | 2025 |
|---------|------|------|------|------|
| Filter API contract | identical | identical | identical | identical |
| `Notification Packages` registry | identical | identical | identical | identical |
| Default RunAsPPL (LSA Protection) | off | off | off, but easy to enable | varies; check |
| Code-signing required | only if RunAsPPL | only if RunAsPPL | only if RunAsPPL | only if RunAsPPL |
| RC4 by default | yes | yes | yes (but warn) | deprecated |
| ADWS default | yes | yes | yes | yes |

**The 2022 implication you care about**: if any 2022 DC has RunAsPPL enabled
(some orgs turned it on as part of credential hardening), our self-signed
DLL **will not load**. See section 3.

**Pre-2016 forests**: not supported by this design. If your friend has a 2012
R2 DC kicking around, it'll work technically (the API is the same), but you're
already past Microsoft's mainstream support and there are unrelated issues
(SMB1, SChannel defaults, etc.). Get them off it before doing this project.

## 3. LSA Protection (RunAsPPL) blocks unsigned filters

This is the big one. If a DC has `HKLM\SYSTEM\CurrentControlSet\Control\Lsa\
RunAsPPL = 1` or `2`, only DLLs signed by Microsoft (not by you, not by your
CA) can load into LSASS. Self-signed = blocked. Enterprise-CA-signed =
blocked. The DLL will silently fail to load, you'll get Event ID 3033 in
Code Integrity / Operational, and password sync just won't work.

### How to check on each DC, before deploying

```powershell
$lsaKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
$ppl = (Get-ItemProperty -Path $lsaKey -Name 'RunAsPPL' -ErrorAction SilentlyContinue).RunAsPPL
if ($ppl -eq 1 -or $ppl -eq 2) {
    Write-Host "BLOCKER: LSA Protection enabled (RunAsPPL=$ppl). Microsoft signing required." -ForegroundColor Red
} else {
    Write-Host "OK: LSA Protection not enabled. Self-signed cert will work."
}
```

Also check via Windows Security UI: `Device security → Core isolation details
→ Local Security Authority protection`.

### Options if RunAsPPL is enabled

**Option A — Disable RunAsPPL on source DCs (NOT RECOMMENDED)**.
You'd be lowering security on a DC. Don't do this. If your security team
turned it on, they turned it on for a reason.

**Option B — Get the DLL Microsoft-signed (LSA plugin signing)**.
Microsoft has a partner program for this. Requires:
- An EV Code Signing certificate (~300-500 USD/year)
- Enrollment in Microsoft Partner Center
- Submission of the DLL through the LSA plug-in signing program
- Microsoft countersigns it
- Free for the program, but the EV cert is not free

This is the legit path. ~2-3 weeks turnaround typically. **No longer "zero
budget"** because of the EV cert cost — but it's a one-time annual cost, not
per-seat licensing.

**Option C — Sidestep by deploying only on DCs without RunAsPPL**.
If only some source DCs have RunAsPPL, deploy the filter only to the others.
Caveat: a password change serviced by an unfiltered DC won't propagate. So
this only works if you can guarantee password changes always go to one of
the filtered DCs (PDC emulator? specific site?). Fragile.

**Option D — Different architecture: scheduled diff sync (no DLL)**.
If RunAsPPL is non-negotiable AND budget is truly zero AND you can tolerate
~15-minute lag: skip the DLL, write a scheduled task that polls
`pwdLastSet` on legacy users every N minutes, and... no, you can't read
password hashes without DCSync rights, and DCSync logs everything as a
security incident. **This path is closed without an LSA hook.**

**Recommendation**: at minimum, audit every source DC for RunAsPPL today.
If any have it on, the design choice changes. Don't find out at deployment
time.

## 4. Coexistence with Specops Password Policy (or similar)

**Architecturally, multiple LSA password filters coexist fine.** Microsoft
designed `Notification Packages` as a list specifically so several filters
can run side-by-side. Our filter doesn't reject anything (always returns
`STATUS_SUCCESS`), so it can never veto a password change that Specops
would otherwise allow.

But there are real failure modes you must avoid:

### 4a. Don't replace `Notification Packages` — append

The single biggest risk. A typical DC with Specops has:

```
Notification Packages = scecli SPP3FLT
```

If you do `Set-ItemProperty ... -Value 'passferry_filter'` you've **wiped
both the Microsoft default password policy filter AND Specops**. Outcomes:
- All Microsoft password complexity rules stop working
- All Specops policies (including breached-password protection) stop working
- Nobody notices until the next compliance audit or breach

The provisioning script and the GPO recipe in `docs/HARDENING.md` use
**Update / append**, never Replace. Verify this manually before pushing:

```powershell
$current = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'Notification Packages').'Notification Packages'
$current   # should show all existing packages PLUS passferry_filter
```

### 4b. Don't crash. Specops won't save you.

Each filter runs in LSASS. If our filter throws an unhandled exception, it
takes down LSASS, which takes down the DC. Specops being installed doesn't
isolate them — they're all in the same process. The `__try / __except` block
in the C code is non-negotiable.

### 4c. Order in the registry doesn't matter for `PasswordChangeNotify`

Specops's filter (SPP3FLT) is a **complexity** filter — it runs in
`PasswordFilter` callback and can REJECT a password. Our filter only runs
in `PasswordChangeNotify` (after the change is accepted). They can't conflict
on the same callback because they're doing different jobs.

Confirmed safe. But verify in the lab anyway: install Specops first in a
test forest, then add our filter, then confirm:
- Specops blocks weak passwords (test: try `Pa$$w0rd1` if it's on their
  blocklist)
- Strong password changes succeed AND get synced to target

### 4d. Cluster Authentication Manager (ClusAuthMgr)

If any source DC has Failover Cluster services installed (rare on a DC, but
possible), ClusAuthMgr is registered as a password filter and there's an
unconfirmed report of it conflicting with custom filters. **Don't install
Failover Cluster on a DC.** If it's already there, that's a separate
remediation conversation before this project.

### 4d. Other known LSA filter products to check for

Run on each source DC:

```powershell
$packages = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'Notification Packages').'Notification Packages'
$packages
```

Recognized values:

| Value | What it is | Coexists with us? |
|-------|-----------|-------------------|
| `scecli` | Microsoft default password policy | yes — leave it alone |
| `rassfm` | RAS server filter (only on RAS servers) | yes |
| `SPP3FLT` | Specops Password Policy | yes |
| `nppwd` | nFront Password Filter | yes |
| `AzureADPasswordProtection*` | Microsoft Entra Password Protection (on-prem agent) | yes — but read note below |
| `LdapEnforcer` | Various third-party LDAP enforcers | yes |
| `ClusAuthMgr` | Failover Cluster auth | risky, see 4c |

If there's something there you don't recognize, **find out what it is before
proceeding**. Not in your inventory = somebody installed something you don't
know about.

**Note on Entra Password Protection (on-prem)**: if your friend is already
running this on their source DCs to enforce Entra password policies, no
conflict with us. It's complementary — they enforce password QUALITY, we
sync password CHANGES.

## 5. Password policy mismatch between legacy and target

If legacy allows shorter/simpler passwords than target:

1. User changes password on legacy: succeeds (legacy policy allows it)
2. Filter captures, forwards to broker
3. Broker calls `Set-ADAccountPassword` on target
4. **target rejects** because it doesn't meet target's policy
5. target user is now out-of-sync — old password still active in target

The broker logs this as `set-failed`, but **the user has no idea**. They
think their password sync worked.

Mitigation options, pick one:

- **Align policies first**: target's policy ≤ legacy's policy. Cleanest.
- **Detect and alert**: when broker logs `set-failed`, send an email to the
  user telling them their target password didn't update and they need to use
  it again next time
- **Pre-validate in the broker**: read target's password policy via PowerShell,
  check the password against it BEFORE calling `Set-ADAccountPassword`. Tell
  the user upfront. Adds complexity, mostly worth it.

The prototype just logs. Production should at minimum send a notification.

## 6. Fine-grained password policies (PSOs)

If target uses PSOs (Password Settings Objects) targeted at specific groups,
the broker is bypassing them in a sense — `Set-ADAccountPassword` enforces
the user's effective policy, but only on the **target** account in target.

Side effect: if a PSO in target is stricter than the source legacy policy,
section 5 applies: silent sync failures.

Audit target's PSOs:

```powershell
Get-ADFineGrainedPasswordPolicy -Filter * | Select-Object Name, Precedence, MinPasswordLength, ComplexityEnabled
```

If any apply to OUs that will hold migrated users, factor them into the
policy alignment in section 5.

## 7. RC4 / Kerberos encryption types

Server 2025 deprecates RC4 aggressively. Older DCs in source forests may
still negotiate RC4 by default. The cross-forest LDAPS calls our broker
makes back to source DCs (for the SAM → GUID lookup) need to negotiate
AES, not RC4.

Check on each source DC:

```powershell
Get-ADDomain | Select-Object Forest, NetBIOSName
$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters'
(Get-ItemProperty -Path $key -Name SupportedEncryptionTypes -ErrorAction SilentlyContinue).SupportedEncryptionTypes
# 0x18 = AES128 + AES256 only (good)
# 0x1C = AES + RC4 (acceptable, RC4 still allowed)
# 0x07 = RC4 + DES + DES56 (bad, modernize)
# null/missing = default = depends on OS version
```

If RC4 is still in heavy use, the broker → legacy LDAPS calls may fail with
"The encryption type requested is not supported by the KDC" once Server
2025 starts refusing RC4 entirely. Plan to enable AES on source domain
trusts before the rollout (`ksetup /setenctypeattr <trust> AES256-CTS-HMAC-SHA1-96`).

## 8. Services / scheduled tasks running on user accounts

If any service or scheduled task on legacy or target runs as a user account
that gets password-synced, the service won't know its password changed.
Service breaks at next start.

Inventory before rollout:

```powershell
# On each member server / DC
Get-CimInstance Win32_Service | Where-Object {
    $_.StartName -and
    $_.StartName -notmatch '^(LocalSystem|NT AUTHORITY|NT SERVICE)'
} | Select-Object Name, StartName

# Scheduled tasks
Get-ScheduledTask | Where-Object {
    $_.Principal.UserId -and
    $_.Principal.UserId -notmatch '^(SYSTEM|LOCAL SERVICE|NETWORK SERVICE)' -and
    $_.Principal.LogonType -eq 'Password'
} | Select-Object TaskName, @{N='User';E={$_.Principal.UserId}}
```

For any hits: migrate to gMSAs (preferred) or document that those passwords
must NOT be synced (filter the user out by group membership in the
provisioning script).

## 9. Legacy users with no `mail` or `displayName`

Provisioning script copies these by default. If they're empty on legacy, the
target user gets created with no email, which:
- Breaks the Entra Connect sync (mail-enabled requires `mail`)
- Breaks any "send notification to user" features in this design
- Makes the target user borderline unusable

Before first run, audit:

```powershell
foreach ($f in @('source-a.example','source-b.example')) {
    $count = (Get-ADUser -Server $f -Filter * -Properties mail,displayName |
        Where-Object { -not $_.mail -or -not $_.displayName } |
        Measure-Object).Count
    Write-Host "$f : $count users with missing mail/displayName"
}
```

Decide policy: skip them, error on them, or backfill before sync.

## 10. Initial backfill (existing users with passwords already set)

The DLL only captures FUTURE password changes. Existing users who don't
change their password keep their old legacy password indefinitely with no
matching target password.

Three options:

- **Wait it out**: as users naturally change passwords (max age policy), they
  get synced. Could take 90+ days for full coverage.
- **Force change at next logon**: stamp `pwdLastSet=0` on legacy users in
  scope. Helpdesk volume spike incoming. Plan capacity.
- **Migration password**: at provisioning time, generate a known-random temp
  password, set it on the target user, email it to the user securely (or to a
  password manager). Then on first legacy logon → password change → sync
  catches up. Most disruptive but most controlled.

The prototype provisioning generates a 24-char random temp password and just
discards it (see `New-RandomPassword`). For prod, email it to the user.

## Pre-flight checklist (run before you write any code)

In each source forest, on each DC:

- [ ] OS version recorded (2016/2019/2022/2025)
- [ ] `RunAsPPL` value recorded (0 / 1 / 2 / absent)
- [ ] `Notification Packages` value recorded (full list)
- [ ] Specops or other 3rd-party password tools inventoried
- [ ] Failover Cluster services NOT installed (uninstall if it is)
- [ ] Kerberos encryption types: AES enabled
- [ ] Console/iLO access verified

In target:

- [ ] `extensionAttribute15` (or chosen attribute) confirmed unused
- [ ] Password policy documented; ≤ strictest legacy policy OR alignment plan made
- [ ] PSOs inventoried
- [ ] Target OU created with delegated rights

Across both:

- [ ] Service-account password hygiene audited (gMSAs preferred)
- [ ] Users with missing required attributes (mail, displayName) listed
- [ ] Initial backfill strategy decided
- [ ] Code-signing strategy decided (self-signed lab → CA-signed prod, OR
      Microsoft-signed if any DC has RunAsPPL=1)
