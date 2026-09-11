# Uccle current-index capture

`current-index-2026.html` is an unchanged contiguous extract of the official
[council page](https://www.uccle.be/fr/ma-commune/le-conseil-communal), fetched on
2026-09-11. It starts at the public meeting-calendar heading and ends after the
last meeting table. Navigation, contacts, and unrelated content are omitted.
Only published index markup is retained; no PDFs are redistributed here.

- Full captured HTML: 253,591 bytes; SHA-256
  `0441ccffc940431b61213442525c5c2456af1788f68653c8f3d6715f0d61e943`.
- Fixture extract: 44,049 bytes; SHA-256
  `063915e4fd3617360bb058e09ec2488fc9b729be0de58fe8d436d3bfb1f49662`.
- September 10 has four links: base/complementary agendas and explanatory notes.
  Its register cell is blank. No outcome follows from this absence.
- The visible calendar lists October 15, November 19, and December 10, 2026.
  Meeting-table captions contain only day/month. URL filenames are not dates.
  The adapter therefore supports the audited 2026 current-table context only.
  A missing, mixed, or changed calendar year fails for review. Rollover needs
  renewed authoritative year evidence; the system clock cannot supply it.
- January includes linked question URLs containing 2025; June includes a `..pdf`
  suffix. Both are exact observed locators, not filename conventions to correct.

Full source identities and the research method are recorded in
`docs/research/2026-09-11-current-coverage-scope.md` (incident research branch).

## Independent full-date corroboration for this capture

On 2026-09-11, fetched the first main-agenda link from each captured table,
with a 2 MB limit per request. All seven returned HTTP 200. Poppler extracted
PDF page 1. The exact printed headings below independently corroborate all
seven full meeting dates in the audited capture. The parser does **not** fetch
these PDFs or use their filenames to assign dates. Its runtime year context
is the same-section HTML calendar, bounded to this audited 2026 layout.
These local research downloads are not application retrieval observations.
Full PDFs and signatures are not committed.

| Exact linked source | PDF page 1 heading | SHA-256 | Bytes |
| --- | --- | --- | ---: |
| [10 septembre](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-09-10-ODJ-U1180_fr_nl.pdf) | `CONSEIL COMMUNAL DU 10 SEPTEMBRE 2026` | `598c08038e057f58455e7f1d47f4a5ed7b9e2b12078827323c12482db3331b2a` | 87,392 |
| [25 juin](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-06-25-ODJ-U1180_fr_nl.pdf) | `CONSEIL COMMUNAL DU 25 JUIN 2026` | `985bfcc975ae6723c67a6c1cc1934c24b9e7d8ab69cd853e0a4ab271095bfca3` | 80,333 |
| [28 mai](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-05-28-ODJ-bis-2_U1180_fr_nl.pdf) | `CONSEIL COMMUNAL DU 28 MAI 2026` | `3cd46c4158acab843a9aaed2b2415e7e676be031bc37f7b1380b4645d2c2a8d7` | 68,213 |
| [23 avril](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-04-23-ODJ_U1180_fr_nl.pdf) | `CONSEIL COMMUNAL DU 23 AVRIL 2026` | `6f925fc048dd877a76bd164993964bc1e84365a65463e5976faa83ead9c83280` | 75,524 |
| [19 mars](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-03-19-OJ_U1180_fr_nl.pdf) | `CONSEIL COMMUNAL DU 19 MARS 2026` | `0aa9487ae3a43d9a5628163e1784e3bcb0ee4a80cf27474d729dd3e4028d05f2` | 81,245 |
| [12 février](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-02-12-ODJ_U1180_fr_nl.pdf) | `CONSEIL COMMUNAL DU 12 FÉVRIER 2026` | `d1153b8dec19f54def0b79cde47f8417766791e981d7273328d3a84725131ad6` | 51,056 |
| [22 janvier](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-01-22-ODJ_U1180_fr_nl.pdf) | `CONSEIL COMMUNAL DU 22 JANVIER 2026` | `8af0cd6040ed12eb34ffe08420a3122b7f310146421bf402e9b1b789d3460dd6` | 60,976 |

### Fail-closed limits

- Only the exact current calendar heading and its immediately following
  dated Thursday list supply year context. Notice/footer years do not.
- Every linked table date must precede the earliest listed calendar session.
  An equal date fails too: this conservative contract does not yet support a
  newly posted upcoming table while the same session remains in that list.
- Mixed years, rollover to another year, missing/full conflicting caption
  dates, invalid calendar dates, and possible December leftovers fail review.
- A bare January caption cannot by itself distinguish a prior-year leftover
  from the current January meeting. The seven PDF headings corroborate this
  captured page, not every possible future edit. Source normalization must
  independently validate document identity before any publication.
- New year/layout support needs a renewed source audit. The system clock and
  arbitrary question/motion filenames are never year authorities.
