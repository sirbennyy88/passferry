# Contributing to PassFerry

Thanks for your interest. PassFerry is a small project run by volunteers — every contribution helps.

## Most valuable contributions for v0.1 → v0.2

1. **Real-world lab test reports.** If you run PassFerry through the test plan in your environment, please open an issue with the details. Especially valuable: which Server versions, which third-party password filters were already installed (Specops, nFront, Entra Password Protection), and any failure modes you hit.

2. **Pre-flight check coverage.** If your environment had a configuration that PassFerry didn't detect or warn about, that's a pre-flight bug worth filing.

3. **Code review of the LSA filter DLL.** This code runs in LSASS. Extra eyes are welcome — particularly on the exception handling, the named pipe semantics, and the buffer-handling around `UNICODE_STRING`.

4. **Documentation improvements.** If something in the docs was unclear or wrong, that's a fix worth making.

## Sprint claims

The [ROADMAP.md](ROADMAP.md) lists sprints (SID History, group migration, computer migration, etc.). To claim one, open an issue using the "Sprint claim" template with:

- Which sprint you're working on
- Your rough timeline
- Any design questions you have up front

Discussion happens in the issue, PRs reference back. The maintainer reserves the right to push back on scope, but the door is genuinely open.

## Pull request guidelines

- **One logical change per PR.** A PR that changes the broker AND the docs AND adds a feature is hard to review.
- **Keep the LSA filter DLL minimal.** Anything that adds complexity to the C code needs to justify why it can't live in the user-mode forwarder. The DLL runs in LSASS and bugs there crash domain controllers — minimalism is a feature, not a limitation.
- **PowerShell style**: stick to PowerShell 5.1 compatibility. No `??` null-coalescing, no `-not` keyword shortcuts that 5.1 doesn't support.
- **Tests where they make sense.** PowerShell Pester tests for the broker's matching logic, for example. Not every script needs unit tests, but anything with branching logic does.
- **Update CHANGELOG.md** under an `## [Unreleased]` heading.
- **Sign off your commits**. We follow [Developer Certificate of Origin](https://developercertificate.org/) — `git commit -s`.

## Code of conduct

Be kind. Disagreements are fine, personal attacks are not. The maintainer reserves the right to lock issues or remove contributors who are abusive.

## Reporting security issues

**Do not open a public GitHub issue for security vulnerabilities.** Instead, email the maintainer (see GitHub profile) with details. We'll respond within 7 days. Coordinated disclosure preferred.

Particular attention to:
- LSA filter DLL — anything that could crash LSASS or be exploited inside it
- Broker authentication — anything that bypasses the mTLS allow-list
- Cleartext password handling — anything that causes the password to be logged, persisted, or transmitted over a non-mTLS channel

## Building and signing the DLL for development

See [filter-dll/BUILD.md](filter-dll/BUILD.md) for the full build instructions. For development, a self-signed lab cert is fine. For any binary that ships in a release, the signing should use the project's official cert (process TBD when we get to that point).

## What this project will NOT accept

- Bidirectional sync (target → source). Out of scope by design.
- Code that introduces commercial dependencies (proprietary libraries, paid services).
- Code that bypasses Server 2025's security defaults (RC4 fallback, RunAsPPL workarounds beyond what's already documented).
- "Vibe code" pull requests — generated wholesale by an LLM without testing or code review. PassFerry was *built* with AI assistance, but every line was reviewed; we expect the same of contributions.
