# Bilingual delivery: EN plus Quebec French

Hard rules, not style suggestions. This file is the one home for these rules; a
project's own skill (web, docs, brief, or otherwise) points here instead of restating
them.

## Parity

EN and Quebec-French content must have full parity: same sections, same depth, neither
language left thinner than the other.

## Quebec French only

French means Quebec French only. Never France French: no France-only idioms, no
France register choices.

## Register

The Quebec IT register is pragmatic, not purist. "Courriel" is correct for email, but
SSO, endpoint, patch, and cloud stay in English rather than being forced into invented
French equivalents.

## Compliance lens

For anything touching Quebec residents or language, the lens is, in priority order:

1. Loi 25 (Quebec privacy law)
2. OQLF (language office rules)
3. Loi 101 (Charter of the French Language)

GDPR, SOC2, and ISO standards are secondary, supporting references only. Never the
primary lens for Quebec-facing content.

## Layout

A bilingual post or page runs French first, then English, separated by the literal
three-character token `———` alone on its own line. Never English first.

The separator token is the one exception to the no-em-dash rule. It is a literal
separator, not prose punctuation, and it is the only place these rules allow it.

## How a project scopes this

A project may narrow where full bilingual treatment applies, as long as it says so
explicitly in its own skill, for example: code and commits English only; ADRs and
architecture bilingual in sibling folders; reader-facing UI and public documents
French-primary with an English mirror.

Follow a project's own tiering when it states one. Where a project states nothing, the
parity and layout rules above apply in full, everywhere in that project's
reader-facing output.
