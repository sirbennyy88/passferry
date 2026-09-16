---
name: passferry
description: PassFerry, Ben Peries's open-source ADMT 3.2 password-sync replacement for Windows Server 2025 Active Directory migrations (C LSA password filter plus PowerShell forwarder/broker/provisioning services, repo sirbennyy88/passferry). Use when writing, reviewing, building, or merging PassFerry code, touching LSASS/RunAsPPL/code-signing concerns, or before any merge to this repo, which requires a Fable 5 adversarial security pass first.
---

# PassFerry

## Governance

This skill imports `archon-standard` for governance (model tiers, the parallelism
approval gate, headless-run rules). Do not restate those here.

## Security is the gate, not a checklist item

PassFerry runs as an LSA password notification filter inside LSASS on production domain
controllers. A defect here is not "a bug," it's a potential crash or compromise of every
DC it's loaded on. Hard rules:

- **Every change gets a Fable 5 adversarial security pass before merge.** No exceptions
  for "small" changes, docs-adjacent code changes, or refactors that "don't touch logic."
  If it's in the repo and it ships, it gets the pass first.
- **There are no repo-level security hooks in passferry today**: `.claude/` is absent
  from the repo. The Fable 5 adversarial pass before merge is the gate itself; the
  absence of hooks is not license to skip or shortcut it.
- Never treat a green build or a passing unit test as a substitute for the security pass.
  This codebase's failure modes (RunAsPPL bypass, credential handling in the forwarder/
  broker path, LDAPS/mTLS trust handling) are exactly the class of bug unit tests don't
  catch.

## What this is

Open-source replacement for ADMT 3.2 password synchronization, because ADMT 3.2 is
**dead on Windows Server 2025**: RC4 deprecation, RunAsPPL enforcement, and a broken PES
(Password Export Server) are non-negotiable blockers, not edge cases to work around.
Repo: `github.com/sirbennyy88/passferry`, MIT license, currently v0.1.

## Architecture (four components, know the boundary of each)

1. **C LSA password notification filter DLL** (`passferry_filter.dll`), runs inside
   LSASS on source DCs. This is the most sensitive component; anything touching it gets
   the security pass and extra scrutiny on memory safety.
2. **PowerShell forwarder service** on source DCs. Forwards captured password events to
   the broker via **mTLS HTTPS**. Never weaken this to plain TLS or unauthenticated HTTP,
   even for local lab testing; test with real (self-signed-lab) mTLS instead.
3. **PowerShell broker service** on a target-forest member server. Resolves users and
   calls `Set-ADAccountPassword` over **LDAPS**. Never call this over plain LDAP.
4. **PowerShell provisioning script**. Syncs users from source forests to the target
   forest on a schedule.

Identity matching between source and target uses a **configurable back-reference
attribute**, default `extensionAttribute15`, config key `BackrefAttribute`. A pre-flight
script audits `extensionAttribute1`-`15` for existing usage before picking one. Never hard
-code `extensionAttribute15` in new code; always read it from `BackrefAttribute`, because
a target environment may already be using it for something else, that's exactly what the
pre-flight audit is for.

## Hard-won gotchas (don't rediscover these)

- **RunAsPPL=1 is the #1 deployment blocker.** With `RunAsPPL` enabled on source DCs
  (required on Server 2025 in most hardened configs), LSASS refuses to load a
  self-signed-signed DLL. The filter DLL needs Microsoft LSA-plugin signing via an **EV
  certificate**; a standard code-signing cert is not sufficient. Don't propose a
  self-signed or standard-cert path as a production fix, only as a lab workaround.
- **The `Notification Packages` registry value must be appended, never replaced.**
  Overwriting it (instead of adding `passferry_filter` to the existing list) breaks any
  co-installed filter, notably Specops/`scecli`. Any installer or provisioning script
  change touching this registry value must read-modify-append, and should have a test
  that asserts an existing entry survives.
- **Build environment**: MSVC needs the Developer Command Prompt or `vcvars64.bat`;
  `cl.exe` is not on PATH in a regular PowerShell session. WSL/UNC source paths don't work
  reliably with MSVC, copy source to a native Windows temp directory first. On a fresh
  install, SDK headers can still be downloading when a build is attempted, a build failure
  right after a fresh VS install is more likely an incomplete SDK than a code problem.
  Current toolchain: MSVC 14.50.35730 (VS 2026 Community). Verify DLL exports with
  `dumpbin /EXPORTS`, not by inference from the build succeeding.
- **Semver discipline going forward**: consistent three-part semver (v0.1.0, v0.1.1,
  v0.2.0, ...). The existing `v0.1` tag (two-part) is legacy and stays as-is, don't
  retroactively rename it, and don't repeat the past mistake of relabeling v0.1.1-scoped
  items as v0.2.
- **Homelab AD testing**: Ubuntu KVM with VirtIO drivers and `virt-manager` is a viable way
  to run a test AD forest. **Windows containers and k3s are not viable** for this, because
  the filter's LSASS/kernel-mode requirements don't work in either. Don't propose a
  container-based test harness for the filter DLL itself.

## Positioning and sanitization

- Recommended open-source pairing: **Lithnet Password Protection** as an enforcement-side
  complement (PassFerry syncs, Lithnet enforces policy). Mention this rather than
  reimplementing enforcement-side logic in PassFerry.
- Direct commercial alternative to be aware of when discussing tradeoffs: **Specops
  Password Sync**.
- Prior art to credit, not silently reinvent: **PassFiltEx**, **Lithnet**,
  **OpenPasswordFilter**.
- **Sanitize internal context before publishing or sharing externally**: strip codenames,
  internal hostnames, and any lab-specific identifiers from anything destined for the
  public repo, README, or a LinkedIn/public post. This has been an active editorial pass
  in this project's history, not a one-time cleanup, apply it to every externally-facing
  change.
- Communication register for this project: direct and precise. Don't claim a fix or
  feature is "infallible," "complete," or "production-ready" without qualifying exactly
  what's been verified; overclaiming has been explicitly flagged before on this project.

## MCP servers

- **Microsoft Learn MCP** (`https://learn.microsoft.com/api/mcp`), an authless
  first-party server, only. Used here for authoritative Windows Server 2025 / Active
  Directory / LSA / Entra Connect documentation (RunAsPPL, LSA notification packages,
  `Set-ADAccountPassword`, etc.); PassFerry's C/PowerShell code is not a .NET-runtime
  concern, so this project does not use it for .NET version guidance. No Context7, no
  other MCP server is provisioned for this project; if a third-party library needs
  docs, check whether it's actually in scope before reaching for tooling this skill
  doesn't have.
