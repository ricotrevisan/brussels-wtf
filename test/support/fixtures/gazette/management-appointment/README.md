# Isolated Gazette management fixture

Authored extracts for [Publish one Gazette management fact end to end](https://github.com/RicoTrevisan/brussels-wtf/issues/45).

These bytes are **not** Official Gazette annexes. They are representative extracts used only in tests. CI must not fetch `ejustice.just.fgov.be`. Fixture facts must not be published as live coverage.

Modelled locators (HTTPS, no query or fragment):

- https://www.ejustice.just.fgov.be/tsv/fr/2026-0123456749-appointment
- https://www.ejustice.just.fgov.be/tsv/fr/2026-0123456749-cessation

Parent index: https://www.ejustice.just.fgov.be/tsv/tsvf2.htm

Legal entity: test CBE `0123456749` / Public Example ASBL.
Person: `Alex Public`, resolved by exact name plus the CBE number printed in the same act.
