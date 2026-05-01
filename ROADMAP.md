# PassFerry Roadmap

PassFerry v0.1 is a focused password sync tool. This roadmap describes the path toward broader ADMT-adjacent feature coverage. Items are organized as sprints, not commitments — anyone is welcome to take any of them on. See [CONTRIBUTING.md](CONTRIBUTING.md).

## At a glance

| Version | Theme | Status | Effort | Depends on |
|---------|-------|--------|--------|------------|
| v0.1    | User provisioning + password sync | ✅ Released | — | — |
| v0.1.1  | DPAPI retry queue + forwarder GUID resolution | 📋 Planned | ~1 weekend | v0.1 |
| v0.2    | SID History migration | 📋 Planned | ~1 weekend | v0.1 |
| v0.3    | Group migration | 📋 Planned | ~2 weekends | v0.1 |
| v0.4    | Computer / workstation migration | 📋 Planned | ~3-4 weekends | v0.2 (SID History) |
| v0.5    | Service account migration | 📋 Planned | ~1-2 weekends | v0.1 |
| v0.6    | Security translation (re-ACL) | 📋 Planned | weeks | v0.2 (SID History) |
| v0.7    | Reporting & observability | 📋 Planned | ~1 weekend | v0.1 |
| v0.8    | Lithnet integration recipe | 📋 Planned | ~1 weekend | v0.1 |

**Status legend**: ✅ released · 🚧 in progress · 📋 planned · ⏸ blocked · ❌ cancelled

## Current focus

v0.1 is in **prototype / lab-testing phase**. Field reports from real multi-forest environments are the most valuable contribution right now — see [docs/TEST-PLAN.md](docs/TEST-PLAN.md).

Active sprint: none yet. v0.1.1 is the natural next target if a contributor takes it on; SID History (v0.2) is the obvious feature follow-up.

## v0.1 (released — May 2026)

**Status**: ✅ Released · **Effort**: — · **Depends on**: —

- ✅ Source → Target user provisioning (PowerShell, watermarked, idempotent)
- ✅ Real-time password sync via LSA filter DLL + forwarder + broker
- ✅ mTLS authentication between forwarders and broker
- ✅ Configurable identity-matching attribute (default `extensionAttribute15`, swap for `employeeID` etc.)
- ✅ Pre-flight validation script (RunAsPPL detection, attribute conflict check, RC4 audit)
- ✅ 5-phase lab test plan
- ✅ Hardening / rollout documentation
- ✅ Compatible with source DCs on 2016/2019/2022/2025; target on 2025

## v0.1.1 — Reliability improvements (Sprint 0)

**Status**: 📋 Planned · **Effort**: ~1 weekend · **Depends on**: v0.1

**Why**: Two known limitations from v0.1 affect production reliability. Both are self-contained improvements that don't require new feature scope.

**Scope**:
- DPAPI-encrypted retry queue in the forwarder — retains password-change events when the broker is unreachable and replays them when it comes back online
- Forwarder-side SAM → `objectGUID` resolution — eliminates the broker's round-trip to the source forest on every password-change event, reducing latency and source-side load

**Difficulty**: Low. Both are contained changes to existing components; no new external dependencies.

## v0.2 — SID History migration (Sprint 1)

**Status**: 📋 Planned · **Effort**: ~1 weekend · **Depends on**: v0.1

**Why**: Without SID History, migrated users lose access to resources still ACL'd by their old SID. ADMT carries SID History as a default; PassFerry should too.

**Scope**:
- Extend `provisioning.ps1` to optionally call `Move-ADObject -IncludeSID` semantics
- Document the source/target rights required (PES-equivalent)
- Add a pre-flight check confirming the `MigrateSIDHistory` registry value on source DC PDC
- Update the test plan with SID History validation steps

**Difficulty**: Low. The mechanism is one PowerShell flag; the operational requirements (rights, registry, audit log) are the real work.

## v0.3 — Group migration (Sprint 2)

**Status**: 📋 Planned · **Effort**: ~2 weekends · **Depends on**: v0.1

**Why**: Users without their group memberships are users without permissions. Most consolidations need this.

**Scope**:
- New `provisioning-groups.ps1` script — reads source groups, creates corresponding groups in target with name-collision handling
- Membership reconciliation (handles nested groups, cross-forest references via SID History)
- Configurable scope filter (security groups only, distribution lists, both)
- `extensionAttribute14` (configurable) as the back-reference for groups, parallel to user back-ref

**Difficulty**: Medium. Logic is straightforward; edge cases (orphaned members, nested groups across forests, name collisions) take care.

## v0.4 — Computer account migration (Sprint 3)

**Status**: 📋 Planned · **Effort**: ~3-4 weekends · **Depends on**: v0.2 (SID History)

**Why**: ADMT migrates computers along with users. PassFerry currently doesn't.

**Scope**:
- Computer object provisioning (similar to user provisioning)
- Client-side agent or remote PowerShell to disjoin/rejoin workstations
- Optional: pre-stage the target computer object so domain rejoin is a one-step operation
- Coordinate with user migration (a workstation should migrate after its primary user)

**Difficulty**: High. The hard part is the workstation-side dance — disjoining the source domain, joining the target domain, preserving the local profile. ADMT does this with an agent. We'd need similar.

## v0.5 — Service account migration (Sprint 4)

**Status**: 📋 Planned · **Effort**: ~1-2 weekends · **Depends on**: v0.1

**Why**: SCM-registered services running as named source-domain accounts will break when those accounts move.

**Scope**:
- Inventory tool (already partially documented in `ISSUES-AND-RISKS.md`) extended to a script
- Migration helper that updates `Win32_Service.StartName` on member servers post-user-migration
- Recommendation engine that suggests gMSA conversions where appropriate

**Difficulty**: Medium. Inventory is easy; the conversion-to-gMSA recommendation is the value-add.

## v0.6 — Security translation (Sprint 5)

**Status**: 📋 Planned · **Effort**: weeks · **Depends on**: v0.2 (SID History)

**Why**: This is ADMT's most painful feature to replicate, and where commercial tools (Quest, Semperis) genuinely differentiate themselves.

**Scope**:
- Walk file-share ACLs, registry ACLs, AD object ACLs
- Translate source-domain SIDs to target-domain SIDs (using SID History as the bridge)
- Optional dry-run mode with diff output
- Resume-from-checkpoint for long runs

**Difficulty**: Hard. This is genuinely complex and requires careful design. Probably warrants a separate sub-project (`passferry-acl`) rather than bolting onto the main repo.

## v0.7 — Reporting and observability (Sprint 6)

**Status**: 📋 Planned · **Effort**: ~1 weekend · **Depends on**: v0.1

**Why**: Audit trails matter. "What did PassFerry do last week?" should have a clear answer.

**Scope**:
- Structured CSV/HTML migration reports (per run, per object, per forest)
- Prometheus metrics endpoint on the broker (queue depth, sync rate, failure rate)
- SIEM-friendly log format (JSON or CEF)
- Post-migration verification report (every source user has a target match, no orphans)

**Difficulty**: Low. Mostly formatting and shipping existing data.

## v0.8 — Lithnet integration recipe (Sprint 7)

**Status**: 📋 Planned · **Effort**: ~1 weekend · **Depends on**: v0.1

**Why**: PassFerry handles password *synchronization* but does not enforce password *quality* (length, complexity, breached-password lookups). The natural open-source pairing is [Lithnet Password Protection for Active Directory](https://github.com/lithnet/ad-password-protection) — mature, MIT-licensed, production-grade enforcement. The README mentions this pairing; v0.8 turns it into a tested, documented recipe.

**Scope**:
- Add a `coexistence/lithnet/` directory with a tested deployment recipe for PassFerry + Lithnet.
- GPO snippet showing correct ordering in `Notification Packages` (ordering does not affect correctness, but documenting the recommended ordering helps with debugging).
- Validation steps: prove that Lithnet still rejects breach-list passwords AND PassFerry still syncs accepted passwords, after both are installed.
- Pre-flight script extension: detect Lithnet's filter and confirm it's registered correctly.
- Documentation: a "Fully open-source AD password security with PassFerry + Lithnet" guide.

**Difficulty**: Low. We are not writing enforcement logic — Lithnet does that excellently. We are documenting and validating clean coexistence patterns.

**Why this is not a from-scratch enforcement build**: Lithnet Password Protection is mature, MIT-licensed, integrates HaveIBeenPwned, and is production-grade. Reinventing it would be wasted effort. PassFerry's value-add is the documented integration recipe.

## Stretch / out of scope

- **Bidirectional sync** (target → source). Explicitly out of scope by design — PassFerry is one-way.
- **Trust migration**. Trusts are administratively re-created, not migrated. Out of scope.
- **Cross-tenant Entra ID migration**. That's a different problem space (Cross-Tenant Sync, B2B). PassFerry is on-prem AD focused.
- **Web UI / dashboard**. Maybe v1.0+ if there's demand. Pure PowerShell + config files for now.

## How to claim a sprint

Open an issue using the "Sprint claim" template indicating which sprint you're working on, your rough timeline, and any design questions. Discussion happens in the issue; PRs reference back to it.

The maintainer reserves the right to review/reject scope creep, but the door is open for serious contributions.
