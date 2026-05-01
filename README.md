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

## Why open source?

Every team consolidating AD forests faces the same choice: pay for a commercial migration tool, or hand-roll something brittle. The mechanism PassFerry uses (LSA password filter → forwarder → broker → LDAPS) is well-documented Microsoft API; there's no technical reason a working implementation should be locked behind enterprise licensing. The codebase is small enough — one C file, four PowerShell scripts — that you can audit it in an afternoon before letting it near LSASS. That's the point.

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

For full forest consolidation today, commercial tools (Quest Migrator Pro, Semperis ADFR, BinaryTree) remain more complete solutions. For password sync only, the closest commercial peer is Specops Password Sync — quote-priced, per-user licensing. PassFerry is the right choice when:

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
│   ├── passferry_filter.c    LSA password filter source
│   ├── passferry_filter.def  Linker exports definition
│   └── BUILD.md              Build, sign, and deploy instructions
└── .github/
    └── workflows/build.yml   CI to compile the DLL on every push
```

## Requirements

PassFerry is MIT-licensed and free to use commercially. Total cost of running PassFerry: zero, plus the Windows Server licenses you already own (and an EV code-signing certificate if you have RunAsPPL enabled — see code-signing tier below).

### Source forest domain controllers (where the LSA filter runs)

| Component | Requirement | Notes |
|---|---|---|
| OS | Windows Server 2016, 2019, 2022, or 2025 (x64) | Same compiled DLL works on all |
| PowerShell | 5.1 minimum (built-in) | PS 7.x supported but not required; 5.1 chosen so no extra runtimes need installing on DCs |
| .NET Framework | 4.7.2+ | Built into supported OS |
| LSA Protection (RunAsPPL) | Must be OFF for self-signed or internal-CA-signed DLL | Pre-flight script flags this |
| Privileges to install | Domain Admin (one-time, registers filter and creates gMSA) | Runtime: gMSA only |
| Disk space | < 10 MB | DLL plus forwarder logs |
| Network | Outbound TCP 8443 to broker (configurable) | No inbound exposure required |

### Broker host (target forest member server)

| Component | Requirement | Notes |
|---|---|---|
| OS | Windows Server 2019, 2022, or 2025 | 2025 recommended to match target DC |
| PowerShell | 7.4+ recommended, 5.1 minimum | Broker uses HttpListener and modern TLS handling |
| RSAT-AD-PowerShell | Required | `Install-WindowsFeature RSAT-AD-PowerShell` |
| Privileges | gMSA with delegated reset-password rights on target OU only | Not domain-wide |
| Network | Inbound TCP 8443 from each source DC; outbound LDAPS (636) to target DC | mTLS allow-list enforced |
| Certificates | Server cert (broker) plus client certs (one per source DC) | Self-signed for lab, internal PKI for production |

### Target forest domain controllers

| Component | Requirement | Notes |
|---|---|---|
| OS | Windows Server 2025 (designed for) | Older versions may work, untested |
| LDAPS | Required, reachable from broker | Pre-flight validates |
| Functional level | 2016 or higher | Modern attribute support |

### Build requirements (only if compiling the DLL yourself)

CI builds the DLL on every commit and uploads as a workflow artifact, so most users never need to build locally. For production deployments, build and sign yourself so you can verify what runs in your LSASS.

| Component | Requirement | Notes |
|---|---|---|
| Compiler | Visual Studio Build Tools 2022 with "Desktop development with C++" workload | 2019 and 2026 also work; 2022 is canonical |
| Windows SDK | 10.0.19041 or later | Provides `ntsecapi.h`, `subauth.h` |
| Architecture | x64 only | LSASS is x64 on supported Server versions |
| Code signing — lab | Self-signed cert | Works only if RunAsPPL=0 on every target DC |
| Code signing — production (no PPL) | Internal CA-issued code-signing cert | Works only if RunAsPPL=0 |
| Code signing — production (RunAsPPL=1 anywhere) | EV cert plus Microsoft LSA-plugin signing program | ~3 weeks turnaround; EV cert ~$300/yr if you don't already have one |
| Build host OS | Windows 10/11 or Windows Server 2019+ | No Linux cross-compilation |

> 💡 **Building on a fresh machine?** See [`filter-dll/BUILD.md`](filter-dll/BUILD.md) for the complete build environment setup guide, including SDK component selection, `cl.exe` PATH troubleshooting, WSL/UNC path gotchas, and what success looks like.

## What you do NOT need

- A Microsoft licensing agreement beyond your existing Windows Server CALs
- Quest, Semperis, BinaryTree, Specops, or any commercial migration/sync tool license
- An Azure subscription (Entra Connect runs on-premises if you already have it)
- Internet access on the DCs at runtime — build and sign once, deploy offline
- Trusts between source and target forests (PassFerry is the bridge, though trusts make some operations easier)

## Coexistence with other password tools

PassFerry's LSA filter coexists by design with other registered password filters. Microsoft's filter chain calls each registered filter independently; PassFerry only consumes password-change notifications and never rejects them, so it cannot interfere with policy-enforcement filters.

| Tool | Purpose | Coexists with PassFerry? |
|---|---|---|
| Microsoft default (`scecli`) | Default Domain Policy enforcement | Yes — leave it registered |
| PassFiltEx | Open-source enforcement filter (MIT-licensed, by Ryan Ries) | Yes |
| OpenPasswordFilter | Open-source dictionary-based enforcement (older but established) | Yes |
| **Lithnet Password Protection for AD** | **Open-source breach-list and weak-password enforcement (MIT-licensed)** | **Yes — recommended pairing for fully open-source AD password security** |
| Microsoft Entra Password Protection (on-prem agent) | Microsoft global banned-password list | Yes |
| Specops Password Policy (`SPP3FLT`) | Commercial password complexity / breach-list enforcement | Yes |
| nFront Password Filter | Commercial complexity enforcement | Yes |
| Specops Password Sync | Commercial cross-forest password sync | **Direct alternative — pick one, not both** |
| Quest / BinaryTree migration suites | Full forest consolidation | Different scope; PassFerry is focused, Quest is comprehensive |

### Recommended open-source pairing: PassFerry + Lithnet Password Protection

For fully open-source AD password security, pair PassFerry (sync) with [Lithnet Password Protection for Active Directory](https://github.com/lithnet/ad-password-protection) (enforcement). Together they cover both halves of the password-management problem without commercial licensing:

- **Lithnet** runs as an LSA password filter, enforces complexity rules, and blocks passwords found in HaveIBeenPwned breach lists. Mature, MIT-licensed, production-grade.
- **PassFerry** runs as a separate LSA password filter, captures accepted password changes, and synchronizes them to your target forest.

Both filters coexist in `Notification Packages`. They run independently — Lithnet decides whether a password is acceptable; PassFerry only sees the change after Lithnet (and any other filter, including Microsoft's defaults) has approved it. There are no known conflicts; the architectures are complementary by design.

A documented deployment recipe for the PassFerry + Lithnet pairing is on the [v0.8 roadmap](ROADMAP.md). Until then, follow Lithnet's installation guide and PassFerry's installation guide separately — both products use the standard `Notification Packages` registration, and our deployment script appends rather than replaces, so the registration order does not matter for correctness.

### Critical coexistence note

When registering PassFerry's filter in `HKLM\SYSTEM\CurrentControlSet\Control\Lsa\Notification Packages`, **append**; never replace. Replacing the registry value wipes existing filters (`scecli`, Lithnet, Specops, etc.) and silently breaks default password policy AND any commercial filter you have. The deployment script in `filter-dll/BUILD.md` does this correctly.

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

## Prior art and acknowledgments

PassFerry's LSA filter implementation follows patterns established by prior open-source work in the AD password-filter space, particularly Ryan Ries's [PassFiltEx](https://github.com/ryanries/PassFiltEx) and the broader [Lithnet](https://github.com/lithnet) project. Where those projects focus on password *enforcement* (rejecting weak or breached passwords), PassFerry focuses on password *synchronization* across forests. The two patterns are complementary — Lithnet decides whether a password is acceptable; PassFerry, running as a separate filter, mirrors accepted passwords to the target forest.

If you need both enforcement and sync (the typical case for forest consolidation), running PassFerry and Lithnet together gives you fully open-source AD password security on Windows Server 2025.

Other open-source projects that informed PassFerry's design:

- [PassFiltEx](https://github.com/ryanries/PassFiltEx) — reference LSA password filter implementation, with the most thorough documentation of "code that runs in LSASS without crashing it" patterns
- [Lithnet Password Protection for Active Directory](https://github.com/lithnet/ad-password-protection) — production-grade enforcement filter with HaveIBeenPwned integration
- [OpenPasswordFilter](https://github.com/jephthai/OpenPasswordFilter) and its forks — earlier dictionary-based enforcement work
- Microsoft's own [password filter documentation](https://learn.microsoft.com/en-us/windows/win32/secmgmt/installing-and-registering-a-password-filter-dll) — the foundation everyone builds on

PassFerry adds a piece that was missing in the open-source ecosystem: a documented, code-signed forest-to-forest synchronization pipeline using the same documented LSA filter mechanism, designed for Windows Server 2025's security defaults (AES-only, mTLS, code-signed, RunAsPPL-aware).

## Credits

PassFerry was concocted and built with the help of [Claude](https://www.anthropic.com/claude) (Claude Opus 4.7), Anthropic's AI assistant. The architecture, code, and documentation were developed collaboratively between human and AI over a series of design and implementation sessions. All code uses documented Microsoft APIs and follows established patterns from prior art (Specops, Lithnet Password Protection, Microsoft's own password filter samples).

If you build on PassFerry or use it in your environment, a star on the repository is appreciated and helps others find it.
