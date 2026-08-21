# CBE Open Data private enrichment

The application reads a privately provisioned full CBE Open Data release. It does not scrape or systematically reuse CBE Public Search.

1. Register for [CBE Open Data](https://economie.fgov.be/en/themes/enterprises/crossroads-bank-enterprises/services-everyone/public-data-available-reuse/cbe-open-data), accept its current terms, and download a full release. The FPS also documents optional registered SFTP access.
2. Retain the downloaded archive privately and record its SHA-256 digest.
3. Extract the release into a private, read-only directory containing `meta.csv`, `code.csv`, `enterprise.csv`, `establishment.csv`, and `denomination.csv`. The expected format is defined by the official [CBE Open Data cookbook](https://economie.fgov.be/sites/default/files/Files/Entreprises/BCE/Cookbook-BCE-Open-Data.pdf).
4. Mount that directory only into the `PROCESS_ROLE=app` service. Set `CBE_OPEN_DATA_DIRECTORY` to the mounted path and `CBE_OPEN_DATA_SHA256` to the lowercase or uppercase 64-character digest, then redeploy.

Both variables are required together. With neither variable present, enrichment stays fail-closed through `BrusselsWtf.CBE.Unconfigured`. Partial configuration prevents the release from starting.

The adapter accepts full releases only. It streams the official CSV data for explicit enterprise-number lookups, records the extract number, snapshot date, format version, and supplied archive digest, and ignores contact and address files. Natural-person registrations remain marked as such and cannot create a legal entity. The application queue handles enrichment asynchronously at concurrency one, so these scans do not block neutral meeting publication.
