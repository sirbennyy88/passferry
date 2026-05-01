# Forwarder service — install & run

This is a Windows service that lives on every source DC alongside the password
filter DLL. It owns the named pipe and forwards captured password changes to
the broker.

## Service account

Create a gMSA in the **legacy** forest:

```powershell
# On a source DC, one-time:
Add-KdsRootKey -EffectiveImmediately   # if not already done
New-ADServiceAccount -Name 'gmsa-passferry-fwd' `
    -DNSHostName 'gmsa-passferry-fwd.source-a.example' `
    -PrincipalsAllowedToRetrieveManagedPassword 'Domain Controllers'
```

Install it on each source DC:
```powershell
Install-ADServiceAccount -Identity 'gmsa-passferry-fwd'
Test-ADServiceAccount -Identity 'gmsa-passferry-fwd'   # should return True
```

## Client cert (for mTLS to broker)

Issue from your CA, or for lab self-sign one. Subject CN should identify the
DC, e.g. `dc01.source-a.example`. Place in `LocalMachine\My`.

The broker's allow-list will be a list of thumbprints / Subjects from these
certs.

## Install with NSSM

```powershell
# Download NSSM from nssm.cc, extract to C:\Tools\nssm
# Register the service:
C:\Tools\nssm\nssm.exe install PassFerryForwarder powershell.exe
C:\Tools\nssm\nssm.exe set PassFerryForwarder AppParameters `
    "-NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\PassFerryForwarder\forwarder.ps1 -SourceForestTag source-a -ClientCertThumb <thumbprint>"
C:\Tools\nssm\nssm.exe set PassFerryForwarder ObjectName 'SOURCE-A\gmsa-passferry-fwd$' ''
C:\Tools\nssm\nssm.exe set PassFerryForwarder Start SERVICE_AUTO_START
C:\Tools\nssm\nssm.exe set PassFerryForwarder AppStdout C:\ProgramData\PassFerryForwarder\stdout.log
C:\Tools\nssm\nssm.exe set PassFerryForwarder AppStderr C:\ProgramData\PassFerryForwarder\stderr.log

Start-Service PassFerryForwarder
```

## Verify

1. `Get-Service PassFerryForwarder` → Running
2. Check `C:\ProgramData\PassFerryForwarder\forwarder.log` → `Waiting for password change...`
3. Change a test user's password in the source forest. Within ~1 second you
   should see a `Forwarded pwd change for ...` line.

## Boot order matters

The forwarder must be running BEFORE LSASS tries to write to the pipe. With
the service set to Automatic Start it should be up well before any password
change happens, but on an idle DC at boot:

- LSASS loads the filter DLL at startup (no traffic yet)
- Forwarder service starts and begins listening
- First password change of the day arrives → pipe is ready

If the forwarder is stopped, the DLL's `WaitNamedPipeW` returns immediately
with no pipe available, the DLL silently exits its function, the password
change still succeeds locally, but is **not** propagated. This is the
acceptable failure mode — never block the user.
