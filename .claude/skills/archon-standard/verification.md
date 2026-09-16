# Verification (AGT-004)

## Verify against the artifact, not the report

Never accept an agent's self-report or dispatch summary as proof of completion. Check
the thing itself.

- To verify published content, read the published content, not what the publishing
  agent said it published.
- To verify ADR counts, list `docs/adr/` directly and count.
- To verify deployed state, query the live cluster directly. A deployment log or a
  dispatch summary saying "deployed" is not deployed state.

If verifying the artifact is not possible in the current context, say so explicitly
rather than treating the self-report as sufficient.

## Security-relevant work

Any security-relevant change gets a Fable 5 adversarial pass before merge. This is not
optional and does not scale down for small diffs. "Security-relevant" includes auth,
secrets handling, permission boundaries, input validation on external-facing surfaces,
and anything touching a mandatory pre-commit gate the project's own skill names (a
sanitization or secrets-scrub pipeline, for example).

## The three-attempt stop rule

After three failed attempts to fix one defect:

1. Stop. Do not attempt a fourth fix on the same assumption.
2. State the assumption that is now in doubt. Name it explicitly, do not just say
   "still broken."
3. Only proceed once that assumption has been checked or replaced. A fourth attempt
   without naming what's in doubt is a defect in its own right.

This counts per defect, not per session. Three attempts across three different
sessions at the same underlying bug still triggers the stop.
