# Model tiers (AGT-001)

Tier by DEPTH of the work, never by task category. A "coding task" is not
automatically Sonnet; a "review task" is not automatically Fable. Ask how deep this
particular piece of work is, then pick the tier.

## The four tiers

| Tier | Use for |
|---|---|
| Opus 5 | Deep orchestration. Standard architecture. All ADR decisions. |
| Sonnet 5 | Light orchestration. Default builder for everything else. Self-escalates to Opus mid-task when the work turns out deep. |
| Fable 5 | Deep architecture. Deep research. Security review. Adversarial verification. |
| Haiku 4.5 | Light coding. Screenshots. Mechanical work: file ops, scaffolding, ADR publish, ADO work item creation. |

## Sonnet self-escalation

Sonnet 5 is the default builder and default light orchestrator. If, mid-task, the work
turns out to be deep (the architecture is not standard, the orchestration has grown
complex), Sonnet escalates itself to Opus 5.

- The escalation must be announced. Never escalate silently.
- State what changed: why this turned out deep, not merely long.
- Do not escalate just because a task is taking a while. Escalate because the nature
  of the decision changed.

## Setting the tier

Tier is set in the subagent's frontmatter `model:` field. It is never inherited from
the session's model.

Resolution order (first one present wins):

1. Per-invocation parameter (an explicit override passed at dispatch time)
2. Subagent frontmatter `model:`
3. `CLAUDE_CODE_SUBAGENT_MODEL` environment variable
4. Session model

## Review tier rule

A review agent must run at the same tier as the work it reviews, or higher. Never
lower. A Fable 5 architecture decision does not get reviewed by Haiku 4.5; a Haiku 4.5
scaffold can be reviewed by Haiku 4.5 or above. An approved project override (see
`SKILL.md`'s Project overrides) may define a different chain for that repo only.

## Common misclassifications to avoid

- "It's just a security check" is not automatically light. Security review is always
  Fable 5, regardless of how small the surface looks.
- "It's just file moves" is not automatically Opus even inside a big migration. If it
  is mechanical, it is Haiku 4.5.
- Orchestrating three trivial subagents is light orchestration (Sonnet 5). Orchestrating
  a multi-service architecture change is deep orchestration (Opus 5), even with the
  same subagent count.
