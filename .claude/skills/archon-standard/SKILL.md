---
name: archon-standard
description: Encodes Ben Peries' Archon Agent Standard v1.1, the governance rules shared by every repo he works in, model tier selection by depth of work, the mandatory approval gate before parallel agent dispatch, headless Claude Code execution rules, verification requirements, per-project stack selection policy, bilingual EN/Quebec-French delivery rules, session lifecycle conventions, and his output contract and hard conventions (currency format, no em dashes, Grype, conventional commits, squash merge). Use whenever delegating to a subagent, choosing a model tier, planning any multi-agent or parallel work, running or scripting Claude Code headless, verifying a completed task, choosing a language or framework for new work, producing a commit, PR, or doc, writing bilingual content, or naming, closing, or handing off a session, so these rules do not need to be re-stated in each repo's own CLAUDE.md.
---

# Archon Agent Standard v1.1

Ben Peries' governance rules for every repo he works in. This is the router. Detail
lives in the reference files below, one level deep, no further nesting.

Reference files in this directory:

- `model-tiers.md` - which model for which job, resolution order, escalation rule
- `parallelism.md` - the approval gate, dispatch rules, isolation, concurrency limits
- `headless-execution.md` - Claude Code headless flags, session naming, cost tracking
- `verification.md` - what to verify and how, the three-attempt stop rule
- `stack-selection.md` - how to pick language/framework/toolset per project
- `conventions.md` - output contract, currency, security tooling, ADR mechanics
- `bilingual.md` - EN plus Quebec-French delivery rules
- `session-lifecycle.md` - session naming, session maps, closing, respawn, handoff docs

## Non-negotiable rules (check every time)

1. Never dispatch parallel agents before Ben gives an explicit go. State agent count,
   tier mix, and each agent's job first, then wait. This is the one hard violation.
   See `parallelism.md`.
2. Set model tier by DEPTH of the work, not by category of task. See `model-tiers.md`.
3. Code in Claude Code headless (`claude -p`). Never in Cowork. Never in Claude Desktop.
   See `headless-execution.md`.
4. Verify against the actual artifact (published content, `docs/adr/` listing, live
   cluster), never against an agent's self-report or dispatch summary. See
   `verification.md`.
5. Stop after three failed fix attempts on one defect and state the assumption now in
   doubt. Do not try a fourth time without it. See `verification.md`.
6. Pick language and toolset for what THIS project's scope needs. No house stack. An
   existing project's stack is never re-litigated. See `stack-selection.md`.
7. No em dashes anywhere: prose, code, comments, commits, docs. Ever.
8. CAD currency format is `5$`, not `$5`.
9. Never send anything outbound (email, message, post) from an agent session. Draft it
   and hand it to Ben. He sends it himself.
10. Lead every response with the answer, command, or path. No preamble, no recap, no
    sign-off. Cap lists at five items. End with one next action.

## Quick routing

| Situation | Go to |
|---|---|
| Choosing which model a subagent should run as | `model-tiers.md` |
| About to dispatch more than one agent | `parallelism.md` |
| Writing or running a `claude -p` invocation | `headless-execution.md` |
| An agent just reported it finished something | `verification.md` |
| Starting a new project or component, picking a framework | `stack-selection.md` |
| Writing a commit, PR, or touching secrets | `conventions.md` |
| Writing bilingual EN/Quebec-French content | `bilingual.md` |
| Naming, closing, or handing off a session | `session-lifecycle.md` |
| Creating a work item, branching, or opening/completing a PR | `archon-ado`, where installed (ADO repos); GitHub repos follow `conventions.md` |

## Scope

This skill ships to every repo, not a fixed list of projects. A project's own
CLAUDE.md or project skill may add project-specific detail (its stack, its domain
rules) but must not restate or override these rules unless the override is an approved
one, listed below.

## Project overrides

A repo's CLAUDE.md or project skill may carry an approved override of one specific
rule, listed here with the date Ben approved it. An override replaces this skill's rule
only in that repo; everywhere else, this skill's rule still applies.

Approved:

- **archon-cc, approved 2026-09-12**: its downward review chain (Sonnet reviews every
  Opus and Fable deliverable, Haiku reviews every Sonnet deliverable, recorded on the
  work item) replaces `model-tiers.md`'s review tier rule in archon-cc only. The
  tiers and the no-cap approval gate still apply there unchanged.
- **vibin, approved 2026-09-14**: the repo's own CLAUDE.md routing stands as written,
  including its model ceiling. The project is dormant since its Phase 0 delivery and
  receives this skill only as a reference.

Pending: a repo whose CLAUDE.md carries its own model routing that this skill does not
list above is a pending decision, not an approved override. Do not follow either side
as settled. Name the conflict to Ben in the first response of the session, then do the
task at the tier both documents agree on, or stop if they agree on nothing.

Anything else that looks like a conflict between a repo's CLAUDE.md and this skill gets
flagged to Ben the same way. Do not silently pick a side.

Never carry one project's stack, skills, or MCP server set into another project. Each
project's scope decides its own tools; this skill only sets the cross-project
governance layer.
