# Uccle agenda layouts (issue #148)

Inspected on 2026-11-03: the retained native-text artifacts of all eight official Uccle
agendas from 2026-05-28 to 2026-10-15 (base and complementary), read from production.
The repository keeps only the minimal excerpts in `test/support/fixtures/uccle/agendas`.

## Layout

- Both documents open with a convocation letter, the commune in both languages, the dated
  `CONSEIL COMMUNAL DU …` and `GEMEENTERAAD VAN …` headings, `ORDRE DU JOUR` /
  `AGENDA` or `ORDRE DU JOUR COMPLÉMENTAIRE` / `AANVULLENDE AGENDA`, and
  `SÉANCE PUBLIQUE - OPENBARE ZITTING`. Only the public session is listed.
- A point is a four-space-indented number followed by French at a fixed column, a blank
  line, then Dutch at the same column. Every page ends in a dated two-line footer with `n/total`.
- Department and service headings sit at the number's indent: capitals, or a short
  `Service - Dienst` pair.
- A page break can fall between the languages, inside the French, or inside the Dutch.
  French that continues on the next page is the only case where an excerpt is shorter than
  the wording: it cites the first page's part, and the location names both pages.
- Numbering can begin at 2 and has no gaps in a well-formed agenda.
- Dutch paragraphs repeat French names (`V.Z.W. Actions pour les familles…`) and can be the
  placeholder `Vertaling zal volgen`, so Dutch cannot be required to be Dutch-dominant.

## The complementary agenda restates and renumbers

A complementary agenda is a complete list, not an addition. New points are inserted, so a
number points at different matters across the two documents: on 2026-10-15, point 29 of the
base agenda is point 30 of the complementary agenda, and point 29 there is a new matter.

Across the pairs, every base wording recurs word for word in the complementary agenda on
2026-05-28, 2026-09-10 and 2026-10-15. On 2026-06-25, three base wordings do not recur: one
removed and two reworded.

Item identity is therefore the exact French wording scoped to the meeting, not the number.
An earlier item that a restating agenda does not carry over opens a review case that blocks
the page, because removal and rewording cannot be told apart from the text.

## Result on the retained documents

Re-run on 2026-11-04 over the retained native text, kept outside Git, with
`UCCLE_REAL_AGENDA_DIR` set for `uccle_normalization_integration_test.exs`. Every emitted excerpt
occurs on its cited page.

| Agenda | Points | Proposals | Result |
| --- | --- | --- | --- |
| 2026-05-28 base | 23 | 16 | parsed |
| 2026-05-28 complementary | 39 | 18 | parsed |
| 2026-06-25 base | - | - | review case: point 28 is malformed at the publisher |
| 2026-06-25 complementary | 51 | 36 | parsed |
| 2026-09-10 base | - | - | unavailable: recorded corpus meeting |
| 2026-09-10 complementary | - | - | unavailable: recorded corpus meeting |
| 2026-10-15 base | 40 | 33 | parsed |
| 2026-10-15 complementary | 58 | 34 | parsed |

Both 2026-10-15 agendas together give 58 items and 34 publishable items, with no review case.

Questions, interpellations and points marked `Prise pour information` or `Prise de
connaissance` stay on the record without a proposal (ADR 0005).

## Recorded corpus meetings

Uccle 2026-09-10 is a recorded corpus meeting, published from its complementary explanatory
note with two sealed items. Normalizing its agendas would add items and change a page that
must stay byte-identical, so the normalizer treats every recorded corpus meeting as
unavailable. Its agenda sources stay unlinked, so their open cases block nothing.

Uccle 2026-10-15 is therefore the only meeting the retry can change. Its explanatory notes keep
their "normalization unavailable" cases: those sources are never linked to the meeting, so the
gate ignores them.
