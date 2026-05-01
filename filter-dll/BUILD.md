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

## Build environment setup (if you've never compiled a Windows DLL before)

Skip this section if `cl.exe` is on your PATH and you've used MSVC before. Otherwise, read carefully — this is where most first-time builds fail.

### Install Visual Studio Build Tools

Either of these works:

- **Visual Studio Build Tools 2022** — smaller download, command-line only. https://visualstudio.microsoft.com/downloads/ → "Tools for Visual Studio" → Build Tools 2022.
- **Visual Studio Community 2022 or 2026** — full IDE, includes Build Tools. Free for individual / OSS use.

Either way, during install, check the **"Desktop development with C++"** workload. This pulls in:

- MSVC compiler (`cl.exe`)
- Windows SDK (provides `ntsecapi.h`, `subauth.h`, `windows.h`)
- `dumpbin.exe`, `link.exe`, signing tools

### Required Windows SDK components

The C++ workload installs the SDK by default, but verify these subfolders exist after install:

```
C:\Program Files (x86)\Windows Kits\10\Include\<sdk-version>
├── ucrt\         (Universal C runtime)
├── shared\       (shared user/kernel headers)
├── um\           (user-mode headers — REQUIRED, this is what we need)
└── winrt\        (modern WinRT, not used)
```

If `um/` is missing, the workload installer didn't finish or didn't include the right components. The build will fail with errors like `cannot open include file: 'windows.h'`. Re-run the installer and explicitly tick the SDK option. The installer can take 10-30 minutes to finish downloading SDK components — wait it out before retrying the build.

### Verify cl.exe is reachable

`cl.exe` is **not** on your default PATH after install. You have three options:

1. **Use the "Developer Command Prompt for VS 2022"** (or 2026) — this is a regular `cmd.exe` with the MSVC environment pre-loaded. Start menu → search "Developer". Simplest option.
2. **Use the "Developer PowerShell for VS 2022"** — same thing for PowerShell.
3. **Manual environment activation** — from a regular shell, run:
   ```cmd
   "C:\Program Files\Microsoft Visual Studio\<version>\Community\VC\Auxiliary\Build\vcvars64.bat"
   ```
   After this, `cl.exe`, `dumpbin.exe`, etc. are on PATH for that shell session only.

Verify with:

```cmd
where cl
cl /?
```

If `where cl` returns a path under `Microsoft Visual Studio\...\bin\Hostx64\x64\cl.exe`, you're good.

### Building from WSL — important gotcha

If your repo lives on the WSL/Linux side (e.g., `/home/<user>/passferry/`), you cannot compile directly via `cmd.exe` — `cmd.exe` refuses to start with a UNC working directory (`\\wsl.localhost\Ubuntu\...`). Two workarounds:

- **Recommended**: keep the repo on the Windows filesystem (`/mnt/c/dev/passferry/` from WSL = `C:\dev\passferry\` from Windows). Edit from either side, compile from Windows side. No copy step needed.
- **Workaround**: use a batch file with `pushd` (not `cd`) to enter the UNC path — `pushd` maps it to a temporary drive letter. Copy the DLL back manually. See [the build session notes in CHANGELOG.md](../CHANGELOG.md) for how this played out during v0.1 development.

Linux cross-compilation with `mingw-w64` is technically possible but produces binaries with slightly different runtime characteristics. For an LSASS-resident DLL, MSVC is recommended — it's the toolchain that gets the most testing in the wild for this use case.

### What "success" looks like

After a clean build:

- `passferry_filter.dll` exists (~600-700 KB with `/Zi` debug info embedded)
- `passferry_filter.pdb` exists (~6-7 MB)
- `dumpbin /EXPORTS passferry_filter.dll` lists exactly three exports: `InitializeChangeNotify`, `PasswordChangeNotify`, `PasswordFilter`
- `dumpbin /HEADERS passferry_filter.dll | findstr machine` shows `8664 machine (x64)`

If any of these checks fail, the DLL will not load into LSASS at all — fix the build before signing. Verifying exports and architecture takes 10 seconds and saves hours of debugging "why won't my DLL load on the DC."

### Common build errors

| Error | Cause | Fix |
|---|---|---|
| `'cl' is not recognized` | Not in Developer Command Prompt | Use Developer Command Prompt or run `vcvars64.bat` |
| `cannot open include file: 'ntsecapi.h'` | Windows SDK `um/` headers missing | Re-run VS installer, tick "Windows SDK" component |
| `LNK1158: cannot run 'rc.exe'` | SDK incomplete | Re-run VS installer, tick "Windows SDK" |
| `error C2059: syntax error` after copy | Source has wrong line endings | Re-clone with `git config core.autocrlf input` |
| `cmd.exe ... UNC paths are not supported` | Compiling from a WSL/UNC path | Move repo to Windows filesystem (`/mnt/c/...`) |
| `dumpbin: not recognized` | Same PATH issue as `cl` | Same fix — Developer Command Prompt or `vcvars64.bat` |
| `error LNK2019: unresolved external symbol` | Wrong `.def` file or missing `/MACHINE:X64` | Verify the linker invocation matches the one above |

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
