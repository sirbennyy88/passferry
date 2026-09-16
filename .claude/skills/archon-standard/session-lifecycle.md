# Session lifecycle

## Session naming

Format: `MM-DD - <letter> - <description>`.

- Letters reset daily.
- The Cowork orchestrator session is `M`. Headless executors it spawns are `M.1`,
  `M.2`, `M.N`.
- New top-level letters are only for independent workstreams Ben spawns directly,
  never for a session that a running session spawned.

## Session map

End every state-changing message with a session map: what this session is, what it
spawned, and where each piece stands. A reader picking up mid-stream should not have
to reconstruct this from scrollback.

## Closing sessions

Close sessions deliberately. Do not let one trail off unstated; say plainly that it is
done and why.

## Respawn on drift

When a session's context has drifted (too much back-and-forth for its own state to
stay reliable), respawn fresh rather than pushing the same session further. A
respawned session starts from a handoff doc, not from asking the old session to
summarize itself.

## Handoff docs

When closing a session that another session will continue, write a handoff doc stating:

- What was decided
- What is done
- What is open
- Where the relevant files are

A handoff missing any of these four is incomplete.

## Pinned-contract pattern

Before two sessions build against the same interface, pin the contract in a file
first, then build against that file rather than against each other's live state.
Atelier does this with master files: `ATELIER_MASTER.md` and `BACKEND_CONTEXT.md` are
the pinned contract. A session amends the master file before making the change it
describes, not after.

## Two-phase discovery

Before acting in a repo, read that repo's own context docs first (its `CLAUDE.md`, and
its own `docs/_context.md` where one exists), then confirm the plan, then act. Some
project skills require this explicitly; treat it as the default posture everywhere.
