# PassFerry Roadmap

PassFerry v0.1 ships with the two ADMT capabilities most affected by the Server 2025 deprecation: **user provisioning** and **real-time password sync**. The features below are the path from "focused tool" to "credible community alternative to ADMT for forest consolidation."

These are organized as sprints, not commitments. Anyone is welcome to take any of them on — see [CONTRIBUTING.md](CONTRIBUTING.md).

## v0.1 (current — May 2026)

- ✅ Source → Target user provisioning (PowerShell, watermarked, idempotent)
- ✅ Real-time password sync via LSA filter DLL + forwarder + broker
- ✅ mTLS authentication between forwarders and broker
- ✅ Configurable identity-matching attribute (default `extensionAttribute15`, swap for `employeeID` etc.)
- ✅ Pre-flight validation script (RunAsPPL detection, attribute conflict check, RC4 audit)
- ✅ 5-phase lab test plan
- ✅ Hardening / rollout documentation
- ✅ Compatible with source DCs on 2016/2019/2022/2025; target on 2025

## v0.2 — SID History migration (Sprint 1)

**Why**: Without SID History, migrated users lose access to resources still ACL'd by their old SID. ADMT carries SID History as a default; PassFerry should too.

**Scope**:
- Extend `provisioning.ps1` to optionally call `Move-ADObject -IncludeSID` semantics
- Document the source/target rights required (PES-equivalent)
- Add a pre-flight check confirming the `MigrateSIDHistory` registry value on source DC PDC
- Update the test plan with SID History validation steps

**Difficulty**: Low. The mechanism is one PowerShell flag; the operational requirements (rights, registry, audit log) are the real work.

## v0.3 — Group migration (Sprint 2)

**Why**: Users without their group memberships are users without permissions. Most consolidations need this.

**Scope**:
- New `provisioning-groups.ps1` script — reads source groups, creates corresponding groups in target with name-collision handling
- Membership reconciliation (handles nested groups, cross-forest references via SID History)
- Configurable scope filter (security groups only, distribution lists, both)
- `extensionAttribute14` (configurable) as the back-reference for groups, parallel to user back-ref

**Difficulty**: Medium. Logic is straightforward; edge cases (orphaned members, nested groups across forests, name collisions) take care.

## v0.4 — Computer account migration (Sprint 3)

**Why**: ADMT migrates computers along with users. PassFerry currently doesn't.

**Scope**:
- Computer object provisioning (similar to user provisioning)
- Client-side agent or remote PowerShell to disjoin/rejoin workstations
- Optional: pre-stage the target computer object so domain rejoin is a one-step operation
- Coordinate with user migration (a workstation should migrate after its primary user)

**Difficulty**: High. The hard part is the workstation-side dance — disjoining the source domain, joining the target domain, preserving the local profile. ADMT does this with an agent. We'd need similar.

## v0.5 — Service account migration (Sprint 4)

**Why**: SCM-registered services running as named source-domain accounts will break when those accounts move.

**Scope**:
- Inventory tool (already partially documented in `ISSUES-AND-RISKS.md`) extended to a script
- Migration helper that updates `Win32_Service.StartName` on member servers post-user-migration
- Recommendation engine that suggests gMSA conversions where appropriate

**Difficulty**: Medium. Inventory is easy; the conversion-to-gMSA recommendation is the value-add.

## v0.6 — Security translation (Sprint 5)

**Why**: This is ADMT's most painful feature to replicate, and where commercial tools (Quest, Semperis) genuinely differentiate themselves.

**Scope**:
- Walk file-share ACLs, registry ACLs, AD object ACLs
- Translate source-domain SIDs to target-domain SIDs (using SID History as the bridge)
- Optional dry-run mode with diff output
- Resume-from-checkpoint for long runs

**Difficulty**: Hard. This is genuinely complex and requires careful design. Probably warrants a separate sub-project (`passferry-acl`) rather than bolting onto the main repo.

## v0.7 — Reporting and observability (Sprint 6)

**Why**: Audit trails matter. "What did PassFerry do last week?" should have a clear answer.

**Scope**:
- Structured CSV/HTML migration reports (per run, per object, per forest)
- Prometheus metrics endpoint on the broker (queue depth, sync rate, failure rate)
- SIEM-friendly log format (JSON or CEF)
- Post-migration verification report (every source user has a target match, no orphans)

**Difficulty**: Low. Mostly formatting and shipping existing data.

## v0.8 — Lithnet integration recipe (Sprint 7)

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
