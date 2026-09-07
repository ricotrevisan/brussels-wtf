# Inspected Ixelles 2024 declaration

`approved-2024.extract.txt` contains only allowlisted OCR lines from physical
pages 14 and 17 of the official 132-page compilation. Empty form-feed pages
preserve physical citation numbers. It is a deliberately reduced extraction,
not a PDF or a substitute for checking the archived PDF hash and OCR provenance.
No fiscal rows, income, private identifiers, addresses or signature images are
included. Other integration fixtures are explicitly synthetic.

Source: https://www.ixelles.be/site/fr/download/transparence/mandats-2024.pdf

SHA-256: `c5b717d6243bd8ad3957f486ca9408a153c636927314642d03ec50e4505fbca2`

Inspected 2026-09-07; 5,206,831 bytes. The official index links this exact URL:
https://www.ixelles.be/site/773-Rapports-annuels-Remunerations-et-avantages?langue=fr

Page 14 identifies Gautier CALOMNE above MANDATS and contains the exact row
`Premier Echevin et Officier de l'Etat Civil (Décembre 2024)`. The first slice
covers that municipal executive mandate for December 1–31, 2024 only. The other
council-role row is outside this contract. Page 17 contains the dated attestation
`Fait à Ixelles, le 30 septembre 2025`, the typed declarant name, and a visually
confirmed handwritten signature. The word “Signature” alone proves nothing;
production accepts this inspected byte version, not arbitrary signed-looking OCR.

The PDF was acquired privately under the operator authorization already recorded
on issue 46. Full raw and OCR PDF artifacts remain private evidentiary material.
Only validated minimal declaration text is retained as derived text. Public
projection excludes the attestation and signature material as well.

## Reproducible extraction contract

A disposable container using the production Debian Bookworm base and production
PDF packages successfully processed the actual bytes with:

```
ocrmypdf --force-ocr --tesseract-pagesegmode 6 --pages 14,17 \
  --language fra+nld --jobs 1 --output-type pdf --rotate-pages input.pdf output.pdf
pdftotext -layout output.pdf output.txt
```

The default redo-OCR profile duplicated existing text. Force-OCR without page
segmentation mode 6 missed table headers. The selected profile produced the
minimal fixture; `Nam` is the observed field-label OCR artifact and table borders
produce `|`, `[` and `O` decorations. Only those structural decorations are
recognized; complete names and role text still match exactly after Unicode,
case and whitespace normalization. The parser does not fuzzy-correct names.
Poppler runs first, but the known scanned source's noisy embedded layer cannot
satisfy source-specific quality, so the two inspected pages require OCR.

The profile is included in OCR processing inputs and config hash; verification
reruns the same isolated OCR profile. Unknown checksums, unsigned inspections,
changed rows, ambiguous identities or absent independent minutes corroboration
produce review cases without publication. A newly corrected report needs a new
inspected registry entry with a higher revision for the same semantic key;
verification then supersedes the predecessor while retaining dated evidence.
The runtime does not accept operator-supplied contract overrides. Synthetic
contracts are enabled only by the test compilation configuration.
