# Ixelles minutes to decisions

[Issue 147](https://github.com/RicoTrevisan/brussels-wtf/issues/147) adds
`BrusselsWtf.Processors.IxellesMinutes`. Once official minutes are extracted, a proposal on
the meeting page becomes a cited decision at the same URL, as a new dated revision.

## What a reading accepts

The layout was checked against the retained 2026 minutes for meetings 262 to 267. Minutes
dated before 2026-01-01 stay unsupported.

- **Identity:** the printed `DD.MM.YYYY/A/NNNN` number. When the meeting's agenda has that
  number, its wording must agree, ignoring case, spacing and punctuation. Real minutes
  renumber and retitle points (267 points 57 to 64, 262 point 28, 265 point 6). An agenda
  wording that also holds the start of a Dutch title agrees only if a paragraph after the
  outcome in these minutes starts with exactly that text.
- **Outcome:** the exact French line and its exact Dutch counterpart.

  | French | Dutch | Disposition |
  | --- | --- | --- |
  | `Le Conseil approuve.` | `De Raad keurt goed.` | approved |
  | `Décision prise par scrutin secret. Le Conseil approuve.` | `Besluit bij geheime stemming. De Raad keurt goed.` | approved |
  | `Le point est rejeté.` | `Het punt wordt verworpen.` | rejected |
  | `Le point est reporté.` | `Het punt wordt verdaagd.` | postponed |
  | `Le Conseil prend connaissance.` | `De Raad neemt kennis.` | other |
  | `Le Conseil prend acte.` | `De Raad neemt akte.` | other |
  | `Le Conseil est informé.` | `De Raad wordt geïnformeerd.` | other |
  | `Le Conseil prend acte et répond en séance.` | `De Raad neemt akte en antwoordt in zitting.` | other |
  | `Le Conseil prend acte et répondra par écrit.` | `De Raad neemt akte en zal schriftelijk beantwoorden.` | other |

- **Vote:** one complete tally directly under the outcome in both languages, and they must
  agree. Per-candidate secret-ballot counts are not one tally, so no vote is recorded.
- **Non-votable points** (interpellation, oral question, council information, communication)
  never become decisions ([ADR 0005](../adr/0005-publish-only-votable-points.md)). They are
  counted as `non_votable`.

Any other point is left out and stays unknown. It is listed in the receipt and in one
`minutes_items_unmatched` review case that does not block the page
([ADR 0006](../adr/0006-partial-minutes-publish.md)). A `DECIDE` paragraph alone is never
read as an outcome. A document failing an identity or structure check records nothing and
opens a `normalization_ambiguity` case.

A point with no agenda row is recorded under its printed dated identifier, with no proposal.
A meeting with no normalized agenda, such as 264, publishes this way. If that agenda is
normalized later, its points arrive as separate items and need review.

## Requeue after a deploy

Run on the live release, so queued jobs reach its Oban queues. Windows default to meetings
from 2026-01-01. Hash-pinned minutes (267) report `recorded_contract` and are not requeued.
Minutes without an accepted extraction report `no_accepted_extraction` and stay unknown. On
2026-11-03 that is 268 and 269, whose ordinary extraction failed with `resource_limit`.
[Large PDF native recovery](large-pdf-native-recovery.md) does not apply: it accepts only
oversized supporting documents, and its runs stay held from normalization. A held run reports
`extraction_only_hold` and is not requeued.

```bash
ssh hetzner
C=$(docker ps --format '{{.Names}}' | grep '^sn1f08alzbb5reus2ynxrswz-' | head -1)

# 1. Dry run. Writes nothing. Read every unmatched point before going on.
docker exec "$C" /app/bin/brussels_wtf rpc 'BrusselsWtf.Ingestion.IxellesMinutesBackfill.dry_run()'

# 2. Queue the same window once. Each meeting then generates coverage, which is paid in paid mode.
docker exec "$C" /app/bin/brussels_wtf rpc 'BrusselsWtf.Ingestion.IxellesMinutesBackfill.requeue()'

# 3. After the normalize and publish queues drain, compare reading and published state.
docker exec "$C" /app/bin/brussels_wtf rpc 'BrusselsWtf.Ingestion.IxellesMinutesBackfill.receipt()'
```

Per meeting, `points` equals `decided + non_votable + unmatched`. When `recorded` equals
`decided` and `published` is lower, the revision has not passed the gate yet: check
`/review` for a publication case on that meeting.

The requeue is idempotent per release: a job under the same normalization contract that
already succeeded is reported as `queued=false`.

## Check the result

- `/meetings/ixelles/266?lang=fr`, `?lang=nl` and `?lang=en` show the decisions at the same
  URL and item anchors, with the earlier revision kept.
- `/coverage/contested-votes` lists any published contested tally.
