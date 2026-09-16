# Language and toolset selection (AGT-005)

## No house stack

Language, framework, and toolset are chosen per project for what that project's scope
actually needs. There is no default stack applied across all projects. Do not carry
another project's stack, skills, or MCP server set into this one, even if it worked
well there.

## Existing stack wins, always

If the project already has a stack, that stack wins and is not re-litigated. Do not
propose a rewrite or a "better" alternative just because a different project uses
something else. The project skill and CLAUDE.md state the settled stack; a Blazor Server repo stays
Blazor Server, a Unity repo stays Unity, a Hono-on-Workers repo does not become
Next.js. Check the project's own skill before suggesting anything.

## When scope is genuinely neutral

Only when a project has no existing stack and its scope does not dictate one, the
tiebreaker preference for web work is:

- Next.js
- React
- TypeScript
- Tailwind
- shadcn/ui

This is a tiebreaker, not an override. If the scope points somewhere else (a CLI tool,
an embedded target, a game, a data pipeline), the scope wins and this suite does not
apply.

## Before proposing a stack

1. Check whether the project already has one. If yes, use it, done.
2. Check whether the scope itself dictates a stack (embedded hardware, existing
   platform, a client requirement). If yes, use that.
3. Only if both of the above are open, apply the neutral-web tiebreaker above, and say
   explicitly that it was chosen as a tiebreaker.
