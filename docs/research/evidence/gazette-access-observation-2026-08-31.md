# Gazette access observation — 2026-08-31T17:26:55Z

This byte-free observation accompanies the 2026-08-31 access spike. No response body, source record, credential, cookie, or personal data is retained.

## Request

- Method: `POST`
- URL: `https://www.ejustice.just.fgov.be/cgi_tsv/tsv_rech.pl?language=fr`
- Encoding: `application/x-www-form-urlencoded`
- Public legal-entity identifier: `btw=0403201185`
- Submit controls: `language=fr`, `rech=Recherche`
- Blank named form controls: `naam`, `postkode`, `localite`, `hrc`, `pdda`, `pddm`, `pddj`, `pdfa`, `pdfm`, `pdfj`, `numpu`, `land`, `akte`, `jvorm`
- User agent: Python Requests default (`python-requests/2.x`)
- Redirect policy: follow redirects

## Response metadata

- Status: `500`
- Redirect chain: none
- Effective URL: `https://www.ejustice.just.fgov.be/cgi_tsv/tsv_rech.pl?language=fr`
- `Date`: `Mon, 31 Aug 2026 17:26:55 GMT`
- `Content-Type`: `text/html`
- Body length observed and discarded: `9205` bytes
- `Content-Length`, `Server`, `Cache-Control`: not supplied

## Interpretation

This exact attempt failed. The CGI contract is undocumented, so the result does not establish that the request is supported or that the interactive browser service is generally down. It does not resolve an exact annex record or prove access/reuse permission. The implementation gate remains closed.
