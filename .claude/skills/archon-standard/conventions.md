# Output contract and hard conventions

## Output contract

- Lead with the answer, the command, or the path before any explanation.
- No preamble. No recap of what was asked. No sign-off.
- Cap lists at five items. If there are more than five, pick the five that matter and
  say the rest exist rather than listing all of them.
- End with one next action, not a menu of options.

## Never send anything outbound from an agent session

Two-part rule. Do not collapse it to either half.

1. Interactive and Cowork sessions NEVER send. No email, no chat message, no post. Draft
   the content and hand it to Ben; he sends it himself from wherever he chooses. A
   connector being present in the session is not authorization to use it for sending.
2. Where a send IS authorized (a scheduled run Ben set up for that purpose), it uses
   the dedicated sending account Ben designates, keeps Ben in CC, carries his explicit
   authorization for that specific send, and ends with an attribution line naming
   Claude (AI) and whether Ben directed it or it ran unattended. The account and the
   exact lines live in Ben's own configuration, not in a repo.

## Formatting

- No em dashes anywhere: prose, code, comments, commit messages, PR descriptions,
  documentation. Use a period, a comma, or two sentences instead.
- CAD currency is formatted `5$`, not `$5`. Amount first, symbol after.
- The surname is Peries, with no accent on the e, in every deliverable.

## Version control

- Conventional commits on every commit message.
- Merge strategy is squash merge. Applies everywhere: ADO repos and GitHub repos alike.

## Security tooling

- Vulnerability scanning is Grype. Not Trivy. (March 2026 TeamPCP compromise, ADR-0003.)
- Secrets never live in a file, an env var in a config, or a git remote URL. Where a
  given project keeps its secrets (Infisical, Azure Key Vault, or something else) is
  that project's own skill to state; this rule holds regardless of backend.

## ADR mechanics

- Default move is amend: add a dated addendum to an existing ADR rather than creating a
  new one. Creating a new ADR is the exception, not the default.
- The ADR path and numbering scheme are project-specific. The project's own skill
  states them; this skill does not guess a path.
- To state or verify an ADR count, list the project's ADR directory directly. Never
  derive a count from PR merge history; partial merges and encoding issues cause
  discrepancies there.

## Applying this in a project's own CLAUDE.md

A project's CLAUDE.md should reference this skill for these rules rather than
restating them. If a project needs an exception, that exception is stated explicitly
in that project's CLAUDE.md with the reason, and flagged to Ben rather than silently
adopted.
