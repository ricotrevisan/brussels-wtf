# First real Ixelles publication

Issue [Publish real Ixelles meeting 268 end to end](https://github.com/RicoTrevisan/brussels-wtf/issues/31) introduces a narrow recorded normalization contract for the council meeting of 2 July 2026. It exists to publish one real evidence-backed record before a general normalization provider is selected.

## Recorded official source versions

The source versions below were retrieved and checked on 21 August 2026.

| Role | Authoritative origin | SHA-256 | Size | Pages |
| --- | --- | --- | ---: | ---: |
| Complementary agenda | `https://www.ixelles.be/uploads/conseil/odj/268.pdf` | `f412ee4ddc45b454691fff79b190e36de0ae60fe6b696ae7861c82557b38fd4b` | 216,552 bytes | 25 |
| Public explanatory notes | `https://www.ixelles.be/uploads/conseil/projets/268.pdf` | `f3fddb8f231916b128b83002d2eeee82b591120b9aa556338a3992df95f9c1f4` | 2,680,949 bytes | 483 |

The full PDFs remain municipal source material and private archived evidence. Repository tests contain only small representative extracts. Their fixture hashes are not the hashes in this table.

`BrusselsWtf.Processors.RecordedIxelles268` accepts only these two raw source hashes. It also checks exact source-specific markers in the extracted text. A replaced PDF, incomplete extraction, changed wording, or different document remains unsupported or creates a normalization ambiguity for review.

## Deployment replay

After deploying the contract:

1. Sign in at `/review`.
2. Filter for open Ixelles normalization cases.
3. Open the cases for the two authoritative origins above and use the audited retry action. The retry creates a new processing generation and does not alter the existing source version or prior processing evidence.
4. If the source versions have not been observed, use **Operational polling** to poll Ixelles, then retry only the two matching normalization cases.
5. Confirm `/meetings/ixelles/268?lang=fr`, `?lang=nl`, and `?lang=en` render the same meeting identity and official citations.
6. Confirm the Timeline links to agenda item `4` and no synthetic seed record is public.

Do not run a broad historical backfill for this slice. Other source hashes remain unsupported until a later normalizer handles them.
