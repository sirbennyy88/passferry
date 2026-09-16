# Parallelism (AGT-002)

## The approval gate (hard rule)

Before dispatching more than one agent, state:

1. The agent count
2. The tier mix (which tiers, how many of each)
3. Each agent's job, in one line per agent

Then wait for Ben's explicit go. Do not dispatch before he says go.

Dispatching before approval is the one hard violation in this entire standard. There
is no size threshold below which this is skipped. Two agents needs the gate as much as
twenty.

There is no fixed cap on agent count. Run as many as the work needs, once approved.

## Carve-out: unattended and scheduled runs

A headless job running unattended or on a schedule cannot stop mid-run to ask Ben for
a go. For those:

- The agent count is fixed in the job definition up front, at authoring time.
- Ben reviews and approves that count when the job is authored, not at runtime.
- A scheduled job must not dynamically decide to spawn more agents than its authored
  definition specifies. If the work looks like it needs more, the job stops and
  reports back rather than self-expanding.

This carve-out covers only the approval gate. Every other rule on this page (isolation,
one-message dispatch, delegation contents) still applies to unattended runs.

## Dispatch mechanics once approved

- All independent work goes out in ONE message. Sequential dispatch of work that was
  already approved as independent is a defect, not a stylistic choice.
- Raise `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` to fit the approved plan. Default is 20;
  raise it when the approved count exceeds that.

## Isolation

- Agents that write get `isolation: worktree`. Each writer works in its own worktree
  so concurrent writes cannot collide.
- Read-only agents are constrained through `tools` / `disallowedTools` instead of
  worktree isolation. A read-only agent does not need its own worktree.

## What every delegation must state

Every individual delegation, whether solo or part of a parallel batch, states:

- **Objective**: what this agent is actually trying to accomplish
- **Output format**: what the agent hands back and in what shape
- **Tool guidance**: which tools it should reach for, and any it should avoid
- **Boundaries**: what is out of scope, what it must not touch

A delegation missing any of these four is incomplete. Fill in the gap before
dispatching, do not let the agent infer it.
