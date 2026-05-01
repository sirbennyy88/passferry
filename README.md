# PassFerry

**Real-time Active Directory password synchronization across forests — an open-source replacement for the password-sync portion of ADMT 3.2 on Windows Server 2025.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Status: Prototype](https://img.shields.io/badge/Status-Prototype-orange.svg)]()
[![Platform: Windows Server 2016+](https://img.shields.io/badge/Platform-Windows%20Server%202016%2B-blue.svg)]()

> ⚠️ **PROTOTYPE STATUS**: PassFerry has been compiled, signed, and code-reviewed, but as of v0.1 it has NOT been validated against real production domain controllers. Treat this as a working starting point that requires lab testing before any production use. See the [Test Plan](docs/TEST-PLAN.md).

## Why does this exist?

The Active Directory Migration Tool (ADMT) version 3.2 is the long-standing Microsoft tool for migrating users, passwords, and groups between AD forests. As of Windows Server 2025, **ADMT 3.2 is effectively unsupported for multi-domain and multi-tenant migrations** — it has not been updated since 2014, depends on deprecated authentication mechanisms (RC4, unconstrained delegation, legacy Password Export Server protocols), and is incompatible with Server 2025's security defaults including LSA Protection (RunAsPPL) and strict driver/DLL signing requirements.

For organizations consolidating multiple legacy AD forests into a single modern forest — typically as a precursor to Microsoft Entra ID (formerly Azure AD) integration via Entra Connect — this leaves a gap. Commercial alternatives (Quest Migrator Pro, BinaryTree, Semperis ADFR) exist but require licensing budget. Microsoft's recommended path is "use Entra Cloud Sync directly", which works for cloud-only consolidation but **does not solve the on-premises forest-to-forest sync many environments still need.**

PassFerry fills that gap with a focused, transparent, MIT-licensed implementation using only documented Microsoft APIs:

- **LSA password notification filter** (the same documented mechanism used by Specops, nFront, Entra Password Protection, and ADMT's own Password Export Server)
- **PowerShell** for orchestration, provisioning, and broker logic
- **Mutual TLS** between source DCs and the broker
- **LDAPS** for the final password set in the target domain
- **gMSA** identities — no static service-account passwords

## What it does

```
User account created in source AD (source = system of record)
       │
       │  PassFerry pipeline:
       │   • provisioning.ps1   (scheduled task, every ~15 min)
       │   • LSA filter DLL + forwarder + broker (real-time pwd sync)
       ▼
Target AD (Windows Server 2025) — auto-mirrored from source
       │
       │  Entra Connect (your existing setup, untouched)
       ▼
Entra ID
```

Two functions:

1. **Provisioning**: A scheduled PowerShell task reads each source forest via ADWS, creates matching users in a target OU, and stamps a back-reference attribute (configurable, defaults to `extensionAttribute15`) so the broker can locate users when password changes arrive.

2. **Real-time password sync**: A small (5 KB source / ~650 KB compiled) C DLL runs in LSASS on each source DC. When a password changes, LSASS calls our DLL with the cleartext password (the only point at which it exists in cleartext — same point ADMT's PES captured it). The DLL writes to a local named pipe and exits. A user-mode forwarder service drains the pipe and forwards via mTLS HTTPS to the broker on the target side. The broker resolves the matching target user and calls `Set-ADAccountPassword` over LDAPS. End-to-end latency: 1-3 seconds.

## What it does NOT do (yet)

PassFerry is **focused, not comprehensive**. It is *adjacent* to ADMT, not a full replacement. As of v0.1, it does not migrate:

- Group membership (planned, see [ROADMAP.md](ROADMAP.md))
- Computer / workstation accounts (planned)
- Service accounts beyond what user provisioning covers (planned)
- Security translation / SID-based ACLs on file shares and registry (planned, complex)
- SID History (small extension, planned for v0.2)
- Trusts (out of scope — these are re-created manually)

For full forest consolidation today, commercial tools (Quest, Semperis) remain a more complete solution. PassFerry is the right choice when:

- You need real-time password sync between source and target AD forests
- You are consolidating into a Server 2025 target domain
- Budget for commercial migration tools is unavailable
- You need to own and audit the code

## Server 2025 specifics

PassFerry was designed for Server 2025 from the start. Specifically:

- **AES-only Kerberos and LDAPS** — no RC4 anywhere in the pipeline (Server 2025 is aggressive about RC4 deprecation)
- **Code-signed DLL** — required by Server 2025's strict driver/DLL signing
- **LSA Protection (RunAsPPL) detection** — pre-flight script flags this as the #1 deal-breaker (a self-signed DLL cannot load into a PPL-protected LSASS; you would need Microsoft's LSA-plugin signing program with an EV cert)
- **Cleartext password handling** — captured momentarily in LSASS, transmitted only over mTLS, never written to disk; AD computes its normal NT/Kerberos hashes at rest
- **Compatible with source DCs running 2016/2019/2022/2025** — same compiled DLL works on all of them

## Quickstart

1. Read [docs/PROBLEM-STATEMENT.md](docs/PROBLEM-STATEMENT.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
2. Read [docs/ISSUES-AND-RISKS.md](docs/ISSUES-AND-RISKS.md) — there are real gotchas, especially around LSA Protection
3. Run the pre-flight check against your DCs:
   ```powershell
   .\scripts\preflight-check.ps1 `
       -SourceDCs 'dc01.source-a.example','dc01.source-b.example' `
       -TargetDC 'dc01.target.example' `
       -BackrefAttribute 'extensionAttribute15'
   ```
4. Build the DLL ([filter-dll/BUILD.md](filter-dll/BUILD.md)) and code-sign it
5. Follow [docs/TEST-PLAN.md](docs/TEST-PLAN.md) in a 2-forest lab
6. Read [docs/HARDENING.md](docs/HARDENING.md) before any production rollout

## Repository layout

```
passferry/
├── LICENSE                   MIT
├── README.md                 (this file)
├── ROADMAP.md                Sprint plan for ADMT-adjacent features
├── CHANGELOG.md              Version history
├── CONTRIBUTING.md           How to contribute
├── docs/
│   ├── PROBLEM-STATEMENT.md  Why PassFerry exists
│   ├── ARCHITECTURE.md       How it works
│   ├── ISSUES-AND-RISKS.md   Known gotchas and pre-flight items
│   ├── TEST-PLAN.md          5-phase lab test plan
│   └── HARDENING.md          Production readiness checklist
├── scripts/
│   ├── preflight-check.ps1   Read-only validation
│   ├── provisioning.ps1      User provisioning source → target
│   ├── forwarder.ps1         User-mode service draining the LSA pipe
│   └── broker.ps1            HTTPS listener, sets passwords on target
├── filter-dll/
│   ├── sync_pwd_filter.c     LSA password filter source
│   ├── sync_pwd_filter.def   Linker exports definition
│   └── BUILD.md              Build, sign, and deploy instructions
└── .github/
    └── workflows/build.yml   CI to compile the DLL on every push
```

## Compatibility

| Component | Supported |
|-----------|-----------|
| Source forest DCs | Windows Server 2016, 2019, 2022, 2025 (x64 only) |
| Target forest DCs | Windows Server 2025 (designed for; older may work but untested) |
| Broker host | Windows Server 2019+ (member of target forest) |
| PowerShell | 5.1 (built-in) — 7.x compatibility not yet validated |
| Build toolchain | Visual Studio Build Tools 2019, 2022, or 2026 with C++ workload |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Issues and pull requests welcome. The most valuable contributions for v0.1 → v0.2 are real-world lab test reports — if you run PassFerry through the test plan in your environment and document what worked or broke, please open an issue with the details.

## Disclaimer

PassFerry is **not affiliated with, endorsed by, or sponsored by Microsoft Corporation**. Active Directory, ADMT, Windows Server, Entra ID, and Azure are trademarks of Microsoft Corporation. PassFerry is independent open-source software using documented public Microsoft APIs.

This software runs custom code inside the LSASS process of domain controllers. Misconfiguration or bugs in this code can render a DC unbootable. Always test in an isolated lab. Always have console access to your DCs. Never deploy to production without completing the test plan and rehearsing the rollback procedure.

The MIT license disclaims all warranty. You are responsible for the consequences of running this software in your environment.

## Credits

PassFerry was concocted and built with the help of [Claude](https://www.anthropic.com/claude) (Claude Opus 4.7), Anthropic's AI assistant. The architecture, code, and documentation were developed collaboratively between human and AI over a series of design and implementation sessions. All code uses documented Microsoft APIs and follows established patterns from prior art (Specops, Lithnet Password Protection, Microsoft's own password filter samples).

If you build on PassFerry or use it in your environment, a star on the repository is appreciated and helps others find it.
