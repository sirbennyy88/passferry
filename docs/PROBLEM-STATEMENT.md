# Problem Statement

## Why PassFerry exists

The Active Directory Migration Tool (ADMT) version 3.2 has been the standard Microsoft-provided utility for cross-forest migrations since 2014. It performs user account migration, password migration via Password Export Server (PES), group migration, computer account migration, service account migration, SID History migration, and security translation across Windows Server domains.

**As of Windows Server 2025, ADMT 3.2 is effectively unsupported for multi-domain and multi-tenant migrations.**

The reasons are accumulated, not singular:

### Code age and lack of updates

ADMT 3.2 was released for Windows Server 2008 R2 / 2012 era and has not received a meaningful update since. Microsoft's official position has long been "best-effort support, no active development." With each successive Windows Server release, more of ADMT's underlying assumptions have become invalid:

- It assumes RC4 Kerberos encryption is available in trusts (Server 2025 deprecates RC4 by default)
- It assumes unconstrained delegation is permitted (modern security baselines disable this)
- It assumes the source DC can be the host of the ADMT installation (Microsoft now recommends installing on the target to avoid the unconstrained delegation requirement)
- The PES installer requires registry shenanigans to run on Server 2019+, more so on 2022, and fails outright on 2025 in many configurations
- The Migration Wizard UI uses MMC snap-ins that increasingly do not load cleanly on modern OSes

### LSA Protection (RunAsPPL) and DLL signing

Windows Server 2025 ships with stricter defaults for LSA Protection (RunAsPPL). When enabled, only Microsoft-signed DLLs can load into the LSASS process. ADMT's PES — which uses an LSA password filter mechanism — was written before this requirement existed and is not signed in a way that satisfies modern PPL-protected LSASS. Either RunAsPPL must be disabled (a security regression) or the password sync function silently fails to load.

### Multi-forest and multi-tenant scenarios

ADMT's design assumes a single source domain and single target domain per migration job. Organizations with three, four, or more legacy forests consolidating into one target — typically as a precursor to Microsoft Entra ID (formerly Azure AD) integration — find themselves running ADMT repeatedly against partial scopes, with brittle configurations and no real orchestration. Multi-tenant Entra scenarios (M&A activity, divestiture) compound this: the on-premises consolidation must complete before Entra Connect can take over, and ADMT becomes the bottleneck.

### The commercial alternative

Quest Migrator Pro for Active Directory (formerly Quest Migration Manager and Binary Tree's Active Directory Pro) is the de-facto commercial replacement. It supports Server 2025, handles multi-forest topologies natively, includes real-time password sync via its own LSA filter, and ships with comprehensive support contracts. It is also expensive — typically priced per user-account migrated, with multi-forest projects running into five or six figures.

For organizations with budget for licensed migration tooling, Quest is the right answer and PassFerry is not necessary. For organizations consolidating legacy forests under budget constraints — including but not limited to non-profits, educational institutions, smaller businesses, and internal IT teams whose CapEx for migration tooling has been rejected — there has been no straightforward open-source alternative.

### What about Entra Cloud Sync?

Microsoft's recommendation for "modernize your identity" scenarios is increasingly to skip the on-premises consolidation entirely and use Entra Cloud Sync (formerly Azure AD Connect Cloud Sync) directly from each legacy forest to a single Entra tenant. This works well when the goal is cloud-only identity. It does not solve scenarios where:

- On-premises applications still require on-premises AD authentication after the migration
- Legacy file shares, print services, and group memberships need to be carried forward
- A single consolidated on-premises AD is required for compliance, GPO management, or regulatory reasons before cloud transition
- Multiple Entra tenants exist and must be reduced to one (M&A scenarios)

In these cases, on-premises AD-to-AD migration remains a real requirement — and that requirement is what ADMT historically addressed.

## What PassFerry addresses

PassFerry implements the **password synchronization** portion of the migration problem — specifically the part that ADMT's PES handled and that breaks most reliably on Server 2025. It performs:

1. **One-way user provisioning** from one or more source forests into a single target forest, on a schedule, idempotently
2. **Real-time password synchronization** from source to target, using the documented LSA password notification filter mechanism

It is intentionally **focused, not comprehensive**. It does not migrate groups, computers, security translations, or trusts as of v0.1. It is *adjacent* to ADMT: it covers the most-broken parts of ADMT's functionality, not all of it. The roadmap (see [ROADMAP.md](../ROADMAP.md)) describes how PassFerry could grow toward a more complete community alternative.

## Design principles

- **Documented APIs only.** Every Microsoft API used by PassFerry is publicly documented. No reflection on internals, no undocumented LSA secrets, no DCSync abuse.
- **Pure Microsoft + PowerShell + minimal C.** No third-party libraries, no cloud dependencies, no commercial components.
- **Server 2025 native.** AES-only Kerberos and LDAPS throughout. Code-signed DLL. No RC4. Compatible with strict driver/DLL signing.
- **Honest about gaps.** Pre-flight checks tell you what could go wrong before you deploy. Documentation is explicit about what's prototype and what's production-ready.
- **One-way and read-mostly.** PassFerry doesn't write to the source forest. It cannot accidentally damage source identities. Source remains the system of record throughout the migration.

## What this is not

- A drop-in ADMT replacement (it covers password sync, not the full ADMT feature surface)
- A commercial product (no support contract, no SLA, no warranty)
- A Microsoft-endorsed tool (PassFerry is independent open-source software using public APIs)
- A way to bypass Server 2025's security improvements (PassFerry works *with* AES, mTLS, code-signing, and gMSAs — not around them)
