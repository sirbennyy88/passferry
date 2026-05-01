# Changelog

All notable changes to PassFerry are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows [Semantic Versioning](https://semver.org/).

## [v0.1] — 2026-05-01 (initial release)

### Added
- LSA password notification filter DLL (`passferry_filter.dll`) — captures password changes on source DCs and writes to a local named pipe
- Forwarder PowerShell service — drains the LSA pipe and forwards password events to the broker over mTLS HTTPS
- Sync broker PowerShell service — receives password events, resolves the matching target user via the configured back-reference attribute, calls `Set-ADAccountPassword` over LDAPS
- User provisioning script (`provisioning.ps1`) — reads source forests via ADWS, creates/updates users in the target OU, stamps a back-reference attribute (default `extensionAttribute15`)
- Pre-flight check script — read-only validation against source and target DCs, detects RunAsPPL, audits `Notification Packages`, identifies attribute conflicts, validates LDAPS reachability and Kerberos encryption types
- Issue and risks documentation covering 10 known gotchas (RunAsPPL, Specops coexistence, password policy mismatches, RC4, missing attributes, initial backfill, etc.)
- 5-phase lab test plan
- Hardening and production rollout guide
- MIT license

### Known limitations (v0.1)
- Not production-validated — prototype status, lab testing required
- Drops password changes silently when broker is unreachable (DPAPI retry queue is on the v0.1.1 roadmap)
- Broker performs a round-trip to the source forest to resolve SAM → objectGUID (forwarder-side resolution is on the v0.1.1 roadmap)
- Self-signed code-signing only works on DCs without LSA Protection (RunAsPPL=0); production deployments with RunAsPPL require Microsoft's LSA-plugin signing program
- No SID History migration (planned v0.2)
- No group, computer, or security translation migration (planned v0.3-v0.6)

### Compatibility
- Source forest DCs: Windows Server 2016, 2019, 2022, 2025 (x64)
- Target forest DCs: Windows Server 2025
- Build toolchain: MSVC (Visual Studio Build Tools 2019/2022/2026 with C++ workload)
