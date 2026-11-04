# City of Brussels agenda layouts (issue #150)

Inspected on 2026-11-04: the retained native-text artifacts of all 22 official City agendas,
supplements and addenda from 2026-01-19 to 2026-10-12, read from production. The repository
keeps only the minimal excerpts in `test/support/fixtures/city_of_brussels`.

## Layout

- Every retained document is French. It opens with `VILLE DE BRUXELLES` / `STAD BRUSSEL`,
  `CONSEIL COMMUNAL DE LA VILLE DE BRUXELLES`, the dated `Séance du …` heading, the title
  (`Ordre du jour`, `Supplément à l'ordre du jour` or `Addendum à l'ordre du Jour`) and
  `Séance publique`.
- Every page ends in a footer naming the title, the date and the page number.
- A point is `[n]`, a department line that closes on a dossier number and `(R)`, wording, then a
  dashed separator. The department line can wrap over two lines.
- Section headings sit between points: `Dossiers de M. le Bourgmestre`,
  `Dossiers de Mme l'Echevine …`, `Dossiers de M. l'Echevin …`, `Motions`, `Questions`,
  `Communications.` and `Interpellation citoyenne`.

## Supplements add, they do not restate

Numbering is continuous within a document, and a supplement continues after a gap in the base
agenda. On 2026-10-12 the base runs 3 to 57 and the supplement 74 to 109. Within each of the
2026 meetings with two parsed documents, no point number or dossier number repeats. So item
identity is the dossier number, and the page covers base plus supplement. A dossier number that
repeats inside one document opens a review case.

## What becomes a proposal

Points under a `Dossiers de …` heading and `Motions` become proposals. Under ADR 0005, these stay
on the record without a proposal:

- points under `Communications`, `Interpellation citoyenne` and `Questions`;
- points whose only action is `Prendre pour information`, `Prendre acte` or `Prendre connaissance`,
  such as college decisions noted under article 234 §3. A point that numbers another action, such
  as `1) Prendre acte … 2) Approuver …`, stays a proposal.

## Result on the retained documents

Run with `CITY_AGENDA_TEXT_DIR` set for `city_of_brussels_normalization_integration_test.exs`,
with the retained text kept outside Git. Every emitted excerpt occurs on its cited page.

| Document | Points | Proposals | Result |
| --- | --- | --- | --- |
| 2026-01-19 agenda | 56 | 22 | parsed |
| 2026-01-19 supplement | 18 | 11 | parsed |
| 2026-02-09 agenda | 32 | 27 | parsed |
| 2026-02-09 supplement | 20 | 13 | parsed |
| 2026-03-16 agenda | 52 | 38 | parsed |
| 2026-03-16 supplement | - | - | review case: heading `Election d'un neuvième Echevin` |
| 2026-04-20 addendum | 1 | 1 | parsed |
| 2026-04-20 agenda | 75 | 46 | parsed |
| 2026-04-20 supplement | - | - | review case: point 133 crosses a page break |
| 2026-05-18 agenda | - | - | review case: heading `Prestation de serment` |
| 2026-05-18 supplement | 52 | 34 | parsed |
| 2026-06-08, 2026-06-29, 2026-09-07 (7 documents) | - | - | unavailable: recorded corpus meeting |
| 2026-09-21 agenda | 34 | 24 | parsed |
| 2026-09-21 supplement | 28 | 14 | parsed |
| 2026-10-12 agenda | 55 | 28 | parsed |
| 2026-10-12 supplement | 36 | 24 | parsed |

Both 2026-10-12 documents together give 91 items and 52 publishable items, with no review case
and a valid publication input.

A document with a heading outside this list, or a point crossing a page, records nothing and
opens a review case, because one excerpt could not cite one page. Those three documents are all
before the retry window.

## Recorded corpus meetings

City 2026-06-08, 2026-06-29 and 2026-09-07 are recorded corpus meetings with two or three sealed
items. Normalizing another of their documents would add items and change a page that must stay
byte-identical, so the normalizer treats them as unavailable. The 2026-09-07 supplement therefore
keeps its "normalization unavailable" case. Its source stays unlinked, so that case blocks nothing.

## Stale cases

Inside the window, only four open "normalization unavailable" cases apply: the agenda and
supplement of 2026-09-21 and 2026-10-12. Supporting documents keep theirs: those sources are never
linked to a meeting, so the gate ignores them.
