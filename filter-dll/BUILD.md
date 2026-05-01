# Building the password filter DLL

You will compile this on a **dev workstation**, not on a DC. The DC just
receives the signed binary later.

## Important: read this first

Before doing ANY of the below, run `scripts/preflight-check.ps1` from the project
root against your source DCs. The output tells you which signing strategy
applies. Specifically, **if any DC has `RunAsPPL=1` or `RunAsPPL=2`, this
self-signed approach will not work** — you'll need either Microsoft LSA-plugin
signing (paid, ~3 weeks turnaround, requires EV cert) or to disable
RunAsPPL on those DCs (not recommended).

## OS compatibility

The same DLL binary works on:
- Windows Server 2016 (x64)
- Windows Server 2019 (x64)
- Windows Server 2022 (x64)
- Windows Server 2025 (x64)

We target the lowest common denominator (`_WIN32_WINNT=0x0A00`, which is
Windows 10 / Server 2016+) so one build deploys everywhere. The C code uses
only stable Win32/LSA APIs that have been unchanged since Windows 2000.

Do NOT compile separately per OS. One x64 build, sign once, deploy everywhere.

## Prerequisites

1. **Visual Studio Build Tools 2022** (free) OR Visual Studio Community.
   Install the "Desktop development with C++" workload.
   Download: https://visualstudio.microsoft.com/downloads/
2. **Windows 11 SDK** (comes with the C++ workload).
3. **VS Code** with Claude Code installed.
4. A code-signing certificate. Options:
   - **Lab**: a self-signed cert is fine (instructions below). Only works if
     RunAsPPL is OFF on every target DC.
   - **Production internal**: enterprise CA-issued code-signing cert. Same
     constraint — only works without RunAsPPL.
   - **Production with RunAsPPL**: Microsoft LSA-plugin signing program.
     Requires EV cert (~$300-500 USD/year), ~2-3 weeks turnaround. Outside
     the "zero budget" scope.

## Step-by-step with Claude Code

Open this folder (`filter-dll/`) in VS Code. Open the Claude Code
panel and paste **the prompt below verbatim**:

---

> Build `passferry_filter.dll` for x64 from `passferry_filter.c` using the MSVC
> toolchain (`cl.exe`), exporting the symbols listed in `passferry_filter.def`.
> Target Windows Server 2016+ (x64) — use `_WIN32_WINNT=0x0A00`. Output should
> be `passferry_filter.dll` plus the `.pdb` file. Use these flags: `/LD /O2 /W4
> /GS /Zi /D_WIN32_WINNT=0x0A00 /DUNICODE /D_UNICODE`. Link with the .def
> file via `/DEF:passferry_filter.def /MACHINE:X64 /SUBSYSTEM:WINDOWS /DLL`.
> After build, verify exports with `dumpbin /EXPORTS passferry_filter.dll`
> — you should see `InitializeChangeNotify`, `PasswordChangeNotify`, and
> `PasswordFilter`. Also run `dumpbin /HEADERS passferry_filter.dll | findstr
> "machine"` to confirm it's `(x64)`.

---

Claude Code will run something like:

```cmd
cl /nologo /LD /O2 /W4 /GS /Zi ^
   /D_WIN32_WINNT=0x0A00 /DUNICODE /D_UNICODE ^
   passferry_filter.c ^
   /link /DEF:passferry_filter.def /MACHINE:X64 ^
         /SUBSYSTEM:WINDOWS /DLL ^
         /OUT:passferry_filter.dll
```

Then verify:

```cmd
dumpbin /EXPORTS passferry_filter.dll
dumpbin /HEADERS passferry_filter.dll | findstr machine
```

Expected output: 3 exports, `machine (x64)`.

## Code signing

### Lab / self-signed (no RunAsPPL on any target DC)

```powershell
$cert = New-SelfSignedCertificate `
    -Subject "CN=PassFerryFilter Lab Signing" `
    -Type CodeSigningCert `
    -CertStoreLocation Cert:\CurrentUser\My `
    -KeyUsage DigitalSignature `
    -KeyAlgorithm RSA -KeyLength 2048 `
    -NotAfter (Get-Date).AddYears(2)

Export-Certificate -Cert $cert -FilePath .\PassFerryFilter-Lab.cer

Set-AuthenticodeSignature `
    -FilePath .\passferry_filter.dll `
    -Certificate $cert `
    -TimestampServer 'http://timestamp.digicert.com' `
    -HashAlgorithm SHA256
```

On every DC where you'll deploy: import `PassFerryFilter-Lab.cer` into
**Trusted Publishers** (Local Machine store).

### Production internal CA

Same `Set-AuthenticodeSignature`, just point `-Certificate` at your
CA-issued cert. Trusted Publisher import not needed if your enterprise CA
chain is already trusted by domain-joined machines.

### Production with RunAsPPL

Out of scope for the zero-budget design. If you need this, the path is:
1. Buy EV code-signing cert
2. Enroll in Microsoft Partner Center
3. Sign your DLL with the EV cert
4. Submit through "File-sign an LSA plug-in" program
5. Microsoft countersigns
6. Deploy the Microsoft-countersigned binary

## Deploy to a DC (manual, lab)

⚠️ **CRITICAL**: read the `Notification Packages` section carefully. Getting
this wrong will silently break Specops, breached-password protection, fine-
grained password policies, and the Microsoft default password complexity
filter ALL AT ONCE.

```powershell
# On the DC, as admin:
Stop-Service -Name "PassFerryForwarder" -ErrorAction SilentlyContinue
Copy-Item .\passferry_filter.dll C:\Windows\System32\

# === REGISTER FILTER — APPEND, NEVER REPLACE ===
$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
$current = (Get-ItemProperty -Path $key -Name 'Notification Packages').'Notification Packages'

# SAFETY: print what's there first, so you can revert if anything goes wrong
Write-Host "Current Notification Packages:" -ForegroundColor Cyan
$current | ForEach-Object { Write-Host "  $_" }
$current | Out-File "C:\notification-packages-before-$(Get-Date -Format yyyyMMdd-HHmmss).txt"

# Only add if not already present
if ($current -notcontains 'passferry_filter') {
    $new = @($current) + 'passferry_filter'   # APPEND, do NOT replace
    Set-ItemProperty -Path $key -Name 'Notification Packages' `
        -Value $new -Type MultiString
    Write-Host "Added passferry_filter. New value:" -ForegroundColor Green
    (Get-ItemProperty -Path $key -Name 'Notification Packages').'Notification Packages' |
        ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "passferry_filter already registered — no change made." -ForegroundColor Yellow
}

# Reboot REQUIRED — Notification Packages is read at LSASS startup
# DO THIS DURING A MAINTENANCE WINDOW
Restart-Computer -Force
```

After reboot, verify:

```powershell
# Confirm registry still has all original packages PLUS ours
(Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' `
    -Name 'Notification Packages').'Notification Packages'

# Confirm DLL loaded into LSASS
tasklist /m passferry_filter.dll
# expect: lsass.exe ... passferry_filter.dll

# Check System event log for any LSASS warnings about the filter
Get-WinEvent -LogName 'System' -MaxEvents 50 |
    Where-Object { $_.Message -match 'lsa|notification|filter' } |
    Format-List TimeCreated, LevelDisplayName, Message

# Check Code Integrity log (Event 3033 = signing rejected)
Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 20 |
    Where-Object { $_.Id -eq 3033 } |
    Format-List
```

## Coexistence with Specops (or other 3rd-party password filters)

Architecturally we coexist fine — see section 4 of `docs/ISSUES-AND-RISKS.md`.
But validate after install:

1. **Specops still rejects bad passwords**. Try changing a test user's
   password to something on Specops's blocklist (e.g., `Password123!`).
   Specops should reject. If it doesn't, you've broken Specops.
2. **Default complexity still enforced**. Try setting a password that
   violates Default Domain Policy (e.g., too short). Should reject. If it
   doesn't, you wiped `scecli` from `Notification Packages` — restore
   immediately.
3. **Our filter still fires**. Change a password to something both Specops
   and DDP allow. Check the forwarder log on the DC — should show "Forwarded
   pwd change for...".

If 1 or 2 fails: you've broken existing security. Roll back IMMEDIATELY using
the BEFORE-state file you saved to `C:\notification-packages-before-*.txt`:

```powershell
$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
$before = Get-Content "C:\notification-packages-before-<TIMESTAMP>.txt" | Where-Object { $_ }
Set-ItemProperty -Path $key -Name 'Notification Packages' -Value $before -Type MultiString
Restart-Computer -Force
```

This is why we save the BEFORE state in the deploy script. Always.

## What can go wrong

| Symptom | Cause | Fix |
|---------|-------|-----|
| DC won't boot, recovery loop | DLL crashed in `DllMain` or LSASS rejected signature | Boot to DSRM, remove name from `Notification Packages`, reboot |
| DLL loads but filter never fires | Name in registry has `.dll` extension | Remove `.dll` — registry value is the bare module name |
| Event 3033 in Code Integrity / Operational | RunAsPPL=1 and DLL not Microsoft-signed | Either disable RunAsPPL (security regression) or get Microsoft-signed |
| LSASS event "filter failed to load" | Bad signature, wrong arch, or missing dependency | `dumpbin /DEPENDENTS` and verify x64; check Trusted Publisher |
| `tasklist /m` doesn't show DLL | Filter didn't load (signing or path issue) | Check Code Integrity log, verify DLL is in `C:\Windows\System32\` |
| Specops stops enforcing | You replaced instead of appended | Restore `SPP3FLT` to `Notification Packages`, reboot |
| Default password policy stops working | You replaced `scecli` | Restore `scecli`, reboot, panic less |
| Forwarder service doesn't see writes | Pipe DACL too restrictive | See `scripts/FORWARDER-RUN.md` — pipe owner is the service |

**Always test on a non-prod DC first. Always have console access (iLO/iDRAC/IPMI).**
**Always record `Notification Packages` BEFORE state and have a rollback ready.**
