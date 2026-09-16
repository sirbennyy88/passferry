# Headless execution (AGT-003)

## Executor rule

Coding happens in Claude Code headless (`claude -p`). Never in Cowork. Never in Claude
Desktop. Cowork and Claude Desktop can plan, review, and orchestrate, but they do not
write code themselves.

## Session roles

Cowork orchestrates as `M`; headless executors are `M.1`, `M.2`, `M.N`. Naming,
session maps, closing and handoff: `session-lifecycle.md`.

## Canonical clone

Run from the repo's canonical clone, never a stale mirror. The project skill names the
clone; if it does not, ask before running anything that writes.

Before trusting an MCP-dependent run, confirm the repo's `.mcp.json` command paths and
key paths resolve on the host the executor is running from. A server that fails to
start registers zero tools without an error; the `system/init` check below is what
catches it.

## Run modes

- **Deterministic runs**: use `--bare`.
- **Unattended runs**: use `--permission-mode dontAsk` (or `acceptEdits` where writes are expected) plus `--permission-prompts none` plus
  `--strict-mcp-config ./.mcp/<job>.json`. An unattended run must not fall back to an
  unscoped or default MCP config.

## MCP server verification

Before trusting an unattended job's output, verify the MCP servers it needed were
actually registered. Check the `system/init` event in the run's stream-json output. If
a required server is missing from that event, fail the job rather than letting it run
degraded.

## Cost tracking

- Capture cost from `--output-format json`, field `total_cost_usd`, on every headless
  run that should be tracked.
- Run a daily ccusage audit.
- Flag any day where Opus spend exceeds Sonnet spend. That is a signal the tier
  discipline in `model-tiers.md` is not being followed, not just a budget note.
