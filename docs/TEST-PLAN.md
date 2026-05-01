# Test plan — 2 forest lab

Realistic budget: **one weekend, focused**. If you've never written a password
filter DLL before, budget two weekends.

## Lab topology

```
source-a.example (Server 2025)        target.example (Server 2025)
├── dc01.source-a  (DC + filter DLL)   ├── target-dc01  (DC, LDAPS enabled)
│                                  ├── broker      (member, runs broker svc)
└── dc01.source-b.example        └── (Entra Connect later, out of scope)
    (DC + filter DLL, in source-b.example forest)
```

Forest trust: two-way between each legacy and `target.example`. Or, if you skip
the trust, make sure the broker can reach source DCs over LDAP (TCP 389/636)
with a credential that has read rights — the broker uses Get-ADUser to look
up legacy users.

## Phase 1 — Provisioning only (Day 1 morning)

Goal: prove that creating a user in source-a results in a matching user in
target within 15 minutes, with `extensionAttribute15` populated.

| # | Action | Expected |
|---|--------|----------|
| 1 | Run `scripts/provisioning.ps1 -WhatIf` | Logs what it *would* do, no changes |
| 2 | Create user `testuser1` in source-a | exists in source-a |
| 3 | Run `scripts/provisioning.ps1` (no -WhatIf) | Logs "Creating target user testuser1..." |
| 4 | `Get-ADUser testuser1 -Server target-dc01 -Properties extensionAttribute15` | exists, extAttr15 = legacy GUID |
| 5 | Modify `testuser1` displayName in source-a | provisioning run picks up change |
| 6 | Re-run provisioning | "Updating target user testuser1..." |
| 7 | Set up scheduled task every 15 min | runs unattended, idempotent |

**Pass criteria**: 10 test users across both forests, all created in target
with correct attribute mapping and back-reference. No duplicates after
multiple runs.

## Phase 2 — Broker only (Day 1 afternoon)

Goal: prove the broker can receive a fake password change and apply it.

| # | Action | Expected |
|---|--------|----------|
| 1 | Install broker service per `scripts/BROKER-RUN.md` | `Get-Service PassFerryBroker` Running |
| 2 | Test cert binding: `netsh http show sslcert ipport=0.0.0.0:8443` | shows server cert + clientcertnegotiation=Enabled |
| 3 | Curl/Invoke-RestMethod with valid client cert + valid testuser1 | `{"status":"ok"}`, broker.log shows "Password set on target user testuser1" |
| 4 | Try to log into target as `testuser1` with the password you just sent | success |
| 5 | Call broker WITHOUT client cert | 401 |
| 6 | Call broker with cert NOT in allow-list | 403 |
| 7 | Call broker for a legacy SAM with no target match | `{"status":"no-match"}`, no failure |

**Pass criteria**: end-to-end password set works for provisioned users,
authn rejection works for everyone else.

## Phase 3 — DLL on a single DC (Day 2 morning) ⚠️ riskiest step

Goal: filter loads cleanly in LSASS, captures a password change, hands off
to forwarder.

**Before you start: snapshot the test DC. Have console access ready.**

| # | Action | Expected |
|---|--------|----------|
| 1 | Build DLL with Claude Code (`filter-dll/BUILD.md`) | passferry_filter.dll exists, dumpbin shows 3 exports |
| 2 | Sign with lab cert, import cert into DC's Trusted Publishers | both done |
| 3 | Install forwarder service first (per `scripts/FORWARDER-RUN.md`) | service Running, log shows "Waiting..." |
| 4 | Copy DLL to `C:\Windows\System32\`, register in `Notification Packages` | registry value contains "passferry_filter" |
| 5 | **Reboot the DC** | DC comes up cleanly |
| 6 | Check System log for LSASS warnings | no errors about filter load |
| 7 | Change `testuser1`'s password in source-a | password changes succeed |
| 8 | Check forwarder.log on the DC | "Forwarded pwd change for testuser1" |
| 9 | Check broker.log on broker.target.example | "Password set on target user testuser1" |
| 10 | Log into target as testuser1 with the new password | success |

**If step 5 fails (DC won't boot):**
- Boot to Directory Services Restore Mode (DSRM)
- Edit registry offline or in DSRM: remove `passferry_filter` from
  `HKLM\SYSTEM\CurrentControlSet\Control\Lsa\Notification Packages`
- Reboot normally
- Investigate (signature, deps, exports) before retrying

**Pass criteria**: 20 password changes against 5 different test users, all
arrive in target within 5 seconds. No LSASS errors. No measurable auth latency
increase on the source DC.

## Phase 4 — Both DCs, both forests (Day 2 afternoon)

Repeat Phase 3 on `dc01.source-b.example`. Then test:

| # | Action | Expected |
|---|--------|----------|
| 1 | Change pwd on user `userB1` in source-b | propagates to target |
| 2 | Stop PassFerryBroker service | broker down |
| 3 | Change pwd in source-a | forwarder.log: "broker POST failed", "DROPPED..." |
| 4 | Restart PassFerryBroker | broker back up |
| 5 | Change pwd in source-a again | propagates normally |
| 6 | Stop PassFerryForwarder on dc01.source-a | forwarder down |
| 7 | Change pwd in source-a | password changes locally; nothing in broker.log |
| 8 | Restart PassFerryForwarder | next pwd change propagates |

**Pass criteria**: every failure mode is "graceful". User-side password
changes never fail. Lost changes when broker is down are logged as DROPPED
(production must add a retry queue — see hardening).

## Phase 5 — Edge cases (Sunday evening, if you survived)

| Scenario | Expected behaviour |
|----------|-------------------|
| Password contains unicode (€, é, 中) | propagates correctly |
| Password is 127 chars (max) | propagates |
| User in legacy doesn't yet exist in target | broker logs "no-match", drops cleanly |
| User disabled in legacy | password change still propagates (target may also disable separately) |
| Two password changes within 1 sec (rare but possible) | both propagate, last-write-wins on target |
| target password policy rejects (too short) | broker logs error, doesn't retry forever |
| Source DC clock skew >5 min from broker | mTLS still works (cert validity is loose); investigate before prod |

## What "done with the lab" looks like

You should be able to demo: a user changes their password on a workstation
joined to source-a, and within 5 seconds, a freshly opened browser session
into Entra (which syncs from target) accepts the new password.

If you can't demo that end-to-end, you're not done. Don't roll to prod.
