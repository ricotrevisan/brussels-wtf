# Ixelles mandate access observation — 2026-09-03T14:29Z

This byte-free observation accompanies the 2026-09-03 Ixelles mandate access spike. No response body, source record, credential, cookie, or personal data is retained.

## Target

- URL: `https://www.ixelles.be/site/fr/download/transparence/mandats-2024.pdf`
- Index: `https://www.ixelles.be/site/773-Rapports-annuels-Remunerations-et-avantages?langue=fr`
- Reporting year resolved from the index: `2024`
- Methods: `HEAD` (default check) and a gated in-memory `GET` (`--fetch-document`), both discarded
- User agent: `brussels-wtf-mandate-access-preflight/1.0`

## Response metadata

- Status: `200`
- Content-Type: `application/pdf`
- Content-Length: `5206831`
- ETag: `"4f732f-64eddc3de826c"`
- Last-Modified: `Tue, 07 Apr 2026 12:17:21 GMT`
- Accept-Ranges: `bytes`
- SHA-256 (of the in-memory bytes): `c5b717d6243bd8ad3957f486ca9408a153c636927314642d03ec50e4505fbca2`

## Structural signals (no personal data)

- Text segments parsed: `89`
- Segments carrying the `MANDATS` header: `7`
- Segments carrying the `FONCTIONS DÉRIVÉES` header: `3`
- Segments containing a parseable mandate row: `6`

## Interpretation

The exact document is reachable and its version signals resolve, but the download path sits under the `robots.txt`-disallowed `/site/fr/` prefix and the municipality publishes no reuse licence. The body was fetched only in memory under the explicit `--fetch-document` flag and discarded; no bytes were written or committed. Automated retrieval and republication remain blocked.
