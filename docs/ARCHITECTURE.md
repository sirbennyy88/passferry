# Architecture

## High-level flow

```text
User account created in source AD (source = system of record)
       │
       │  PassFerry pipeline:
       │   • provisioning.ps1   (scheduled task, every ~15 min)
       │   • LSA filter DLL + forwarder + broker (real-time pwd sync)
       ▼
Target AD (Windows Server 2025) — auto-mirrored from source
       │
       │  Entra Connect (existing setup, untouched)
       ▼
Entra ID
```

PassFerry is **strictly one-way**: source → target. The source remains the system of record. The target receives mirrored users and passwords. PassFerry does not write back to the source forest at any point.

## Component diagram

```text
Source Forests (one or more)                       Target Forest
┌──────────────────────────────┐                  ┌──────────────────────────────┐
│  Source DC                   │                  │  Target DC                   │
│   ├── LSASS                  │                  │   └── (Entra Connect →       │
│   │    └── passferry_filter ─┼──┐               │        Entra ID)             │
│   │         DLL              │  │               │                              │
│   │                          │  │ named pipe    │                              │
│   └── forwarder.ps1 service ─┼──┘ (cleartext    │                              │
│        (PowerShell)          │    pwd, local    │                              │
│                              │    only)         │                              │
└────────┬─────────────────────┘                  └──────────▲───────────────────┘
         │ HTTPS + mTLS                                      │ LDAPS
         │ (cleartext pwd                                    │ Set-ADAccountPwd
         │  in TLS tunnel)                                   │
         │                                                   │
         └──► broker.ps1 service (target-forest member) ─────┘
                  │
                  │  provisioning.ps1 (separate scheduled task on broker host)
                  │  ───────────────────────────────────────────────────────
                  └──► Reads source forests via ADWS, creates/updates target users
```

## Components in detail

### 1. provisioning.ps1

A PowerShell scheduled task running on the broker host (or any member server in the target forest with read access to source forests). Reads each configured source forest via ADWS, creates or updates corresponding users in a target OU, stamps a back-reference attribute (configurable, default `extensionAttribute15`) holding the source `objectGUID`.

- **Watermarked**: tracks `whenChanged` per source forest, only processes deltas
- **Idempotent**: safe to re-run
- **Configurable attribute mapping**: `givenName`, `sn`, `mail`, `employeeID`, etc.
- **Collision handling**: detects sAMAccountName collisions across source forests, applies a forest tag suffix
- **Temp passwords**: generates a 24-char random password for newly-created users (the real password arrives via the password sync pipeline once the user changes it on source)

### 2. passferry_filter.dll

A small (~5 KB source, ~650 KB compiled with debug info) C DLL that runs inside LSASS on each source DC. Implements the standard Microsoft LSA password filter contract:

- `InitializeChangeNotify()` — returns TRUE
- `PasswordChangeNotify(user, rid, password)` — captures the cleartext password and writes it to a local named pipe `\\.\pipe\PassFerryFilter`, then returns
- `PasswordFilter()` — always returns success (we are not a complexity filter; we don't reject anything)

**Critical invariants** (these are why the DLL is so minimal):

- **Never block.** All operations are non-blocking with short timeouts. LSASS is on the critical authentication path; if we block, every user authentication on this DC stalls.
- **Never crash.** Wrapped in `__try / __except`. An unhandled exception inside LSASS would crash the DC.
- **Never allocate large buffers.** LSASS is memory-sensitive.
- **Never do network I/O.** All network work is delegated to user-mode services.

The DLL writes to a local named pipe and exits. Everything else happens in user-mode where it can be safely iterated.

### 3. forwarder.ps1

A user-mode PowerShell Windows service running on each source DC alongside the DLL. It owns the named pipe (creates it with a restricted DACL: only LocalSystem can write), drains password events as they arrive, and forwards each one to the broker over mTLS HTTPS.

- **mTLS authentication**: presents a client cert from `LocalMachine\My`, broker validates against an allow-list
- **Run as gMSA**: no static service-account password
- **Logging**: structured logs to `C:\ProgramData\PassFerryForwarder\forwarder.log`
- **Failure handling (v0.1)**: drops events if broker is unreachable. **Production should add a DPAPI-encrypted retry queue — this is on the v0.1.1 roadmap.**

### 4. broker.ps1

A user-mode PowerShell service running on a member server in the target forest. Listens on HTTPS (default port 8443) with mTLS. For each accepted request:

1. Validates the client cert thumbprint against the allow-list (`allowed-clients.txt`, re-read every request — adding a new source DC requires no service restart)
2. Resolves the source SAM → source `objectGUID` via the source forest (an ADWS round-trip — to be pushed into the forwarder in v0.1.1)
3. Looks up the matching target user via the configured `BackrefAttribute` (default `extensionAttribute15`)
4. Calls `Set-ADAccountPassword` on the target DC over LDAPS

Total round-trip latency: typically 1-3 seconds from password change on source to password set on target. Entra Connect picks up the change on its next sync cycle (default 30 minutes).

### 5. preflight-check.ps1

A read-only validation script. Runs against your real source and target DCs and reports any blockers, warnings, or informational findings before deployment. Detects:

- LSA Protection (RunAsPPL) — the #1 deal-breaker for self-signed DLL deployments
- Existing `Notification Packages` — identifies coexisting filters (Specops, nFront, Entra Password Protection, etc.)
- Failover Cluster role on a DC — known to conflict with custom password filters
- Kerberos encryption types — flags forests still using RC4
- Back-reference attribute usage — confirms the chosen attribute is unused
- Fine-Grained Password Policies — flags PSOs stricter than source policy
- LDAPS reachability on the target DC

Read-only, makes no changes.

## Data flow for a single password change

```text
T+0.000s   User changes password on workstation joined to source-a forest
T+0.001s   Workstation sends password change to its source DC
T+0.002s   Source DC: LSASS validates against current password policy, accepts
T+0.003s   Source DC: LSASS calls each registered filter in Notification Packages,
           in registry order. passferry_filter.dll receives the call.
T+0.004s   passferry_filter.dll opens local pipe, writes (sAMAccountName, password),
           closes pipe, returns STATUS_SUCCESS
T+0.005s   Source DC: LSASS commits the password change locally
T+0.006s   forwarder.ps1: reads pipe message, parses
T+0.020s   forwarder.ps1: HTTPS POST to broker.target.example:8443/sync
                          payload: {"sourceForest":"source-a", "sAMAccountName":"alice",
                                    "password":"...", "timestamp":"..."}
T+0.250s   broker.ps1: mTLS handshake completes, request accepted
T+0.300s   broker.ps1: resolves source SAM → source objectGUID via ADWS
T+0.500s   broker.ps1: LDAPS lookup target user by extensionAttribute15
T+0.700s   broker.ps1: Set-ADAccountPassword on target DC
T+1.000s   Target DC: password set, returns success
T+1.100s   broker.ps1: returns {"status":"ok"} to forwarder
T+1.200s   forwarder.ps1: logs success, password buffer zeroed and discarded

(then, separately:)
T+~30 min  Entra Connect's next sync cycle picks up the changed pwdLastSet on target
T+~30 min  Entra Connect calculates the new MD4-hash-of-MD4-hash, ships to Entra ID
```

## Security model

### What can the cleartext password touch?

- LSASS memory on the source DC (briefly, during the filter callback) — same as it would for any password change
- The local named pipe on the source DC — kernel-mode buffer, never disk
- The forwarder.ps1 process memory — briefly, during the mTLS POST
- The TLS tunnel between source DC and broker — encrypted in transit
- The broker.ps1 process memory — briefly, during the LDAPS Set-ADAccountPassword call
- The LDAPS connection between broker and target DC — encrypted in transit
- LSASS memory on the target DC — same as any password set

The cleartext password is **never written to any disk** by PassFerry. It exists only in memory, and only briefly. Both forwarder and broker explicitly zero password buffers after use (best-effort given PowerShell's string immutability).

### What about logs?

PassFerry's logs record the **fact** of a password change, the username, the source forest, and the result. They do **not** record the password itself. Code review verifies this; the audit step in CONTRIBUTING.md emphasizes maintaining this guarantee.

### Authentication

- **Forwarder → broker**: mutual TLS. Both sides present certs. Broker maintains an explicit allow-list of forwarder client cert thumbprints. Adding a new source DC requires adding its thumbprint to the allow-list (no broker restart needed).
- **Provisioning → source forests**: read-only via ADWS, runs as gMSA with read rights only.
- **Provisioning → target forest**: write rights restricted to the target OU only.
- **Broker → target forest**: gMSA with delegated "reset password" rights on the target OU. No domain-wide rights.

### What an attacker needs to compromise PassFerry

Threat: an attacker who could intercept or inject password changes through the pipeline.

- **Compromise the source DC**: already game-over independent of PassFerry — they could read SAM, dump LSASS, etc.
- **Compromise the forwarder service**: requires code execution on the source DC as the gMSA or higher. Same prerequisite as above.
- **Network MITM between forwarder and broker**: requires either (a) compromising the forwarder's client cert private key, OR (b) compromising the broker's server cert AND a CA trusted by the forwarder. mTLS is bidirectional, so a one-sided MITM is not enough.
- **Compromise the broker service**: requires code execution on the broker host as the gMSA or higher. The broker has password-reset rights on the target OU only — limited blast radius.

PassFerry does not introduce attack surface that is materially different from ADMT's PES. The mechanism is the same; the implementation is more transparent and uses modern crypto (mTLS, AES-only) rather than legacy mechanisms (RPC, RC4, unconstrained delegation).

## Configuration model

All operational state is in config files, not code:

| File | Owner | Purpose |
|------|-------|---------|
| `scripts/provisioning.ps1`'s `config.json` | provisioning script | Source forests, target DC, target OU, attribute map, BackrefAttribute |
| Forwarder service NSSM args | per-source-DC | Source forest tag, broker URL, client cert thumbprint |
| Broker service NSSM args | broker host | Listen port, server cert thumbprint, target DC, BackrefAttribute |
| `C:\ProgramData\PassFerryBroker\allowed-clients.txt` | broker host | Allow-list of forwarder client cert thumbprints |

Changing the back-reference attribute (e.g., from `extensionAttribute15` to `employeeID`) is a config change, not a code change.

## What's not in v0.1 (and why)

| Feature | Why deferred | Sprint |
|---------|--------------|--------|
| DPAPI retry queue in forwarder | Drops password changes if broker unreachable | v0.1.1 |
| objectGUID sent from forwarder | Avoids broker round-trip to source | v0.1.1 |
| SID History migration | Provisioning extension only | v0.2 |
| Group migration | Substantial new logic | v0.3 |
| Computer migration | Requires client-side agent | v0.4 |
| Service account migration | Inventory-driven, complex | v0.5 |
| Security translation | Most complex feature, possibly separate sub-project | v0.6 |
| Reporting / observability | Lower priority for prototype | v0.7 |

See [ROADMAP.md](../ROADMAP.md) for the full sprint plan.
